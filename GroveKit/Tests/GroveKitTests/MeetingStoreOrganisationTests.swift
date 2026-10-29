import XCTest

@testable import GroveKit

/// Folders, renaming, and moving.
///
/// All of it operates on real directories rather than an index, because the
/// promise is that meetings stay plain files you can open in Finder or Obsidian.
/// These tests assert against the filesystem for that reason — an index that
/// merely *agreed* with itself would pass a weaker test and still break the
/// promise.
final class MeetingStoreOrganisationTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MeetingStore(baseDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func meeting(_ title: String, folder: String? = nil, minutesAgo: Int = 0) -> Meeting {
        Meeting(
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000 - Double(minutesAgo) * 60),
            endedAt: Date(timeIntervalSince1970: 1_760_000_000),
            roughNotes: "- something",
            folder: folder)
    }

    private var onDisk: [String] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
        return contents.map(\.lastPathComponent).sorted()
    }

    func testTopLevelMeetingRoundTrips() throws {
        let saved = meeting("Growth sync")
        try store.save(saved)

        let listed = try store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.title, "Growth sync")
        XCTAssertNil(listed.first?.folder, "a top-level meeting has no folder")
    }

    func testMeetingInAFolderLivesInThatDirectory() throws {
        try store.save(meeting("Weekly 1:1", folder: "Team"))

        XCTAssertEqual(onDisk, ["Team"], "the meeting should be inside Team/, not beside it")

        let listed = try store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.folder, "Team")
    }

    func testListSpansFoldersAndTopLevelNewestFirst() throws {
        try store.save(meeting("Oldest", minutesAgo: 30))
        try store.save(meeting("Middle", folder: "Clients", minutesAgo: 20))
        try store.save(meeting("Newest", folder: "Team", minutesAgo: 0))

        XCTAssertEqual(try store.list().map(\.title), ["Newest", "Middle", "Oldest"])
    }

    func testFoldersAreListedButMeetingDirectoriesAreNot() throws {
        try store.save(meeting("Standup"))
        try store.save(meeting("Retro", folder: "Team"))
        try store.createFolder(named: "Empty")

        // "Standup" is a directory at the top level too, but it is a meeting.
        XCTAssertEqual(try store.folders(), ["Empty", "Team"])
    }

    func testTheDirectoryWinsWhenJSONDisagreesAboutTheFolder() throws {
        // Simulates the user dragging a meeting between folders in Finder: the
        // JSON still says "Team", but it now sits in "Clients".
        try store.save(meeting("Kickoff", folder: "Team"))
        let from = root.appendingPathComponent("Team", isDirectory: true)
        let to = root.appendingPathComponent("Clients", isDirectory: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let name = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)
                .first)
        try FileManager.default.moveItem(at: name, to: to.appendingPathComponent(name.lastPathComponent))

        XCTAssertEqual(try store.list().first?.folder, "Clients")
    }

    func testRenameMovesTheDirectoryAndRewritesTheFiles() throws {
        let original = meeting("Untitled")
        try store.save(original)

        let renamed = try store.rename(original, to: "Pricing review")
        XCTAssertEqual(renamed.title, "Pricing review")

        let listed = try store.list()
        XCTAssertEqual(listed.count, 1, "renaming must not leave the old copy behind")
        XCTAssertEqual(listed.first?.title, "Pricing review")

        let notes = try String(
            contentsOf: store.directory(for: renamed).appendingPathComponent("notes.md"),
            encoding: .utf8)
        XCTAssertTrue(
            notes.contains("Pricing review"),
            "the markdown carries the title in its front matter and heading")
        XCTAssertFalse(notes.contains("Untitled"))
    }

    func testRenameRejectsAnEmptyTitle() throws {
        let saved = meeting("Real title")
        try store.save(saved)
        XCTAssertThrowsError(try store.rename(saved, to: "   "))
    }

    func testMoveIntoAndBackOutOfAFolder() throws {
        let saved = meeting("Roadmap")
        try store.save(saved)

        let moved = try store.move(saved, toFolder: "Planning")
        XCTAssertEqual(moved.folder, "Planning")
        XCTAssertEqual(try store.list().map(\.folder), ["Planning"])
        XCTAssertFalse(
            onDisk.contains(saved.folderName), "the top-level copy should be gone")

        let back = try store.move(moved, toFolder: nil)
        XCTAssertNil(back.folder)
        XCTAssertEqual(try store.list().map(\.folder), [String?.none])
    }

    func testRelocatingNeverOverwritesAnExistingMeeting() throws {
        // Same title, same minute: the folder names collide.
        let first = meeting("Sync")
        let second = Meeting(
            title: "Other", startedAt: first.startedAt, endedAt: first.endedAt)
        try store.save(first)
        try store.save(second)

        _ = try store.rename(second, to: "Sync")

        let listed = try store.list()
        XCTAssertEqual(listed.count, 2, "neither meeting may be clobbered")
        XCTAssertEqual(listed.filter { $0.title == "Sync" }.count, 2)
    }

    func testDeletingAFolderWithMeetingsIsRefused() throws {
        try store.save(meeting("Important", folder: "Keep"))
        XCTAssertThrowsError(try store.deleteFolder(named: "Keep")) { error in
            XCTAssertTrue("\(error)".contains("still has meetings"))
        }
        XCTAssertEqual(try store.list().count, 1)
    }

    func testDeletingAnEmptyFolderWorks() throws {
        try store.createFolder(named: "Scratch")
        XCTAssertEqual(try store.folders(), ["Scratch"])
        try store.deleteFolder(named: "Scratch")
        XCTAssertEqual(try store.folders(), [])
    }

    func testFolderNamesCannotEscapeTheStore() throws {
        try store.save(meeting("Sneaky", folder: "../../etc"))
        let listed = try store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(
            store.directory(for: listed[0]).path.hasPrefix(root.path),
            "a slash in a folder name must not write outside the store")
    }

    func testRecordedDurationIsPreferredOverWallClock() {
        // A meeting paused for an hour should not report as an hour longer.
        let paused = Meeting(
            title: "Paused",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3_600),
            recordedDuration: 120)
        XCTAssertEqual(paused.duration, 120)

        let legacy = Meeting(
            title: "Before pausing existed",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(legacy.duration, 300, "older meetings fall back to wall clock")
    }
}

/// Resuming a meeting: a second recording session appended to the first.
final class TranscriptAppendTests: XCTestCase {
    private func transcript(_ entries: [(Speaker, String, TimeInterval, TimeInterval)]) -> Transcript {
        var transcript = Transcript()
        for entry in entries {
            transcript.insert(
                TranscriptSegment(speaker: entry.0, text: entry.1, start: entry.2, end: entry.3))
        }
        return transcript
    }

    func testLaterSessionIsShiftedPastTheFirst() {
        let first = transcript([(.them, "Opening remarks", 0, 10)])
        // A resumed session starts from zero again, which is the whole problem.
        let second = transcript([(.me, "Second half", 0, 5)])

        let combined = first.appending(second, gap: 1)

        XCTAssertEqual(combined.segments.map(\.text), ["Opening remarks", "Second half"])
        XCTAssertEqual(combined.segments[1].start, 11, "shifted past the end plus the gap")
        XCTAssertEqual(combined.segments[1].end, 16)
    }

    func testTimelineStaysIncreasing() {
        let first = transcript([(.them, "a", 0, 4), (.me, "b", 5, 9)])
        let second = transcript([(.them, "c", 0, 2), (.me, "d", 3, 6)])

        let starts = first.appending(second).segments.map(\.start)
        XCTAssertEqual(starts, starts.sorted(), "everything downstream assumes one ordered timeline")
    }

    func testAppendingToOrFromEmptyIsLossless() {
        let real = transcript([(.them, "only", 0, 3)])
        XCTAssertEqual(Transcript().appending(real).segments.count, 1)
        XCTAssertEqual(real.appending(Transcript()).segments.count, 1)
        XCTAssertEqual(real.appending(Transcript()).segments[0].start, 0, "no phantom shift")
    }

    func testSegmentsKeepTheirIdentityAcrossTheShift() {
        let second = transcript([(.me, "kept", 0, 1)])
        let id = second.segments[0].id
        let combined = transcript([(.them, "first", 0, 2)]).appending(second)
        XCTAssertEqual(combined.segments[1].id, id)
    }
}
