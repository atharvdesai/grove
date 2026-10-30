import CoreSpotlight
import GroveKit
import UniformTypeIdentifiers
import UserNotifications

/// Puts meetings in the Mac's own search, so ⌘Space "Acme pricing" opens
/// the right meeting without opening Grove first.
///
/// The index holds the title, the one-line summary and the notes — enough for
/// Spotlight to find a meeting by anything said in its write-up. Rebuilt from
/// disk on every library reload, so it never lists a meeting that's gone.
enum SpotlightIndex {
    static let domain = "app.grove.meetings"

    static func update(with meetings: [Meeting]) {
        let items = meetings.map { meeting -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = meeting.title
            attributes.contentDescription = meeting.resolvedInsights.summary.isEmpty
                ? meeting.folder.map { "Meeting · \($0)" } ?? "Meeting"
                : meeting.resolvedInsights.summary
            attributes.textContent = [meeting.enhancedNotes ?? "", meeting.roughNotes]
                .joined(separator: "\n")
            attributes.contentCreationDate = meeting.startedAt
            attributes.keywords = (meeting.attendees ?? []) + [meeting.folder].compactMap { $0 }
            return CSSearchableItem(
                uniqueIdentifier: meeting.id.uuidString, domainIdentifier: domain,
                attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// The meeting a Spotlight result points at, from the activity macOS hands
    /// the app when the user picks it.
    static func meetingID(from activity: NSUserActivity) -> UUID? {
        (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init)
    }
}

/// Turns "I'll send it by Friday" into a notification on Thursday afternoon.
///
/// Only the user's own promises, and only ones with a time attached — a
/// reminder for everything said in every meeting would be noise within a day.
enum CommitmentReminders {
    static func schedule(for meeting: Meeting, myName: String) {
        let mine = meeting.resolvedInsights.commitments.filter { $0.isMine(myName: myName) && $0.due != nil }
        guard !mine.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for commitment in mine {
                guard let due = commitment.due,
                    let when = DueDates.date(for: due, saidOn: meeting.startedAt),
                    let fire = fireDate(for: when), fire > Date()
                else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Due \(due): \(commitment.task)"
                content.body = "You said you'd do this in “\(meeting.title)”."
                content.sound = .default
                content.userInfo = ["meetingID": meeting.id.uuidString]
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                center.add(UNNotificationRequest(
                    // Stable across launches, so re-saving a meeting replaces
                    // its reminders instead of doubling them.
                    identifier: "grove.\(meeting.id.uuidString).\(stableKey(commitment.task))",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
            }
        }
    }

    private static func stableKey(_ text: String) -> String {
        String(text.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }, radix: 36)
    }

    /// The afternoon before it's due, or the morning of if it's due tomorrow
    /// or sooner — late enough to be relevant, early enough to act on.
    static func fireDate(for due: Date) -> Date? {
        let calendar = Calendar.current
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: due)
            .flatMap { calendar.date(bySettingHour: 16, minute: 0, second: 0, of: $0) }
        if let dayBefore, dayBefore > Date() { return dayBefore }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: due)
    }
}
