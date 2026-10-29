import Foundation

public struct Meeting: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// What the user typed during the meeting — the outline the enhancement
    /// pass must preserve.
    public var roughNotes: String
    public var transcript: Transcript
    public var enhancedNotes: String?
    public var templateID: String

    /// Folder this meeting is filed under, or nil for the top level.
    ///
    /// Mirrors a real directory inside the store rather than being an index the
    /// app maintains — moving a meeting in Finder moves it in Grove, which is the
    /// whole point of keeping meetings as plain files.
    public var folder: String?

    /// Seconds actually recorded, excluding time spent paused.
    ///
    /// Optional because meetings saved before pausing existed do not have it;
    /// those fall back to wall-clock elapsed.
    public var recordedDuration: TimeInterval?

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        roughNotes: String = "",
        transcript: Transcript = Transcript(),
        enhancedNotes: String? = nil,
        templateID: String = NoteTemplate.general.id,
        folder: String? = nil,
        recordedDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.roughNotes = roughNotes
        self.transcript = transcript
        self.enhancedNotes = enhancedNotes
        self.templateID = templateID
        self.folder = folder
        self.recordedDuration = recordedDuration
    }

    /// How long the meeting actually ran. Prefers recorded time so a meeting
    /// paused for twenty minutes is not reported as twenty minutes longer.
    public var duration: TimeInterval {
        recordedDuration ?? (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public var template: NoteTemplate { .named(templateID) }

    /// Filesystem-safe folder name that still sorts chronologically and stays
    /// readable when browsed outside the app.
    public var folderName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let slug =
            title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeSlug = slug.isEmpty ? "meeting" : String(slug.prefix(48))
        return "\(formatter.string(from: startedAt))-\(safeSlug)"
    }
}
