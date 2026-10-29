import Observation
import GroveKit
import SwiftUI

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
            loadError = nil
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

    @State private var renaming: Meeting?
    @State private var deleting: Meeting?
    @State private var newFolderName = ""
    @State private var showingNewFolder = false

    var body: some View {
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
            let loose = library.meetings(in: nil)
            if !loose.isEmpty {
                Section("Meetings") {
                    ForEach(loose) { row(for: $0) }
                }
            }

            ForEach(library.allFolders, id: \.self) { folder in
                Section {
                    ForEach(library.meetings(in: folder)) { row(for: $0) }
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
        .overlay {
            if library.meetings.isEmpty && !session.isBusy {
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
    @State private var title: String

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
    @State private var tab: Tab?
    @State private var pendingSeek: TranscriptSeek?
    @State private var highlightedSegment: TranscriptSegment.ID?

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case myNotes = "My notes"
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
            Text(meeting.roughNotes)
                .font(.system(size: 14))
                .textSelection(.enabled)
        case .transcript:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(meeting.transcript.merged()) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(segment.speaker.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(segment.speaker == .me ? Color.accentColor : .secondary)
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
                                    ? Color.accentColor.opacity(0.18) : .clear))
                    .id(segment.id)
                }
            }
        }
    }

    private var folder: URL { library.store.directory(for: meeting) }

    /// Copies whatever the reader is actually looking at. A single "copy" that
    /// always yielded the notes would be wrong half the time.
    private var copyLabel: String {
        switch selectedTab {
        case .notes: return "Copy Notes"
        case .myNotes: return "Copy My Notes"
        case .transcript: return "Copy Transcript"
        }
    }

    private var copyableText: String {
        switch selectedTab {
        case .notes: return meeting.enhancedNotes ?? ""
        case .myNotes: return meeting.roughNotes
        case .transcript:
            // Speaker-labelled and timestamped, so a pasted transcript still
            // says who said what and when.
            return meeting.transcript.merged()
                .map { segment in
                    let minutes = Int(segment.start) / 60
                    let seconds = Int(segment.start) % 60
                    return String(
                        format: "%@ %02d:%02d  %@", segment.speaker.displayName, minutes, seconds,
                        segment.text)
                }
                .joined(separator: "\n")
        }
    }
}
