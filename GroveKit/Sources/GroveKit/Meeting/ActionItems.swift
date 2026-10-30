import Foundation

/// A follow-up someone committed to in a meeting.
public struct ActionItem: Sendable, Equatable, Identifiable, Hashable {
    public let meetingID: UUID
    public let meetingTitle: String
    public let meetingDate: Date
    /// The bullet's text, without the list marker or the `(m:ss)` reference.
    public let text: String
    /// Where in the transcript it was said, when the notes linked it.
    public let time: TimeInterval?
    public var isDone: Bool

    public var id: String { "\(meetingID.uuidString)|\(text)" }
}

/// Reads action items out of a meeting's written-up notes.
///
/// Parsed, not generated: the enhancement pass already wrote an "Action items"
/// or "Next steps" section from the transcript, and those lines already carry
/// timestamps into it. Asking the model a second time would cost a minute per
/// meeting and could disagree with the notes the user is reading.
public enum ActionItems {
    /// Headings that introduce follow-ups, matched loosely so "Next steps",
    /// "Action Items" and "Follow-ups" from a hand-edited notes.md all count.
    static let headingWords = ["action", "next step", "follow-up", "follow up", "todo", "to do", "to-do"]

    public static func extract(from meeting: Meeting) -> [ActionItem] {
        guard let notes = meeting.enhancedNotes else { return [] }
        let done = Set(meeting.completedActionItems ?? [])
        return lines(in: notes).map { line in
            let parsed = TimestampLinker.trailingClock(in: line)
            let text = parsed?.text ?? line
            return ActionItem(
                meetingID: meeting.id, meetingTitle: meeting.title,
                meetingDate: meeting.startedAt, text: text, time: parsed?.time,
                isDone: done.contains(text))
        }
    }

    /// Every meeting's items, newest meeting first, open items before done.
    public static func extract(from meetings: [Meeting]) -> [ActionItem] {
        meetings.sorted { $0.startedAt > $1.startedAt }.flatMap { meeting in
            extract(from: meeting).sorted { !$0.isDone && $1.isDone }
        }
    }

    /// The bullet lines under an action-items heading, markers removed.
    static func lines(in notes: String) -> [String] {
        var inSection = false
        var found: [String] = []
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                inSection = headingWords.contains { heading.contains($0) }
                continue
            }
            guard inSection else { continue }
            guard let item = bulletText(line) else { continue }
            found.append(item)
        }
        return found
    }

    /// "- x", "* x", "1. x" and "- [ ] x" all become "x".
    private static func bulletText(_ line: String) -> String? {
        guard
            let range = line.range(
                of: #"^([-*•]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, options: .regularExpression)
        else { return nil }
        let text = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

extension Meeting {
    public var actionItems: [ActionItem] { ActionItems.extract(from: self) }

    /// A copy with one action item ticked or unticked.
    public func settingActionItem(_ text: String, done: Bool) -> Meeting {
        var copy = self
        var completed = Set(completedActionItems ?? [])
        if done { completed.insert(text) } else { completed.remove(text) }
        copy.completedActionItems = completed.isEmpty ? nil : completed.sorted()
        return copy
    }
}
