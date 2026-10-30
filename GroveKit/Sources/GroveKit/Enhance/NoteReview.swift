import Foundation

/// A line of the user's notes that the transcript says otherwise about.
public struct NoteConflict: Codable, Sendable, Equatable, Identifiable {
    /// The user's line, exactly as written.
    public let note: String
    /// What was actually said, and when and by whom.
    public let transcriptSays: String
    public let time: TimeInterval
    public let speaker: String
    /// Why they disagree, in a few words: "the transcript says $16, not $18".
    public let explanation: String
    /// The line rewritten to match the transcript, offered as a one-click fix.
    public let suggestion: String?

    public var id: String { note }
}

/// Checks the user's own notes against what was said, and asks about the
/// lines that disagree.
///
/// Notes are typed fast, mid-conversation, and a wrong number or a misheard
/// name in them is worse than a gap: it's in your own words, so you'll trust
/// it later. This only flags *contradictions* — a different number, date,
/// name, owner or outcome — never lines the transcript just doesn't mention,
/// because plenty of good notes are things nobody said out loud.
public struct NoteChecker: Sendable {
    public let model: any NoteWritingModel

    public init(model: any NoteWritingModel = FoundationModelsEngine()) {
        self.model = model
    }

    /// Notes per model call, so the prompt fits the on-device model.
    static let batchSize = 12
    static let excerptsPerNote = 3

    public func check(roughNotes: String, transcript: Transcript) async throws -> [NoteConflict] {
        let passages = transcript.merged()
        let candidates: [(note: String, evidence: [TranscriptSegment])] = Self.noteLines(roughNotes)
            .compactMap { note in
                let evidence = Self.evidence(for: note, in: passages)
                return evidence.isEmpty ? nil : (note, evidence)
            }

        var conflicts: [NoteConflict] = []
        var start = 0
        while start < candidates.count {
            let batch = Array(candidates[start..<min(start + Self.batchSize, candidates.count)])
            let response = try await model.generate(
                instructions: Self.instructions, prompt: Self.prompt(for: batch))
            conflicts += Self.parse(response, batch: batch)
            start += Self.batchSize
        }
        return conflicts
    }

    static let instructions = """
        You compare a person's meeting notes with transcript excerpts. For each \
        numbered note, decide whether the excerpts CONTRADICT it: a different \
        number, price, date, name, owner, or outcome. Different wording of the \
        same fact is not a contradiction. A note the excerpts don't mention is \
        not a contradiction.

        Output one line per note, nothing else:
        <n>: OK
        or
        <n>: CONFLICT <excerpt letter> | <why, under 15 words> | FIX: <the note rewritten to match the transcript>

        Only say CONFLICT when an excerpt clearly states something different.
        """

    static func prompt(for batch: [(note: String, evidence: [TranscriptSegment])]) -> String {
        batch.enumerated().map { index, item in
            let excerpts = item.evidence.enumerated().map { letterIndex, segment in
                "  [\(letter(letterIndex))] (\(TimestampLinker.clockString(segment.start))) "
                    + "\(segment.speaker.displayName): \(segment.text)"
            }
            return "Note \(index + 1): \"\(item.note)\"\n" + excerpts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func parse(
        _ response: String, batch: [(note: String, evidence: [TranscriptSegment])]
    ) -> [NoteConflict] {
        response.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -*•\t"))
                .replacingOccurrences(of: "**", with: "")
            guard let colon = line.firstIndex(of: ":"),
                let number = Int(line[..<colon].filter(\.isNumber)),
                (1...batch.count).contains(number)
            else { return nil }
            let verdict = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard verdict.uppercased().hasPrefix("CONFLICT") else { return nil }

            let parts = verdict.dropFirst("CONFLICT".count)
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let item = batch[number - 1]
            let letterText = parts.first?.lowercased().filter(\.isLetter) ?? ""
            let excerptIndex = letterText.first.flatMap { index(ofLetter: $0) } ?? 0
            let segment = item.evidence[min(excerptIndex, item.evidence.count - 1)]
            let explanation = parts.count > 1 ? parts[1] : "The transcript says something different."
            let fix = parts.count > 2
                ? parts[2].replacingOccurrences(of: "FIX:", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespaces)
                : ""

            return NoteConflict(
                note: item.note, transcriptSays: segment.text, time: segment.start,
                speaker: segment.speaker.displayName, explanation: explanation,
                suggestion: fix.isEmpty ? nil : fix)
        }
    }

    // MARK: - Finding the evidence

    /// The user's note lines worth checking: bullets and sentences with enough
    /// words to state a fact. Headings and one-word jottings are skipped.
    static func noteLines(_ notes: String) -> [String] {
        notes.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return nil }
            let text = line.replacingOccurrences(
                of: #"^([-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            return TopicSegmenter.words(in: text) >= 3 ? text : nil
        }
    }

    /// The passages that talk about the same thing as a note, best first.
    static func evidence(for note: String, in passages: [TranscriptSegment]) -> [TranscriptSegment] {
        let terms = Set(TopicSegmenter.content(of: note))
        guard !terms.isEmpty else { return [] }
        return passages
            .map { passage -> (Double, TranscriptSegment) in
                let words = Set(TopicSegmenter.content(of: passage.text))
                return (Double(SearchTerms.matchCount(terms, in: words)) / Double(terms.count), passage)
            }
            .filter { $0.0 >= 0.34 }
            .sorted { $0.0 > $1.0 }
            .prefix(excerptsPerNote)
            .map(\.1)
    }

    private static func letter(_ index: Int) -> String {
        String(Character(UnicodeScalar(UInt8(97 + index))))
    }

    private static func index(ofLetter letter: Character) -> Int? {
        guard let ascii = letter.asciiValue, ascii >= 97, ascii < 97 + 26 else { return nil }
        return Int(ascii) - 97
    }
}

/// Tidies the user's own notes — their points, their order — and cites every
/// line to the moment in the transcript that backs it.
///
/// Different from the full write-up: nothing new is added. A polished line is
/// the same thought, spelled out, with the names and numbers checked against
/// what was said, so the result is something you can paste anywhere and
/// still stand behind. Each line that the transcript supports ends in a
/// clickable `(m:ss)`; a line without one is one the transcript doesn't cover.
public struct NotePolisher: Sendable {
    public let model: any NoteWritingModel

    public init(model: any NoteWritingModel = FoundationModelsEngine()) {
        self.model = model
    }

    public func polish(roughNotes: String, transcript: Transcript) async throws -> String {
        let notes = roughNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            throw CaptureError.message("There are no notes of yours to polish.")
        }
        let polished = try await model.generate(
            instructions: Self.instructions,
            prompt: """
                Transcript (evidence — for checking names, numbers and wording):
                <transcript>
                \(evidence(notes: notes, transcript: transcript))
                </transcript>

                My notes:
                <notes>
                \(notes)
                </notes>
                """)
        return TimestampLinker.link(notes: polished, transcript: transcript)
    }

    static let instructions = """
        You polish a person's own meeting notes. Rewrite each of their lines so it \
        reads clearly: fix typos, expand shorthand and abbreviations, and complete \
        fragments — using the transcript to get names, numbers and dates exactly \
        right.

        Rules:
        - Keep their points, their order and their headings. One output bullet \
        per note line.
        - Add nothing they didn't write. No new topics, no summary, no conclusions.
        - If the transcript contradicts a note, write what the transcript says.
        - Plain Markdown. No preamble.
        """

    /// The whole transcript when it fits; otherwise the passages that bear on
    /// the notes, so a long meeting still fits the on-device model.
    private func evidence(notes: String, transcript: Transcript) -> String {
        let full = transcript.formatted()
        guard TopicSegmenter.words(in: full) > model.singlePassWordLimit else { return full }
        let passages = transcript.merged()
        var chosen: [TranscriptSegment] = []
        for line in NoteChecker.noteLines(notes) {
            for passage in NoteChecker.evidence(for: line, in: passages)
            where !chosen.contains(where: { $0.id == passage.id }) {
                chosen.append(passage)
            }
        }
        var used = 0
        return chosen.sorted { $0.start < $1.start }
            .prefix { passage in
                used += TopicSegmenter.words(in: passage.text)
                return used <= model.singlePassWordLimit
            }
            .map { "[\(TimestampLinker.clockString($0.start))] [\($0.speaker.displayName)] \($0.text)" }
            .joined(separator: "\n")
    }
}
