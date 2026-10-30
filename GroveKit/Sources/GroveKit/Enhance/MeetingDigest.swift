import Foundation

/// "What happened this week": one summary across several meetings' notes.
///
/// Built from the written-up notes rather than raw transcripts. Notes are
/// already condensed and already checked against the transcript, and a week of
/// transcripts would not fit the on-device model's context in any case.
@available(macOS 26.0, *)
public struct MeetingDigest: Sendable {
    public let model: any NoteWritingModel

    public init(model: any NoteWritingModel = FoundationModelsEngine()) {
        self.model = model
    }

    public var availability: ModelAvailability { model.availability }

    /// Words of notes sent in total, shared out across the meetings so one long
    /// meeting cannot crowd out the rest of the week.
    static let wordBudget = 1_800

    /// Meetings that started in the last `days` days, oldest first.
    public static func meetings(
        _ meetings: [Meeting], inLast days: Int = 7, now: Date = Date()
    ) -> [Meeting] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        return meetings.filter { $0.startedAt >= since && $0.startedAt <= now }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Nil when none of the meetings has notes to summarise. A digest of
    /// nothing would be written anyway, and it would be invented.
    public func write(for meetings: [Meeting]) async throws -> String? {
        let withNotes = meetings.filter { !Self.notes(of: $0).isEmpty }
        guard !withNotes.isEmpty else { return nil }
        return try await model.generate(
            instructions: Self.instructions, prompt: Self.prompt(for: withNotes))
    }

    static let instructions = """
        You write a short weekly digest of someone's meetings from their notes. \
        Use only what the notes say.

        Output Markdown with these sections, leaving out any with nothing in it:
        ## Decisions
        ## Action items
        ## Open questions
        ## Changed since earlier in the week

        Rules:
        - One line per item. End each line with the meeting title in brackets, \
        exactly as given, like [Pricing follow-up].
        - When a later meeting changes something an earlier one decided, report \
        the latest value and put the change under "Changed since earlier in the week".
        - Never invent owners, dates or numbers. No preamble.
        """

    static func prompt(for meetings: [Meeting]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        let perMeeting = max(120, wordBudget / max(1, meetings.count))
        return meetings.map { meeting in
            let words = notes(of: meeting).split(separator: " ")
            let body = words.prefix(perMeeting).joined(separator: " ")
            return "### \(meeting.title) (\(formatter.string(from: meeting.startedAt)))\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// The written-up notes, else the user's own; never the raw transcript.
    static func notes(of meeting: Meeting) -> String {
        (meeting.enhancedNotes ?? meeting.roughNotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
