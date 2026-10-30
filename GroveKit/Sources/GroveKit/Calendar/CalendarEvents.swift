import EventKit
import Foundation

/// A calendar event, reduced to what naming a meeting needs.
public struct CalendarEvent: Sendable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// Other people invited, by name (or email when no name is known). Never
    /// includes the user.
    public let attendees: [String]
    /// A Zoom, Meet, Teams or Webex link in the event — the best sign it is a
    /// call rather than a reminder to pick up groceries.
    public let hasVideoLink: Bool

    public init(
        title: String, start: Date, end: Date, isAllDay: Bool = false,
        attendees: [String] = [], hasVideoLink: Bool = false
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.hasVideoLink = hasVideoLink
    }
}

/// Reads the user's calendar, on-device, to name meetings and say who was in
/// them. EventKit reads the calendars macOS already syncs; nothing here touches
/// the network.
public enum CalendarEvents {
    private static let store = EKEventStore()

    /// Events this close to starting count as the meeting you are joining.
    /// People join early far more often than late.
    public static let earlyJoin: TimeInterval = 10 * 60

    public static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks once; afterwards macOS answers from the user's earlier choice, so
    /// a "no" can only be changed in System Settings.
    public static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The event happening at `date`, if the calendar has one.
    public static func current(at date: Date = Date()) -> CalendarEvent? {
        guard hasAccess else { return nil }
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-6 * 3600),
            end: date.addingTimeInterval(earlyJoin), calendars: nil)
        return best(in: store.events(matching: predicate).map(event(from:)), at: date)
    }

    /// Of the events overlapping `date`, the one most likely to be this call:
    /// timed rather than all-day, with a call link, with other people, then
    /// the one that started closest to now.
    static func best(in events: [CalendarEvent], at date: Date) -> CalendarEvent? {
        events
            .filter { !$0.isAllDay && $0.start.addingTimeInterval(-earlyJoin) <= date && date < $0.end }
            .min { lhs, rhs in
                if lhs.hasVideoLink != rhs.hasVideoLink { return lhs.hasVideoLink }
                if lhs.attendees.isEmpty != rhs.attendees.isEmpty { return !lhs.attendees.isEmpty }
                return abs(lhs.start.timeIntervalSince(date)) < abs(rhs.start.timeIntervalSince(date))
            }
    }

    static let videoHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]

    private static func event(from event: EKEvent) -> CalendarEvent {
        let attendees = (event.attendees ?? [])
            .filter { !$0.isCurrentUser }
            .compactMap { participant -> String? in
                if let name = participant.name, !name.isEmpty { return name }
                let address = participant.url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                return address.isEmpty ? nil : address
            }
        let haystack = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return CalendarEvent(
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            attendees: attendees,
            hasVideoLink: videoHosts.contains { haystack.contains($0) })
    }
}
