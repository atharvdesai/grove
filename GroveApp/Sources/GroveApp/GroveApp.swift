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
                    RootView().frame(minWidth: 880, minHeight: 560)
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
        .defaultSize(width: 1120, height: 720)
        // No title bar: the sidebar and the content card run to the top edge,
        // with the traffic lights sitting on the canvas. The background still
        // drags the window, as a title bar would.
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
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

/// The window: sidebar on the tinted canvas, the current page on a card.
///
/// The card-on-canvas shape is borrowed from Arc. It gives every page the same
/// frame, keeps the sidebar visually quiet without a divider, and leaves the
/// traffic lights sitting on the canvas rather than over content.
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var destination: Destination = .home
    @ViewState private var sidebarVisible = true
    @ViewState private var transcriptSeek: TranscriptSeek?

    /// The one sheet slot. Every app-level sheet goes through it, so two can
    /// never be up, or half-up, at once.
    @ViewState private var appSheet: AppSheet?
    /// What to do once the current sheet has finished closing: usually
    /// opening the next one. Run from `onDismiss`, never on a timer, because a
    /// sheet presented while another is still animating out is exactly the
    /// sheet whose Done button stops working.
    @ViewState private var afterSheet: (() -> Void)?

    /// `destination`, corrected for things that have gone away: the live
    /// page once the meeting is written up, a meeting that was deleted.
    private var shown: Destination {
        switch destination {
        case .live where !session.isBusy:
            return .home
        case .meeting(let id) where !library.meetings.contains(where: { $0.id == id }):
            return .home
        default:
            return destination
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                Sidebar(
                    destination: $destination,
                    newMeeting: { present(.newMeeting) },
                    hide: { withAnimation(Motion.respecting(reduceMotion)) { sidebarVisible = false } })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            ZStack {
                page
                    .id(shown)
                    .transition(
                        reduceMotion
                            ? AnyTransition.opacity
                            : AnyTransition.asymmetric(
                                insertion: AnyTransition.opacity.combined(with: .offset(y: 6)),
                                removal: AnyTransition.opacity))
            }
            .animation(Motion.respecting(reduceMotion, Motion.gentle), value: shown)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.groveCard)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 2)
            .padding(.top, sidebarVisible ? 8 : 40)
            .padding([.trailing, .bottom], 8)
            .padding(.leading, sidebarVisible ? 0 : 8)
        }
        .overlay(alignment: .topLeading) {
            if !sidebarVisible {
                Button {
                    withAnimation(Motion.respecting(reduceMotion)) { sidebarVisible = true }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(CircleIconStyle(size: 26))
                .foregroundStyle(.secondary)
                .keyboardShortcut("s", modifiers: [.control, .command])
                .help("Show the sidebar (⌃⌘S)")
                // Clear of the traffic lights.
                .padding(.leading, 78)
                .padding(.top, 7)
            }
        }
        .background(Color.groveCanvas)
        .ignoresSafeArea()
        .sheet(item: $appSheet, onDismiss: runAfterSheet) { sheet in
            sheetContent(sheet)
                .environment(
                    \.closeSheet,
                    CloseSheetAction { then in
                        afterSheet = then
                        appSheet = nil
                    })
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAppSheet)) { note in
            guard let raw = note.userInfo?["sheet"] as? String, let sheet = AppSheet(rawValue: raw)
            else { return }
            present(sheet)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = SpotlightIndex.meetingID(from: activity) else { return }
            destination = .meeting(id)
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
            destination = .meeting(id)
            if let time = note.userInfo?["time"] as? TimeInterval {
                transcriptSeek = TranscriptSeek(meetingID: id, time: time)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMeeting)) { _ in
            guard !session.isBusy else { return }
            present(.newMeeting)
        }
        // However a meeting starts — this window, the menu bar, the call
        // prompt — the window follows it to the live page.
        .onChange(of: session.isBusy) { _, busy in
            if busy { destination = .live }
        }
        .onChange(of: session.lastSaved) { _, saved in
            guard let saved else { return }
            library.reload()
            destination = .meeting(saved.id)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch shown {
        case .live:
            RecordingView()
        case .meeting(let id):
            if let meeting = library.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting, seek: $transcriptSeek)
            }
        case .ask:
            ChatView()
        case .actionItems:
            ActionItemsView()
        case .insights(let tab):
            InsightsView(tab: tab)
        case .home:
            HomeView(newMeeting: { present(.newMeeting) }, destination: $destination)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .newMeeting: NewMeetingSheet()
        case .digest: DigestView()
        case .palette: CommandPalette()
        // Pages, routed in `present` and never shown as sheets.
        case .chat, .actionItems, .people, .decisions, .waiting, .questions, .glossary:
            EmptyView()
        }
    }

    /// Shows a sheet — first closing whatever is up and waiting for it to go
    /// — or, for the cases that are pages, navigates there.
    private func present(_ sheet: AppSheet) {
        if let page = sheet.page {
            if appSheet == nil {
                destination = page
            } else {
                afterSheet = { destination = page }
                appSheet = nil
            }
            return
        }
        guard appSheet != sheet else { return }
        if appSheet == nil {
            appSheet = sheet
        } else {
            afterSheet = { appSheet = sheet }
            appSheet = nil
        }
    }

    private func runAfterSheet() {
        guard let next = afterSheet else { return }
        afterSheet = nil
        DispatchQueue.main.async(execute: next)
    }
}

extension AppSheet {
    /// The page this opens, for the destinations that live in the window
    /// rather than in a sheet.
    var page: Destination? {
        switch self {
        case .chat: return .ask
        case .actionItems: return .actionItems
        case .people: return .insights(.people)
        case .decisions: return .insights(.decisions)
        case .waiting: return .insights(.waiting)
        case .questions: return .insights(.questions)
        case .glossary: return .insights(.glossary)
        case .newMeeting, .digest, .palette: return nil
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
    @CloseSheet private var close

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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                IconTile(systemName: "record.circle.fill", size: 34, tint: .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Meeting").font(.headline)
                    Text("Everything here is optional — Return starts recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 16)

            TextField(
                "Title", text: $title,
                prompt: Text(settings.autoOrganize ? "Named for you when it ends" : "Meeting title"))
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .surface(cornerRadius: Metrics.controlRadius)
                .focused($titleFocused)
                .onSubmit(start)
                .padding(.bottom, 14)

            Form {
                Picker("Template", selection: $templateID) {
                    ForEach(library.templates) { Text($0.name).tag($0.id) }
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

                Toggle("In person — a lecture or a room, not a call", isOn: $inPerson)
                    .onChange(of: inPerson) { _, isOn in
                        if isOn, templateID == NoteTemplate.general.id {
                            templateID = NoteTemplate.lecture.id
                        }
                    }
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(action: start) {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .buttonStyle(ProminentCapsuleStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(22)
        .frame(width: 440)
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
        // Recording starts once the sheet is gone, so the recording screen
        // animates in over a settled window rather than under a closing sheet.
        close { Task { await session.start() } }
    }
}
