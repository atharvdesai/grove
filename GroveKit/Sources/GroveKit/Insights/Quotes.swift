import Foundation

extension Meeting {
    /// A line from the meeting as a quote you can paste anywhere and still
    /// stand behind: who said it, in which meeting, on what day, at what time.
    ///
    ///     “10% off the first year if signed by November 30.”
    ///     — Janet Liu, Acme SSO check-in, Oct 20 (14:05)
    public func quote(_ text: String, speaker: Speaker? = nil, at time: TimeInterval? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        var attribution: [String] = []
        if let speaker { attribution.append(displayName(for: speaker)) }
        attribution.append(title)
        var dated = formatter.string(from: startedAt)
        if let time { dated += " (\(TimestampLinker.clockString(time)))" }
        attribution.append(dated)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "“\(body)”\n— \(attribution.joined(separator: ", "))"
    }
}

/// A stretch of a recording the user marked as off the record.
public struct OffRecordSpan: Sendable, Equatable {
    public let start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

extension Transcript {
    /// The transcript with everything said off the record removed — not
    /// hidden, removed — so it can't reach notes, chat, email or the files.
    /// A segment that merely overlaps a span goes too: half a sentence of
    /// something private is still private.
    public func removing(_ spans: [OffRecordSpan]) -> Transcript {
        guard !spans.isEmpty else { return self }
        return Transcript(segments: segments.filter { segment in
            !spans.contains { segment.start < $0.end && segment.end > $0.start }
        })
    }
}
