import XCTest

@testable import GroveKit

private struct CannedEngine: NoteWritingModel {
    let name = "canned"
    let singlePassWordLimit = 1_500
    let chunkWordLimit = 1_200
    let availability = ModelAvailability.available
    let response: String

    func generate(instructions: String, prompt: String) async throws -> String { response }
}

@available(macOS 26.0, *)
final class MeetingNamerTests: XCTestCase {
    private let folders = ["Acme", "Hiring", "1:1s"]

    private func transcript(words: Int) -> Transcript {
        var transcript = Transcript()
        transcript.insert(
            TranscriptSegment(
                speaker: .them,
                text: Array(repeating: "pricing", count: words).joined(separator: " "),
                start: 0, end: 10))
        return transcript
    }

    func testParsesTitleAndAnExistingFolder() {
        let suggestion = MeetingNamer.parse(
            "Title: Acme renewal pricing\nFolder: Acme", folders: folders)
        XCTAssertEqual(suggestion, .init(title: "Acme renewal pricing", folder: "Acme"))
    }

    func testFolderMatchIgnoresCaseButKeepsTheSpellingOnDisk() {
        let suggestion = MeetingNamer.parse("Title: Loop\nFolder: hiring", folders: folders)
        XCTAssertEqual(suggestion?.folder, "Hiring")
    }

    func testAnInventedFolderFilesNowhere() {
        let suggestion = MeetingNamer.parse(
            "Title: Board prep\nFolder: Board Meetings", folders: folders)
        XCTAssertEqual(suggestion?.title, "Board prep")
        XCTAssertNil(suggestion?.folder, "only folders that already exist may be chosen")
    }

    func testNoneMeansTopLevel() {
        XCTAssertNil(MeetingNamer.parse("Title: Standup\nFolder: None", folders: folders)?.folder)
    }

    func testStripsTheDecorationTheModelLikesToAdd() {
        let suggestion = MeetingNamer.parse(
            "Sure! Here you go:\n**Title:** \"Q3 roadmap review.\"\n**Folder:** `Acme`",
            folders: folders)
        XCTAssertEqual(suggestion, .init(title: "Q3 roadmap review", folder: "Acme"))
    }

    func testNoTitleLineIsNoSuggestion() {
        XCTAssertNil(MeetingNamer.parse("I could not determine a title.", folders: folders))
    }

    func testLongTitlesAreCutAtAWord() {
        let long = Array(repeating: "quarterly", count: 12).joined(separator: " ")
        let title = MeetingNamer.cleanTitle(long)
        XCTAssertLessThanOrEqual(title.count, MeetingNamer.maximumTitleLength)
        XCTAssertFalse(title.hasSuffix(" "))
        XCTAssertTrue(long.hasPrefix(title))
    }

    func testTooLittleToGoOnNeverReachesTheModel() async throws {
        let namer = MeetingNamer(model: CannedEngine(response: "Title: Invented\nFolder: None"))
        let suggestion = try await namer.suggest(
            transcript: transcript(words: 5), notes: "", folders: [])
        XCTAssertNil(suggestion, "a title from five words would be a guess")
    }

    func testNotesAloneAreEnoughToName() async throws {
        let namer = MeetingNamer(model: CannedEngine(response: "Title: Offsite planning\nFolder: None"))
        let suggestion = try await namer.suggest(
            transcript: Transcript(), notes: "- venue\n- dates", folders: [])
        XCTAssertEqual(suggestion?.title, "Offsite planning")
    }

    func testThePromptShowsWhatEachFolderHolds() {
        let prompt = MeetingNamer.prompt(
            transcript: transcript(words: 30), notes: "",
            folders: [.init(name: "Acme", recentTitles: ["Acme weekly sync"])],
            appName: "Zoom")
        XCTAssertTrue(prompt.contains("- Acme (holds: Acme weekly sync)"))
        XCTAssertTrue(prompt.contains("Call app: Zoom"))
    }

    func testMeetingAppsMatchTheirHelperProcesses() {
        XCTAssertEqual(MeetingApp.matching(bundleID: "us.zoom.xos")?.name, "Zoom")
        XCTAssertEqual(
            MeetingApp.matching(bundleID: "com.google.Chrome.helper")?.name, "Google Chrome")
        XCTAssertEqual(MeetingApp.matching(bundleID: "com.google.Chrome.helper")?.isBrowser, true)
        XCTAssertNil(MeetingApp.matching(bundleID: "com.google.Chromecast"))
        XCTAssertNil(MeetingApp.matching(bundleID: "com.apple.VoiceMemos"))
    }
}
