import Foundation

/// Shapes the enhanced output for a kind of meeting.
///
/// A template never overrides the user's own structure — it only supplies
/// sections to fall back on when the rough notes don't imply one.
public struct NoteTemplate: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let sections: [String]
    public let guidance: String

    public init(id: String, name: String, sections: [String], guidance: String) {
        self.id = id
        self.name = name
        self.sections = sections
        self.guidance = guidance
    }

    public static let general = NoteTemplate(
        id: "general",
        name: "General meeting",
        sections: ["Discussion", "Decisions", "Action items"],
        guidance: "Capture what was decided and what happens next.")

    public static let oneOnOne = NoteTemplate(
        id: "one-on-one",
        name: "1:1",
        sections: ["Updates", "Blockers", "Feedback", "Action items"],
        guidance:
            "Focus on the person: what they're working on, what's in their way, "
            + "and anything they asked for.")

    public static let standup = NoteTemplate(
        id: "standup",
        name: "Stand-up",
        sections: ["Progress", "Blockers", "Action items"],
        guidance: "Keep it to one or two lines per person. Blockers matter most.")

    public static let customerCall = NoteTemplate(
        id: "customer-call",
        name: "Customer call",
        sections: [
            "Context", "Pain points", "Feature requests", "Objections", "Action items",
        ],
        guidance:
            "Quote the customer's own words for pain points and objections rather "
            + "than paraphrasing them.")

    public static let builtIns: [NoteTemplate] = [general, oneOnOne, standup, customerCall]

    public static func named(_ id: String) -> NoteTemplate {
        builtIns.first { $0.id == id } ?? .general
    }
}
