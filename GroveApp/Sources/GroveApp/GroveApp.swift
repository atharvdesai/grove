import GroveKit
import SwiftUI

/// Keeps auxiliary windows from outliving the main one.
///
/// Closing the Grove window left the Settings window floating on its own: the
/// app was still running for the menu-bar item, so macOS kept the orphan
/// on screen with nothing behind it. Settings is a companion to the main
/// window, not a document, so it should not survive it.
///
/// Quitting is deliberately left alone. Grove lives in the menu bar, so closing
/// the window is not the same as quitting, and terminating here would take the
/// recorder down mid-meeting.
final class WindowCoordinator: NSObject, NSApplicationDelegate {
    private var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let closing = note.object as? NSWindow else { return }
            // Deferred: at willClose the window still counts as open, so the
            // "is anything left?" question can only be answered afterwards.
            DispatchQueue.main.async { self?.closeAuxiliaryWindowsIfMainIsGone(besides: closing) }
        }
    }

    private func closeAuxiliaryWindowsIfMainIsGone(besides closed: NSWindow) {
        let candidates = NSApp.windows.filter {
            $0 !== closed && $0.isVisible && $0.styleMask.contains(.titled)
        }
        guard !candidates.contains(where: isMain) else { return }
        for window in candidates where !isMain(window) {
            window.close()
        }
    }

    /// The main window is the one the `Window(id: "main")` scene owns. Its title
    /// is stable; the Settings window's is not — it takes the selected tab's
    /// name, so it reads "Permissions" or "Notes" depending on where you were.
    private func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "main" || window.title == "Grove"
    }
}

@main
struct GroveApp: App {
    @NSApplicationDelegateAdaptor(WindowCoordinator.self) private var windowCoordinator
    @State private var settings: AppSettings
    @State private var session: MeetingSession
    @State private var library: MeetingLibrary

    /// Held for its lifetime, not its value: it owns the floating panel and must
    /// outlive the main window, since the point of the overlay is to still be
    /// there when you are working in another app.
    @State private var overlay: RecordingOverlayController

    init() {
        let settings = AppSettings()
        let session = MeetingSession(settings: settings)
        let library = MeetingLibrary(settings: settings)
        _settings = State(initialValue: settings)
        _session = State(initialValue: session)
        _library = State(initialValue: library)
        _overlay = State(
            initialValue: RecordingOverlayController(session: session, settings: settings) {
                await session.stop()
                library.reload()
            })
    }

    var body: some Scene {
        Window("Grove", id: "main") {
            Group {
                if settings.hasCompletedOnboarding {
                    RootView().frame(minWidth: 860, minHeight: 540)
                } else {
                    OnboardingView()
                }
            }
            .environment(settings)
            .environment(session)
            .environment(library)
            .preferredColorScheme(settings.appearance.colorScheme)
        }
        .defaultSize(width: 1040, height: 660)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Meeting…") { NotificationCenter.default.post(name: .newMeeting, object: nil) }
                    .keyboardShortcut("n")
                    .disabled(session.isBusy)

                Button(session.isRecording ? "Stop Recording" : "Start Recording") {
                    Task { await toggleRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session.phase == .starting || session.phase == .finishing
                    || session.phase == .enhancing)

                Button(session.isPaused ? "Resume Recording" : "Pause Recording") {
                    session.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!session.isRecording)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(library)
                .preferredColorScheme(settings.appearance.colorScheme)
        }

        // The menu bar is the point of an app like this: the meeting is happening
        // in another window, and starting a recording should never require
        // hunting for ours.
        MenuBarExtra("Grove", systemImage: menuBarSymbol) {
            MenuBarContent(toggleRecording: toggleRecording)
                .environment(session)
        }
    }

    private var menuBarSymbol: String {
        if session.isPaused { return "pause.circle.fill" }
        return session.isCapturing ? "record.circle.fill" : "circle.dotted"
    }

    private func toggleRecording() async {
        if session.isRecording {
            await session.stop()
            library.reload()
        } else {
            await session.start()
        }
    }
}

extension Notification.Name {
    static let newMeeting = Notification.Name("app.grove.newMeeting")
    /// Posted by chat citations. userInfo: "meetingID" (UUID), "time"
    /// (TimeInterval) — the transcript moment to open.
    static let navigateToMeeting = Notification.Name("app.grove.navigateToMeeting")
}

private struct MenuBarContent: View {
    @Environment(MeetingSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    let toggleRecording: () async -> Void

    var body: some View {
        if session.isRecording {
            Text(session.isPaused ? "Paused — \(session.elapsed.clockString)"
                : "Recording — \(session.elapsed.clockString)")
        } else if session.isBusy {
            Text(session.statusText)
        }

        Button(session.isRecording ? "Stop Recording" : "Start Recording") {
            Task { await toggleRecording() }
        }
        .disabled(session.isBusy && !session.isRecording)

        if session.isRecording {
            Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
        }

        Button("Open Grove") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Divider()
        Button("Quit Grove") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Library on the left, live meeting or a saved one on the right.
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library
    @State private var selection: Meeting.ID?
    @State private var showingNewMeeting = false
    @State private var transcriptSeek: TranscriptSeek?

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if session.isBusy {
                RecordingView()
            } else if let meeting = library.meetings.first(where: { $0.id == selection }) {
                MeetingDetailView(meeting: meeting, seek: $transcriptSeek)
            } else {
                HomeView(newMeeting: { showingNewMeeting = true }, selection: $selection)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HomeButton(selection: $selection)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if session.isRecording {
                    Button {
                        session.togglePause()
                    } label: {
                        Label(
                            session.isPaused ? "Resume" : "Pause",
                            systemImage: session.isPaused ? "play.fill" : "pause.fill")
                    }
                    .help(session.isPaused ? "Resume recording" : "Pause recording")
                }
                RecordButton { showingNewMeeting = true }
            }
        }
        .sheet(isPresented: $showingNewMeeting) {
            NewMeetingSheet()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { session.errorMessage != nil || library.loadError != nil },
                set: { if !$0 { session.dismissError(); library.loadError = nil } })
        ) {
            Button("OK") { session.dismissError(); library.loadError = nil }
        } message: {
            Text(session.errorMessage ?? library.loadError ?? "")
        }
        .task { library.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMeeting)) { note in
            guard let id = note.userInfo?["meetingID"] as? UUID else { return }
            selection = id
            if let time = note.userInfo?["time"] as? TimeInterval {
                transcriptSeek = TranscriptSeek(meetingID: id, time: time)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMeeting)) { _ in
            guard !session.isBusy else { return }
            showingNewMeeting = true
        }
        .onChange(of: session.lastSaved) { _, saved in
            guard let saved else { return }
            library.reload()
            selection = saved.id
        }
    }
}

/// Toolbar control: start a new meeting, or stop the running one.
///
/// It says "New Meeting" rather than "Record" because of where it sits. Above an
/// open meeting, a button labelled "Record" reads as *record into this meeting*,
/// and it does the opposite — it starts a fresh one. Naming the action removes
/// the ambiguity that position creates. Recording into the meeting you are
/// looking at is `Resume`, which lives on the meeting itself.
///
/// Prominence comes from the red dot, not from a filled blue slab, which was too
/// loud for a toolbar sitting above quiet text. Stop earns the solid treatment:
/// it is momentary, destructive of the recording, and should be hard to miss.
struct RecordButton: View {
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library
    let newMeeting: () -> Void

    var body: some View {
        if session.isRecording {
            Button {
                Task {
                    await session.stop()
                    library.reload()
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Stop and write up the meeting")
        } else {
            Button(action: newMeeting) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    Text("New Meeting")
                }
            }
            .buttonStyle(.bordered)
            .disabled(session.isBusy)
            .help("Name a meeting and start recording (⌘N)")
        }
    }
}

/// Asks for a name before recording starts.
///
/// Naming afterwards is possible too, but a meeting you have to rename later is
/// a meeting saved as "Meeting Sunday 12:48", and a library full of those is
/// unnavigable. Everything here is optional — Return starts recording.
private struct NewMeetingSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var templateID = ""
    @State private var folder: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Meeting").font(.headline)

            Form {
                TextField("Title", text: $title, prompt: Text("Optional"))
                    .focused($titleFocused)
                    .onSubmit(start)

                Picker("Template", selection: $templateID) {
                    ForEach(NoteTemplate.builtIns) { Text($0.name).tag($0.id) }
                }

                Picker("Folder", selection: $folder) {
                    Text("Meetings").tag(String?.none)
                    ForEach(library.allFolders, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start Recording", action: start)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            templateID = settings.defaultTemplateID
            titleFocused = true
        }
    }

    private func start() {
        session.title = title
        session.templateID = templateID.isEmpty ? settings.defaultTemplateID : templateID
        session.folder = folder
        dismiss()
        Task { await session.start() }
    }
}

/// Returns to the home screen by clearing the selection — a "home" affordance,
/// since a sidebar list has no natural way back to nothing-selected.
struct HomeButton: View {
    @Binding var selection: Meeting.ID?

    var body: some View {
        Button { selection = nil } label: {
            Label("Home", systemImage: "house")
        }
        .disabled(selection == nil)
        .help("Back to the home screen")
    }
}
