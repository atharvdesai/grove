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

    /// Recorded in a room rather than on a call: one microphone, everyone on
    /// it, transcribed as the other side.
    public var inPerson: Bool?

    /// The user's own notes, tidied and cited to the transcript. See
    /// `NotePolisher`.
    public var polishedNotes: String?

    /// Lines of the user's notes the transcript contradicts, waiting for the
    /// user to keep or fix. Cleared as each is answered.
    public var noteConflicts: [NoteConflict]?

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
        completedActionItems: [String]? = nil,
        inPerson: Bool? = nil,
        polishedNotes: String? = nil,
        noteConflicts: [NoteConflict]? = nil
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
        self.inPerson = inPerson
        self.polishedNotes = polishedNotes
        self.noteConflicts = noteConflicts
    }

    /// Answers a conflict: with `useSuggestion`, the note line is replaced by
    /// the transcript-matching rewrite; either way the question goes away.
    public func resolving(_ conflict: NoteConflict, useSuggestion: Bool) -> Meeting {
        var copy = self
        if useSuggestion, let suggestion = conflict.suggestion {
            copy.roughNotes = roughNotes.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    guard line.contains(conflict.note) else { return String(line) }
                    return line.replacingOccurrences(of: conflict.note, with: suggestion)
                }
                .joined(separator: "\n")
        }
        let remaining = (noteConflicts ?? []).filter { $0.id != conflict.id }
        copy.noteConflicts = remaining.isEmpty ? nil : remaining
        return copy
    }

    /// The label for a speaker in this meeting: "Me", or the other side's
    /// name when one is known, else "Them".
    public func displayName(for speaker: Speaker) -> String {
        if speaker == .them, let name = speakerName?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        {
            return name
        }
        if speaker == .them, inPerson == true { return "Room" }
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
