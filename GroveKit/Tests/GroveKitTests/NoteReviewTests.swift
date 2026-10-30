import XCTest

@testable import GroveKit

private final class ScriptedEngine: NoteWritingModel, @unchecked Sendable {
    let name = "scripted"
    let singlePassWordLimit = 1_500
    let chunkWordLimit = 1_200
    let availability = ModelAvailability.available
    let response: String
    private(set) var prompts: [String] = []

    init(_ response: String) { self.response = response }

    func generate(instructions: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        return response
    }
}

@available(macOS 26.0, *)
final class NoteReviewTests: XCTestCase {
    private func transcript() -> Transcript {
        var transcript = Transcript()
        transcript.insert(TranscriptSegment(
            speaker: .them, text: "we agreed the pro plan price is sixteen dollars per month",
            start: 750, end: 756))
        transcript.insert(TranscriptSegment(
            speaker: .me, text: "and the launch moves to november twentieth", start: 800, end: 805))
        return transcript
    }

    func testOnlyNotesWithRelatedPassagesAreSentToTheModel() async throws {
        let engine = ScriptedEngine("1: OK")
        _ = try await NoteChecker(model: engine).check(
            roughNotes: "# Pricing\n- pro plan price eighteen dollars\n- buy milk later today",
            transcript: transcript())
        XCTAssertEqual(engine.prompts.count, 1)
        XCTAssertTrue(engine.prompts[0].contains("pro plan price eighteen dollars"))
        XCTAssertFalse(engine.prompts[0].contains("buy milk"), "nothing in the transcript to check it against")
        XCTAssertFalse(engine.prompts[0].contains("# Pricing"), "headings aren't claims")
    }

    func testAConflictCarriesTheEvidenceAndTheFix() async throws {
        let engine = ScriptedEngine(
            "**1: CONFLICT a | transcript says $16 not $18 | FIX: Pro plan price is $16 a month**")
        let conflicts = try await NoteChecker(model: engine).check(
            roughNotes: "- pro plan price eighteen dollars", transcript: transcript())
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflict.note, "pro plan price eighteen dollars")
        XCTAssertEqual(conflict.time, 750)
        XCTAssertEqual(conflict.explanation, "transcript says $16 not $18")
        XCTAssertEqual(conflict.suggestion, "Pro plan price is $16 a month")
    }

    func testAgreementIsNoConflict() async throws {
        let conflicts = try await NoteChecker(model: ScriptedEngine("1: OK")).check(
            roughNotes: "- pro plan price sixteen dollars", transcript: transcript())
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testUsingTheFixRewritesOnlyThatLine() {
        let conflict = NoteConflict(
            note: "pro plan price eighteen dollars", transcriptSays: "", time: 750, speaker: "Them",
            explanation: "", suggestion: "Pro plan price is $16 a month")
        let meeting = Meeting(
            title: "Pricing", roughNotes: "- pro plan price eighteen dollars\n- launch soon",
            noteConflicts: [conflict])

        let fixed = meeting.resolving(conflict, useSuggestion: true)
        XCTAssertEqual(fixed.roughNotes, "- Pro plan price is $16 a month\n- launch soon")
        XCTAssertNil(fixed.noteConflicts)

        let kept = meeting.resolving(conflict, useSuggestion: false)
        XCTAssertEqual(kept.roughNotes, meeting.roughNotes)
        XCTAssertNil(kept.noteConflicts)
    }

    func testPolishedLinesAreCitedToTheTranscript() async throws {
        let engine = ScriptedEngine(
            "- We agreed the Pro plan price is sixteen dollars per month\n- Remember to thank Priya")
        let polished = try await NotePolisher(model: engine).polish(
            roughNotes: "- pro 16/mo\n- thank priya", transcript: transcript())
        XCTAssertTrue(polished.contains("sixteen dollars per month (12:30)"), polished)
        XCTAssertFalse(polished.contains("Priya ("), "a line the transcript doesn't cover gets no citation")
    }

    func testPolishingNothingIsRefused() async {
        do {
            _ = try await NotePolisher(model: ScriptedEngine("x")).polish(
                roughNotes: "  ", transcript: transcript())
            XCTFail("empty notes have nothing to polish")
        } catch {}
    }

    func testClaudeErrorsBecomeInstructions() {
        XCTAssertTrue(ClaudeCodeEngine.explain("Error: not logged in").contains("sign in"))
        XCTAssertTrue(ClaudeCodeEngine.explain("Usage limit reached").contains("limit"))
        XCTAssertTrue(ClaudeCodeError(message: ClaudeCodeEngine.explain("error: unknown option '--tools'")).isUnknownOption)
        XCTAssertEqual(ClaudeCodeEngine.model, "claude-haiku-5-5")
        XCTAssertEqual(
            ClaudeCodeEngine(executable: nil).availability == .available, false,
            "no Claude Code means the engine says so instead of failing mid-meeting")
    }
}
