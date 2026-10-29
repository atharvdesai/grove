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

    func testParseClockReadsBothFormats() {
        XCTAssertEqual(TimestampLinker.parseClock("1:15"), 75)
        XCTAssertEqual(TimestampLinker.parseClock("01:15"), 75)
        XCTAssertEqual(TimestampLinker.parseClock("1:01:01"), 3661)
    }

    func testParseClockRejectsNonClocks() {
        XCTAssertNil(TimestampLinker.parseClock(""))
        XCTAssertNil(TimestampLinker.parseClock("notes"))
        XCTAssertNil(TimestampLinker.parseClock("1:75"))  // no such second
        XCTAssertNil(TimestampLinker.parseClock("1:2:3:4"))
        XCTAssertNil(TimestampLinker.parseClock("1:"))
    }

    func testTrailingClockReadsBackWhatLinkWrote() {
        let line = "- Budget set at forty thousand for next quarter (1:15)"
        let parsed = TimestampLinker.trailingClock(in: line)
        XCTAssertEqual(parsed?.text, "- Budget set at forty thousand for next quarter")
        XCTAssertEqual(parsed?.time, 75)
    }

    func testTrailingClockIgnoresLinesWithoutOne() {
        XCTAssertNil(TimestampLinker.trailingClock(in: "- Budget set at forty thousand"))
        XCTAssertNil(TimestampLinker.trailingClock(in: "- A parenthetical (not a time)"))
        XCTAssertNil(TimestampLinker.trailingClock(in: "- trailing paren but no clock (see above)"))
    }

    func testClockStringFormatsUnderAndOverAnHour() {
        XCTAssertEqual(TimestampLinker.clockString(75), "1:15")
        XCTAssertEqual(TimestampLinker.clockString(0), "0:00")
        XCTAssertEqual(TimestampLinker.clockString(3661), "1:01:01")
    }
}
