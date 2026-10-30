import GroveKit
import SwiftUI

/// Questions across every saved meeting, answered on-device.
///
/// Lives behind the home screen rather than in the sidebar because it is about
/// the library as a whole, not any one meeting. Every answer lists the exact
/// transcript excerpts the model saw, numbered to match the answer's [n]
/// citations (which `MeetingChat` validates — an invented number is stripped),
/// and clicking a source opens that meeting's transcript at that moment. An
/// answer that rests on nothing is refused by `MeetingChat` before the model
/// is ever called.
struct ChatView: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @ViewState private var question = ""
    @ViewState private var turns: [Turn] = []
    @ViewState private var isAsking = false
    @ViewState private var availability: ModelAvailability = .available

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
                                        Text("SOURCES")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        ForEach(
                                            Array(answer.excerpts.enumerated()), id: \.element.id
                                        ) { index, excerpt in
                                            Button {
                                                navigate(to: excerpt)
                                            } label: {
                                                Text(
                                                    "\(index + 1). \(excerpt.meetingTitle) · "
                                                        + TimestampLinker.clockString(excerpt.start)
                                                        + " · \(excerpt.speakerName)"
                                                )
                                                .font(.caption)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(Color.grove)
                                            .help("Open the transcript at this moment")
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
        .task { availability = MeetingChat(model: settings.writingModel).availability }
    }

    /// Opens the cited meeting at the cited moment. The notification carries
    /// the meeting and time; the library handles the selection and the scroll.
    private func navigate(to excerpt: MeetingChat.Excerpt) {
        NotificationCenter.default.post(
            name: .navigateToMeeting,
            object: nil,
            userInfo: ["meetingID": excerpt.meetingID, "time": excerpt.start])
        dismiss()
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
                let answer = try await MeetingChat(model: settings.writingModel).ask(
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
