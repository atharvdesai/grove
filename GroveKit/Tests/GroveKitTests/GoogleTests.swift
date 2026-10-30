import XCTest

@testable import GroveKit

final class GoogleTests: XCTestCase {
    private let config = GoogleConfig(clientID: "123-abc.apps.googleusercontent.com")!

    func testPKCEMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertFalse(PKCE.verifier().contains("="))
    }

    func testConfigRejectsAnythingButAClientID() {
        XCTAssertNil(GoogleConfig(clientID: nil))
        XCTAssertNil(GoogleConfig(clientID: "not-a-client-id"))
        XCTAssertEqual(config.callbackScheme, "com.googleusercontent.apps.123-abc")
        XCTAssertEqual(config.redirectURI, "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }

    func testAuthorizationURLAsksForOfflineSendOnlyAccess() {
        let url = GoogleOAuth.authorizationURL(config: config, challenge: "c", state: "s")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        XCTAssertEqual(value("access_type"), "offline")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertTrue(value("scope")?.contains("gmail.send") == true)
        XCTAssertFalse(value("scope")?.contains("gmail.readonly") == true, "Grove never reads mail")
    }

    func testCallbackStateMustMatch() throws {
        let good = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?code=xyz&state=s1")!
        XCTAssertEqual(try GoogleOAuth.code(from: good, expectedState: "s1"), "xyz")
        XCTAssertThrowsError(try GoogleOAuth.code(from: good, expectedState: "other"))
        let denied = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?error=access_denied&state=s1")!
        XCTAssertThrowsError(try GoogleOAuth.code(from: denied, expectedState: "s1"))
    }

    func testCalendarParsingKeepsRealMeetingsOnly() throws {
        let json = """
            {"items": [
              {"summary": "Acme sync", "status": "confirmed",
               "start": {"dateTime": "2026-10-30T15:00:00-07:00"},
               "end": {"dateTime": "2026-10-30T15:30:00-07:00"},
               "hangoutLink": "https://meet.google.com/abc-defg-hij",
               "attendees": [
                 {"email": "me@example.com", "self": true, "responseStatus": "accepted"},
                 {"email": "janet@acme.com", "displayName": "Janet Liu"}
               ]},
              {"summary": "Declined", "status": "confirmed",
               "start": {"dateTime": "2026-10-30T16:00:00Z"}, "end": {"dateTime": "2026-10-30T17:00:00Z"},
               "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "declined"}]},
              {"summary": "Cancelled", "status": "cancelled",
               "start": {"dateTime": "2026-10-30T16:00:00Z"}, "end": {"dateTime": "2026-10-30T17:00:00Z"}},
              {"summary": "Holiday", "start": {"date": "2026-10-31"}, "end": {"date": "2026-11-01"}}
            ]}
            """
        let events = try GoogleCalendar.parse(Data(json.utf8))
        XCTAssertEqual(events.map(\.title), ["Acme sync", "Holiday"])
        XCTAssertEqual(events[0].attendees, ["Janet Liu"], "the user is not their own attendee")
        XCTAssertTrue(events[0].hasVideoLink)
        XCTAssertTrue(events[1].isAllDay)
    }

    func testSummaryEmailDropsAppOnlyTimestampsAndEscapesHTML() {
        let meeting = Meeting(
            title: "Pricing <review>",
            enhancedNotes: "## Decisions\n- Pro is **$16** (0:30)",
            attendees: ["Janet Liu"])
        let email = SummaryEmail(meeting: meeting, to: ["me@example.com"])
        XCTAssertEqual(email?.subject, "Notes: Pricing <review>")
        XCTAssertTrue(email?.markdown.contains("- Pro is **$16**\n") == true)
        XCTAssertFalse(email?.markdown.contains("(0:30)") == true)
        XCTAssertTrue(email?.markdown.contains("With Janet Liu") == true)

        let html = SummaryEmail.html(from: "## A <b>\n- **bold** item")
        XCTAssertTrue(html.contains("<h3>A &lt;b&gt;</h3>"))
        XCTAssertTrue(html.contains("<li><strong>bold</strong> item</li>"))
    }

    func testNothingToSendIsNoEmail() {
        XCTAssertNil(SummaryEmail(meeting: Meeting(title: "Empty"), to: ["me@example.com"]))
        XCTAssertNil(SummaryEmail(meeting: Meeting(title: "x", roughNotes: "hi"), to: []))
    }

    func testMIMEIsMultipartWithAnEncodedSubject() {
        let mime = SummaryEmail(to: ["a@b.com"], subject: "Café", markdown: "hi").mime(boundary: "B")
        XCTAssertTrue(mime.contains("To: a@b.com\r\n"))
        XCTAssertTrue(mime.contains("Subject: =?UTF-8?B?"))
        XCTAssertTrue(mime.contains("multipart/alternative; boundary=\"B\""))
        XCTAssertTrue(mime.contains("--B\r\nContent-Type: text/html; charset=UTF-8"))
        XCTAssertTrue(mime.hasSuffix("--B--\r\n"))
    }
}
