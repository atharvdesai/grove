import Foundation
import XCTest

@testable import GroveKit

final class TranscriptTests: XCTestCase {
    private func segment(
        _ speaker: Speaker, _ text: String, _ start: TimeInterval, _ end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, text: text, start: start, end: end)
    }

    /// Two independent transcribers finalize at different rates, so segments can
    /// arrive out of order and must still land on a correct timeline.
    func testInsertKeepsTimelineOrderedRegardlessOfArrivalOrder() {
        var transcript = Transcript()
        transcript.insert(segment(.them, "third", 10, 12))
        transcript.insert(segment(.me, "first", 0, 2))
        transcript.insert(segment(.them, "second", 5, 7))

        XCTAssertEqual(transcript.segments.map(\.text), ["first", "second", "third"])
    }

    func testMergedJoinsSameSpeakerWithinGapTolerance() {
        var transcript = Transcript()
        transcript.insert(segment(.me, "Hello there", 0, 1))
        transcript.insert(segment(.me, "how are you", 1.5, 3))
        transcript.insert(segment(.them, "Good thanks", 3.5, 5))

        let merged = transcript.merged(gapTolerance: 2.0)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].text, "Hello there how are you")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 3)
        XCTAssertEqual(merged[1].speaker, .them)
    }

    func testMergedKeepsSpeakerTurnsSeparateAcrossLongPause() {
        var transcript = Transcript()
        transcript.insert(segment(.me, "One", 0, 1))
        transcript.insert(segment(.me, "Two", 30, 31))

        XCTAssertEqual(transcript.merged(gapTolerance: 2.0).count, 2)
    }

    func testSegmentAtFindsTheCoveringSegment() {
        var transcript = Transcript()
        transcript.insert(segment(.me, "early", 0, 10))
        transcript.insert(segment(.them, "later", 60, 70))

        XCTAssertEqual(transcript.segment(at: 5)?.text, "early")
        XCTAssertEqual(transcript.segment(at: 65)?.text, "later")
    }

    func testSegmentAtFallsForwardAcrossAGap() {
        var transcript = Transcript()
        transcript.insert(segment(.me, "early", 0, 10))
        transcript.insert(segment(.them, "later", 60, 70))

        // A reference landing in silence belongs to whatever is said next;
        // one past the end belongs to the last thing said.
        XCTAssertEqual(transcript.segment(at: 30)?.text, "later")
        XCTAssertEqual(transcript.segment(at: 600)?.text, "later")
        XCTAssertNil(Transcript().segment(at: 30))
    }

    func testFormattedLabelsSpeakersForTheEnhancementPrompt() {
        var transcript = Transcript()
        transcript.insert(segment(.me, "What's the number?", 0, 1))
        transcript.insert(segment(.them, "Forty percent.", 1, 2))

        XCTAssertEqual(
            transcript.formatted(),
            "[Me] What's the number?\n[Them] Forty percent.")
    }
}

final class EchoSuppressionTests: XCTestCase {
    private func segment(
        _ speaker: Speaker, _ text: String, _ start: TimeInterval, _ end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, text: text, start: start, end: end)
    }

    /// The exact failure seen in the first live recording: on speakers, the mic
    /// re-hears the far end and the same sentence lands under both speakers.
    func testRemovesMicrophoneEchoOfRemoteSpeech() {
        var transcript = Transcript()
        transcript.insert(segment(.them, "About forty percent bail there.", 7, 9))
        transcript.insert(segment(.me, "About 40% bail there.", 8, 10))

        let cleaned = transcript.withoutEcho()
        XCTAssertEqual(cleaned.segments.count, 1)
        XCTAssertEqual(cleaned.segments.first?.speaker, .them)
    }

    /// The tap is a clean digital copy, so a genuine reply must survive even
    /// when it lands close in time to remote speech.
    func testKeepsGenuineUserSpeech() {
        var transcript = Transcript()
        transcript.insert(segment(.them, "Can you get Priya on it this week?", 14, 16))
        transcript.insert(segment(.me, "Yes, I'll ask her on Monday.", 16, 18))

        XCTAssertEqual(transcript.withoutEcho().segments.count, 2)
    }

    /// A short agreement shares few words with anything, so it must not be
    /// mistaken for an echo.
    func testKeepsShortAcknowledgements() {
        var transcript = Transcript()
        transcript.insert(segment(.them, "So let us make skip a real button.", 9, 11))
        transcript.insert(segment(.me, "Agreed.", 11, 12))

        XCTAssertEqual(transcript.withoutEcho().segments.count, 2)
    }

    /// Identical text far apart in time is repetition, not echo.
    func testKeepsMatchingTextOutsideTheEchoWindow() {
        var transcript = Transcript()
        transcript.insert(segment(.them, "Let us push mobile to quarter three.", 0, 2))
        transcript.insert(segment(.me, "Let us push mobile to quarter three.", 600, 602))

        XCTAssertEqual(transcript.withoutEcho(window: 8).segments.count, 2)
    }

    func testNeverDiscardsRemoteSpeech() {
        var transcript = Transcript()
        transcript.insert(segment(.them, "Same words here.", 0, 2))
        transcript.insert(segment(.them, "Same words here.", 1, 3))

        XCTAssertEqual(transcript.withoutEcho().segments.count, 2)
    }
}

final class NoteEnhancerChunkingTests: XCTestCase {
    /// The on-device model's context window covers prompt and completion
    /// together, so long meetings must be split — and never mid-utterance.
    func testChunkNeverSplitsASpeakerTurn() {
        let lines = (0..<50).map { "[Them] " + String(repeating: "word", count: 1) + " \($0)" }
        let transcript = lines.joined(separator: "\n")

        let chunks = NoteEnhancer.chunk(transcript, maxWords: 20)

        XCTAssertGreaterThan(chunks.count, 1)
        let recombined = chunks.joined(separator: "\n")
        XCTAssertEqual(recombined, transcript, "chunking must be lossless")
        for chunk in chunks {
            for line in chunk.split(separator: "\n") {
                XCTAssertTrue(line.hasPrefix("[Them]"), "a turn was cut in half: \(line)")
            }
        }
    }

    func testChunkKeepsShortTranscriptWhole() {
        let transcript = "[Me] short\n[Them] also short"
        XCTAssertEqual(NoteEnhancer.chunk(transcript, maxWords: 1_000), [transcript])
    }
}

final class MeetingTests: XCTestCase {
    func testFolderNameIsChronologicalAndFilesystemSafe() {
        let date = ISO8601DateFormatter().date(from: "2026-08-09T14:30:00Z")!
        let meeting = Meeting(title: "Q3 Roadmap / Pricing?!", startedAt: date)

        let folder = meeting.folderName
        XCTAssertTrue(folder.hasSuffix("q3-roadmap-pricing"), folder)
        XCTAssertFalse(folder.contains("/"))
        XCTAssertFalse(folder.contains("?"))
    }

    func testFolderNameFallsBackWhenTitleHasNoUsableCharacters() {
        let meeting = Meeting(title: "!!!")
        XCTAssertTrue(meeting.folderName.hasSuffix("-meeting"), meeting.folderName)
    }

    /// Meetings must stay readable without Grove installed, so the enhanced notes
    /// and the user's original notes both survive a round trip to disk.
    func testSaveAndLoadRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MeetingStore(baseDirectory: directory)
        var transcript = Transcript()
        transcript.insert(
            TranscriptSegment(speaker: .them, text: "Forty percent bail.", start: 0, end: 2))

        let meeting = Meeting(
            title: "Onboarding",
            roughNotes: "- step 3 problem",
            transcript: transcript,
            enhancedNotes: "## Onboarding\n- 40% drop-off at step 3")

        let folder = try store.save(meeting)
        let loaded = try store.load(from: folder)

        XCTAssertEqual(loaded.title, meeting.title)
        XCTAssertEqual(loaded.roughNotes, meeting.roughNotes)
        XCTAssertEqual(loaded.transcript, meeting.transcript)
        XCTAssertEqual(loaded.enhancedNotes, meeting.enhancedNotes)

        let notes = try String(
            contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains("40% drop-off at step 3"))
        XCTAssertTrue(notes.contains("## My original notes"), "original notes must be preserved")

        let transcriptFile = try String(
            contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(transcriptFile.contains("Forty percent bail."))
        XCTAssertTrue(transcriptFile.contains("**Them**"))
    }

    func testListReturnsMostRecentFirst() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MeetingStore(baseDirectory: directory)
        let old = Meeting(title: "Older", startedAt: Date(timeIntervalSince1970: 1_000_000))
        let new = Meeting(title: "Newer", startedAt: Date(timeIntervalSince1970: 2_000_000))
        try store.save(old)
        try store.save(new)

        XCTAssertEqual(try store.list().map(\.title), ["Newer", "Older"])
    }
}

final class NoteTemplateTests: XCTestCase {
    func testNamedFallsBackToGeneralForUnknownIdentifier() {
        XCTAssertEqual(NoteTemplate.named("nope"), .general)
        XCTAssertEqual(NoteTemplate.named("customer-call").id, "customer-call")
    }
}
