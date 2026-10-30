import GroveKit
import SwiftUI

/// The during-the-meeting screen: your notepad on the left, the live transcript
/// on the right.
///
/// The notepad is the bigger half on purpose. The transcript is evidence the
/// enhancement pass consults; what the user types is the outline it must
/// preserve, and that is the whole premise of the product.
struct RecordingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingSession.self) private var session

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            RecordingHeader()
            Divider()

            // No ideal widths, and modest minimums. With ideals the two panes
            // asked for 940pt, which together with the 260pt sidebar exceeded
            // the window; rather than shrink, the split view pushed the sidebar
            // 41pt off the left edge and clipped it. The minimums here (560
            // plus a 220 sidebar) fit inside the 860pt minimum window with room
            // to spare, so nothing can be forced out of view.
            HSplitView {
                NotepadPane(text: $session.roughNotes)
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .layoutPriority(1)  // the notepad gets the spare space
                if settings.showTranscriptWhileRecording {
                    TranscriptPane(segments: session.segments)
                        .frame(minWidth: 240, maxWidth: .infinity)
                }
            }
        }
    }
}

private struct RecordingHeader: View {
    @Environment(MeetingSession.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library

    var body: some View {
        @Bindable var session = session

        HStack(spacing: 12) {
            RecordingIndicator(active: session.isCapturing, paused: session.isPaused)

            // Everything here must be able to give up width. With a fixed-width
            // picker and an untruncatable status string, the header's demand
            // plus the sidebar exceeded the window, and NavigationSplitView
            // resolved that by sliding the sidebar off the left edge.
            TextField(
                settings.autoOrganize ? "Untitled — named when it ends" : "Meeting title",
                text: $session.title)
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium))
                .frame(minWidth: 100, maxWidth: 360)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if session.isRecording {
                Picker("Template", selection: $session.templateID) {
                    ForEach(library.templates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 110, idealWidth: 160, maxWidth: 160)
                .help("How Grove should structure the finished notes")
            }

            Text(session.statusText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(session.isRecording ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if session.isRecording && !session.microphoneAvailable {
                Text("Microphone unavailable — only the far end will be transcribed")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct RecordingIndicator: View {
    let active: Bool
    var paused: Bool = false
    @ViewState private var pulsing = false

    var body: some View {
        Circle()
            .fill(paused ? Color.orange : (active ? Color.red : Color.secondary))
            .frame(width: 10, height: 10)
            .opacity(active && pulsing ? 0.35 : 1)
            .animation(
                active
                    ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear { pulsing = active }
            .onChange(of: active) { _, isActive in pulsing = isActive }
            .accessibilityLabel(active ? "Recording" : "Not recording")
    }
}

private struct NotepadPane: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle("Your notes", detail: "Fragments are fine")

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .focused($focused)

                if text.isEmpty {
                    Text("- who said they'd own onboarding?\n- 40% drop at invite screen\n- revisit mobile after week-4 retention")
                        .font(.system(size: 14))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
        }
        // Typing is the main job on this screen, so take the caret immediately.
        .onAppear { focused = true }
    }
}

private struct TranscriptPane: View {
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle("Transcript", detail: segments.isEmpty ? "Listening…" : "\(segments.count) segments")

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(segments) { segment in
                            SegmentRow(segment: segment).id(segment.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: segments.count) { _, _ in
                    guard let last = segments.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(.quaternary.opacity(0.12))
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(segment.speaker.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(segment.speaker == .me ? Color.accentColor : .secondary)
                Text(segment.start.clockString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(segment.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PaneTitle: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
