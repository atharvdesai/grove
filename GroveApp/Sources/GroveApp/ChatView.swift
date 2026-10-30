import GroveKit
import SwiftUI

/// The conversation on the Ask page, kept outside the view so it survives
/// going somewhere else and coming back — and so an answer that is still
/// being written keeps arriving while you look at something else.
@MainActor
@Observable
final class AskConversation {
    static let shared = AskConversation()

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: MeetingChat.Answer?
    }

    private(set) var turns: [Turn] = []
    private(set) var isAsking = false

    func ask(_ question: String, model: any NoteWritingModel, meetings: [Meeting]) {
        let asked = question.trimmed
        guard !asked.isEmpty, !isAsking else { return }
        let turn = Turn(question: asked)
        turns.append(turn)
        isAsking = true
        Task {
            defer { isAsking = false }
            let answer: MeetingChat.Answer
            do {
                answer = try await MeetingChat(model: model).ask(question: asked, meetings: meetings)
            } catch {
                answer = MeetingChat.Answer(
                    text: "Something went wrong: \(error.localizedDescription)", excerpts: [])
            }
            if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                turns[index].answer = answer
            }
        }
    }

    func clear() {
        guard !isAsking else { return }
        turns = []
    }
}

/// Questions across every saved meeting.
///
/// A page in the window, laid out like a chat app: a prompt and suggestions
/// when it is empty, the conversation once it is not, and the composer always
/// at the bottom. Every answer lists the exact transcript excerpts the model
/// saw, numbered to match the answer's [n] citations (which `MeetingChat`
/// validates — an invented number is stripped), and clicking a source opens
/// that meeting's transcript at that moment. An answer that rests on nothing
/// is refused by `MeetingChat` before the model is ever called.
struct ChatView: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @FocusState private var inputFocused: Bool

    @ViewState private var question = ""
    @ViewState private var availability: ModelAvailability = .available

    private var conversation: AskConversation { .shared }

    var body: some View {
        VStack(spacing: 0) {
            if conversation.turns.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                transcript
                    .transition(.opacity)
            }
            composer
        }
        .animation(Motion.gentle, value: conversation.turns.isEmpty)
        .task {
            availability = MeetingChat(model: settings.writingModel).availability
            if let pending = AskHandoff.pending {
                AskHandoff.pending = nil
                ask(pending)
            }
            inputFocused = true
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            IconTile(systemName: "sparkle", size: 44)
            VStack(spacing: 8) {
                Text("What do you want to know?")
                    .font(.display(30))
                Text(
                    "Ask across \(library.meetings.count) "
                        + "\(library.meetings.count == 1 ? "meeting" : "meetings") — decisions, names, "
                        + "numbers, who promised what. Answers cite the moments they come from.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            VStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        ask(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            Text(suggestion)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(CardButtonStyle(cornerRadius: 10))
                    .disabled(library.meetings.isEmpty || availability != .available)
                }
            }
            .frame(maxWidth: 440)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Conversation

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HStack {
                    Spacer()
                    Button("New Chat") {
                        withAnimation(Motion.gentle) { conversation.clear() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(conversation.isAsking)
                }
                ForEach(conversation.turns) { turn in
                    TurnView(turn: turn, navigate: navigate)
                        .id(turn.id)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
            .frame(maxWidth: Metrics.readingWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .animation(Motion.snappy, value: conversation.turns.count)
            .animation(Motion.gentle, value: conversation.turns.last?.answer?.text)
        }
        .defaultScrollAnchor(.bottom)
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        switch availability {
        case .available:
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your meetings…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { ask() }
                    .disabled(library.meetings.isEmpty)
                    .padding(.vertical, 4)
                Button { ask() } label: {
                    Image(systemName: conversation.isAsking ? "ellipsis" : "arrow.up")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(CircleIconStyle(tint: .grove, size: 30))
                .disabled(!canAsk)
                .opacity(canAsk || conversation.isAsking ? 1 : 0.4)
                .help("Ask (Return)")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.groveCard))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        inputFocused ? Color.grove.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 3)
            .animation(Motion.hover, value: inputFocused)
            .frame(maxWidth: Metrics.readingWidth)
            .padding(.horizontal, 40)
            .padding(.bottom, 22)
            .padding(.top, 8)
        case .unavailable(let reason):
            Text(
                "The writing model is unavailable (\(reason)). "
                    + "Turn on Apple Intelligence in System Settings, or connect Claude from the sidebar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(24)
        }
    }

    private var canAsk: Bool {
        !conversation.isAsking && !library.meetings.isEmpty && !question.trimmed.isEmpty
    }

    private func ask(_ text: String? = nil) {
        let asked = (text ?? question).trimmed
        guard !asked.isEmpty else { return }
        question = ""
        conversation.ask(asked, model: settings.writingModel, meetings: library.meetings)
    }

    /// Opens the cited meeting at the cited moment. The notification carries
    /// the meeting and time; the window handles the navigation and the scroll.
    private func navigate(to excerpt: MeetingChat.Excerpt) {
        NotificationCenter.default.post(
            name: .navigateToMeeting,
            object: nil,
            userInfo: ["meetingID": excerpt.meetingID, "time": excerpt.start])
    }

    private static let suggestions = [
        "What did we decide last week?",
        "What am I still owed?",
        "What numbers came up most recently?",
    ]
}

/// One question and its answer.
private struct TurnView: View {
    let turn: AskConversation.Turn
    let navigate: (MeetingChat.Excerpt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 80)
                Text(turn.question)
                    .font(.system(size: 14))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        Color.groveWash,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }

            if let answer = turn.answer {
                VStack(alignment: .leading, spacing: 12) {
                    Text(answer.text)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !answer.excerpts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Sources")
                            ForEach(Array(answer.excerpts.enumerated()), id: \.element.id) { index, excerpt in
                                Button {
                                    navigate(excerpt)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(Color.grove)
                                            .frame(width: 18, height: 18)
                                            .background(Color.grove.opacity(0.13), in: Circle())
                                        Text(excerpt.meetingTitle)
                                            .lineLimit(1)
                                        Text(
                                            "\(TimestampLinker.clockString(excerpt.start)) · \(excerpt.speakerName)"
                                        )
                                        .foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                }
                                .buttonStyle(RowButtonStyle())
                                .help("Open the transcript at this moment")
                            }
                        }
                    }
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your meetings…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
