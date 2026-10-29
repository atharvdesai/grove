import XCTest

@testable import GroveKit

private final class RecordingEngine: NoteWritingModel, @unchecked Sendable {
    let name = "stub"
    let singlePassWordLimit = 1_500
    let chunkWordLimit = 1_200
    var availability: ModelAvailability = .available

    private let lock = NSLock()
    private var _calls: [(instructions: String, prompt: String)] = []
    private let response: String

    init(response: String = "The budget is forty thousand (Planning, 1:15).") {
        self.response = response
    }

    var calls: [(instructions: String, prompt: String)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func generate(instructions: String, prompt: String) async throws -> String {
        lock.lock()
        _calls.append((instructions, prompt))
        lock.unlock()
        return response
    }
}

@available(macOS 26.0, *)
final class MeetingChatTests: XCTestCase {

    private func meeting(title: String, segments: [(Speaker, String, TimeInterval)]) -> Meeting {
        var transcript = Transcript()
        for (speaker, text, start) in segments {
            transcript.insert(
                TranscriptSegment(speaker: speaker, text: text, start: start, end: start + 5))
        }
        return Meeting(title: title, transcript: transcript)
    }

    private func meetings() -> [Meeting] {
        [
            meeting(title: "Planning", segments: [
                (.them, "the budget for next quarter is forty thousand", 75),
                (.me, "sounds good to me", 82),
            ]),
            meeting(title: "Hiring", segments: [
                (.them, "we need two more designers on the team", 10),
            ]),
        ]
    }

    func testRetrievalFindsTheRelevantSegment() {
        let ranked = MeetingChat.retrieve(question: "what budget was agreed", meetings: meetings())
        XCTAssertEqual(ranked.first?.excerpt.meetingTitle, "Planning")
        XCTAssertEqual(ranked.first?.excerpt.start, 75)
    }

    func testStopwordOnlyQuestionRetrievesNothing() {
        XCTAssertTrue(MeetingChat.retrieve(question: "what is the it", meetings: meetings()).isEmpty)
    }

    func testUnrelatedQuestionRetrievesNothingUseful() {
        let ranked = MeetingChat.retrieve(question: "kubernetes cluster latency", meetings: meetings())
        XCTAssertTrue(ranked.isEmpty)
    }

    func testAskBelowTheFloorNeverCallsTheModel() async throws {
        let engine = RecordingEngine()
        let chat = MeetingChat(model: engine)
        let answer = try await chat.ask(
            question: "kubernetes cluster latency", meetings: meetings())
        XCTAssertEqual(
            answer.text, "I couldn't find anything in your meetings that mentions that.")
        XCTAssertTrue(answer.excerpts.isEmpty)
        XCTAssertTrue(engine.calls.isEmpty, "a refused question must not reach the model")
    }

    func testAskReturnsModelTextWithTheExcerptsItSaw() async throws {
        let engine = RecordingEngine()
        let chat = MeetingChat(model: engine)
        let answer = try await chat.ask(
            question: "what budget was agreed", meetings: meetings())
        XCTAssertEqual(answer.text, "The budget is forty thousand (Planning, 1:15).")
        XCTAssertEqual(answer.excerpts.first?.meetingTitle, "Planning")
        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertTrue(engine.calls.first?.prompt.contains("forty thousand") == true)
        XCTAssertTrue(engine.calls.first?.prompt.contains("Question: what budget was agreed") == true)
    }

    func testContextRespectsTheWordBudget() {
        let long = String(repeating: "word ", count: 400)
        let excerpts = (0..<5).map { index in
            MeetingChat.Excerpt(
                id: UUID(), meetingID: UUID(), meetingTitle: "M\(index)",
                startedAt: Date(), speaker: .them,
                start: TimeInterval(index * 60), end: TimeInterval(index * 60 + 30),
                text: long)
        }
        let context = MeetingChat.context(for: excerpts, wordBudget: 1_200)
        XCTAssertLessThan(context.split(separator: " ").count, 1_200 + 410)
        XCTAssertTrue(context.contains("M0"))
    }
}
