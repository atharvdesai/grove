import Foundation

/// Who was talking.
///
/// Grove gets this for free rather than from a diarization model: the microphone
/// stream is the user and the system-audio stream is everyone else. That is
/// exactly the "Me / Them" split Granola shows, without running any extra ML.
/// Distinguishing individual remote participants needs real diarization and is
/// deliberately out of scope for v1.
public enum Speaker: String, Codable, Sendable, CaseIterable {
    case me
    case them

    public var displayName: String {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        }
    }
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let speaker: Speaker
    public let text: String
    /// Seconds from the start of the recording.
    public let start: TimeInterval
    public let end: TimeInterval

    public init(
        id: UUID = UUID(),
        speaker: Speaker,
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public private(set) var segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment] = []) {
        self.segments = segments
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// Keeps the timeline ordered as segments arrive from two independent
    /// transcribers that finalize at different rates.
    public mutating func insert(_ segment: TranscriptSegment) {
        let index = segments.firstIndex { $0.start > segment.start } ?? segments.count
        segments.insert(segment, at: index)
    }

    /// Appends a later recording session onto this one.
    ///
    /// Resuming a meeting starts a fresh recorder, so its segments are timed
    /// from zero again. Shifting them past the end of what is already here keeps
    /// one increasing timeline, which everything downstream assumes: `merged()`
    /// joins by adjacency, `withoutEcho()` compares within a time window, and
    /// the transcript view reads top to bottom.
    ///
    /// - Parameter gap: Silence inserted between the two sessions, so a resumed
    ///   meeting does not look like the speaker continued mid-sentence.
    public func appending(_ later: Transcript, gap: TimeInterval = 1) -> Transcript {
        guard !later.isEmpty else { return self }
        guard !isEmpty else { return later }

        let offset = (segments.map(\.end).max() ?? 0) + gap
        var combined = self
        for segment in later.segments {
            combined.insert(
                TranscriptSegment(
                    id: segment.id,
                    speaker: segment.speaker,
                    text: segment.text,
                    start: segment.start + offset,
                    end: segment.end + offset))
        }
        return combined
    }

    /// Speaker-labelled plain text, which is what the enhancement prompt sees.
    public func formatted() -> String {
        segments
            .map { "[\($0.speaker.displayName)] \($0.text)" }
            .joined(separator: "\n")
    }

    /// Drops "Me" segments that are really the microphone re-hearing the far end
    /// through the speakers.
    ///
    /// The OS voice-processing unit removes most of this, but it cannot always
    /// engage (some virtual and aggregate input devices refuse it), and the
    /// residue is bad: the same sentence appears twice, attributed to both
    /// speakers, which then misleads the enhancement pass about who said what.
    ///
    /// Only `.me` segments are ever discarded. The system-audio tap is a clean
    /// digital copy of the far end, so when the two disagree it is the
    /// microphone that is wrong.
    /// - Parameter minimumWords: Utterances shorter than this are never treated
    ///   as echo. "Yeah", "Agreed", "Okay" overlap trivially with anything, and
    ///   wrongly deleting the user's agreement is worse than keeping a duplicate.
    public func withoutEcho(
        similarityThreshold: Double = 0.7,
        window: TimeInterval = 8,
        minimumWords: Int = 4
    ) -> Transcript {
        let remoteSegments = segments.filter { $0.speaker == .them }
        guard !remoteSegments.isEmpty else { return self }

        let kept = segments.filter { segment in
            guard segment.speaker == .me else { return true }
            guard Transcript.normalize(segment.text).count >= minimumWords else { return true }

            let nearby = remoteSegments.filter { remote in
                remote.start < segment.end + window && segment.start < remote.end + window
            }
            return !nearby.contains { remote in
                Transcript.similarity(segment.text, remote.text) >= similarityThreshold
            }
        }
        return Transcript(segments: kept)
    }

    /// Containment: shared words over the length of the *shorter* utterance.
    ///
    /// Jaccard was the obvious choice and it failed on a real recording, where
    /// the tap heard "About forty percent bail there." and the echoed mic copy
    /// came back "About 40% bail there." — the same sentence, scored 0.5 because
    /// ASR spells numbers differently in each. Containment tolerates one side
    /// being wordier, which is exactly how these pairs differ.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(normalize(lhs))
        let right = Set(normalize(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        return Double(intersection) / Double(min(left.count, right.count))
    }

    static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The merged segment best matching a note's `(mm:ss)` reference: the one
    /// containing that moment, else the next to start, else the last. This is
    /// how a timestamp written into the notes finds its way back to a real
    /// transcript moment when the reader clicks it.
    public func segment(at time: TimeInterval) -> TranscriptSegment? {
        let merged = merged()
        if let covering = merged.first(where: { $0.start <= time && time < $0.end }) {
            return covering
        }
        return merged.first(where: { $0.start >= time }) ?? merged.last
    }

    /// Merges runs by the same speaker so the reader sees paragraphs rather than
    /// one line per utterance.
    public func merged(gapTolerance: TimeInterval = 2.0) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            if let last = result.last,
                last.speaker == segment.speaker,
                segment.start - last.end <= gapTolerance
            {
                result[result.count - 1] = TranscriptSegment(
                    id: last.id,
                    speaker: last.speaker,
                    text: last.text + " " + segment.text,
                    start: last.start,
                    end: segment.end)
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
