import Foundation

/// Search in plain English: "with Janet last month", "hiring meetings about
/// salary", "yesterday in School".
///
/// Parsed by hand rather than by a model so it filters as you type. Whatever
/// isn't a person, a date or a folder is matched as words, in any form.
public struct MeetingQuery: Sendable, Equatable {
    public var person: String?
    public var from: Date?
    public var to: Date?
    public var folder: String?
    public var words: String = ""

    public static func parse(
        _ text: String, folders: [String], now: Date = Date(), calendar: Calendar = .current
    ) -> MeetingQuery {
        var query = MeetingQuery()
        var rest = " " + text.lowercased() + " "

        func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest))
            else { return nil }
            let groups = (0..<match.numberOfRanges).map { index -> String in
                guard let range = Range(match.range(at: index), in: rest) else { return "" }
                return String(rest[range])
            }
            if let whole = Range(match.range, in: rest) { rest.replaceSubrange(whole, with: " ") }
            return groups
        }

        let today = calendar.startOfDay(for: now)
        let day: TimeInterval = 86_400
        if take(#"\b(today)\b"#) != nil {
            query.from = today
        } else if take(#"\b(yesterday)\b"#) != nil {
            query.from = today.addingTimeInterval(-day)
            query.to = today
        } else if take(#"\b(this week)\b"#) != nil {
            query.from = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        } else if take(#"\b(last week)\b"#) != nil {
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            query.from = thisWeek.addingTimeInterval(-7 * day)
            query.to = thisWeek
        } else if take(#"\b(this month)\b"#) != nil {
            query.from = calendar.dateInterval(of: .month, for: now)?.start
        } else if take(#"\b(last month)\b"#) != nil {
            let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
            query.from = calendar.date(byAdding: .month, value: -1, to: thisMonth)
            query.to = thisMonth
        } else if let groups = take(#"\b(?:last|past) (\d+) days?\b"#), let n = Double(groups[1]) {
            query.from = today.addingTimeInterval(-n * day)
        }

        // Folder names, longest first so "Side projects" beats "projects".
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            let name = NSRegularExpression.escapedPattern(for: folder.lowercased())
            if take(#"\b(?:in |from )?"# + name + #"(?: meetings?| folder)?\b"#) != nil {
                query.folder = folder
                break
            }
        }

        if let groups = take(#"\bwith ([a-z][a-z'.-]*(?: [a-z][a-z'.-]*)?)"#) {
            // Up to two words of name, but "with janet about pricing" means
            // Janet — a joining word ends the name and goes back to the search.
            let joiners: Set<String> = ["about", "on", "re", "regarding", "in", "from", "and", "for"]
            let parts = groups[1].split(separator: " ").map(String.init)
            if parts.count == 2, joiners.contains(parts[1]) {
                query.person = parts[0]
                rest += " \(parts[1]) "
            } else {
                query.person = groups[1]
            }
        }

        query.words = rest
            .replacingOccurrences(of: #"\b(meetings?|about|regarding|re|the|on|in)\b"#, with: " ",
                                  options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        return query
    }

    public func matches(_ meeting: Meeting) -> Bool {
        if let from, meeting.startedAt < from { return false }
        if let to, meeting.startedAt >= to { return false }
        if let folder, meeting.folder != folder { return false }
        if let person {
            let people = (meeting.attendees ?? []) + [meeting.speakerName ?? ""]
                + meeting.resolvedInsights.commitments.map(\.owner)
            let wanted = person.lowercased()
            let found = people.contains { $0.lowercased().hasPrefix(wanted) }
                || SearchTerms.text(meeting.title, matchesQuery: person)
            if !found { return false }
        }
        guard !words.isEmpty else { return true }
        let text = [
            meeting.title, meeting.roughNotes, meeting.enhancedNotes ?? "",
            meeting.transcript.formatted(), (meeting.attendees ?? []).joined(separator: " "),
        ].joined(separator: " ")
        return SearchTerms.text(text, matchesQuery: words)
    }

    /// A short description of the filters in play, for the search field.
    public var summary: String {
        var parts: [String] = []
        if let person { parts.append("with \(person.capitalized)") }
        if let folder { parts.append("in \(folder)") }
        if from != nil || to != nil { parts.append("in that time") }
        if !words.isEmpty { parts.append("mentioning “\(words)”") }
        return parts.joined(separator: " · ")
    }
}

/// When a promise is due, from the way it was said: "by Friday", "tomorrow",
/// "end of the week", "November 30".
public enum DueDates {
    public static func date(
        for phrase: String, saidOn meetingDate: Date, calendar: Calendar = .current
    ) -> Date? {
        let text = phrase.lowercased()
        let start = calendar.startOfDay(for: meetingDate)
        if text.contains("today") || text.contains("tonight") || text.contains("end of day") {
            return start
        }
        if text.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: start)
        }
        if text.contains("end of the week") || text.contains("end of week") || text.contains("eow") {
            return next(weekday: 6, after: start, calendar: calendar, includeToday: true)
        }
        if text.contains("next week") {
            return next(weekday: 2, after: start, calendar: calendar, includeToday: false)
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let index = weekdays.firstIndex(where: { text.contains($0) }) {
            return next(weekday: index + 1, after: start, calendar: calendar, includeToday: false)
        }
        // An explicit date ("November 30", "Nov 10th"), in the meeting's year,
        // rolled forward if that would put it before the meeting.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
            let match = detector.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)),
            let found = match.date
        {
            var parts = calendar.dateComponents([.month, .day], from: found)
            parts.year = calendar.component(.year, from: meetingDate)
            if let dated = calendar.date(from: parts) {
                return dated < start ? calendar.date(byAdding: .year, value: 1, to: dated) : dated
            }
        }
        return nil
    }

    private static func next(weekday: Int, after date: Date, calendar: Calendar, includeToday: Bool) -> Date? {
        if includeToday, calendar.component(.weekday, from: date) == weekday { return date }
        return calendar.nextDate(
            after: date, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)
    }
}
