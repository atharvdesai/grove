import XCTest

@testable import GroveKit

/// A recording stand-in for a real engine.
///
/// The point of the `NoteWritingModel` seam: before it, none of the logic below
/// could be tested at all, because every path ran through Apple's on-device
/// model — slow, non-deterministic, and unavailable on a CI runner. The refusal
/// floor and the chunking maths are exactly the parts that must not regress
/// quietly, and now they run in milliseconds.
private final class StubEngine: NoteWritingModel, @unchecked Sendable {
    let name = "stub"
    let singlePassWordLimit: Int
    let chunkWordLimit: Int
    var availability: ModelAvailability

    private let lock = NSLock()
    private var _calls: [(instructions: String, prompt: String)] = []
    private let response: String
    private let failure: Error?

    init(
        singlePassWordLimit: Int = 1_500,
        chunkWordLimit: Int = 1_200,
        availability: ModelAvailability = .available,
        response: String = "## Notes\n\nSomething grounded.",
        failure: Error? = nil
    ) {
        self.singlePassWordLimit = singlePassWordLimit
        self.chunkWordLimit = chunkWordLimit
        self.availability = availability
        self.response = response
        self.failure = failure
    }

    var calls: [(instructions: String, prompt: String)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func generate(instructions: String, prompt: String) async throws -> String {
        lock.lock()
        _calls.append((instructions, prompt))
        lock.unlock()
        if let failure { throw failure }
        return response
    }
}

@available(macOS 26.0, *)
final class NoteEnhancerEngineTests: XCTestCase {
    private func transcript(wordsPerSegment: Int, segments: Int) -> Transcript {
        var transcript = Transcript()
        let text = Array(repeating: "word", count: wordsPerSegment).joined(separator: " ")
        for index in 0..<segments {
            transcript.insert(
                TranscriptSegment(
                    speaker: index.isMultiple(of: 2) ? .them : .me,
                    text: text,
                    start: Double(index) * 5, end: Double(index) * 5 + 4))
        }
        return transcript
    }

    func testRefusalFloorNeverReachesTheEngine() async {
        let engine = StubEngine()
        let enhancer = NoteEnhancer(model: engine)

        _ = try? await enhancer.enhance(
            roughNotes: "- OKRs", transcript: transcript(wordsPerSegment: 5, segments: 1))

        XCTAssertTrue(
            engine.calls.isEmpty,
            "below the floor the model must not be called at all — the refusal is in code")
    }

    func testShortMeetingIsOneSinglePassCall() async throws {
        let engine = StubEngine()
        let enhancer = NoteEnhancer(model: engine)

        let notes = try await enhancer.enhance(
            roughNotes: "- invite screen drop-off",
            transcript: transcript(wordsPerSegment: 25, segments: 4))

        XCTAssertEqual(notes, "## Notes\n\nSomething grounded.")
        XCTAssertEqual(engine.calls.count, 1, "a short meeting needs no condensing pass")
    }

    func testThePromptCarriesBothTheTranscriptAndTheUsersNotes() async throws {
        let engine = StubEngine()
        let enhancer = NoteEnhancer(model: engine)

        _ = try await enhancer.enhance(
            roughNotes: "- priya owns onboarding",
            transcript: transcript(wordsPerSegment: 25, segments: 4),
            meetingTitle: "Growth sync")

        let call = try XCTUnwrap(engine.calls.first)
        XCTAssertTrue(call.prompt.contains("priya owns onboarding"), "the outline must be sent")
        XCTAssertTrue(call.prompt.contains("Growth sync"), "the title gives useful context")
        XCTAssertTrue(call.prompt.contains("[Them]"), "speaker labels are evidence")
        // The anti-fabrication rules are the reason the reported OKR bug is fixed;
        // losing them from the instructions would be a silent regression.
        XCTAssertTrue(call.instructions.contains("Naming a topic is not discussing it"))
    }

    func testLongMeetingIsReducedToFactsBeforeTheFinalPass() async throws {
        // Limits chosen so the transcript must split: 10 segments x 30 words.
        let engine = StubEngine(
            singlePassWordLimit: 100, chunkWordLimit: 60, response: "DECISION: ship on Friday")
        let enhancer = NoteEnhancer(model: engine)

        _ = try await enhancer.enhance(
            roughNotes: "", transcript: transcript(wordsPerSegment: 30, segments: 10))

        XCTAssertGreaterThan(
            engine.calls.count, 2, "a long transcript must be split before the final pass")
        XCTAssertTrue(
            engine.calls.dropLast().allSatisfy { $0.instructions.contains("extract facts") },
            "every call but the last extracts facts from one part")
        let final = try XCTUnwrap(engine.calls.last)
        XCTAssertTrue(final.instructions.contains("polished notes"), "the final call writes the notes")
        XCTAssertTrue(final.prompt.contains("DECISION: ship on Friday"), "it writes from the facts")
    }

    func testNoExtractableFactsFallsBackToCondensing() async throws {
        let engine = StubEngine(singlePassWordLimit: 100, chunkWordLimit: 60)
        let enhancer = NoteEnhancer(model: engine)

        _ = try await enhancer.enhance(
            roughNotes: "", transcript: transcript(wordsPerSegment: 30, segments: 10))

        XCTAssertTrue(
            engine.calls.contains { $0.instructions.contains("compress") },
            "with no facts to go on, the old condensing path still runs")
    }

    func testEngineFailurePropagatesRatherThanReturningPartialNotes() async {
        let engine = StubEngine(failure: CaptureError.message("engine exploded"))
        let enhancer = NoteEnhancer(model: engine)

        do {
            _ = try await enhancer.enhance(
                roughNotes: "", transcript: transcript(wordsPerSegment: 25, segments: 4))
            XCTFail("an engine failure must surface, not yield half-written notes")
        } catch {
            XCTAssertTrue("\(error)".contains("engine exploded"))
        }
    }

    func testAvailabilityComesFromTheEngine() {
        XCTAssertEqual(
            NoteEnhancer(model: StubEngine(availability: .unavailable("no weights"))).availability,
            .unavailable("no weights"))
        XCTAssertEqual(NoteEnhancer(model: StubEngine()).availability, .available)
    }

    /// Guards the property that makes the zero-download tier possible.
    func testDefaultEngineIsApplesOnDeviceModel() {
        XCTAssertTrue(
            NoteEnhancer().model is FoundationModelsEngine,
            "the default must stay the engine that needs no download")
    }
}
