import Foundation

/// A stretch of transcript about one thing, small enough for one model call.
public struct TranscriptChunk: Sendable, Equatable {
    public let segments: [TranscriptSegment]
    public var start: TimeInterval { segments.first?.start ?? 0 }
    public var end: TimeInterval { segments.last?.end ?? 0 }
    public var wordCount: Int { segments.reduce(0) { $0 + TopicSegmenter.words(in: $1.text) } }

    /// `[mm:ss] [Speaker] text` lines, the form every prompt uses.
    public func formatted() -> String {
        segments.map { "[\(TimestampLinker.clockString($0.start))] [\($0.speaker.displayName)] \($0.text)" }
            .joined(separator: "\n")
    }
}

/// Splits a long transcript where the conversation changes subject, instead
/// of every N words.
///
/// The on-device model reads about 1,500 words at a time, so a long meeting
/// has to be split. Cutting blindly at a word count splits a discussion down
/// the middle — the decision lands in one chunk and its reasoning in the next,
/// and neither half makes sense alone. Cutting where the topic changes keeps
/// each chunk about one thing, which is what lets a small model summarise it
/// faithfully.
///
/// Topic changes are found the TextTiling way (Hearst, 1997): compare the
/// vocabulary just before each speaker turn with the vocabulary just after; a
/// sharp drop in overlap is a new subject. Long pauses and spoken cues ("moving
/// on", "next item") strengthen a boundary. Pure arithmetic — no model call, so
/// it is instant and testable.
public enum TopicSegmenter {
    /// Words on each side compared when scoring a boundary.
    static let window = 120

    public static func chunks(_ transcript: Transcript, maxWords: Int) -> [TranscriptChunk] {
        let units = splitLongTurns(transcript.merged(), maxWords: max(40, maxWords / 3))
        guard !units.isEmpty else { return [] }
        let total = units.reduce(0) { $0 + words(in: $1.text) }
        guard total > maxWords else { return [TranscriptChunk(segments: units)] }

        let scores = boundaryScores(units)
        let minWords = maxWords / 3
        var chunks: [TranscriptChunk] = []
        var start = 0
        while start < units.count {
            var end = start
            var count = 0
            // Take everything that fits.
            while end < units.count, count + words(in: units[end].text) <= maxWords || end == start {
                count += words(in: units[end].text)
                end += 1
            }
            if end < units.count {
                // Then step back to the strongest topic boundary in the part of
                // the chunk past its minimum size. scores[i] is the boundary
                // after unit i, so cutting there ends the chunk at i + 1.
                var running = 0
                var best: (score: Double, cut: Int)?
                for i in start..<(end - 1) {
                    running += words(in: units[i].text)
                    guard running >= minWords else { continue }
                    if best == nil || scores[i] > best!.score { best = (scores[i], i + 1) }
                }
                if let best { end = best.cut }
            }
            chunks.append(TranscriptChunk(segments: Array(units[start..<end])))
            start = end
        }
        return chunks
    }

    /// How strongly the conversation changes subject after each unit. Higher
    /// means a better place to cut. One score per gap, so `units.count - 1`.
    static func boundaryScores(_ units: [TranscriptSegment]) -> [Double] {
        guard units.count > 1 else { return [] }
        let stems = units.map { content(of: $0.text) }
        return (0..<(units.count - 1)).map { i in
            let before = bag(stems, from: i, step: -1)
            let after = bag(stems, from: i + 1, step: 1)
            var score = 1 - cosine(before, after)
            let pause = units[i + 1].start - units[i].end
            score += min(max(pause, 0) / 10, 1) * 0.3
            if startsNewTopic(units[i + 1].text) { score += 0.35 }
            return score
        }
    }

    /// Phrases people use to change the subject out loud.
    static let topicCues = [
        "moving on", "next item", "next topic", "next up", "let's talk about",
        "let's move", "another thing", "one more thing", "switching gears", "next question",
        "the other thing", "on to", "okay so", "alright so", "all right so",
    ]

    static func startsNewTopic(_ text: String) -> Bool {
        let opening = text.lowercased().prefix(40)
        return topicCues.contains { opening.contains($0) }
    }

    // MARK: - Long monologues

    /// A lecture or a long explanation arrives as one enormous turn. Split such
    /// turns at sentence ends, sharing out their time by word count, so the
    /// segmenter has places to cut.
    static func splitLongTurns(_ units: [TranscriptSegment], maxWords: Int) -> [TranscriptSegment] {
        units.flatMap { unit -> [TranscriptSegment] in
            let total = words(in: unit.text)
            guard total > maxWords else { return [unit] }
            let sentences = sentencesOf(unit.text)
            var pieces: [String] = []
            var current = ""
            for sentence in sentences {
                if words(in: current) + words(in: sentence) > maxWords, !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                current += current.isEmpty ? sentence : " " + sentence
            }
            if !current.isEmpty { pieces.append(current) }

            let duration = unit.end - unit.start
            var cursor = unit.start
            return pieces.map { piece in
                let share = duration * Double(words(in: piece)) / Double(max(total, 1))
                defer { cursor += share }
                return TranscriptSegment(
                    speaker: unit.speaker, text: piece, start: cursor, end: cursor + share)
            }
        }
    }

    static func sentencesOf(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - Vocabulary

    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    /// Stemmed content words, stopwords removed — the vocabulary that says
    /// what a stretch is *about*.
    static func content(of text: String) -> [String] {
        Transcript.normalize(text)
            .filter { $0.count > 2 && !MeetingChat.stopwords.contains($0) }
            .map(SearchTerms.stem)
    }

    /// Word counts gathered from units starting at `index`, walking `step`
    /// (back or forward) until the window is full.
    private static func bag(_ stems: [[String]], from index: Int, step: Int) -> [String: Int] {
        var counts: [String: Int] = [:]
        var taken = 0
        var i = index
        while i >= 0, i < stems.count, taken < window {
            for stem in stems[i] { counts[stem, default: 0] += 1 }
            taken += stems[i].count
            i += step
        }
        return counts
    }

    private static func cosine(_ a: [String: Int], _ b: [String: Int]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let dot = a.reduce(0.0) { $0 + Double($1.value * (b[$1.key] ?? 0)) }
        let norm = { (v: [String: Int]) in sqrt(v.values.reduce(0.0) { $0 + Double($1 * $1) }) }
        return dot / (norm(a) * norm(b))
    }
}
