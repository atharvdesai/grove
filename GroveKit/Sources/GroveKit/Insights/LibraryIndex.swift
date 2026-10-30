import Foundation

/// Views across the whole library, built from each meeting's insights: people,
/// decisions, promises, questions, terms, and how a recurring meeting changed.
///
/// All plain computation over meetings already on disk — no model calls — so
/// these open instantly and always agree with the files.
public enum LibraryIndex {

    // MARK: - Items that point back at a meeting

    public struct Ref: Sendable, Equatable, Hashable, Identifiable {
        public let meetingID: UUID
        public let meetingTitle: String
        public let date: Date
        public let text: String
        public var id: String { "\(meetingID.uuidString)|\(text)" }
    }

    public struct Promise: Sendable, Equatable, Hashable, Identifiable {
        public let ref: Ref
        public let commitment: Commitment
        public let isDone: Bool
        public var id: String { ref.id }
        /// How long it has been outstanding.
        public var age: TimeInterval { Date().timeIntervalSince(ref.date) }
    }

    // MARK: - Promises

    /// Every promise, newest meeting first. Done-ness is the meeting's own
    /// `completedActionItems`, shared with the action items list.
    public static func promises(in meetings: [Meeting]) -> [Promise] {
        meetings.sorted { $0.startedAt > $1.startedAt }.flatMap { meeting in
            let done = Set(meeting.completedActionItems ?? [])
            return meeting.resolvedInsights.commitments.map { commitment in
                Promise(
                    ref: Ref(meetingID: meeting.id, meetingTitle: meeting.title,
                             date: meeting.startedAt, text: commitment.task),
                    commitment: commitment, isDone: done.contains(commitment.task))
            }
        }
    }

    /// What other people promised you and haven't done yet, oldest first —
    /// the ones you've waited on longest are the ones to chase.
    public static func waitingOn(_ meetings: [Meeting], myName: String) -> [Promise] {
        promises(in: meetings)
            .filter { !$0.isDone && !$0.commitment.isMine(myName: myName) && !$0.commitment.owner.isEmpty }
            .sorted { $0.ref.date < $1.ref.date }
    }

    // MARK: - Decisions

    public struct Decision: Sendable, Equatable, Identifiable {
        public let ref: Ref
        /// The later decision that changed this one, if any.
        public var replacedBy: Ref?
        public var id: String { ref.id }
    }

    /// Every decision, newest first. A decision that a later meeting revisits
    /// — same subject, mostly the same words — is marked as replaced, so the
    /// log answers "what did we decide?" with the current answer.
    public static func decisions(in meetings: [Meeting]) -> [Decision] {
        let chronological = meetings.sorted { $0.startedAt < $1.startedAt }
            .flatMap { meeting in
                meeting.resolvedInsights.decisions.map {
                    Ref(meetingID: meeting.id, meetingTitle: meeting.title, date: meeting.startedAt, text: $0)
                }
            }
        var log = chronological.map { Decision(ref: $0, replacedBy: nil) }
        for i in log.indices {
            for later in log.indices where later > i && log[later].ref.meetingID != log[i].ref.meetingID {
                if FactSheet.similar(log[i].ref.text, log[later].ref.text) {
                    log[i].replacedBy = log[later].ref
                }
            }
        }
        return log.reversed()
    }

    // MARK: - Questions

    /// Questions raised and never settled, newest first. One counts as settled
    /// when a later meeting decided something about the same thing.
    public static func openQuestions(in meetings: [Meeting]) -> [Ref] {
        let log = decisions(in: meetings)
        return meetings.sorted { $0.startedAt > $1.startedAt }.flatMap { meeting in
            meeting.resolvedInsights.questions.compactMap { question -> Ref? in
                let answered = log.contains {
                    $0.ref.date >= meeting.startedAt && FactSheet.similar(question, $0.ref.text)
                }
                return answered ? nil : Ref(meetingID: meeting.id, meetingTitle: meeting.title,
                                            date: meeting.startedAt, text: question)
            }
        }
    }

    // MARK: - Glossary

    public struct GlossaryEntry: Sendable, Equatable, Identifiable {
        public let term: String
        public let definition: String
        public let ref: Ref
        public let folder: String?
        public var id: String { term.lowercased() }
    }

    /// Terms with their latest definition, alphabetical, optionally for one folder.
    public static func glossary(in meetings: [Meeting], folder: String? = nil) -> [GlossaryEntry] {
        var byTerm: [String: GlossaryEntry] = [:]
        for meeting in meetings.sorted(by: { $0.startedAt < $1.startedAt })
        where folder == nil || meeting.folder == folder {
            for term in meeting.resolvedInsights.terms {
                byTerm[term.term.lowercased()] = GlossaryEntry(
                    term: term.term, definition: term.definition,
                    ref: Ref(meetingID: meeting.id, meetingTitle: meeting.title,
                             date: meeting.startedAt, text: term.term),
                    folder: meeting.folder)
            }
        }
        return byTerm.values.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }

    // MARK: - People

    public struct Person: Sendable, Equatable, Identifiable {
        public let name: String
        public let meetings: [Ref]
        /// Their open promises to you.
        public let owesYou: [Promise]
        /// Your open promises from meetings they were in.
        public let youOwe: [Promise]
        public let openQuestions: [Ref]
        public var id: String { name.lowercased() }
        public var lastSeen: Date? { meetings.map(\.date).max() }
    }

    /// Everyone you've met, most recently seen first. People come from
    /// calendar attendees, named speakers and promise owners; "Janet" and
    /// "Janet Liu" are the same person when only one Janet is known.
    public static func people(in meetings: [Meeting], myName: String) -> [Person] {
        var names: [String: Set<UUID>] = [:]
        func add(_ raw: String, _ meeting: Meeting) {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !Commitment(owner: name, task: "").isMine(myName: myName)
            else { return }
            names[name, default: []].insert(meeting.id)
        }
        for meeting in meetings {
            (meeting.attendees ?? []).forEach { add($0, meeting) }
            if let speaker = meeting.speakerName { add(speaker, meeting) }
            meeting.resolvedInsights.commitments.forEach { add($0.owner, meeting) }
        }

        // Fold a first name into the one full name that starts with it.
        let full = names.keys.filter { $0.contains(" ") }
        for short in names.keys where !short.contains(" ") {
            let matches = full.filter { $0.lowercased().hasPrefix(short.lowercased() + " ") }
            if matches.count == 1, let ids = names.removeValue(forKey: short) {
                names[matches[0], default: []].formUnion(ids)
            }
        }

        let byID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        let allPromises = promises(in: meetings)
        let questions = openQuestions(in: meetings)
        return names.map { name, ids in
            let theirMeetings = ids.compactMap { byID[$0] }.sorted { $0.startedAt > $1.startedAt }
            let first = name.split(separator: " ").first.map(String.init)?.lowercased() ?? name.lowercased()
            let isThem = { (owner: String) in
                let o = owner.lowercased()
                return o == name.lowercased() || o == first
            }
            return Person(
                name: name,
                meetings: theirMeetings.map {
                    Ref(meetingID: $0.id, meetingTitle: $0.title, date: $0.startedAt,
                        text: $0.resolvedInsights.summary)
                },
                owesYou: allPromises.filter { !$0.isDone && isThem($0.commitment.owner) },
                youOwe: allPromises.filter {
                    !$0.isDone && $0.commitment.isMine(myName: myName) && ids.contains($0.ref.meetingID)
                },
                openQuestions: questions.filter { ids.contains($0.meetingID) })
        }
        .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    // MARK: - Recurring meetings

    /// The most recent earlier meeting that is "the same meeting": the same
    /// title once dates and numbers are ignored, or largely the same people.
    public static func previous(
        title: String, attendees: [String], before date: Date, in meetings: [Meeting]
    ) -> Meeting? {
        let key = recurringKey(title)
        let people = Set(attendees.map { $0.lowercased() })
        return meetings
            .filter { $0.startedAt < date }
            .sorted { $0.startedAt > $1.startedAt }
            .first { meeting in
                if !key.isEmpty, recurringKey(meeting.title) == key { return true }
                let theirs = Set((meeting.attendees ?? []).map { $0.lowercased() })
                guard people.count >= 2, theirs.count >= 2 else { return false }
                let overlap = Double(people.intersection(theirs).count) / Double(people.union(theirs).count)
                return overlap >= 0.6
            }
    }

    /// "Weekly standup — Oct 13" and "Weekly Standup #42" share a key.
    static func recurringKey(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: #"\d+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                // Whole month and day names only, so "marketing" keeps its "mar".
                of: #"\b(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sept?(ember)?|oct(ober)?|nov(ember)?|dec(ember)?|mon(day)?|tue(s(day)?)?|wed(nesday)?|thu(rs(day)?)?|fri(day)?|sat(urday)?|sun(day)?)\b"#,
                with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "meeting" }
            .joined(separator: " ")
    }

    /// What a recurring meeting should start from: last time's unfinished
    /// promises and unanswered questions, as a checklist.
    public static func carryOver(from previous: Meeting) -> String {
        let insights = previous.resolvedInsights
        let done = Set(previous.completedActionItems ?? [])
        let open = insights.commitments.filter { !done.contains($0.task) }
        guard !open.isEmpty || !insights.questions.isEmpty else { return "" }
        var lines = ["## From last time"]
        lines += open.map { commitment in
            let owner = commitment.owner.isEmpty ? "" : "\(commitment.owner): "
            return "- [ ] \(owner)\(commitment.task)"
        }
        lines += insights.questions.map { "- [ ] Open question: \($0)" }
        return lines.joined(separator: "\n") + "\n\n"
    }

    public struct Changes: Sendable, Equatable {
        public var newDecisions: [String] = []
        public var stillOpen: [Commitment] = []
        public var settledQuestions: [String] = []
        public var isEmpty: Bool { newDecisions.isEmpty && stillOpen.isEmpty && settledQuestions.isEmpty }
    }

    /// How this meeting differs from the last one in its series.
    public static func changes(from previous: Meeting, to current: Meeting) -> Changes {
        let before = previous.resolvedInsights
        let now = current.resolvedInsights
        let done = Set((previous.completedActionItems ?? []) + (current.completedActionItems ?? []))
        var changes = Changes()
        changes.newDecisions = now.decisions.filter { decision in
            !before.decisions.contains { FactSheet.similar($0, decision) }
        }
        changes.stillOpen = before.commitments.filter { !done.contains($0.task) }
        changes.settledQuestions = before.questions.filter { question in
            now.decisions.contains { FactSheet.similar(question, $0) }
        }
        return changes
    }
}
