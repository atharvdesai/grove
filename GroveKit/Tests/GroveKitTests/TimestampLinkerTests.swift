import XCTest

@testable import GroveKit

final class TimestampLinkerTests: XCTestCase {

    private func segment(_ speaker: Speaker, _ text: String, start: TimeInterval)
        -> TranscriptSegment
    {
        TranscriptSegment(speaker: speaker, text: text, start: start, end: start + 5)
    }

    private func transcript() -> Transcript {
        var transcript = Transcript()
        transcript.insert(segment(.them, "the budget for next quarter is forty thousand", start: 75))
        transcript.insert(segment(.me, "can we review the hiring plan for the design team", start: 200))
        return transcript
    }

    func testMatchingLineGetsTimestamp() {
        let notes = "- Budget set at forty thousand for next quarter"
        let linked = TimestampLinker.link(notes: notes, transcript: transcript())
        XCTAssertEqual(linked, "- Budget set at forty thousand for next quarter (1:15)")
    }

    func testUnrelatedLineIsLeftAlone() {
        let notes = "- My private reminder about dentist appointment scheduling"
        let linked = TimestampLinker.link(notes: notes, transcript: transcript())
        XCTAssertEqual(linked, notes)
    }

    func testHeadingsAndShortLinesAreNeverLinked() {
        let notes = "# Budget\n\n- ok"
        let linked = TimestampLinker.link(notes: notes, transcript: transcript())
        XCTAssertEqual(linked, notes)
    }

    func testEmptyTranscriptReturnsNotesUnchanged() {
        let notes = "- Budget set at forty thousand for next quarter"
        XCTAssertEqual(TimestampLinker.link(notes: notes, transcript: Transcript()), notes)
    }

    func testClockStringFormatsUnderAndOverAnHour() {
        XCTAssertEqual(TimestampLinker.clockString(75), "1:15")
        XCTAssertEqual(TimestampLinker.clockString(0), "0:00")
        XCTAssertEqual(TimestampLinker.clockString(3661), "1:01:01")
    }
}
