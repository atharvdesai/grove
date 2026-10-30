import GroveKit
import SwiftUI

/// The sheets the main window can show, openable from anywhere — a home
/// screen card, the ⌘K bar, a menu — by posting `.showAppSheet`.
enum AppSheet: String, Identifiable {
    case newMeeting
    case chat, actionItems, digest, palette
    case people, decisions, waiting, questions, glossary

    var id: String { rawValue }

    func show() {
        NotificationCenter.default.post(name: .showAppSheet, object: nil, userInfo: ["sheet": rawValue])
    }
}

/// ⌘K: type anything, jump anywhere.
///
/// Meetings (with the same plain-English search as the sidebar), people,
/// decisions and commands in one list. Return opens the top result, so the
/// common case is ⌘K, a few letters, Return.
struct CommandPalette: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(MeetingSession.self) private var session
    @CloseSheet private var close
    @ViewState private var text = ""
    @ViewState private var highlighted = 0
    @FocusState private var focused: Bool

    fileprivate struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let run: () -> Void
    }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search meetings, people, decisions, or type a command", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(items, at: highlighted) }
                    .onKeyPress(.downArrow) {
                        move(by: 1, count: items.count)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(by: -1, count: items.count)
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, isHighlighted: index == highlighted)
                                .id(item.id)
                                .onTapGesture { item.run() }
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id)
                }
            }

            Divider()
            HStack(spacing: 14) {
                KeyHint(keys: "↑↓", label: "Move")
                KeyHint(keys: "↩", label: "Open")
                KeyHint(keys: "esc", label: "Close")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 600, height: 440)
        .onAppear { focused = true }
        .onExitCommand { close() }
        .onChange(of: text) { _, _ in highlighted = 0 }
    }

    private func move(by step: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = min(max(highlighted + step, 0), count - 1)
    }

    private func run(_ items: [Item], at index: Int) {
        guard items.indices.contains(index) else {
            items.first?.run()
            return
        }
        items[index].run()
    }

    private var items: [Item] {
        let query = text.trimmed
        let commands = self.commands.filter {
            query.isEmpty || SearchTerms.text($0.title, matchesQuery: query)
        }
        guard !query.isEmpty else { return commands + recentMeetings }

        let meetings = library.meetings(matching: query).prefix(8).map(meetingItem)
        let people = library.people
            .filter { $0.name.lowercased().contains(query.lowercased()) }
            .prefix(4)
            .map { person in
                Item(id: "person-\(person.id)", icon: "person.crop.circle", title: person.name,
                     detail: "\(person.meetings.count) meetings") {
                    finish { AppSheet.people.show() }
                }
            }
        let decisions = library.decisionLog
            .filter { $0.replacedBy == nil && SearchTerms.text($0.ref.text, matchesQuery: query) }
            .prefix(4)
            .map { decision in
                Item(id: "decision-\(decision.id)", icon: "checkmark.seal", title: decision.ref.text,
                     detail: "Decided in \(decision.ref.meetingTitle)") {
                    finish { navigate(to: decision.ref.meetingID) }
                }
            }
        return Array(meetings) + Array(people) + Array(decisions) + commands
    }

    private var recentMeetings: [Item] {
        library.meetings.prefix(5).map(meetingItem)
    }

    private func meetingItem(_ meeting: Meeting) -> Item {
        let summary = meeting.resolvedInsights.summary
        return Item(
            id: "meeting-\(meeting.id)", icon: "doc.text", title: meeting.title,
            detail: summary.isEmpty ? meeting.startedAt.formatted(date: .abbreviated, time: .shortened) : summary
        ) {
            finish { navigate(to: meeting.id) }
        }
    }

    private var commands: [Item] {
        var list = [
            Item(id: "new", icon: "record.circle", title: "New Meeting", detail: "⌘N") {
                finish { NotificationCenter.default.post(name: .newMeeting, object: nil) }
            },
            Item(id: "lecture", icon: "graduationcap", title: "Record In Person (Lecture)", detail: "") {
                finish {
                    session.inPerson = true
                    session.templateID = NoteTemplate.lecture.id
                    Task { await session.start() }
                }
            },
            Item(id: "quick", icon: "square.and.pencil", title: "Quick Notes", detail: QuickNotesShortcut.label) {
                finish { NotificationCenter.default.post(name: .toggleQuickNotes, object: nil) }
            },
            Item(id: "ask", icon: "bubble.left.and.bubble.right", title: "Ask Your Meetings", detail: "") {
                finish { AppSheet.chat.show() }
            },
            Item(id: "actions", icon: "checklist", title: "Action Items", detail: "") {
                finish { AppSheet.actionItems.show() }
            },
            Item(id: "waiting", icon: "hourglass", title: "Waiting On", detail: "") {
                finish { AppSheet.waiting.show() }
            },
            Item(id: "people", icon: "person.2", title: "People", detail: "") {
                finish { AppSheet.people.show() }
            },
            Item(id: "decisions", icon: "checkmark.seal", title: "Decision Log", detail: "") {
                finish { AppSheet.decisions.show() }
            },
            Item(id: "questions", icon: "questionmark.bubble", title: "Open Questions", detail: "") {
                finish { AppSheet.questions.show() }
            },
            Item(id: "glossary", icon: "character.book.closed", title: "Glossary", detail: "") {
                finish { AppSheet.glossary.show() }
            },
            Item(id: "week", icon: "calendar", title: "This Week", detail: "") {
                finish { AppSheet.digest.show() }
            },
        ]
        if session.isRecording {
            list.insert(
                Item(id: "offrecord", icon: "eye.slash",
                     title: session.isOffRecord ? "Back On the Record" : "Go Off the Record", detail: "⌃⌥O") {
                    finish { session.toggleOffRecord() }
                }, at: 0)
        }
        return list
    }

    private func navigate(to id: UUID) {
        NotificationCenter.default.post(name: .navigateToMeeting, object: nil, userInfo: ["meetingID": id])
    }

    /// Closes the palette first, and runs the command once it has gone, so a
    /// command that opens another sheet never overlaps this one.
    private func finish(_ action: @escaping () -> Void) {
        close(then: action)
    }
}

/// One palette result. The highlight is the keyboard cursor; hovering moves it,
/// so mouse and keyboard never disagree about which row Return will open.
private struct PaletteRow: View {
    let item: CommandPalette.Item
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 22)
                .foregroundStyle(isHighlighted ? Color.white : Color.grove)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isHighlighted {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(isHighlighted ? Color.grove : Color.clear))
        .contentShape(Rectangle())
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption2.weight(.semibold).monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}
