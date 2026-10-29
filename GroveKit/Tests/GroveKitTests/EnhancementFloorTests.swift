import XCTest

@testable import GroveKit

/// The floor below which Grove will not write notes.
///
/// This exists because of a real report: the user said "let's talk about the
/// OKRs" and stopped, and the notes claimed the team had discussed and
/// finalised the OKRs. The model does not decline to write notes from almost
/// nothing — it writes plausible ones. Prompting helps and does not hold, so
/// the refusal is enforced in code and pinned here.
final class EnhancementFloorTests: XCTestCase {
    private func transcript(_ lines: [(Speaker, String)]) -> Transcript {
        var transcript = Transcript()
        for (index, line) in lines.enumerated() {
            transcript.insert(
                TranscriptSegment(
                    speaker: line.0, text: line.1,
                    start: Double(index) * 2, end: Double(index) * 2 + 1.5))
        }
        return transcript
    }

    func testCountsOnlySpokenWordsNotSpeakerLabels() {
        // `formatted()` prefixes every line with "[Me] " / "[Them] ". Counting
        // the rendered text would let many tiny segments clear the floor on
        // labels alone.
        let short = transcript((0..<20).map { _ in (Speaker.me, "yeah") })
        XCTAssertEqual(NoteEnhancer.spokenWordCount(short), 20)
        XCTAssertLessThan(
            NoteEnhancer.spokenWordCount(short), NoteEnhancer.minimumTranscriptWords,
            "twenty one-word segments must not clear the floor")
    }

    func testTheReportedCaseFallsBelowTheFloor() {
        let reported = transcript([(.me, "Let's talk about the OKRs")])
        XCTAssertLessThan(
            NoteEnhancer.spokenWordCount(reported), NoteEnhancer.minimumTranscriptWords)
    }

    func testARealShortExchangeClearsTheFloor() {
        // Roughly twenty seconds of genuine conversation. The floor must not be
        // so high that it refuses to write up a legitimately brief meeting.
        let real = transcript([
            (.them, "We know it is step three, the workspace invite screen, and about forty percent of people bail there."),
            (.me, "Do we know why they drop off at that point in the flow?"),
            (.them, "Mostly because we ask them to invite teammates before they have seen any value from the product."),
            (.me, "Priya will own the onboarding rewrite and we ship it Thursday."),
        ])
        XCTAssertGreaterThanOrEqual(
            NoteEnhancer.spokenWordCount(real), NoteEnhancer.minimumTranscriptWords,
            "a real short meeting must still be written up")
    }

    func testEnhancingBelowTheFloorThrowsRatherThanGuessing() async {
        let reported = transcript([(.me, "Let's talk about the OKRs")])
        do {
            _ = try await NoteEnhancer().enhance(roughNotes: "- OKRs", transcript: reported)
            XCTFail("enhancing a six-word transcript must refuse, not invent")
        } catch {
            // The message is user-facing, so it must say why rather than just fail.
            XCTAssertTrue(
                "\(error)".contains("too little"),
                "the refusal should explain itself, got: \(error)")
        }
    }

    func testEmptyTranscriptStillRefuses() async {
        do {
            _ = try await NoteEnhancer().enhance(roughNotes: "- OKRs", transcript: Transcript())
            XCTFail("an empty transcript must not be enhanced")
        } catch {
            // Expected.
        }
    }
}
