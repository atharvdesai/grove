import Foundation

/// What a meeting amounted to, in a shape the rest of the app can use:
/// a one-line summary for skimming, decisions for the decision log, promises
/// for "waiting on", questions to chase, and terms for the glossary.
///
/// Extracted once when the meeting is saved and kept in meeting.json, so
/// every view that needs it reads a field instead of asking a model again.
public struct MeetingInsights: Codable, Sendable, Equatable {
    public var summary: String
    public var highlights: [String]
    public var decisions: [String]
    public var commitments: [Commitment]
    public var questions: [String]
    public var terms: [Term]

    public init(
        summary: String = "", highlights: [String] = [], decisions: [String] = [],
        commitments: [Commitment] = [], questions: [String] = [], terms: [Term] = []
    ) {
        self.summary = summary
        self.highlights = highlights
        self.decisions = decisions
        self.commitments = commitments
        self.questions = questions
        self.terms = terms
    }

    public var isEmpty: Bool {
        summary.isEmpty && decisions.isEmpty && commitments.isEmpty && questions.isEmpty
    }
}

/// Someone promised to do something.
public struct Commitment: Codable, Sendable, Equatable, Hashable {
    /// Who promised, as said; "me" when it was the person taking notes.
    public var owner: String
    public var task: String
    /// When by, as said ("Friday", "November 30"), if a time was given.
    public var due: String?

    public init(owner: String, task: String, due: String? = nil) {
        self.owner = owner
        self.task = task
        self.due = due
    }

    /// The note-taker's own promise — a to-do — rather than someone else's,
    /// which is something you're waiting on.
    public func isMine(myName: String = "") -> Bool {
        let owner = owner.trimmingCharacters(in: .whitespaces).lowercased()
        let me = myName.trimmingCharacters(in: .whitespaces).lowercased()
        if ["me", "i", "myself", "you"].contains(owner) { return true }
        guard !me.isEmpty, !owner.isEmpty else { return false }
        return owner == me || owner.split(separator: " ").first.map(String.init) == me
            || me.split(separator: " ").first.map(String.init) == owner
    }
}

/// A term of art and what it meant in this meeting.
public struct Term: Codable, Sendable, Equatable, Hashable {
    public var term: String
    public var definition: String

    public init(term: String, definition: String) {
        self.term = term
        self.definition = definition
    }
}

/// Pulls `MeetingInsights` out of a meeting with one model call.
public struct InsightExtractor: Sendable {
    public let model: any NoteWritingModel

    public init(model: any NoteWritingModel = FoundationModelsEngine()) {
        self.model = model
    }

    public func insights(for meeting: Meeting) async throws -> MeetingInsights {
        let response = try await model.generate(
            instructions: Self.instructions, prompt: prompt(for: meeting))
        let parsed = Self.parse(response)
        // A model that returned nothing usable shouldn't leave the meeting
        // with less than its own notes already say.
        return parsed.isEmpty ? Self.fromNotes(meeting) : parsed
    }

    static let instructions = """
        You read a meeting's notes and transcript and list what it amounted to. \
        Output labelled lines only, nothing else:
        SUMMARY: one plain sentence saying what the meeting was about and what came of it
        HIGHLIGHT: one of the three most important points (up to 3 lines)
        DECISION: something explicitly decided or agreed
        COMMITMENT: <who> | <what they will do> | <by when, or ->
        QUESTION: something raised and left unanswered
        TERM: <acronym or jargon> | <what it means, from how it was used>

        In the transcript, [Me] is the person taking notes: write "me" as the \
        owner of their commitments. Use people's names when they were said. \
        Report only what the meeting shows; leave a label out if there is \
        nothing for it.
        """

    private func prompt(for meeting: Meeting) -> String {
        var parts = ["Meeting: \(meeting.title)"]
        if let attendees = meeting.attendees, !attendees.isEmpty {
            parts.append("Attendees: \(attendees.joined(separator: ", "))")
        }
        let notes = meeting.enhancedNotes ?? meeting.roughNotes
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Notes:\n\(notes)")
        }
        // The transcript when it fits; the notes alone carry it otherwise.
        let transcript = meeting.transcript.formatted()
        let budget = model.singlePassWordLimit - TopicSegmenter.words(in: notes) - 200
        if !transcript.isEmpty, TopicSegmenter.words(in: transcript) <= budget {
            parts.append("Transcript:\n\(transcript)")
        }
        return parts.joined(separator: "\n\n")
    }

    static func parse(_ response: String) -> MeetingInsights {
        var insights = MeetingInsights()
        for raw in response.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -*•\t"))
                .replacingOccurrences(of: "**", with: "")
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            switch label {
            case "SUMMARY" where insights.summary.isEmpty:
                insights.summary = value
            case "HIGHLIGHT" where insights.highlights.count < 3:
                insights.highlights.append(value)
            case "DECISION":
                insights.decisions.append(value)
            case "COMMITMENT" where fields.count >= 2 && !fields[1].isEmpty:
                let due = fields.count > 2 && !["", "-", "—", "none", "n/a"].contains(fields[2].lowercased())
                    ? fields[2] : nil
                insights.commitments.append(Commitment(owner: fields[0], task: fields[1], due: due))
            case "QUESTION":
                insights.questions.append(value)
            case "TERM" where fields.count >= 2 && !fields[1].isEmpty:
                insights.terms.append(Term(term: fields[0], definition: fields[1]))
            default:
                continue
            }
        }
        return insights
    }

    /// Insights read straight off the written-up notes, with no model: the
    /// decisions and action-item sections already say most of it. Used for
    /// meetings saved before insights existed, and as a floor when a model
    /// call fails.
    public static func fromNotes(_ meeting: Meeting) -> MeetingInsights {
        guard let notes = meeting.enhancedNotes else { return MeetingInsights() }
        var insights = MeetingInsights()
        var section = ""
        for raw in notes.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                continue
            }
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let text = TimestampLinker.trailingClock(in: String(line.dropFirst(2)))?.text
                ?? String(line.dropFirst(2))
            if section.contains("decision") {
                insights.decisions.append(text)
            } else if ActionItems.headingWords.contains(where: { section.contains($0) }) {
                insights.commitments.append(commitment(from: text))
            } else if section.contains("question") {
                insights.questions.append(text)
            } else if insights.highlights.count < 3 {
                insights.highlights.append(text)
            }
        }
        insights.summary = insights.highlights.first ?? insights.decisions.first ?? ""
        return insights
    }

    /// "Priya: pricing page copy by Monday" → owner Priya, task, due Monday.
    static func commitment(from text: String) -> Commitment {
        var owner = ""
        var task = text
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) < 30 {
            owner = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            task = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        var due: String?
        if let range = task.range(of: #"\bby ([A-Z][a-z]+( \d{1,2}(st|nd|rd|th)?)?|tomorrow|today|end of (the )?week)\b"#,
                                   options: [.regularExpression, .caseInsensitive]) {
            due = String(task[range]).replacingOccurrences(of: "by ", with: "", options: .caseInsensitive)
        }
        return Commitment(owner: owner, task: task, due: due)
    }
}

extension Meeting {
    /// Stored insights, or what the notes alone can say.
    public var resolvedInsights: MeetingInsights {
        if let insights, !insights.isEmpty { return insights }
        return InsightExtractor.fromNotes(self)
    }
}
