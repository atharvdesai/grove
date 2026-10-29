import Foundation

/// Meetings on disk as plain files.
///
/// One folder per meeting containing `meeting.json` (canonical), `notes.md`, and
/// `transcript.md`. Deliberately not an opaque database: Granola encrypting its
/// local cache in 2026 broke every community export tool overnight, and the
/// whole point of Grove is that your meetings stay yours — greppable, syncable,
/// and readable in Obsidian or any editor without Grove installed.
public struct MeetingStore: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory =
            baseDirectory
            ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Grove", isDirectory: true)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Where a meeting's folder lives: `base/<folder>/<meeting>`, or
    /// `base/<meeting>` at the top level.
    public func directory(for meeting: Meeting) -> URL {
        let parent =
            meeting.folder.map {
                baseDirectory.appendingPathComponent(Self.sanitized($0), isDirectory: true)
            } ?? baseDirectory
        return parent.appendingPathComponent(meeting.folderName, isDirectory: true)
    }

    @discardableResult
    public func save(_ meeting: Meeting) throws -> URL {
        let folder = directory(for: meeting)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try encoder.encode(meeting)
            .write(to: folder.appendingPathComponent("meeting.json"))
        try Self.notesMarkdown(for: meeting)
            .write(
                to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try Self.transcriptMarkdown(for: meeting)
            .write(
                to: folder.appendingPathComponent("transcript.md"), atomically: true,
                encoding: .utf8)
        return folder
    }

    public func load(from folder: URL) throws -> Meeting {
        let data = try Data(contentsOf: folder.appendingPathComponent("meeting.json"))
        return try decoder.decode(Meeting.self, from: data)
    }

    /// Most recent first, across the top level and one level of folders.
    ///
    /// Folder membership is taken from where the meeting actually sits on disk,
    /// not from the `folder` field in its JSON. The filesystem is the source of
    /// truth, so moving a meeting in Finder moves it in Grove — if the two ever
    /// disagree, the directory wins.
    public func list() throws -> [Meeting] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }

        var meetings: [Meeting] = []
        for entry in try fileManager.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        {
            guard entry.hasDirectoryPath else { continue }

            if var meeting = try? load(from: entry) {
                meeting.folder = nil
                meetings.append(meeting)
                continue
            }
            // Not a meeting, so treat it as a folder of meetings.
            let name = entry.lastPathComponent
            let contents =
                (try? fileManager.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in contents where child.hasDirectoryPath {
                if var meeting = try? load(from: child) {
                    meeting.folder = name
                    meetings.append(meeting)
                }
            }
        }
        return meetings.sorted { $0.startedAt > $1.startedAt }
    }

    /// Folder names that exist on disk, including empty ones.
    public func folders() throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }
        return try fileManager
            .contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.hasDirectoryPath }
            .filter { (try? load(from: $0)) == nil }  // a meeting is not a folder
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func createFolder(named name: String) throws {
        let clean = Self.sanitized(name)
        guard !clean.isEmpty else {
            throw CaptureError.message("A folder needs a name")
        }
        try FileManager.default.createDirectory(
            at: baseDirectory.appendingPathComponent(clean, isDirectory: true),
            withIntermediateDirectories: true)
    }

    /// Deletes an empty folder. Refuses if it still holds meetings, so a
    /// mis-click cannot take a month of notes with it.
    public func deleteFolder(named name: String) throws {
        let url = baseDirectory.appendingPathComponent(Self.sanitized(name), isDirectory: true)
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)) ?? []
        guard contents.filter({ !$0.lastPathComponent.hasPrefix(".") }).isEmpty else {
            throw CaptureError.message(
                "\"\(name)\" still has meetings in it. Move them out first.")
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Moves the meeting's folder to the trash rather than deleting it.
    ///
    /// These are the user's notes and there is no undo in the app; the Finder's
    /// undo is better than none.
    public func delete(_ meeting: Meeting) throws {
        let url = directory(for: meeting)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Retitles a meeting, rewriting its files and renaming its directory.
    @discardableResult
    public func rename(_ meeting: Meeting, to newTitle: String) throws -> Meeting {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptureError.message("A meeting needs a title") }

        var renamed = meeting
        renamed.title = trimmed
        return try relocate(meeting, to: renamed)
    }

    /// Files a meeting under `folder`, or at the top level when nil.
    @discardableResult
    public func move(_ meeting: Meeting, toFolder folder: String?) throws -> Meeting {
        var moved = meeting
        moved.folder = folder.map(Self.sanitized).flatMap { $0.isEmpty ? nil : $0 }
        return try relocate(meeting, to: moved)
    }

    /// Shared by rename and move: write the new location, then remove the old.
    ///
    /// Written before deleted on purpose. If anything fails in between, the
    /// meeting still exists somewhere rather than nowhere.
    private func relocate(_ old: Meeting, to new: Meeting) throws -> Meeting {
        let source = directory(for: old)
        var destination = directory(for: new)

        if source == destination {
            try save(new)
            return new
        }

        // Two meetings retitled the same on the same minute would collide.
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = destination.deletingLastPathComponent()
                .appendingPathComponent("\(new.folderName)-\(attempt)", isDirectory: true)
            attempt += 1
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
        }

        // Rewrite in place: the directory moved, but the files inside still
        // carry the old title in their front matter and headings.
        try encoder.encode(new).write(to: destination.appendingPathComponent("meeting.json"))
        try Self.notesMarkdown(for: new)
            .write(
                to: destination.appendingPathComponent("notes.md"), atomically: true,
                encoding: .utf8)
        try Self.transcriptMarkdown(for: new)
            .write(
                to: destination.appendingPathComponent("transcript.md"), atomically: true,
                encoding: .utf8)
        return new
    }

    /// Keeps a user-supplied folder name usable as a single path component.
    static func sanitized(_ name: String) -> String {
        name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    // MARK: - Rendering

    static func notesMarkdown(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        var lines = [
            "---",
            "title: \(meeting.title)",
            "date: \(ISO8601DateFormatter().string(from: meeting.startedAt))",
            "duration_minutes: \(Int(meeting.duration / 60))",
            "template: \(meeting.templateID)",
            "---",
            "",
            "# \(meeting.title)",
            "",
            "*\(formatter.string(from: meeting.startedAt))*",
            "",
        ]

        if let enhanced = meeting.enhancedNotes, !enhanced.isEmpty {
            lines.append(enhanced)
        } else {
            lines.append("## Notes")
            lines.append("")
            lines.append(
                meeting.roughNotes.isEmpty ? "*No notes taken.*" : meeting.roughNotes)
        }

        if !meeting.roughNotes.isEmpty, meeting.enhancedNotes != nil {
            lines.append(contentsOf: ["", "---", "", "## My original notes", "", meeting.roughNotes])
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func transcriptMarkdown(for meeting: Meeting) -> String {
        var lines = ["# Transcript — \(meeting.title)", ""]
        for segment in meeting.transcript.merged() {
            let minutes = Int(segment.start) / 60
            let seconds = Int(segment.start) % 60
            lines.append(
                String(
                    format: "**%@** `%02d:%02d`  \n%@\n", segment.speaker.displayName, minutes,
                    seconds, segment.text))
        }
        return lines.joined(separator: "\n")
    }
}
