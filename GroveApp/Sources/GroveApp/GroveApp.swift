import CoreSpotlight
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
    @ViewState private var settings: AppSettings
    @ViewState private var session: MeetingSession
    @ViewState private var library: MeetingLibrary

    /// Held for its lifetime, not its value: it owns the floating panel and must
    /// outlive the main window, since the point of the overlay is to still be
    /// there when you are working in another app.
    @ViewState private var overlay: RecordingOverlayController

    /// Held for its lifetime too: it watches for calls whether or not any
    /// window is open.
    @ViewState private var watcher: MeetingWatcher
    @ViewState private var google: GoogleConnection
    @ViewState private var quickNotes: QuickNotesController

    init() {
        let settings = AppSettings()
        let session = MeetingSession(settings: settings)
        let library = MeetingLibrary(settings: settings)
        let google = GoogleConnection(settings: settings)
        session.calendarLookup = { google.currentEvent() }
        session.onSaved = { meeting in
            google.meetingSaved(meeting)
            if settings.remindAboutPromises {
                CommitmentReminders.schedule(for: meeting, myName: settings.userName)
            }
        }
        google.meetingsProvider = { library.meetings }
        _google = State(initialValue: google)
        _quickNotes = State(initialValue: QuickNotesController(session: session))
        _settings = State(initialValue: settings)
        _session = State(initialValue: session)
        _library = State(initialValue: library)
        let stopAndReload: @MainActor () async -> Void = {
            await session.stop()
            library.reload()
        }
        _overlay = State(
            initialValue: RecordingOverlayController(
                session: session, settings: settings, stop: stopAndReload))
        _watcher = State(
            initialValue: MeetingWatcher(
                session: session, settings: settings, stop: stopAndReload))
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
            .environment(google)
            .tint(.grove)
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
                .disabled(session.isBusy && !session.isRecording)

                Button(session.isPaused ? "Resume Recording" : "Pause Recording") {
                    session.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!session.isRecording)

                Button("Go to…") { AppSheet.palette.show() }
                    .keyboardShortcut("k")

                // The real shortcut is the global ⌃⌥N hot key, which works from
                // any app; this entry is how people find out it exists.
                Button("Quick Notes  \(QuickNotesShortcut.label)") {
                    NotificationCenter.default.post(name: .toggleQuickNotes, object: nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(library)
                .environment(google)
                .tint(.grove)
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
    static let toggleQuickNotes = Notification.Name("app.grove.toggleQuickNotes")
    /// userInfo "sheet": an `AppSheet` raw value.
    static let showAppSheet = Notification.Name("app.grove.showAppSheet")
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

        Button("Quick Notes  \(QuickNotesShortcut.label)") {
            NotificationCenter.default.post(name: .toggleQuickNotes, object: nil)
        }

        if !session.isBusy {
            // A lecture has no call to detect, so it gets its own one-click start.
            Button("Record In Person (Lecture)") {
                session.inPerson = true
                session.templateID = NoteTemplate.lecture.id
                Task { await session.start() }
            }
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
    @ViewState private var selection: Meeting.ID?
    @ViewState private var showingNewMeeting = false
    @ViewState private var transcriptSeek: TranscriptSeek?
    @ViewState private var appSheet: AppSheet?

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
        .sheet(item: $appSheet) { sheet in
            switch sheet {
            case .chat: ChatView()
            case .actionItems: ActionItemsView()
            case .digest: DigestView()
            case .palette: CommandPalette()
            case .people: InsightsView(tab: .people)
            case .decisions: InsightsView(tab: .decisions)
            case .waiting: InsightsView(tab: .waiting)
            case .questions: InsightsView(tab: .questions)
            case .glossary: InsightsView(tab: .glossary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAppSheet)) { note in
            guard let raw = note.userInfo?["sheet"] as? String, let sheet = AppSheet(rawValue: raw)
            else { return }
            // One sheet at a time: close whatever is up, then open the new one.
            if appSheet != nil {
                appSheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { appSheet = sheet }
            } else {
                appSheet = sheet
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = SpotlightIndex.meetingID(from: activity) else { return }
            selection = id
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

    @ViewState private var title = ""
    @ViewState private var templateID = ""
    @ViewState private var folder: FolderChoice = .automatic
    @ViewState private var inPerson = false
    @FocusState private var titleFocused: Bool

    /// "Automatic" and "Meetings" both end with no folder chosen up front; the
    /// difference is whether Grove may file the meeting itself afterwards.
    private enum FolderChoice: Hashable {
        case automatic
        case topLevel
        case named(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Meeting").font(.headline)

            Form {
                TextField(
                    "Title", text: $title,
                    prompt: Text(settings.autoOrganize ? "Named for you when it ends" : "Optional"))
                    .focused($titleFocused)
                    .onSubmit(start)

                Picker("Template", selection: $templateID) {
                    ForEach(library.templates) { Text($0.name).tag($0.id) }
                }

                Toggle("In person — a lecture or a room, not a call", isOn: $inPerson)
                    .onChange(of: inPerson) { _, isOn in
                        if isOn, templateID == NoteTemplate.general.id {
                            templateID = NoteTemplate.lecture.id
                        }
                    }

                Picker("Folder", selection: $folder) {
                    if settings.autoOrganize {
                        Text("Choose for me").tag(FolderChoice.automatic)
                    }
                    Text("Meetings").tag(FolderChoice.topLevel)
                    ForEach(library.allFolders, id: \.self) { name in
                        Text(name).tag(FolderChoice.named(name))
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
            if !settings.autoOrganize { folder = .topLevel }
            titleFocused = true
        }
    }

    private func start() {
        session.title = title
        session.templateID = templateID.isEmpty ? settings.defaultTemplateID : templateID
        session.inPerson = inPerson
        switch folder {
        case .automatic:
            session.folder = nil
            session.folderIsAutomatic = true
        case .topLevel:
            session.folder = nil
            session.folderIsAutomatic = false
        case .named(let name):
            session.folder = name
            session.folderIsAutomatic = false
        }
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
