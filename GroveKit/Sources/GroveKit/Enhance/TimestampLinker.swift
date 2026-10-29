import Foundation

/// Appends `(mm:ss)` references to enhanced notes, pointing each line at the
/// transcript moment it rests on.
///
/// Granola does this with a magnifying glass per note; Grove puts the time
/// straight into the Markdown, so the reference survives export to Obsidian or
/// anywhere else the file is read.
///
/// The link is computed, not written by the model: each note line is matched
/// back to the transcript segment that covers it best by word containment,
/// and lines with no good match are left alone. A generated timestamp would
/// occasionally point at the wrong minute and look authoritative doing it — a
/// computed one can only point at real overlap or stay silent.
public enum TimestampLinker {

    /// How much of a note line a segment must cover to be named as its source.
    /// The enhancement pass works from the transcript's own wording, so real
    /// matches score high; the floor only has to catch lines that came from
    /// the user's rough notes instead.
    public static let threshold = 0.5

    /// Lines with fewer content words than this are never linked. Short lines
    /// ("Ship it") overlap with everything and match nothing in particular.
    public static let minimumWords = 4

    public static func link(notes: String, transcript: Transcript) -> String {
        let segments = transcript.merged()
        guard !segments.isEmpty else { return notes }

        return notes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let segment = bestSegment(for: String(line), in: segments) else {
                    return String(line)
                }
                return "\(line) (\(clockString(segment.start)))"
            }
            .joined(separator: "\n")
    }

    /// The segment covering the largest share of the line's words, or nil when
    /// nothing passes the floor. Headings and already-timed lines never match.
    static func bestSegment(for line: String, in segments: [TranscriptSegment])
        -> TranscriptSegment?
    {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let words = Transcript.normalize(
            trimmed.replacingOccurrences(of: "^[-*\\d. )]+", with: "", options: .regularExpression))
        guard words.count >= minimumWords else { return nil }

        var best: (score: Double, segment: TranscriptSegment)?
        for segment in segments {
            let segmentWords = Set(Transcript.normalize(segment.text))
            guard !segmentWords.isEmpty else { continue }
            let covered = words.filter { segmentWords.contains($0) }.count
            let score = Double(covered) / Double(words.count)
            if score >= threshold, score > (best?.score ?? 0) {
                best = (score, segment)
            }
        }
        return best?.segment
    }

    /// `m:ss` under an hour, `h:mm:ss` above it — the same clock the live
    /// transcript view shows.
    public static func clockString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
