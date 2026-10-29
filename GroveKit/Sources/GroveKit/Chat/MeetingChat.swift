import Foundation

/// Answers questions across past meetings, on-device, with receipts.
///
/// This is Grove's counterpart to Granola's chat, with one hard rule borrowed
/// from the enhancement pass: the model may only report what the transcripts
/// actually contain. Two mechanisms hold that line rather than one:
///
/// - Retrieval is code, not the model. Question words are matched against
///   transcript segments by containment, and below a relevance floor the
///   question is declined *before* the model is ever called — a model asked to
///   answer from nothing will answer from its imagination.
/// - The sources returned alongside the answer are the exact segments the
///   model saw, attached by the caller. The UI never has to trust the prose
///   to know what the answer rests on.
@available(macOS 26.0, *)
public struct MeetingChat: Sendable {

    /// One transcript passage the answer may draw on.
    public struct Excerpt: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let meetingID: UUID
        public let meetingTitle: String
        public let startedAt: Date
        public let speaker: Speaker
        /// Seconds from the start of that meeting's recording.
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String

        public init(
            id: UUID,
            meetingID: UUID,
            meetingTitle: String,
            startedAt: Date,
            speaker: Speaker,
            start: TimeInterval,
            end: TimeInterval,
            text: String
        ) {
            self.id = id
            self.meetingID = meetingID
            self.meetingTitle = meetingTitle
            self.startedAt = startedAt
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public struct Answer: Sendable, Equatable {
        public let text: String
        /// The exact transcript excerpts the model was given, best first.
        public let excerpts: [Excerpt]

        public init(text: String, excerpts: [Excerpt]) {
            self.text = text
            self.excerpts = excerpts
        }
    }

    /// The engine that writes the answer. Same seam as `NoteEnhancer`, so a
    /// larger local engine improves both features at once and tests can
    /// substitute a stub.
    public let model: any NoteWritingModel

    /// Containment floor for a single excerpt. Below this, no excerpt shares
    /// enough of the question's content words to be evidence, and the honest
    /// answer is "your meetings don't mention that" — not a model call.
    public static let minimumScore = 0.34

    /// Most excerpts sent to the model for one question.
    public static let excerptLimit = 8

    /// Question words too common to mean anything in a match. Without this
    /// list, "what did we decide about the budget" matches every segment
    /// containing "the".
    static let stopwords: Set<String> = [
        "a", "an", "the", "is", "was", "were", "are", "be", "been",
        "do", "does", "did", "have", "has", "had",
        "what", "who", "whom", "when", "where", "which", "why", "how",
        "i", "me", "my", "we", "our", "you", "your", "they", "them", "their",
        "he", "she", "it", "its", "this", "that", "these", "those",
        "and", "or", "but", "if", "then", "so",
        "to", "of", "in", "on", "at", "by", "for", "with", "about", "from",
        "any", "some", "all", "there", "here", "say", "said", "tell", "told",
    ]

    public init(model: any NoteWritingModel = FoundationModelsEngine()) {
        self.model = model
    }

    public var availability: ModelAvailability { model.availability }

    /// Ranks transcript excerpts across every meeting by how much of the
    /// question they cover. Pure code with no model involvement, which is what
    /// makes the relevance floor testable.
    ///
    /// Adjacent segments from the same speaker are merged first, so an answer
    /// split across two utterances still scores as one passage.
    public static func retrieve(
        question: String,
        meetings: [Meeting],
        limit: Int = excerptLimit
    ) -> [(score: Double, excerpt: Excerpt)] {
        let content = Set(Transcript.normalize(question)).subtracting(stopwords)
        guard !content.isEmpty else { return [] }

        var scored: [(Double, Excerpt)] = []
        for meeting in meetings {
            for segment in meeting.transcript.merged() {
                let words = Set(Transcript.normalize(segment.text))
                guard !words.isEmpty else { continue }
                let shared = content.intersection(words).count
                guard shared > 0 else { continue }
                let score = Double(shared) / Double(content.count)
                scored.append(
                    (score,
                     Excerpt(
                        id: segment.id,
                        meetingID: meeting.id,
                        meetingTitle: meeting.title,
                        startedAt: meeting.startedAt,
                        speaker: segment.speaker,
                        start: segment.start,
                        end: segment.end,
                        text: segment.text)))
            }
        }
        return
            scored
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.start < $1.1.start }
            .prefix(limit)
            .map { (score: $0.0, excerpt: $0.1) }
    }

    public func ask(question: String, meetings: [Meeting]) async throws -> Answer {
        let ranked = Self.retrieve(question: question, meetings: meetings)

        guard let best = ranked.first, best.score >= Self.minimumScore else {
            return Answer(
                text: "I couldn't find anything in your meetings that mentions that.",
                excerpts: [])
        }
        let excerpts = ranked.map { $0.excerpt }

        let context = Self.context(for: excerpts, wordBudget: model.chunkWordLimit)
        let text = try await model.generate(
            instructions: instructions,
            prompt: """
                Transcript excerpts from past meetings:

                \(context)

                Question: \(question)
                """)
        return Answer(text: text, excerpts: excerpts)
    }

    private var instructions: String {
        """
        You answer questions about the user's past meetings using only the \
        transcript excerpts provided.

        Rules:
        - The excerpts are your only source of fact. Never use outside \
        knowledge or guess at what a meeting probably concluded.
        - Back every claim with its source as (meeting title, mm:ss), using \
        the timestamp on the excerpt it came from.
        - The excerpts are the most relevant passages that exist, not the \
        whole meetings. If they do not answer the question, say that plainly \
        rather than bridging the gap.
        - Distinguish "raised" from "decided": a topic being mentioned is not \
        it being agreed. Report only what the words show.
        - Be terse. No preamble, no "based on the excerpts" framing.
        """
    }

    /// Formats excerpts for the prompt, oldest meeting first, until the word
    /// budget runs out. The budget exists because the on-device model's context
    /// covers prompt and completion together — overfill it and the answer is
    /// truncated, not merely slow.
    static func context(for excerpts: [Excerpt], wordBudget: Int) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var used = 0
        var blocks: [String] = []
        // Chronological order reads as a conversation; relevance order already
        // decided *which* excerpts made the cut.
        for excerpt in excerpts.sorted(by: { ($0.startedAt, $0.start) < ($1.startedAt, $1.start) }) {
            let line =
                "Meeting: \(excerpt.meetingTitle) (\(dateFormatter.string(from: excerpt.startedAt)))\n"
                + "[\(TimestampLinker.clockString(excerpt.start))] "
                + "[\(excerpt.speaker.displayName)] \(excerpt.text)"
            let words = line.split(separator: " ").count
            if used + words > wordBudget && !blocks.isEmpty { break }
            used += words
            blocks.append(line)
        }
        return blocks.joined(separator: "\n\n")
    }
}
