import XCTest

@testable import GroveKit

@available(macOS 26.0, *)
final class InsightsTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func meeting(
        _ title: String, daysAgo: Double, attendees: [String]? = nil,
        decisions: [String] = [], commitments: [Commitment] = [], questions: [String] = [],
        terms: [Term] = [], folder: String? = nil
    ) -> Meeting {
        Meeting(
            title: title, startedAt: Date().addingTimeInterval(-daysAgo * day), folder: folder,
            attendees: attendees,
            insights: MeetingInsights(
                summary: "\(title) summary", decisions: decisions, commitments: commitments,
                questions: questions, terms: terms))
    }

    func testParsingTheExtractionFormat() {
        let insights = InsightExtractor.parse(
            """
            SUMMARY: Acme agreed SSO by December.
            HIGHLIGHT: Okta works in staging
            DECISION: 10% discount if signed by Nov 30
            - **COMMITMENT:** Raj | send Okta details | Friday
            COMMITMENT: me | send the updated quote | -
            QUESTION: Does legal need EU account data?
            TERM: SCIM | automatic removal of users who leave
            COMMITMENT: nobody |
            """)
        XCTAssertEqual(insights.summary, "Acme agreed SSO by December.")
        XCTAssertEqual(insights.decisions, ["10% discount if signed by Nov 30"])
        XCTAssertEqual(insights.commitments, [
            Commitment(owner: "Raj", task: "send Okta details", due: "Friday"),
            Commitment(owner: "me", task: "send the updated quote", due: nil),
        ])
        XCTAssertEqual(insights.terms.first?.term, "SCIM")
    }

    func testNotesAloneGiveInsightsForOlderMeetings() {
        let old = Meeting(
            title: "Pricing",
            enhancedNotes: """
                ## Decision
                - Pro is now $16/month (0:30)
                ## Action items
                - Priya: pricing page copy by Monday (1:05)
                ## Open questions
                - Student discount
                """)
        let insights = old.resolvedInsights
        XCTAssertEqual(insights.decisions, ["Pro is now $16/month"])
        XCTAssertEqual(insights.commitments.first?.owner, "Priya")
        XCTAssertEqual(insights.commitments.first?.due, "Monday")
        XCTAssertEqual(insights.questions, ["Student discount"])
    }

    func testWhoseCommitmentItIs() {
        XCTAssertTrue(Commitment(owner: "me", task: "x").isMine())
        XCTAssertTrue(Commitment(owner: "Atharv", task: "x").isMine(myName: "Atharv Desai"))
        XCTAssertFalse(Commitment(owner: "Raj", task: "x").isMine(myName: "Atharv"))
    }

    func testWaitingOnIsOthersOpenPromisesOldestFirst() {
        var recent = meeting("Sync", daysAgo: 1, commitments: [Commitment(owner: "Raj", task: "send Okta details")])
        let older = meeting("Kickoff", daysAgo: 9, commitments: [
            Commitment(owner: "Janet", task: "share budget"), Commitment(owner: "me", task: "send quote"),
        ])
        recent.completedActionItems = nil
        let waiting = LibraryIndex.waitingOn([recent, older], myName: "Atharv")
        XCTAssertEqual(waiting.map(\.commitment.task), ["share budget", "send Okta details"])

        var done = recent
        done.completedActionItems = ["send Okta details"]
        XCTAssertEqual(LibraryIndex.waitingOn([done], myName: "").count, 0)
    }

    func testALaterDecisionReplacesAnEarlierOne() {
        let log = LibraryIndex.decisions(in: [
            meeting("Pricing review", daysAgo: 10, decisions: ["Pro plan price is $18 per month"]),
            meeting("Pricing follow-up", daysAgo: 3, decisions: ["Pro plan price is $16 per month"]),
        ])
        XCTAssertEqual(log.first?.ref.text, "Pro plan price is $16 per month", "newest first")
        XCTAssertNil(log.first?.replacedBy)
        XCTAssertEqual(log.last?.replacedBy?.meetingTitle, "Pricing follow-up")
    }

    func testAQuestionSettledLaterIsNoLongerOpen() {
        let open = LibraryIndex.openQuestions(in: [
            meeting("A", daysAgo: 5, questions: ["student discount for the pro plan", "offsite venue"]),
            meeting("B", daysAgo: 1, decisions: ["no student discount on the pro plan"]),
        ])
        XCTAssertEqual(open.map(\.text), ["offsite venue"])
    }

    func testPeopleMergeFirstNamesIntoFullNames() {
        let people = LibraryIndex.people(in: [
            meeting("Kickoff", daysAgo: 9, attendees: ["Janet Liu", "Raj Mehta"]),
            meeting("Sync", daysAgo: 1, commitments: [Commitment(owner: "Janet", task: "share budget")]),
        ], myName: "Atharv")
        let janet = try? XCTUnwrap(people.first { $0.name == "Janet Liu" })
        XCTAssertEqual(janet?.meetings.count, 2)
        XCTAssertEqual(janet?.owesYou.map(\.commitment.task), ["share budget"])
        XCTAssertFalse(people.contains { $0.name == "Janet" })
    }

    func testRecurringMeetingsAreFoundByTitleOrPeople() {
        let standup = meeting("Weekly standup — Oct 13", daysAgo: 7)
        let acme = meeting("Acme sync", daysAgo: 6, attendees: ["Janet Liu", "Raj Mehta"])
        let all = [standup, acme]
        XCTAssertEqual(
            LibraryIndex.previous(title: "Weekly Standup #42", attendees: [], before: Date(), in: all)?.id,
            standup.id)
        XCTAssertEqual(
            LibraryIndex.previous(title: "SSO check-in", attendees: ["Raj Mehta", "Janet Liu"], before: Date(), in: all)?.id,
            acme.id)
        XCTAssertNil(LibraryIndex.previous(title: "Offsite", attendees: [], before: Date(), in: all))
    }

    func testCarryOverListsWhatWasLeftOpen() {
        var last = meeting("Standup", daysAgo: 7,
                           commitments: [Commitment(owner: "Dana", task: "fix export bug"),
                                         Commitment(owner: "Leo", task: "Okta sandbox")],
                           questions: ["when does 2.4 ship"])
        last.completedActionItems = ["Okta sandbox"]
        let carried = LibraryIndex.carryOver(from: last)
        XCTAssertTrue(carried.hasPrefix("## From last time"))
        XCTAssertTrue(carried.contains("- [ ] Dana: fix export bug"))
        XCTAssertFalse(carried.contains("Okta"))
        XCTAssertTrue(carried.contains("Open question: when does 2.4 ship"))
    }

    func testChangesSinceLastTime() {
        let last = meeting("Standup", daysAgo: 7, decisions: ["release 2.4 on October 22"],
                           commitments: [Commitment(owner: "Dana", task: "fix export bug")],
                           questions: ["does the export bug block release 2.4"])
        let now = meeting("Standup", daysAgo: 0, decisions: ["release 2.4 on October 22", "export bug blocks release 2.4 until fixed"])
        let changes = LibraryIndex.changes(from: last, to: now)
        XCTAssertEqual(changes.newDecisions, ["export bug blocks release 2.4 until fixed"])
        XCTAssertEqual(changes.stillOpen.map(\.task), ["fix export bug"])
        XCTAssertEqual(changes.settledQuestions.count, 1)
    }

    func testGlossaryKeepsTheLatestDefinitionPerTerm() {
        let entries = LibraryIndex.glossary(in: [
            meeting("A", daysAgo: 5, terms: [Term(term: "SCIM", definition: "old")], folder: "Acme"),
            meeting("B", daysAgo: 1, terms: [Term(term: "scim", definition: "new"), Term(term: "DER", definition: "error rate")]),
        ])
        XCTAssertEqual(entries.map(\.definition), ["error rate", "new"])
        XCTAssertEqual(LibraryIndex.glossary(in: [meeting("A", daysAgo: 5, terms: [Term(term: "SCIM", definition: "old")], folder: "Acme")], folder: "Hiring").count, 0)
    }

    func testPlainEnglishQueries() {
        let now = Date()
        let q = MeetingQuery.parse("with janet about pricing last week", folders: ["Acme"], now: now)
        XCTAssertEqual(q.person, "janet")
        XCTAssertEqual(q.words, "pricing")
        XCTAssertNotNil(q.from)
        XCTAssertNotNil(q.to)

        let folderQuery = MeetingQuery.parse("hiring meetings about salary", folders: ["Hiring", "Acme"])
        XCTAssertEqual(folderQuery.folder, "Hiring")
        XCTAssertEqual(folderQuery.words, "salary")

        let janetMeeting = meeting("Acme sync", daysAgo: 0, attendees: ["Janet Liu"], folder: "Acme")
        XCTAssertTrue(MeetingQuery.parse("with janet", folders: []).matches(janetMeeting))
        XCTAssertFalse(MeetingQuery.parse("with raj", folders: []).matches(janetMeeting))
        XCTAssertFalse(MeetingQuery.parse("in hiring", folders: ["Hiring"]).matches(janetMeeting))
    }

    func testDueDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        let friday = DueDates.date(for: "by Friday", saidOn: tuesday, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: friday!), 23)
        let tomorrow = DueDates.date(for: "tomorrow", saidOn: tuesday, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: tomorrow!), 21)
        XCTAssertNil(DueDates.date(for: "soon", saidOn: tuesday, calendar: calendar))
    }

    func testOffTheRecordIsRemovedNotHidden() {
        var transcript = Transcript()
        transcript.insert(TranscriptSegment(speaker: .me, text: "public", start: 0, end: 5))
        transcript.insert(TranscriptSegment(speaker: .them, text: "private", start: 10, end: 15))
        transcript.insert(TranscriptSegment(speaker: .me, text: "straddles", start: 19, end: 22))
        transcript.insert(TranscriptSegment(speaker: .them, text: "public again", start: 30, end: 35))
        let kept = transcript.removing([OffRecordSpan(start: 8, end: 20)])
        XCTAssertEqual(kept.segments.map(\.text), ["public", "public again"])
    }

    func testQuotesCarryTheirSource() {
        var meeting = Meeting(title: "Acme SSO check-in")
        meeting.speakerName = "Janet Liu"
        let quote = meeting.quote("10% off if signed by Nov 30", speaker: .them, at: 845)
        XCTAssertTrue(quote.hasPrefix("“10% off if signed by Nov 30”"))
        XCTAssertTrue(quote.contains("— Janet Liu, Acme SSO check-in, "))
        XCTAssertTrue(quote.hasSuffix("(14:05)"))
    }
}
