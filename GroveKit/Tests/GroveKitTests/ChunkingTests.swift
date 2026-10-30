import XCTest

@testable import GroveKit

@available(macOS 26.0, *)
final class ChunkingTests: XCTestCase {
    private func turn(_ speaker: Speaker, _ text: String, at start: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, text: text, start: start, end: start + 8)
    }

    /// Two clearly different topics, each a few turns long.
    private func twoTopicMeeting() -> Transcript {
        let pricing = [
            "the pricing for the pro plan should be sixteen dollars per month",
            "pricing at sixteen dollars keeps churn lower than eighteen dollars",
            "annual pricing discount of twenty five percent on the pro plan",
            "so pricing is settled pro plan sixteen dollars and annual discount",
        ]
        let hiring = [
            "moving on, the backend engineer candidate did well on postgres",
            "the candidate interview showed strong postgres indexing skills",
            "we should make the candidate an offer for the backend engineer role",
            "the offer for the engineer candidate should be at the top of the band",
        ]
        var transcript = Transcript()
        var t: TimeInterval = 0
        for (index, text) in (pricing + hiring).enumerated() {
            transcript.insert(turn(index.isMultiple(of: 2) ? .me : .them, text, at: t))
            t += 10
        }
        return transcript
    }

    func testCutsWhereTheTopicChanges() {
        let chunks = TopicSegmenter.chunks(twoTopicMeeting(), maxWords: 60)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].formatted().contains("pricing"))
        XCTAssertFalse(
            chunks[0].formatted().contains("candidate"),
            "the first chunk should end where pricing ends, not mid-way into hiring")
        XCTAssertTrue(chunks[1].formatted().lowercased().contains("moving on"))
    }

    func testEveryTurnLandsInExactlyOneChunk() {
        let transcript = twoTopicMeeting()
        let chunks = TopicSegmenter.chunks(transcript, maxWords: 45)
        XCTAssertEqual(chunks.flatMap(\.segments).count, transcript.merged().count)
        XCTAssertTrue(chunks.allSatisfy { $0.wordCount <= 45 })
    }

    func testShortTranscriptIsOneChunk() {
        let chunks = TopicSegmenter.chunks(twoTopicMeeting(), maxWords: 10_000)
        XCTAssertEqual(chunks.count, 1)
    }

    func testALectureMonologueIsSplitAtSentences() {
        let sentence = "Mitochondria produce energy for the cell through respiration."
        let lecture = Array(repeating: sentence, count: 40).joined(separator: " ")
        var transcript = Transcript()
        transcript.insert(TranscriptSegment(speaker: .them, text: lecture, start: 0, end: 400))

        let chunks = TopicSegmenter.chunks(transcript, maxWords: 120)
        XCTAssertGreaterThan(chunks.count, 1, "one enormous turn must still be split")
        XCTAssertTrue(chunks.allSatisfy { $0.wordCount <= 120 })
        XCTAssertTrue(chunks.allSatisfy { $0.formatted().hasSuffix(".") }, "cuts land on sentence ends")
        XCTAssertGreaterThan(chunks[1].start, 0, "time is shared out across the pieces")
    }

    func testFactsAreReadLeniently() {
        let facts = FactSheet.parse(
            """
            Here are the facts:
            - **DECISION:** Pro is $16
            * action: Priya writes the pricing page by Monday
            NUMBER: 25% annual discount
            Something without a label
            QUESTION:
            """, time: 90)
        XCTAssertEqual(facts.map(\.kind), [.decision, .action, .number])
        XCTAssertEqual(facts.first?.text, "Pro is $16")
        XCTAssertEqual(facts.first?.time, 90)
    }

    func testALaterRevisionReplacesTheEarlierFact() {
        let merged = FactSheet.merge([
            MeetingFact(kind: .decision, text: "Pro plan price is $18 per month", time: 0),
            MeetingFact(kind: .action, text: "Marcus updates Stripe", time: 10),
            MeetingFact(kind: .decision, text: "Pro plan price is $16 per month", time: 600),
        ])
        XCTAssertEqual(merged.filter { $0.kind == .decision }.map(\.text), ["Pro plan price is $16 per month"])
        XCTAssertEqual(merged.count, 2)
    }

    func testTrimmingDropsPointsBeforeDecisions() {
        let facts = [
            MeetingFact(kind: .point, text: String(repeating: "chatter ", count: 30), time: 0),
            MeetingFact(kind: .decision, text: "ship on Friday", time: 5),
        ]
        let sheet = FactSheet.render(facts, maxWords: 10)
        XCTAssertTrue(sheet.contains("DECISION: ship on Friday"))
        XCTAssertFalse(sheet.contains("chatter"))
    }
}
