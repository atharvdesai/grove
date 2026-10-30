import Foundation

/// One thing a meeting established, pulled out of one chunk of transcript.
public struct MeetingFact: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case decision = "DECISION"
        case action = "ACTION"
        case number = "NUMBER"
        case question = "QUESTION"
        case point = "POINT"

        /// What survives first when the sheet has to be trimmed to fit.
        var priority: Int {
            switch self {
            case .decision: return 0
            case .action: return 1
            case .number: return 2
            case .question: return 3
            case .point: return 4
            }
        }
    }

    public let kind: Kind
    public let text: String
    /// Start of the chunk it came from, so the final notes can still point at
    /// roughly the right moment.
    public let time: TimeInterval
}

/// Long meetings, the small-model way: extract facts from each topic, then
/// write the notes from the facts.
///
/// Asking a 3B model to *summarise* a chunk loses things — it decides what
/// matters, and it decides badly. Asking it to *fill in a form* (every
/// decision, every action, every number) is the job small models do well. The
/// forms from all chunks are merged — a later statement about the same thing
/// replaces an earlier one, so a price revised mid-meeting ends up revised —
/// and the final writing pass works from that compact, complete sheet instead
/// of a lossy summary of a summary.
public enum FactSheet {
    static let extractionInstructions = """
        You extract facts from part of a meeting transcript. Output one fact per \
        line, each starting with exactly one of these labels:
        DECISION: something explicitly agreed or decided, with any condition attached
        ACTION: a task someone committed to — include who and by when if said
        NUMBER: a figure, price, date, count or deadline, with what it refers to
        QUESTION: something raised and left unanswered
        POINT: any other substantive point made

        Rules: report only what the transcript says. Use people's names when \
        spoken. Keep each line short and specific. No preamble, no commentary, \
        nothing that isn't a labelled line. If the section is small talk, output \
        nothing.
        """

    /// Facts from one chunk, read leniently: the model sometimes adds bullets,
    /// bold, or a lowercase label, and none of that should lose a fact.
    static func parse(_ response: String, time: TimeInterval) -> [MeetingFact] {
        response.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -*•\t"))
                .replacingOccurrences(of: "**", with: "")
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            guard let kind = MeetingFact.Kind(rawValue: label) else { return nil }
            let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : MeetingFact(kind: kind, text: text, time: time)
        }
    }

    /// Drops repeats across chunks. Two facts of the same kind that share most
    /// of their words are the same fact; the later one wins, because a meeting
    /// that comes back to something usually comes back to change it.
    static func merge(_ facts: [MeetingFact]) -> [MeetingFact] {
        var kept: [MeetingFact] = []
        for fact in facts {
            if let index = kept.lastIndex(where: { $0.kind == fact.kind && similar($0.text, fact.text) }) {
                kept.remove(at: index)
            }
            kept.append(fact)
        }
        return kept
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let left = Set(TopicSegmenter.content(of: a))
        let right = Set(TopicSegmenter.content(of: b))
        guard !left.isEmpty, !right.isEmpty else { return false }
        let overlap = Double(left.intersection(right).count) / Double(min(left.count, right.count))
        // Same subject but a different number is a revision, not a repeat —
        // that is exactly the case where the later value must replace the
        // earlier, so it still counts as similar.
        return overlap >= 0.7
    }

    /// The sheet as the final prompt sees it, trimmed to `maxWords` by
    /// dropping the least important kinds first.
    static func render(_ facts: [MeetingFact], maxWords: Int) -> String {
        var chosen = facts
        func wordCount(_ list: [MeetingFact]) -> Int {
            list.reduce(0) { $0 + TopicSegmenter.words(in: $1.text) + 2 }
        }
        while wordCount(chosen) > maxWords,
            let worst = chosen.indices.max(by: { chosen[$0].kind.priority < chosen[$1].kind.priority })
        {
            chosen.remove(at: worst)
        }
        return chosen.map { "[\(TimestampLinker.clockString($0.time))] \($0.kind.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }
}
