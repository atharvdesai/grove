import XCTest

@testable import GroveKit

private struct EchoEngine: NoteWritingModel {
    let name = "echo"
    let singlePassWordLimit = 1_500
    let chunkWordLimit = 1_200
    let availability = ModelAvailability.available

    func generate(instructions: String, prompt: String) async throws -> String { prompt }
}

@available(macOS 26.0, *)
final class SearchTermsTests: XCTestCase {
    func testRelatedFormsMatch() {
        XCTAssertTrue(SearchTerms.matches("decide", "decision"))
        XCTAssertTrue(SearchTerms.matches("price", "pricing"))
        XCTAssertTrue(SearchTerms.matches("start", "starting"))
        XCTAssertTrue(SearchTerms.matches("lead", "leading"))
    }

    func testShortWordsNeedAnExactMatch() {
        XCTAssertFalse(SearchTerms.matches("sam", "same"))
        XCTAssertFalse(SearchTerms.matches("budget", "kubernetes"))
    }

    func testLibrarySearchNeedsEveryWord() {
        XCTAssertTrue(SearchTerms.text("Acme pricing review", matchesQuery: "acme price"))
        XCTAssertFalse(SearchTerms.text("Acme kickoff", matchesQuery: "acme price"))
        XCTAssertTrue(SearchTerms.text("anything", matchesQuery: "  "))
    }

    func testRetrievalFindsAWordInAnotherForm() {
        var transcript = Transcript()
        transcript.insert(
            TranscriptSegment(speaker: .me, text: "the decision is sixteen dollars", start: 0, end: 4))
        let ranked = MeetingChat.retrieve(
            question: "what did we decide", meetings: [Meeting(title: "Pricing", transcript: transcript)])
        XCTAssertEqual(ranked.first?.excerpt.text, "the decision is sixteen dollars")
        XCTAssertGreaterThanOrEqual(ranked.first?.score ?? 0, MeetingChat.minimumScore)
    }

    func testTheMeetingTitleHelpsButCannotMatchAlone() {
        var transcript = Transcript()
        transcript.insert(
            TranscriptSegment(speaker: .them, text: "I'd like to lead the mobile app", start: 0, end: 4))
        transcript.insert(
            TranscriptSegment(speaker: .me, text: "sounds good to me", start: 10, end: 12))
        let meetings = [Meeting(title: "1:1 with Dana", transcript: transcript)]

        let ranked = MeetingChat.retrieve(question: "what does Dana want to lead", meetings: meetings)
        XCTAssertEqual(ranked.first?.excerpt.text, "I'd like to lead the mobile app")
        XCTAssertGreaterThanOrEqual(ranked.first?.score ?? 0, MeetingChat.minimumScore)
        XCTAssertFalse(
            ranked.contains { $0.excerpt.text == "sounds good to me" },
            "a title match alone must not pull in every passage of the meeting")
    }

    func testExcerptsUseTheMeetingsSpeakerName() {
        var transcript = Transcript()
        transcript.insert(TranscriptSegment(speaker: .them, text: "budget is fine", start: 0, end: 4))
        var meeting = Meeting(title: "Sync", transcript: transcript)
        meeting.speakerName = "Dana"
        let ranked = MeetingChat.retrieve(question: "budget", meetings: [meeting])
        XCTAssertEqual(ranked.first?.excerpt.speakerName, "Dana")
    }
}

@available(macOS 26.0, *)
final class ActionItemTests: XCTestCase {
    private let notes = """
        ## Decisions
        - Pro is $16 (0:30)

        ## Action items
        - Priya: pricing page copy by Monday (1:05)
        * Marcus: Stripe prices by Friday
        1. [ ] Send the quote

        ## Next steps
        - Check in on the 20th (2:10)
        """

    func testReadsBulletsUnderActionHeadingsOnly() {
        let meeting = Meeting(title: "Pricing", enhancedNotes: notes)
        XCTAssertEqual(
            meeting.actionItems.map(\.text),
            [
                "Priya: pricing page copy by Monday", "Marcus: Stripe prices by Friday",
                "Send the quote", "Check in on the 20th",
            ])
        XCTAssertEqual(meeting.actionItems.first?.time, 65)
        XCTAssertNil(meeting.actionItems[1].time)
    }

    func testTickingAnItemIsRememberedByText() {
        let meeting = Meeting(title: "Pricing", enhancedNotes: notes)
            .settingActionItem("Send the quote", done: true)
        XCTAssertEqual(meeting.actionItems.filter(\.isDone).map(\.text), ["Send the quote"])

        let unticked = meeting.settingActionItem("Send the quote", done: false)
        XCTAssertNil(unticked.completedActionItems)
    }

    func testNoNotesMeansNoItems() {
        XCTAssertTrue(Meeting(title: "Raw", roughNotes: "## Action items\n- x").actionItems.isEmpty)
    }
}

@available(macOS 26.0, *)
final class DigestTests: XCTestCase {
    func testOnlyRecentMeetingsAreIncluded() {
        let now = Date()
        let meetings = [
            Meeting(title: "Old", startedAt: now.addingTimeInterval(-10 * 86_400)),
            Meeting(title: "Monday", startedAt: now.addingTimeInterval(-3 * 86_400)),
            Meeting(title: "Today", startedAt: now.addingTimeInterval(-3_600)),
        ]
        XCTAssertEqual(
            MeetingDigest.meetings(meetings, inLast: 7, now: now).map(\.title), ["Monday", "Today"])
    }

    func testNothingToSummariseIsNoDigest() async throws {
        let digest = MeetingDigest(model: EchoEngine())
        let result = try await digest.write(for: [Meeting(title: "Empty")])
        XCTAssertNil(result)
    }

    func testThePromptCarriesEachMeetingsNotes() async throws {
        let digest = MeetingDigest(model: EchoEngine())
        let result = try await digest.write(for: [
            Meeting(title: "Pricing", enhancedNotes: "- Pro is $16"),
            Meeting(title: "Standup", roughNotes: "release slips"),
        ])
        XCTAssertTrue(result?.contains("### Pricing") == true)
        XCTAssertTrue(result?.contains("Pro is $16") == true)
        XCTAssertTrue(result?.contains("release slips") == true)
    }
}

@available(macOS 26.0, *)
final class CalendarAndTemplateTests: XCTestCase {
    func testPicksTheTimedCallWithPeopleOverAnAllDayEvent() {
        let now = Date()
        let events = [
            CalendarEvent(title: "Offsite week", start: now.addingTimeInterval(-86_400),
                          end: now.addingTimeInterval(86_400), isAllDay: true),
            CalendarEvent(title: "Focus time", start: now.addingTimeInterval(-1_800),
                          end: now.addingTimeInterval(1_800)),
            CalendarEvent(title: "Acme sync", start: now.addingTimeInterval(300),
                          end: now.addingTimeInterval(3_600), attendees: ["Janet Liu"],
                          hasVideoLink: true),
        ]
        XCTAssertEqual(CalendarEvents.best(in: events, at: now)?.title, "Acme sync")
    }

    func testNothingCurrentIsNil() {
        let now = Date()
        let later = CalendarEvent(title: "Later", start: now.addingTimeInterval(7_200),
                                  end: now.addingTimeInterval(9_000))
        XCTAssertNil(CalendarEvents.best(in: [later], at: now))
    }

    func testCustomTemplatesRoundTripAndWinLookups() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = MeetingStore(baseDirectory: base)

        let interview = NoteTemplate(
            id: "interview", name: "Interview", sections: ["Strengths", "Concerns"],
            guidance: "Separate evidence from impressions.")
        try store.saveCustomTemplates([interview])

        XCTAssertEqual(store.customTemplates(), [interview])
        XCTAssertEqual(store.template(id: "interview"), interview)
        XCTAssertEqual(store.template(id: "standup"), .standup)
        XCTAssertFalse(interview.isBuiltIn)
        XCTAssertTrue(try store.folders().isEmpty, "the templates folder is not a meeting folder")
    }

    func testTheOtherSidesNameReplacesThem() {
        var meeting = Meeting(title: "1:1")
        XCTAssertEqual(meeting.displayName(for: .them), "Them")
        meeting.speakerName = "Dana"
        XCTAssertEqual(meeting.displayName(for: .them), "Dana")
        XCTAssertEqual(meeting.displayName(for: .me), "Me")
    }
}
