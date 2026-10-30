import GroveKit
import SwiftUI

/// The sheets the main window can show, openable from anywhere — a home
/// screen card, the ⌘K bar, a menu — by posting `.showAppSheet`.
enum AppSheet: String, Identifiable {
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
    @Environment(\.dismiss) private var dismiss
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let run: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search meetings, people, decisions, or type a command", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { items.first?.run() }
            }
            .padding(14)
            Divider()

            List(items) { item in
                Button(action: item.run) {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .frame(width: 20)
                            .foregroundStyle(Color.grove)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 560, height: 420)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
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

    /// Closes the palette first, so a command that opens another sheet isn't
    /// blocked by this one.
    private func finish(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: action)
    }
}
