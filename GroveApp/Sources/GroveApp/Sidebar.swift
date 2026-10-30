import AppKit
import GroveKit
import SwiftUI

/// Where the content card is pointed.
enum Destination: Hashable {
    case home
    case live
    case ask
    case actionItems
    case insights(InsightsView.Tab)
    case meeting(Meeting.ID)
}

/// The left column: search, the one big button, places, and meetings by day.
///
/// Built by hand rather than with a sidebar `List`, for the same reason Arc
/// and Notion do: the stock sidebar decides its own fonts, highlight and
/// spacing, and those are most of what makes an app feel like itself. The
/// order is the order of use — start something, go somewhere, find something
/// — with settings and status out of the way at the bottom.
struct Sidebar: View {
    @Binding var destination: Destination
    let newMeeting: () -> Void
    let hide: () -> Void

    @Environment(MeetingLibrary.self) private var library
    @Environment(MeetingSession.self) private var session

    @ViewState private var query = ""
    @ViewState private var expandedFolders: Set<String> = []
    @ViewState private var renaming: Meeting?
    @ViewState private var deleting: Meeting?
    @ViewState private var showingNewFolder = false
    @ViewState private var newFolderName = ""
    @FocusState private var searchFocused: Bool

    init(destination: Binding<Destination>, newMeeting: @escaping () -> Void, hide: @escaping () -> Void) {
        _destination = destination
        self.newMeeting = newMeeting
        self.hide = hide
    }

    private var searching: Bool { !query.trimmed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBarRow
            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            primaryAction
                .padding(.horizontal, 10)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !searching {
                        places
                        folders
                    }
                    meetingsByDay
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .animation(Motion.snappy, value: library.meetings.map(\.id))
                .animation(Motion.snappy, value: expandedFolders)
            }
            .scrollIndicators(.never)

            footer
        }
        .frame(width: 252)
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { library.createFolder(named: newFolderName) }
        }
        .managedSheet(item: $renaming) { meeting in
            RenameSheet(meeting: meeting) { library.rename(meeting, to: $0) }
        }
        .confirmationDialog(
            "Move “\(deleting?.title ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { meeting in
            Button("Move to Trash", role: .destructive) {
                if destination == .meeting(meeting.id) { destination = .home }
                library.delete(meeting)
            }
        } message: { _ in
            Text("The notes and transcript go to the Trash, so you can put them back.")
        }
    }

    // MARK: - Top

    /// The strip the traffic lights sit in. Empty on the left for them.
    private var titleBarRow: some View {
        HStack {
            Spacer()
            Button(action: hide) {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(CircleIconStyle(size: 26))
            .foregroundStyle(.secondary)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help("Hide the sidebar (⌃⌘S)")
        }
        .frame(height: 40)
        .padding(.horizontal, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search meetings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onExitCommand { query = "" }
            if searching {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                Button { AppSheet.palette.show() } label: {
                    Text("⌘K")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.groveWash, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Jump to anything (⌘K)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(searchFocused ? Color.groveCard : Color.groveWash))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(searchFocused ? Color.grove.opacity(0.5) : Color.clear, lineWidth: 1))
        .animation(Motion.hover, value: searchFocused)
    }

    /// New Meeting, or — while one runs — the way back to it.
    @ViewBuilder
    private var primaryAction: some View {
        if session.isBusy {
            LiveMeetingCard(selected: destination == .live) { destination = .live }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            Button(action: newMeeting) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("New Meeting")
                    Spacer()
                    Text("⌘N")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ProminentCapsuleStyle())
            .help("Name a meeting and start recording")
            .transition(.opacity)
        }
    }

    // MARK: - Lists

    private var places: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarItem(icon: "house", title: "Home", selected: destination == .home) {
                destination = .home
            }
            SidebarItem(
                icon: "bubble.left.and.text.bubble.right", title: "Ask Grove",
                selected: destination == .ask
            ) {
                destination = .ask
            }
            SidebarItem(
                icon: "checklist", title: "Action Items", badge: openItems,
                selected: destination == .actionItems
            ) {
                destination = .actionItems
            }
            SidebarItem(
                icon: "person.2", title: "People",
                selected: destination == .insights(.people)
            ) {
                destination = .insights(.people)
            }
            SidebarItem(
                icon: "checkmark.seal", title: "Decisions",
                selected: destination == .insights(.decisions)
            ) {
                destination = .insights(.decisions)
            }
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var folders: some View {
        if !library.allFolders.isEmpty {
            SidebarHeading("Folders") {
                Button {
                    newFolderName = ""
                    showingNewFolder = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New folder")
            }
            ForEach(library.allFolders, id: \.self) { folder in
                let open = expandedFolders.contains(folder)
                SidebarItem(
                    icon: open ? "folder.fill" : "folder", title: folder,
                    badge: "\(library.meetings(in: folder).count)",
                    disclosure: open,
                    selected: false
                ) {
                    if open { expandedFolders.remove(folder) } else { expandedFolders.insert(folder) }
                }
                .contextMenu {
                    Button("Delete Folder", role: .destructive) {
                        library.deleteFolder(named: folder)
                    }
                }
                if open {
                    ForEach(library.meetings(in: folder)) { meeting in
                        meetingRow(meeting)
                            .padding(.leading, 14)
                            .transition(.opacity)
                    }
                }
            }
            Spacer().frame(height: 14)
        }
    }

    @ViewBuilder
    private var meetingsByDay: some View {
        let visible = library.meetings(matching: query)
        let days = Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.startedAt) }
        let order = days.keys.sorted(by: >)

        if searching && visible.isEmpty {
            Text("No meetings match “\(query.trimmed)”")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.top, 8)
        } else if library.meetings.isEmpty {
            Text("Meetings you record show up here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.top, 4)
        }

        ForEach(order, id: \.self) { day in
            SidebarHeading(DayLabel.label(for: day))
            ForEach(days[day] ?? []) { meeting in
                meetingRow(meeting)
            }
            Spacer().frame(height: 10)
        }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        MeetingSidebarRow(meeting: meeting, selected: destination == .meeting(meeting.id)) {
            destination = .meeting(meeting.id)
        }
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
            .disabled(library.allFolders.filter { $0 != meeting.folder }.isEmpty && meeting.folder == nil)

            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(
                    nil, inFileViewerRootedAtPath: library.store.directory(for: meeting).path)
            }
            Divider()
            Button("Move to Trash", role: .destructive) { deleting = meeting }
        }
    }

    // MARK: - Bottom

    private var footer: some View {
        HStack(spacing: 4) {
            EngineStatusChip()
            Spacer()
            Button {
                NotificationCenter.default.post(name: .toggleQuickNotes, object: nil)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(CircleIconStyle(size: 28))
            .foregroundStyle(.secondary)
            .help("Quick notes (\(QuickNotesShortcut.label))")

            if library.allFolders.isEmpty {
                Button {
                    newFolderName = ""
                    showingNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(CircleIconStyle(size: 28))
                .foregroundStyle(.secondary)
                .help("New folder")
            }

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(CircleIconStyle(size: 28))
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var openItems: String? {
        let open = ActionItems.extract(from: library.meetings).filter { !$0.isDone }.count
        return open == 0 ? nil : "\(open)"
    }
}

// MARK: - Pieces

/// A small heading over a run of sidebar rows, with optional trailing control.
private struct SidebarHeading<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

extension SidebarHeading where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// The selected row is a raised paper tab, like Arc's; hover is a faint wash.
private struct SidebarHighlight: View {
    let selected: Bool
    let hovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.groveCard : hovering ? Color.groveWash : Color.clear)
            .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 2, y: 1)
    }
}

private struct SidebarItem: View {
    let icon: String
    let title: String
    var badge: String? = nil
    /// nil for a plain row; true/false draws an open/closed chevron.
    var disclosure: Bool? = nil
    let selected: Bool
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.grove : Color.secondary)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let disclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                }
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(SidebarHighlight(selected: selected, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.snappy, value: selected)
    }
}

private struct MeetingSidebarRow: View {
    let meeting: Meeting
    let selected: Bool
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(meeting.title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(meeting.startedAt, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(SidebarHighlight(selected: selected, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.snappy, value: selected)
        .help(meeting.resolvedInsights.summary.isEmpty ? meeting.title : meeting.resolvedInsights.summary)
    }
}

/// Stands in for New Meeting while a meeting runs: what is recording, for how
/// long, and one click back to it from anywhere in the app.
private struct LiveMeetingCard: View {
    let selected: Bool
    let open: () -> Void
    @Environment(MeetingSession.self) private var session

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                if session.isRecording {
                    ListeningBars(
                        active: session.isCapturing, activity: session.segments.count,
                        color: session.isPaused ? .orange : .red)
                        .frame(width: 20)
                } else {
                    ProgressView().controlSize(.small).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title.trimmed.isEmpty ? "Live meeting" : session.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(session.statusText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.groveCard : Color.red.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.red.opacity(selected ? 0.25 : 0.15), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.snappy, value: session.elapsed)
        .help("Back to the meeting")
    }
}
