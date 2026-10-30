import GroveKit
import SwiftUI

/// "You wrote $18 — the transcript says $16. Which is right?"
///
/// One card per note the transcript contradicts. Each answer is a click: take
/// the transcript's version, keep yours (sometimes the notes are right and the
/// transcription misheard), or jump to the moment and listen for yourself.
struct NoteConflictsSheet: View {
    let meeting: Meeting
    let showInTranscript: (TimeInterval) -> Void

    @Environment(MeetingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// Read live from the library, so a card disappears as soon as it's answered.
    private var conflicts: [NoteConflict] {
        library.meetings.first { $0.id == meeting.id }?.noteConflicts ?? []
    }

    private var current: Meeting {
        library.meetings.first { $0.id == meeting.id } ?? meeting
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check your notes").font(.headline)
                    Text("These lines disagree with what was said.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if conflicts.isEmpty {
                ContentUnavailableView(
                    "All sorted", systemImage: "checkmark.circle",
                    description: Text("Your notes and the transcript agree."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(conflicts) { conflict in
                            ConflictCard(conflict: conflict) {
                                library.resolve(conflict, in: current, useSuggestion: true)
                            } keep: {
                                library.resolve(conflict, in: current, useSuggestion: false)
                            } show: {
                                showInTranscript(conflict.time)
                                dismiss()
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 540, height: 480)
    }
}

private struct ConflictCard: View {
    let conflict: NoteConflict
    let fix: () -> Void
    let keep: () -> Void
    let show: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(conflict.explanation, systemImage: "exclamationmark.bubble.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("YOU WROTE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(conflict.note)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("\(conflict.speaker.uppercased()) SAID AT \(conflict.time.clockString)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("“\(conflict.transcriptSays)”")
                    .italic()
                    .lineLimit(4)
            }

            HStack {
                if let suggestion = conflict.suggestion {
                    Button("Use “\(suggestion.prefix(48))\(suggestion.count > 48 ? "…" : "")”", action: fix)
                        .buttonStyle(.borderedProminent)
                }
                Button("Keep Mine", action: keep)
                Spacer()
                Button("Show in Transcript", action: show)
                    .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
