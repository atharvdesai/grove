import GroveKit
import SwiftUI

/// Questions across every saved meeting, answered on-device.
///
/// Lives behind the home screen rather than in the sidebar because it is about
/// the library as a whole, not any one meeting. Every answer lists the exact
/// transcript excerpts it was written from; an answer that rests on nothing is
/// refused by `MeetingChat` before the model is ever called.
struct ChatView: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var turns: [Turn] = []
    @State private var isAsking = false
    @State private var availability: ModelAvailability = .available

    private struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: MeetingChat.Answer?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask your meetings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if turns.isEmpty {
                        Text(
                            "Ask anything across \(library.meetings.count) "
                                + "\(library.meetings.count == 1 ? "meeting" : "meetings") — "
                                + "decisions, names, numbers, who promised what. "
                                + "Answers cite the transcript moments they come from."
                        )
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(turn.question).font(.body.weight(.medium))
                            if let answer = turn.answer {
                                Text(answer.text)
                                if !answer.excerpts.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(answer.excerpts) { excerpt in
                                            Text(
                                                "\(excerpt.meetingTitle) · "
                                                    + TimestampLinker.clockString(excerpt.start)
                                                    + " · \(excerpt.speaker.displayName)"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }

            Divider()

            switch availability {
            case .available:
                HStack(spacing: 10) {
                    TextField("Ask about a past meeting…", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(ask)
                        .disabled(isAsking || library.meetings.isEmpty)
                    Button("Ask", action: ask)
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            isAsking || library.meetings.isEmpty
                                || question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
            case .unavailable(let reason):
                Text(
                    "The on-device model is unavailable (\(reason)). "
                        + "Enable Apple Intelligence in System Settings to ask questions."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()
            }
        }
        .frame(minWidth: 540, minHeight: 440)
        .task { availability = MeetingChat().availability }
    }

    private func ask() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isAsking else { return }
        question = ""
        let turn = Turn(question: asked)
        turns.append(turn)
        isAsking = true
        Task {
            defer { isAsking = false }
            do {
                let answer = try await MeetingChat().ask(
                    question: asked, meetings: library.meetings)
                if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                    turns[index].answer = answer
                }
            } catch {
                if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                    turns[index].answer = MeetingChat.Answer(
                        text: "Something went wrong: \(error.localizedDescription)",
                        excerpts: [])
                }
            }
        }
    }
}
