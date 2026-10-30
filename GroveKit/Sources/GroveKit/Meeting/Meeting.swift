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

    /// Who was invited, from the calendar event the meeting matched. Optional
    /// like every field added after the first release, so older meeting.json
    /// files still decode.
    public var attendees: [String]?

    /// What to call the far side of the call instead of "Them" — the other
    /// person in a 1:1, set from the calendar or by hand.
    public var speakerName: String?

    /// Action items ticked off, by their text. Keyed by text rather than a
    /// position so editing notes.md by hand cannot tick the wrong item.
    public var completedActionItems: [String]?

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
        recordedDuration: TimeInterval? = nil,
        attendees: [String]? = nil,
        speakerName: String? = nil,
        completedActionItems: [String]? = nil
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
        self.attendees = attendees
        self.speakerName = speakerName
        self.completedActionItems = completedActionItems
    }

    /// The label for a speaker in this meeting: "Me", or the other side's
    /// name when one is known, else "Them".
    public func displayName(for speaker: Speaker) -> String {
        if speaker == .them, let name = speakerName?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        {
            return name
        }
        return speaker.displayName
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
