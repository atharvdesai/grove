import Observation
import GroveKit
import SwiftUI
import UniformTypeIdentifiers

/// A one-shot request to open a meeting's transcript at a moment, posted by
/// chat citations and carried down to the detail view. The nonce keeps two
/// requests for the same moment distinct, so `.onChange` fires every time —
/// otherwise clicking the same citation twice would do nothing the second time.
struct TranscriptSeek: Equatable {
    let meetingID: Meeting.ID
    let time: TimeInterval
    let nonce = UUID()
}

/// Saved meetings, read straight off disk.
///
/// There is no database and no index: `MeetingStore` reads the same Markdown and
/// JSON folders a user can open in Finder or Obsidian. Re-reading on demand is
/// what keeps "your data stays readable without us" true rather than aspirational
/// — the app is just another reader of those files.
@MainActor
@Observable
final class MeetingLibrary {
    private(set) var meetings: [Meeting] = []
    private(set) var folders: [String] = []
    /// Built-in templates followed by the user's own.
    private(set) var templates: [NoteTemplate] = NoteTemplate.builtIns
    var loadError: String?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Resolved on each use so a storage-location change in Settings applies
    /// immediately rather than at next launch.
    var store: MeetingStore { settings.store }

    func reload() {
        do {
            meetings = try store.list()
            folders = try store.folders()
            templates = NoteTemplate.builtIns + store.customTemplates()
            loadError = nil
            SpotlightIndex.update(with: meetings)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Meetings filed under `folder`, or loose at the top level when nil.
    func meetings(in folder: String?) -> [Meeting] {
        meetings.filter { $0.folder == folder }
    }

    /// Folder names that currently hold something, plus every empty folder that
    /// exists on disk, so a folder you just made does not vanish.
    var allFolders: [String] {
        Set(folders + meetings.compactMap(\.folder))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // Each of these reloads rather than mutating the array in place: the
    // filesystem is the source of truth, and re-reading it is cheap next to
    // getting the two out of step.

    func rename(_ meeting: Meeting, to title: String) {
        perform { _ = try store.rename(meeting, to: title) }
    }

    func move(_ meeting: Meeting, to folder: String?) {
        perform { _ = try store.move(meeting, toFolder: folder) }
    }

    func delete(_ meeting: Meeting) {
        perform { try store.delete(meeting) }
    }

    var customTemplates: [NoteTemplate] { templates.filter { !$0.isBuiltIn } }

    // MARK: - Across the library

    /// Who "me" is, for telling your promises from other people's.
    var myName: String { settings.userName }

    var people: [LibraryIndex.Person] { LibraryIndex.people(in: meetings, myName: myName) }
    var decisionLog: [LibraryIndex.Decision] { LibraryIndex.decisions(in: meetings) }
    var waitingOn: [LibraryIndex.Promise] { LibraryIndex.waitingOn(meetings, myName: myName) }
    var openQuestions: [LibraryIndex.Ref] { LibraryIndex.openQuestions(in: meetings) }
    func glossary(folder: String? = nil) -> [LibraryIndex.GlossaryEntry] {
        LibraryIndex.glossary(in: meetings, folder: folder)
    }

    /// Ticks a promise off, in the same list as action items.
    func setDone(_ promise: LibraryIndex.Promise, done: Bool) {
        guard let meeting = meetings.first(where: { $0.id == promise.ref.meetingID }) else { return }
        perform { try store.save(meeting.settingActionItem(promise.commitment.task, done: done)) }
    }

    /// The meeting before this one in its series, if it has one.
    func previous(to meeting: Meeting) -> Meeting? {
        LibraryIndex.previous(
            title: meeting.title, attendees: meeting.attendees ?? [], before: meeting.startedAt,
            in: meetings)
    }

    /// Re-reads summaries and promises for meetings saved before insights
    /// existed. One model call each, so it runs only when asked.
    func analyzeOlderMeetings() async -> String {
        let missing = meetings.filter { $0.insights == nil && $0.enhancedNotes != nil }
        var done = 0
        for meeting in missing {
            let models: [any NoteWritingModel] = [settings.writingModel, FoundationModelsEngine()]
            for model in models where model.availability == .available {
                if let insights = try? await InsightExtractor(model: model).insights(for: meeting) {
                    var updated = meeting
                    updated.insights = insights
                    try? store.save(updated)
                    done += 1
                    break
                }
            }
        }
        reload()
        return missing.isEmpty ? "Every meeting is already analysed." : "Analysed \(done) of \(missing.count) meetings."
    }

    func template(id: String) -> NoteTemplate { NoteTemplate.named(id, among: templates) }

    func saveCustomTemplates(_ templates: [NoteTemplate]) {
        perform { try store.saveCustomTemplates(templates) }
    }

    func setActionItem(_ item: ActionItem, done: Bool) {
        guard let meeting = meetings.first(where: { $0.id == item.meetingID }) else { return }
        perform { try store.save(meeting.settingActionItem(item.text, done: done)) }
    }

    // MARK: - Reviewing and polishing the user's notes

    /// Polishes the meeting's own notes with the chosen engine (falling back
    /// to on-device), cites them, and saves. Returns an error message, if any.
    func polish(_ meeting: Meeting) async -> String? {
        do {
            let polished = try await withFallback { model in
                try await NotePolisher(model: model).polish(
                    roughNotes: meeting.roughNotes, transcript: meeting.transcript)
            }
            var updated = meeting
            updated.polishedNotes = polished
            perform { try store.save(updated) }
            return nil
        } catch {
            return "Couldn't polish the notes: \(error.localizedDescription)"
        }
    }

    /// Re-checks the meeting's notes against its transcript.
    func review(_ meeting: Meeting) async -> String? {
        do {
            let conflicts = try await withFallback { model in
                try await NoteChecker(model: model).check(
                    roughNotes: meeting.roughNotes, transcript: meeting.transcript)
            }
            var updated = meeting
            updated.noteConflicts = conflicts.isEmpty ? nil : conflicts
            perform { try store.save(updated) }
            return conflicts.isEmpty ? "Your notes match the transcript." : nil
        } catch {
            return "Couldn't check the notes: \(error.localizedDescription)"
        }
    }

    func resolve(_ conflict: NoteConflict, in meeting: Meeting, useSuggestion: Bool) {
        perform { try store.save(meeting.resolving(conflict, useSuggestion: useSuggestion)) }
    }

    /// Rewrites a saved meeting's notes with Claude — for meetings written
    /// on-device before Claude was set up, or ones that matter more.
    func rewriteWithClaude(_ meeting: Meeting) async -> String? {
        guard let path = settings.claudeExecutable else { return "Claude Code isn't installed." }
        do {
            let notes = try await NoteEnhancer(model: ClaudeCodeEngine(executable: path)).enhance(
                roughNotes: meeting.roughNotes, transcript: meeting.transcript,
                template: template(id: meeting.templateID), meetingTitle: meeting.title)
            var updated = meeting
            updated.enhancedNotes = TimestampLinker.link(notes: notes, transcript: meeting.transcript)
            perform { try store.save(updated) }
            return nil
        } catch {
            return "Claude couldn't rewrite the notes: \(error.localizedDescription)"
        }
    }

    /// Runs with the chosen engine, and once more on-device if that was
    /// Claude and it failed.
    private func withFallback<T>(_ work: (any NoteWritingModel) async throws -> T) async throws -> T {
        do {
            return try await work(settings.writingModel)
        } catch where settings.usesClaude {
            return try await work(FoundationModelsEngine())
        }
    }

    /// Names the far side of the call in place of "Them". Blank clears it.
    func setSpeakerName(_ name: String, for meeting: Meeting) {
        var updated = meeting
        let trimmed = name.trimmed
        updated.speakerName = trimmed.isEmpty ? nil : trimmed
        perform { try store.save(updated) }
    }

    /// Meetings matching a plain-English search: "with Janet last month",
    /// "hiring about salary". See `MeetingQuery`.
    func meetings(matching query: String) -> [Meeting] {
        guard !query.trimmed.isEmpty else { return meetings }
        let parsed = MeetingQuery.parse(query, folders: allFolders)
        return meetings.filter(parsed.matches)
    }

    func createFolder(named name: String) {
        perform { try store.createFolder(named: name) }
    }

    func deleteFolder(named name: String) {
        perform { try store.deleteFolder(named: name) }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        reload()
    }
}

struct LibrarySidebar: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(MeetingSession.self) private var session
    @Binding var selection: Meeting.ID?

    @ViewState private var renaming: Meeting?
    @ViewState private var deleting: Meeting?
    @ViewState private var newFolderName = ""
    @ViewState private var showingNewFolder = false
    @ViewState private var query = ""

    private var searching: Bool { !query.trimmed.isEmpty }

    var body: some View {
        let visible = library.meetings(matching: query)

        List(selection: $selection) {
            if session.isBusy {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: session.isPaused ? "pause.circle.fill" : "record.circle.fill")
                            .foregroundStyle(session.isPaused ? .orange : .red)
                        Text(session.isRecording ? "In progress" : session.statusText)
                            .lineLimit(1)
                    }
                    .font(.callout)
                }
            }

            // Loose meetings first, then a section per folder. A tree with
            // disclosure would nest more prettily and makes drag-to-file harder
            // to get right; sections keep everything one click away.
            let loose = visible.filter { $0.folder == nil }
            if !loose.isEmpty {
                Section("Meetings") {
                    ForEach(loose) { row(for: $0) }
                }
            }

            // While searching, a folder with no matches is just noise.
            ForEach(
                library.allFolders.filter { folder in
                    !searching || visible.contains { $0.folder == folder }
                }, id: \.self
            ) { folder in
                Section {
                    ForEach(visible.filter { $0.folder == folder }) { row(for: $0) }
                } header: {
                    HStack {
                        Label(folder, systemImage: "folder")
                        Spacer()
                    }
                    .contextMenu {
                        Button("Delete Folder", role: .destructive) {
                            library.deleteFolder(named: folder)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search meetings")
        .overlay {
            if searching && visible.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if library.meetings.isEmpty && !session.isBusy {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "tray",
                    description: Text("Recorded meetings are saved to\n\(library.store.baseDirectory.path)"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 14) {
                Button {
                    NotificationCenter.default.post(name: .newMeeting, object: nil)
                } label: {
                    Label("New Meeting", systemImage: "plus.circle.fill")
                }
                .disabled(session.isBusy)
                .help("Name a meeting and start recording (⌘N)")

                Spacer()

                Button {
                    newFolderName = ""
                    showingNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .help("New folder")

                // ⌘, is the Mac convention and completely undiscoverable to
                // anyone who does not already know it.
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help("Settings (⌘,)")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { library.createFolder(named: newFolderName) }
        }
        .sheet(item: $renaming) { meeting in
            RenameSheet(meeting: meeting) { library.rename(meeting, to: $0) }
        }
        .confirmationDialog(
            "Move “\(deleting?.title ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { meeting in
            Button("Move to Trash", role: .destructive) {
                if selection == meeting.id { selection = nil }
                library.delete(meeting)
            }
        } message: { _ in
            Text("The notes and transcript go to the Trash, so you can put them back.")
        }
    }

    @ViewBuilder
    private func row(for meeting: Meeting) -> some View {
        // `.tag` must be the outermost modifier. Applied before `.contextMenu`
        // the list stops finding it and selection silently never happens —
        // clicks land, nothing highlights, the detail pane stays empty.
        MeetingRow(meeting: meeting)
            .contextMenu {
                Button("Rename…") { renaming = meeting }

                Menu("Move to") {
                    if meeting.folder != nil {
                        Button("Meetings") { library.move(meeting, to: nil) }
                    }
                    ForEach(library.allFolders.filter { $0 != meeting.folder }, id: \.self) { folder in
                        Button(folder) { library.move(meeting, to: folder) }
                    }
                }
                .disabled(library.allFolders.filter { $0 != meeting.folder }.isEmpty
                    && meeting.folder == nil)

                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: library.store.directory(for: meeting).path)
                }
                Divider()
                Button("Move to Trash", role: .destructive) { deleting = meeting }
            }
            .tag(meeting.id)
    }
}

private struct RenameSheet: View {
    let meeting: Meeting
    let commit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var title: String

    init(meeting: Meeting, commit: @escaping (String) -> Void) {
        self.meeting = meeting
        self.commit = commit
        _title = State(initialValue: meeting.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Meeting").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        guard !title.trimmed.isEmpty else { return }
        commit(title)
        dismiss()
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).lineLimit(1)
            if !meeting.resolvedInsights.summary.isEmpty {
                Text(meeting.resolvedInsights.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(meeting.resolvedInsights.summary)
            }
            HStack(spacing: 6) {
                Text(meeting.startedAt, format: .dateTime.day().month().hour().minute())
                if meeting.duration >= 60 {
                    Text("· \(Int(meeting.duration / 60)) min")
                }
                if meeting.enhancedNotes == nil {
                    Text("· transcript only")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A saved meeting: the polished notes, with the raw material behind a picker.
struct MeetingDetailView: View {
    let meeting: Meeting
    /// External request to open the transcript at a moment (a chat citation).
    /// A binding so the detail can consume it: clearing it here keeps a stale
    /// request from re-firing when this view is recreated later.
    @Binding var seek: TranscriptSeek?
    @Environment(MeetingLibrary.self) private var library
    @Environment(MeetingSession.self) private var session
    /// Resolved against `availableTabs` before use — a meeting that was never
    /// enhanced has no Notes tab, and defaulting to it stranded the reader on
    /// "These notes were not enhanced." instead of the transcript they do have.
    @ViewState private var tab: Tab?
    @ViewState private var pendingSeek: TranscriptSeek?
    @ViewState private var highlightedSegment: TranscriptSegment.ID?
    @ViewState private var namingSpeaker = false
    @ViewState private var speakerDraft = ""
    @ViewState private var emailing = false
    @ViewState private var reviewingConflicts = false
    /// What's running on this meeting right now ("Polishing…"), if anything.
    @ViewState private var working: String?
    @ViewState private var workResult: String?
    @Environment(GoogleConnection.self) private var google
    @Environment(AppSettings.self) private var settings

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case myNotes = "My notes"
        case polished = "Polished"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.title2.weight(.semibold))
                    Text(meeting.startedAt, format: .dateTime.weekday(.wide).day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let attendees = meeting.attendees, !attendees.isEmpty {
                        Text("With \(attendees.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(attendees.joined(separator: "\n"))
                    }
                }
                Spacer()
                // Without this, a saved meeting is a dead end: the only way to
                // keep recording is a new meeting, and a call that resumes after
                // a break ends up split across two folders.
                // Same red dot as the toolbar's New Meeting, so "red dot" reads
                // consistently as "this starts recording" — the difference being
                // that this one records into the meeting you are looking at.
                Button {
                    Task { await session.resume(meeting) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                        Text("Resume")
                    }
                }
                .disabled(session.isBusy)
                .help("Record more into this meeting and rewrite its notes")

                CopyButton(title: copyLabel, text: copyableText)
                    .disabled(copyableText.isEmpty)

                // The share sheet reaches Mail, Messages, Notes and any app that
                // takes text — sharing is always something the user does, never
                // something Grove does on its own.
                ShareLink(
                    item: MeetingStore.notesMarkdown(for: meeting),
                    subject: Text(meeting.title)
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share these notes")

                Menu {
                    Button("Email Notes…") { emailing = true }
                        .disabled(!google.isSignedIn)
                    Button("Rewrite Notes with Claude") {
                        run("Claude is rewriting the notes…") { await library.rewriteWithClaude(meeting) }
                    }
                    .disabled(settings.claudeExecutable == nil || working != nil)
                    Button("Name the Other Speaker…") {
                        speakerDraft = meeting.speakerName ?? ""
                        namingSpeaker = true
                    }
                    Button("Export Notes as Markdown…", action: exportNotes)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                Button {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: folder.path)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help(folder.path)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            MeetingOverview(meeting: meeting, previous: library.previous(to: meeting))
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            if let conflicts = meeting.noteConflicts, !conflicts.isEmpty {
                Button {
                    reviewingConflicts = true
                } label: {
                    Label(
                        conflicts.count == 1
                            ? "One of your notes doesn't match the transcript — review"
                            : "\(conflicts.count) of your notes don't match the transcript — review",
                        systemImage: "exclamationmark.bubble")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if let working {
                Label(working, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            } else if let workResult {
                Text(workResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if let email = google.lastEmail, email.meetingID == meeting.id {
                Label(email.result, systemImage: "envelope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if availableTabs.count > 1 {
                Picker("", selection: Binding(get: { selectedTab }, set: { tab = $0 })) {
                    ForEach(availableTabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear(perform: consumeSeek)
                .onChange(of: seek) { _, _ in consumeSeek() }
                .onChange(of: pendingSeek) { _, _ in
                    // The transcript rows exist only after the tab switch has
                    // rendered, so the scroll waits one run-loop turn.
                    DispatchQueue.main.async { applyPendingSeek(using: proxy) }
                }
            }
        }
        .sheet(isPresented: $emailing) { EmailNotesSheet(meeting: meeting) }
        .sheet(isPresented: $reviewingConflicts) {
            NoteConflictsSheet(meeting: meeting) { time in seekInTranscript(to: time) }
        }
        .alert("Who is “Them” in this meeting?", isPresented: $namingSpeaker) {
            TextField("Name", text: $speakerDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { library.setSpeakerName(speakerDraft, for: meeting) }
        } message: {
            Text("Shown instead of “Them” in the transcript and in chat sources. Leave it blank to go back to “Them”.")
        }
        // Selecting a different meeting must not carry a tab that meeting lacks.
        .onChange(of: meeting.id) { _, _ in
            tab = nil
            pendingSeek = nil
            highlightedSegment = nil
        }
    }

    /// Takes ownership of an external seek aimed at this meeting: switches to
    /// the transcript and queues the scroll. Clearing the binding is what
    /// stops the same request from re-applying when the view is recreated.
    private func consumeSeek() {
        guard let seek, seek.meetingID == meeting.id else { return }
        tab = .transcript
        pendingSeek = seek
        self.seek = nil
    }

    /// From a note's own `(m:ss)` reference — same destination as a chat
    /// citation, just already inside this meeting.
    private func seekInTranscript(to time: TimeInterval) {
        tab = .transcript
        pendingSeek = TranscriptSeek(meetingID: meeting.id, time: time)
    }

    private func applyPendingSeek(using proxy: ScrollViewProxy) {
        guard let seek = pendingSeek, seek.meetingID == meeting.id else { return }
        pendingSeek = nil
        guard let segment = meeting.transcript.segment(at: seek.time) else { return }
        withAnimation { proxy.scrollTo(segment.id, anchor: .top) }
        highlightedSegment = segment.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlightedSegment == segment.id {
                withAnimation { highlightedSegment = nil }
            }
        }
    }

    /// The chosen tab if it still exists for this meeting, else the first one
    /// that does.
    private var selectedTab: Tab {
        if let tab, availableTabs.contains(tab) { return tab }
        return availableTabs.first ?? .transcript
    }

    private var availableTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .notes: return meeting.enhancedNotes != nil
            case .myNotes: return !meeting.roughNotes.trimmed.isEmpty
            case .polished: return meeting.polishedNotes != nil
            case .transcript: return !meeting.transcript.isEmpty
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .notes:
            if let notes = meeting.enhancedNotes {
                NotesText(markdown: notes) { time in seekInTranscript(to: time) }
            } else {
                Text("These notes were not enhanced.").foregroundStyle(.secondary)
            }
        case .myNotes:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button {
                        run("Polishing your notes…") {
                            let error = await library.polish(meeting)
                            if error == nil { tab = .polished }
                            return error
                        }
                    } label: {
                        Label("Polish & Cite", systemImage: "wand.and.stars")
                    }
                    .help("Tidy your notes and link each line to the transcript moment behind it")
                    Button {
                        run("Checking your notes against the transcript…") {
                            await library.review(meeting)
                        }
                    } label: {
                        Label("Check Against Transcript", systemImage: "checkmark.bubble")
                    }
                    .help("Find notes the transcript says otherwise about")
                }
                .disabled(working != nil || meeting.transcript.isEmpty)

                Text(meeting.roughNotes)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
            }
        case .polished:
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Your notes, tidied. A time after a line is the moment in the transcript "
                        + "that backs it — click it to check. Lines without one weren't found in "
                        + "the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NotesText(markdown: meeting.polishedNotes ?? "") { time in seekInTranscript(to: time) }
            }
        case .transcript:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(meeting.transcript.merged()) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(meeting.displayName(for: segment.speaker))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(segment.speaker == .me ? Color.grove : .secondary)
                            Text(segment.start.clockString)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text(segment.text)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                highlightedSegment == segment.id
                                    ? Color.grove.opacity(0.18) : .clear))
                    .contextMenu {
                        Button("Copy as Quote") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                meeting.quote(segment.text, speaker: segment.speaker, at: segment.start),
                                forType: .string)
                        }
                    }
                    .id(segment.id)
                }
            }
        }
    }

    private var folder: URL { library.store.directory(for: meeting) }

    /// Runs a slow AI job on this meeting with a status line, and shows its
    /// message afterwards (an error, or "your notes match").
    private func run(_ status: String, _ job: @escaping () async -> String?) {
        working = status
        workResult = nil
        Task {
            let result = await job()
            working = nil
            workResult = result
        }
    }

    private func exportNotes() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(meeting.folderName).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MeetingStore.notesMarkdown(for: meeting)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            library.loadError = "Could not export the notes: \(error.localizedDescription)"
        }
    }

    /// Copies whatever the reader is actually looking at. A single "copy" that
    /// always yielded the notes would be wrong half the time.
    private var copyLabel: String {
        switch selectedTab {
        case .notes: return "Copy Notes"
        case .myNotes: return "Copy My Notes"
        case .polished: return "Copy Polished Notes"
        case .transcript: return "Copy Transcript"
        }
    }

    private var copyableText: String {
        switch selectedTab {
        case .notes: return meeting.enhancedNotes ?? ""
        case .myNotes: return meeting.roughNotes
        case .polished: return meeting.polishedNotes ?? ""
        case .transcript:
            // Speaker-labelled and timestamped, so a pasted transcript still
            // says who said what and when.
            return meeting.transcript.merged()
                .map { segment in
                    let minutes = Int(segment.start) / 60
                    let seconds = Int(segment.start) % 60
                    return String(
                        format: "%@ %02d:%02d  %@", meeting.displayName(for: segment.speaker), minutes, seconds,
                        segment.text)
                }
                .joined(separator: "\n")
        }
    }
}

/// The top of a meeting: what it came to in a sentence, and — for a meeting in
/// a series — what changed since the last one.
private struct MeetingOverview: View {
    let meeting: Meeting
    let previous: Meeting?

    var body: some View {
        let insights = meeting.resolvedInsights
        let changes = previous.map { LibraryIndex.changes(from: $0, to: meeting) }

        if !insights.summary.isEmpty || (changes.map { !$0.isEmpty } ?? false) {
            VStack(alignment: .leading, spacing: 10) {
                if !insights.summary.isEmpty {
                    Text(insights.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let changes, let previous, !changes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SINCE “\(previous.title.uppercased())” ON \(previous.startedAt.formatted(.dateTime.month().day()).uppercased())")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(changes.newDecisions, id: \.self) { decision in
                            Label(decision, systemImage: "plus.circle").font(.caption)
                        }
                        ForEach(changes.settledQuestions, id: \.self) { question in
                            Label("Settled: \(question)", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        ForEach(changes.stillOpen, id: \.self) { commitment in
                            Label(
                                "Still open: \(commitment.owner.isEmpty ? "" : commitment.owner + " — ")\(commitment.task)",
                                systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
