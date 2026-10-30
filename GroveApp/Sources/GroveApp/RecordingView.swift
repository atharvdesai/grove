import GroveKit
import SwiftUI

/// The during-the-meeting page: a notepad, a transcript drawer, and a floating
/// control bar — then, once you stop, the notes being written.
///
/// The notepad is the page on purpose. The transcript is evidence the
/// enhancement pass consults; what the user types is the outline it must
/// preserve, and that is the whole premise of the product. So the notepad gets
/// the full reading column, and the transcript is a drawer you open when you
/// want to check something — the way Granola keeps it a click away rather than
/// competing for attention.
struct RecordingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingSession.self) private var session

    private var isWritingUp: Bool {
        switch session.phase {
        case .finishing, .enhancing, .naming: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            if isWritingUp {
                WritingUpView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                LiveNotepad()
                    .transition(.opacity)
            }
        }
        .animation(Motion.gentle, value: isWritingUp)
    }
}

// MARK: - Live

private struct LiveNotepad: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingSession.self) private var session

    var body: some View {
        @Bindable var settings = settings

        HStack(spacing: 0) {
            NotepadColumn()
                .frame(maxWidth: .infinity)

            if settings.showTranscriptWhileRecording {
                TranscriptDrawer(segments: session.segments)
                    .frame(width: 330)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if session.isRecording && !session.microphoneAvailable {
                    Label(
                        "Microphone unavailable — only the far end will be transcribed",
                        systemImage: "mic.slash")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .floatingSurface(Capsule())
                }
                ControlBar(showTranscript: $settings.showTranscriptWhileRecording.animation(Motion.gentle))
            }
            .padding(.bottom, 18)
        }
    }
}

private struct NotepadColumn: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library
    @FocusState private var notesFocused: Bool

    var body: some View {
        @Bindable var session = session

        VStack(alignment: .leading, spacing: 10) {
            meta

            TextField(
                settings.autoOrganize ? "Untitled — named when it ends" : "Meeting title",
                text: $session.title)
                .textFieldStyle(.plain)
                .font(.display(30))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $session.roughNotes)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .focused($notesFocused)
                    // TextEditor insets its text by a few points; this lines
                    // the caret up with the title above it.
                    .padding(.leading, -5)

                if session.roughNotes.isEmpty {
                    Text(
                        "Write what matters to you — fragments are fine.\n"
                            + "Grove fills in the rest from what was said.")
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.top, 40)
        // Room for the control bar, so the last line never hides under it.
        .padding(.bottom, 84)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Typing is the main job on this page, so take the caret immediately.
        .onAppear { notesFocused = true }
    }

    /// Chips above the title: when, where, and the template.
    private var meta: some View {
        HStack(spacing: 6) {
            MetaChip(icon: "calendar", text: Date().formatted(.dateTime.weekday(.abbreviated).day().month()))
            if session.inPerson {
                MetaChip(icon: "person.2", text: "In person")
            } else if let app = session.meetingApp {
                MetaChip(icon: "video", text: app)
            }
            if let event = session.calendarEvent, !event.attendees.isEmpty {
                MetaChip(
                    icon: "person.crop.circle",
                    text: event.attendees.prefix(2).joined(separator: ", ")
                        + (event.attendees.count > 2 ? " +\(event.attendees.count - 2)" : ""))
            }
            Menu {
                ForEach(library.templates) { template in
                    Button {
                        session.templateID = template.id
                    } label: {
                        if template.id == session.templateID {
                            Label(template.name, systemImage: "checkmark")
                        } else {
                            Text(template.name)
                        }
                    }
                }
            } label: {
                MetaChip(icon: "list.bullet.rectangle", text: library.template(id: session.templateID).name)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How Grove should structure the finished notes")
        }
    }
}

private struct MetaChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.groveWash, in: Capsule())
    }
}

/// The floating capsule: what's happening, and every control a meeting needs.
private struct ControlBar: View {
    @Binding var showTranscript: Bool
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 9) {
                if session.phase == .starting {
                    ProgressView().controlSize(.small)
                    Text("Getting ready…")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    ListeningBars(
                        active: session.isCapturing && !session.isOffRecord,
                        activity: session.segments.count,
                        color: session.isPaused ? .orange : session.isOffRecord ? .secondary : .red)
                    Text(session.elapsed.clockString)
                        .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
                        .contentTransition(.numericText())
                        .animation(Motion.snappy, value: session.elapsed)
                    if session.isPaused {
                        Text("Paused")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    } else if session.isOffRecord {
                        Text("Off the record")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)

            Divider().frame(height: 18)

            Button {
                session.togglePause()
            } label: {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(CircleIconStyle(size: 32))
            .disabled(!session.isRecording)
            .help(session.isPaused ? "Resume (⇧⌘P)" : "Pause (⇧⌘P)")

            Button {
                session.toggleOffRecord()
            } label: {
                Image(systemName: session.isOffRecord ? "eye.slash.fill" : "eye.slash")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(CircleIconStyle(tint: session.isOffRecord ? .orange : nil, size: 32))
            .disabled(!session.isRecording)
            .help(session.isOffRecord ? "Back on the record (⌃⌥O)" : "Off the record — nothing said is kept (⌃⌥O)")

            Button {
                showTranscript.toggle()
            } label: {
                Image(systemName: "text.quote")
            }
            .buttonStyle(CircleIconStyle(tint: showTranscript ? .grove : nil, size: 32))
            .help(showTranscript ? "Hide the live transcript" : "Show the live transcript")

            Button {
                Task {
                    await session.stop()
                    library.reload()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                    Text("Stop")
                }
            }
            .buttonStyle(ProminentCapsuleStyle(tint: .red))
            .disabled(!session.isRecording)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop and write up the meeting (⌘.)")
            .padding(.leading, 4)
        }
        .padding(5)
        .floatingSurface(Capsule())
        .animation(Motion.snappy, value: session.isPaused)
        .animation(Motion.snappy, value: session.isOffRecord)
    }
}

private struct TranscriptDrawer: View {
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live transcript")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(segments.isEmpty ? "Listening…" : "\(segments.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if segments.isEmpty {
                VStack(spacing: 10) {
                    ListeningBars(active: true, color: .secondary, barCount: 5, height: 18)
                    Text("Words appear here as people speak.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(segments) { segment in
                            SegmentRow(segment: segment)
                                .id(segment.id)
                                .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 90)
                    .animation(Motion.snappy, value: segments.count)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(segment.speaker == .me ? Color.grove : Color.blue)
                    .frame(width: 6, height: 6)
                Text(segment.speaker.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(segment.speaker == .me ? Color.grove : Color.blue)
                Text(segment.start.clockString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(segment.text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Writing up

/// What you see between Stop and the finished notes: which step is running,
/// so a pause of several seconds reads as work rather than a hang.
private struct WritingUpView: View {
    @Environment(MeetingSession.self) private var session

    private struct Step: Identifiable {
        let id: Int
        let title: String
    }

    private let steps = [
        Step(id: 0, title: "Finishing the transcript"),
        Step(id: 1, title: "Writing your notes"),
        Step(id: 2, title: "Naming and filing"),
    ]

    private var current: Int {
        switch session.phase {
        case .finishing: return 0
        case .enhancing: return 1
        case .naming: return 2
        default: return 0
        }
    }

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.grove)
                .symbolEffect(.pulse, options: .repeating)
            VStack(spacing: 6) {
                Text(session.title.trimmed.isEmpty ? "Writing up your meeting" : session.title)
                    .font(.display(28))
                    .multilineTextAlignment(.center)
                Text("\(session.elapsed.clockString) recorded · this takes a few seconds")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(steps) { step in
                    HStack(spacing: 10) {
                        Group {
                            if step.id < current {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.grove)
                            } else if step.id == current {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.quaternary)
                            }
                        }
                        .frame(width: 18)
                        .transition(.scale.combined(with: .opacity))
                        Text(step.title)
                            .foregroundStyle(step.id <= current ? .primary : .secondary)
                    }
                    .font(.system(size: 14))
                }
            }
            .padding(18)
            .frame(width: 300, alignment: .leading)
            .surface()
            .animation(Motion.snappy, value: current)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
