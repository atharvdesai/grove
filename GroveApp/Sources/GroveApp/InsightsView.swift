import AppKit
import GroveKit
import SwiftUI

/// The library seen across meetings rather than one at a time: who you meet,
/// what was decided, what you're owed, what's still unanswered, and what the
/// jargon means. Every row opens the meeting it came from.
struct InsightsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case people = "People"
        case decisions = "Decisions"
        case waiting = "Waiting on"
        case questions = "Open questions"
        case glossary = "Glossary"
        var id: String { rawValue }
    }

    @Environment(MeetingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @ViewState var tab: Tab = .people
    @ViewState private var person: LibraryIndex.Person?
    @ViewState private var folder: String?
    @ViewState private var analyzing = false
    @ViewState private var analyzeResult: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            Group {
                switch tab {
                case .people: peopleTab
                case .decisions: decisionsTab
                case .waiting: waitingTab
                case .questions: questionsTab
                case .glossary: glossaryTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if let analyzeResult {
                    Text(analyzeResult).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(analyzing ? "Analysing…" : "Analyse Older Meetings") {
                    analyzing = true
                    Task {
                        analyzeResult = await library.analyzeOlderMeetings()
                        analyzing = false
                    }
                }
                .disabled(analyzing)
                .help("Read summaries, decisions and promises out of meetings saved before Grove did this")
            }
            .padding(10)
        }
        .frame(width: 640, height: 560)
        .sheet(item: $person) { PersonView(person: $0, open: open) }
    }

    // MARK: - Tabs

    private var peopleTab: some View {
        let people = library.people
        return Group {
            if people.isEmpty {
                empty("No people yet", "People come from calendar invites and from who promised what.")
            } else {
                List(people) { person in
                    Button { self.person = person } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.grove)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name).font(.headline)
                                Text(peopleDetail(person)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !person.owesYou.isEmpty {
                                Badge(text: "owes you \(person.owesYou.count)", color: .orange)
                            }
                            if !person.youOwe.isEmpty {
                                Badge(text: "you owe \(person.youOwe.count)", color: .blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var decisionsTab: some View {
        let log = library.decisionLog
        return Group {
            if log.isEmpty {
                empty("No decisions yet", "Decisions are read out of each meeting when it's saved.")
            } else {
                List(log) { decision in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(decision.ref.text)
                            .strikethrough(decision.replacedBy != nil)
                            .foregroundStyle(decision.replacedBy == nil ? .primary : .secondary)
                        HStack(spacing: 6) {
                            SourceLink(ref: decision.ref, open: open)
                            if let newer = decision.replacedBy {
                                Text("· replaced in").foregroundStyle(.secondary)
                                SourceLink(ref: newer, open: open)
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                    .contextMenu { copyQuote(decision.ref) }
                }
            }
        }
    }

    private var waitingTab: some View {
        let waiting = library.waitingOn
        return Group {
            if waiting.isEmpty {
                empty("Nobody owes you anything", "Promises other people make in meetings show up here until they're done.")
            } else {
                List(waiting) { promise in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button { library.setDone(promise, done: true) } label: {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Mark as done")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(promise.commitment.owner): \(promise.commitment.task)")
                            HStack(spacing: 6) {
                                Text(waitingFor(promise.age)).foregroundStyle(promise.age > 7 * 86_400 ? Color.orange : Color.secondary)
                                if let due = promise.commitment.due { Text("· due \(due)").foregroundStyle(.secondary) }
                                SourceLink(ref: promise.ref, open: open)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var questionsTab: some View {
        let questions = library.openQuestions
        return Group {
            if questions.isEmpty {
                empty("No open questions", "Questions raised and never answered collect here.")
            } else {
                List(questions) { question in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(question.text)
                        SourceLink(ref: question, open: open).font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var glossaryTab: some View {
        let entries = library.glossary(folder: folder)
        return VStack(spacing: 0) {
            Picker("Folder", selection: $folder) {
                Text("All folders").tag(String?.none)
                ForEach(library.allFolders, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 260)
            .padding(10)
            if entries.isEmpty {
                empty("No terms yet", "Acronyms and jargon are defined from how they were used.")
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.term).font(.headline)
                        Text(entry.definition)
                        SourceLink(ref: entry.ref, open: open).font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Helpers

    private func open(_ ref: LibraryIndex.Ref) {
        NotificationCenter.default.post(
            name: .navigateToMeeting, object: nil, userInfo: ["meetingID": ref.meetingID])
        person = nil
        dismiss()
    }

    @ViewBuilder
    private func copyQuote(_ ref: LibraryIndex.Ref) -> some View {
        if let meeting = library.meetings.first(where: { $0.id == ref.meetingID }) {
            Button("Copy as Quote") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(meeting.quote(ref.text), forType: .string)
            }
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "sparkles", description: Text(detail))
    }

    private func peopleDetail(_ person: LibraryIndex.Person) -> String {
        let count = "\(person.meetings.count) \(person.meetings.count == 1 ? "meeting" : "meetings")"
        guard let last = person.lastSeen else { return count }
        return "\(count) · last \(last.formatted(.relative(presentation: .named)))"
    }

    private func waitingFor(_ age: TimeInterval) -> String {
        let days = Int(age / 86_400)
        return days == 0 ? "asked today" : "waiting \(days) \(days == 1 ? "day" : "days")"
    }
}

/// Everything about one person: your meetings together, what each owes the
/// other, and what's still unanswered between you.
private struct PersonView: View {
    let person: LibraryIndex.Person
    let open: (LibraryIndex.Ref) -> Void
    @Environment(MeetingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(Color.grove)
                VStack(alignment: .leading) {
                    Text(person.name).font(.title2.weight(.semibold))
                    if let last = person.lastSeen {
                        Text("Last met \(last.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            List {
                if !person.owesYou.isEmpty {
                    Section("They owe you") {
                        ForEach(person.owesYou) { promise in promiseRow(promise) }
                    }
                }
                if !person.youOwe.isEmpty {
                    Section("You owe them") {
                        ForEach(person.youOwe) { promise in promiseRow(promise) }
                    }
                }
                if !person.openQuestions.isEmpty {
                    Section("Still unanswered") {
                        ForEach(person.openQuestions) { question in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(question.text)
                                SourceLink(ref: question, open: open).font(.caption)
                            }
                        }
                    }
                }
                Section("Meetings") {
                    ForEach(person.meetings) { ref in
                        Button { open(ref) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ref.meetingTitle)
                                Text(ref.text.isEmpty ? ref.date.formatted(date: .abbreviated, time: .shortened) : ref.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 560, height: 520)
    }

    private func promiseRow(_ promise: LibraryIndex.Promise) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { library.setDone(promise, done: true) } label: {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(promise.commitment.task)
                HStack(spacing: 6) {
                    if let due = promise.commitment.due { Text("due \(due) ·").foregroundStyle(.secondary) }
                    SourceLink(ref: promise.ref, open: open)
                }
                .font(.caption)
            }
        }
    }
}

/// "Acme SSO check-in · Oct 20", as a link to that meeting.
struct SourceLink: View {
    let ref: LibraryIndex.Ref
    let open: (LibraryIndex.Ref) -> Void

    var body: some View {
        Button { open(ref) } label: {
            Text("\(ref.meetingTitle) · \(ref.date.formatted(.dateTime.month().day()))")
                .underline()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.grove)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
