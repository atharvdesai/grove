import Foundation

/// Reads events from the signed-in user's primary Google Calendar.
public enum GoogleCalendar {
    /// Timed and all-day events between two dates, soonest first.
    public static func events(from start: Date, to end: Date, accessToken: String) async throws
        -> [CalendarEvent]
    {
        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        let formatter = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: start)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GoogleError.server("Google Calendar returned HTTP \(status)")
        }
        return try parse(data)
    }

    // MARK: - Parsing

    private struct Page: Decodable { let items: [Item]? }

    private struct Item: Decodable {
        struct When: Decodable {
            let dateTime: String?
            let date: String?
        }
        struct Attendee: Decodable {
            let email: String?
            let displayName: String?
            /// The API marks the signed-in user's own entry with `"self": true`.
            let isSelf: Bool?
            let responseStatus: String?

            enum CodingKeys: String, CodingKey {
                case email, displayName, responseStatus
                case isSelf = "self"
            }
        }
        struct Conference: Decodable {
            struct Entry: Decodable { let uri: String? }
            let entryPoints: [Entry]?
        }
        let summary: String?
        let status: String?
        let start: When?
        let end: When?
        let attendees: [Attendee]?
        let hangoutLink: String?
        let location: String?
        let description: String?
        let conferenceData: Conference?
    }

    /// Turns the API's JSON into events. Cancelled events and invitations the
    /// user declined are dropped — neither is a meeting they are in.
    public static func parse(_ data: Data) throws -> [CalendarEvent] {
        let page = try JSONDecoder().decode(Page.self, from: data)
        return (page.items ?? []).compactMap { item in
            guard item.status != "cancelled",
                item.attendees?.first(where: { $0.isSelf == true })?.responseStatus != "declined",
                let start = date(item.start), let end = date(item.end)
            else { return nil }

            let attendees = (item.attendees ?? [])
                .filter { $0.isSelf != true }
                .compactMap { $0.displayName ?? $0.email }
            let links = [item.hangoutLink, item.location, item.description]
                + (item.conferenceData?.entryPoints ?? []).map(\.uri)
            let haystack = links.compactMap { $0 }.joined(separator: " ").lowercased()

            return CalendarEvent(
                title: item.summary ?? "",
                start: start, end: end,
                isAllDay: item.start?.dateTime == nil,
                attendees: attendees,
                hasVideoLink: CalendarEvents.videoHosts.contains { haystack.contains($0) })
        }
    }

    private static func date(_ when: Item.When?) -> Date? {
        if let dateTime = when?.dateTime {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateTime) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: dateTime)
        }
        if let day = when?.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: day)
        }
        return nil
    }
}

extension CalendarEvents {
    /// `best(in:at:)`, exposed for events that came from somewhere other than
    /// EventKit — Google Calendar.
    public static func current(in events: [CalendarEvent], at date: Date = Date()) -> CalendarEvent? {
        best(in: events, at: date)
    }
}
