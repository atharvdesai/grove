import Foundation
import FoundationModels

/// Turns rough notes plus a transcript into polished notes, on-device.
///
/// This is the move Grove exists for, and it is not summarization: the user's
/// notes are the outline and the transcript is the evidence. Output follows the
/// user's headings, order, and emphasis — a summarizer that reorganizes the
/// meeting into its own idea of what mattered has failed at this job.
@available(macOS 26.0, *)
public struct NoteEnhancer: Sendable {

    /// The engine that actually writes. Swapping this is how a larger local
    /// model gets added; everything below — prompting, chunking, the refusal
    /// floor — is engine-independent and stays put.
    public let model: any NoteWritingModel

    /// Below this many transcribed words, Grove refuses to write notes at all.
    ///
    /// Prompting alone cannot hold this line. Asked to produce meeting notes
    /// from "let's talk about the OKRs", the model does not decline — it reports
    /// that the team discussed and finalised the OKRs, because that is what
    /// notes from such a meeting would plausibly look like. The failure is worse
    /// than an empty result: it is confident, well-formatted, and wrong about
    /// what a real meeting concluded.
    ///
    /// So the floor is enforced in code, before the model is ever called. A
    /// genuine minute of conversation runs to a couple of hundred words; this
    /// only catches meetings where essentially nothing was captured.
    public static let minimumTranscriptWords = 40

    public typealias Availability = ModelAvailability

    public init(model: any NoteWritingModel = FoundationModelsEngine()) {
        self.model = model
    }

    public var availability: ModelAvailability { model.availability }

    /// Availability of the default engine, for callers that have not chosen one.
    public static var availability: ModelAvailability { FoundationModelsEngine().availability }

    public func enhance(
        roughNotes: String,
        transcript: Transcript,
        template: NoteTemplate = .general,
        meetingTitle: String? = nil
    ) async throws -> String {
        let text = transcript.formatted()
        guard !text.isEmpty else {
            throw CaptureError.message("Nothing was transcribed, so there is nothing to enhance")
        }

        let spokenWords = Self.spokenWordCount(transcript)
        guard spokenWords >= Self.minimumTranscriptWords else {
            throw CaptureError.message(
                "Only \(spokenWords) \(spokenWords == 1 ? "word was" : "words were") transcribed — "
                    + "too little to write up without inventing the rest")
        }

        var source = text
        var evidence = Evidence.transcript
        if wordCount(text) > model.singlePassWordLimit {
            // Too long to read at once: facts per topic, then write from those.
            let sheet = try await factSheet(transcript)
            if sheet.isEmpty {
                source = try await condense(text)
            } else {
                source = sheet
                evidence = .facts
            }
        }

        return try await model.generate(
            instructions: instructions(for: template),
            prompt: prompt(
                transcript: source,
                roughNotes: roughNotes,
                template: template,
                meetingTitle: meetingTitle,
                evidence: evidence))
    }

    enum Evidence { case transcript, facts }

    /// Splits the transcript at topic changes, extracts every decision,
    /// action, number and open question from each part, and merges them. See
    /// `TopicSegmenter` and `FactSheet` for why this beats condensing.
    func factSheet(_ transcript: Transcript) async throws -> String {
        var facts: [MeetingFact] = []
        for chunk in TopicSegmenter.chunks(transcript, maxWords: model.chunkWordLimit) {
            let response = try await model.generate(
                instructions: FactSheet.extractionInstructions, prompt: chunk.formatted())
            facts += FactSheet.parse(response, time: chunk.start)
        }
        // Leave room in the final pass for the instructions and the user's notes.
        return FactSheet.render(
            FactSheet.merge(facts), maxWords: model.singlePassWordLimit - 300)
    }

    // MARK: - Prompting

    private func instructions(for template: NoteTemplate) -> String {
        """
        You turn a person's rough meeting notes into polished notes, using the \
        meeting transcript as evidence.

        You are reporting a meeting that happened, not composing a plausible one. \
        The transcript is your only source of fact. Everything you write must be \
        traceable to a specific line in it.

        Rules:
        - The user's notes are the outline. Keep their headings, their order, and \
        their emphasis. Never reorganize into your own structure.
        - Expand each fragment with specifics from the transcript: numbers, names, \
        dates, owners, and decisions. Prefer the speakers' own words.
        - Where the user wrote a question, answer it only if the transcript \
        answers it. Otherwise leave the question standing.
        - Record every decision explicitly stated, including any condition or \
        threshold attached to it.
        - Naming a topic is not discussing it. If a speaker says "let's talk \
        about the OKRs" and the transcript ends there, the OKRs were *raised* and \
        nothing more. Never write that something was discussed, reviewed, agreed, \
        finalised, or assigned unless the transcript shows it actually happening.
        - Never invent owners, dates, numbers, or outcomes, and never emit \
        placeholders like "[Owner Name]" or "TBD". If nobody was named, say \
        nothing about ownership.
        - Omit any section you have no evidence for. Leaving a section out is \
        always better than filling it with a guess.
        - Let the length follow the evidence. Two sentences of transcript support \
        two sentences of notes. Do not pad.
        - If the user noted something the transcript never covers, keep their line \
        unchanged rather than elaborating on it.
        - Be terse and factual. No preamble and no "in this meeting" framing.
        - Output Markdown, starting directly with the first heading.

        For a meeting of this type: \(template.guidance)
        If the user's notes imply no structure, you may draw on these sections, \
        using only the ones the transcript supports: \
        \(template.sections.joined(separator: ", ")).
        """
    }

    private func prompt(
        transcript: String, roughNotes: String, template: NoteTemplate, meetingTitle: String?,
        evidence: Evidence = .transcript
    ) -> String {
        let trimmedNotes = roughNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesBlock =
            trimmedNotes.isEmpty
            ? "(The user took no notes. Use the template sections and keep it brief.)"
            : trimmedNotes

        let evidenceLabel =
            evidence == .facts
            ? "Facts extracted from the full transcript, each with the time it came up "
                + "(treat them as the transcript; later facts supersede earlier ones):"
            : "Transcript:"

        return """
            \(meetingTitle.map { "Meeting: \($0)\n" } ?? "")\(evidenceLabel)

            <transcript>
            \(transcript)
            </transcript>

            My rough notes from during the meeting:

            <notes>
            \(notesBlock)
            </notes>

            Rewrite my notes as polished meeting notes.
            """
    }

    // MARK: - Long meetings

    /// Condenses a long transcript chunk by chunk so the enhancement pass fits
    /// in the model's context. Chunks split on speaker turns rather than raw
    /// word counts, so an utterance is never cut in half.
    private func condense(_ transcript: String) async throws -> String {
        let chunks = Self.chunk(transcript, maxWords: model.chunkWordLimit)
        var condensed: [String] = []
        condensed.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            let text = try await model.generate(
                instructions: """
                    You compress a section of a meeting transcript while losing no \
                    facts. Keep every decision, number, name, owner, date, and \
                    commitment, and keep the speaker labels. Drop only filler and \
                    small talk. Output plain lines, no preamble.
                    """,
                prompt: """
                    Section \(index + 1) of \(chunks.count):

                    \(chunk)
                    """)
            condensed.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return condensed.joined(separator: "\n")
    }

    static func chunk(_ transcript: String, maxWords: Int) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0

        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = line.split(separator: " ").count
            if currentWords + words > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentWords = 0
            }
            current.append(String(line))
            currentWords += words
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    /// Words actually spoken, excluding the `[Me]` / `[Them]` labels that
    /// `Transcript.formatted()` adds — counting those would let a handful of
    /// one-word segments clear the floor on labels alone.
    public static func spokenWordCount(_ transcript: Transcript) -> Int {
        transcript.segments.reduce(0) { total, segment in
            total + segment.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        }
    }
}
