import Foundation

/// Names a finished meeting and picks the folder it belongs in, on-device.
///
/// Only ever chooses among folders that already exist. Inventing a folder per
/// meeting would scatter the library faster than leaving everything at the top
/// level, so a model answer that names anything else is treated as "no folder".
@available(macOS 26.0, *)
public struct MeetingNamer: Sendable {
    public struct Suggestion: Sendable, Equatable {
        public var title: String
        /// An existing folder, exactly as spelled on disk, or nil for the top level.
        public var folder: String?
    }

    /// An existing folder and a few titles already filed there.
    ///
    /// The titles are what let the model file well: a folder called "Acme" says
    /// little, but one holding "Acme weekly sync" and "Acme renewal" says
    /// exactly which meetings go in it.
    public struct FolderContext: Sendable, Equatable {
        public var name: String
        public var recentTitles: [String]

        public init(name: String, recentTitles: [String]) {
            self.name = name
            self.recentTitles = recentTitles
        }
    }

    /// Below this, a title would be a guess at what the meeting was about.
    /// Lower than the enhancement floor because a title claims far less than a
    /// page of notes does.
    public static let minimumTranscriptWords = 25

    public static let maximumTitleLength = 60

    public let model: any NoteWritingModel

    public init(model: any NoteWritingModel = FoundationModelsEngine()) {
        self.model = model
    }

    public var availability: ModelAvailability { model.availability }

    /// Words of transcript sent to the model: the opening of a call is where the
    /// agenda usually gets said out loud.
    static let transcriptWordBudget = 700
    static let folderLimit = 25
    static let titlesPerFolder = 3

    /// Returns nil when there is too little to go on, so the caller keeps its
    /// fallback title instead of saving a confident name for a meeting that
    /// barely happened.
    public func suggest(
        transcript: Transcript,
        notes: String,
        folders: [FolderContext],
        appName: String? = nil
    ) async throws -> Suggestion? {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NoteEnhancer.spokenWordCount(transcript) >= Self.minimumTranscriptWords
            || !notes.isEmpty
        else { return nil }

        let response = try await model.generate(
            instructions: Self.instructions,
            prompt: Self.prompt(
                transcript: transcript, notes: notes,
                folders: Array(folders.prefix(Self.folderLimit)), appName: appName))
        return Self.parse(response, folders: folders.map(\.name))
    }

    // MARK: - Prompting

    static let instructions = """
        You name meetings and file them. Reply with exactly two lines and nothing else:
        Title: <a short, specific title>
        Folder: <one folder name copied exactly from the list, or None>

        Title rules:
        - 2 to 7 words. Name the subject, not the format: "Q3 pricing review", \
        not "Meeting about things".
        - Include the company, project, or person's name when the conversation \
        makes it clear.
        - No dates, no quotation marks, no trailing punctuation.

        Folder rules:
        - Choose a folder only if this meeting clearly belongs with the meetings \
        already in it. When unsure, answer None.
        - Never invent a folder name.
        """

    static func prompt(
        transcript: Transcript, notes: String, folders: [FolderContext], appName: String?
    ) -> String {
        var sections: [String] = []
        if let appName { sections.append("Call app: \(appName)") }

        if folders.isEmpty {
            sections.append("Folders: (none — answer Folder: None)")
        } else {
            let lines = folders.map { folder -> String in
                let titles = folder.recentTitles.prefix(titlesPerFolder)
                return titles.isEmpty
                    ? "- \(folder.name)"
                    : "- \(folder.name) (holds: \(titles.joined(separator: "; ")))"
            }
            sections.append("Folders:\n" + lines.joined(separator: "\n"))
        }

        if !notes.isEmpty {
            sections.append("Notes:\n<notes>\n\(truncated(notes, words: 300))\n</notes>")
        }
        let text = transcript.formatted()
        if !text.isEmpty {
            sections.append(
                "Transcript (opening):\n<transcript>\n"
                    + truncated(text, words: transcriptWordBudget) + "\n</transcript>")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Parsing

    /// Reads the two-line answer defensively: the on-device model sometimes adds
    /// quotes, bold markers, or a preamble, and none of that should reach a
    /// folder name on disk.
    static func parse(_ response: String, folders: [String]) -> Suggestion? {
        var title: String?
        var folder: String?
        for line in response.split(whereSeparator: \.isNewline) {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*-# "))
            if let value = value(of: "Title", in: cleaned), title == nil {
                title = value
            } else if let value = value(of: "Folder", in: cleaned), folder == nil {
                folder = value
            }
        }

        guard let title = title.map(cleanTitle), !title.isEmpty else { return nil }
        return Suggestion(title: title, folder: folder.flatMap { match($0, in: folders) })
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = key + ":"
        guard line.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        // One combined set, so "** `Acme`" loses the stars, the space and the
        // backticks together rather than stopping at the first space.
        return String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: decoration)
    }

    private static let decoration = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: "\"'“”‘’*`"))

    static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!\"'“”‘’"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if title.count > maximumTitleLength {
            // Cut at a word boundary so the title does not end mid-word.
            let cut = title.prefix(maximumTitleLength)
            title = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }
        return title
    }

    /// An existing folder the answer names, ignoring case. Anything else — None,
    /// a new name, a near miss — files nowhere.
    static func match(_ answer: String, in folders: [String]) -> String? {
        let wanted = answer.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty, wanted != "none" else { return nil }
        return folders.first { $0.lowercased() == wanted }
    }

    private static func truncated(_ text: String, words limit: Int) -> String {
        var count = 0
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = line.split(separator: " ").count
            if count + words > limit, !kept.isEmpty { break }
            kept.append(line)
            count += words
        }
        return kept.joined(separator: "\n")
    }
}
