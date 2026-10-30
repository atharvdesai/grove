import GroveKit
import SwiftUI

/// What you see when you open Grove.
///
/// Ordered by what you are most likely to want in the next minute:
///
/// 1. **Now** — a call on your calendar that is happening, with one click to
///    take notes. That is the moment people open a meeting app (Granola leads
///    with it for the same reason).
/// 2. **Ask** — a composer, because the next most common reason to open your
///    meeting notes is to look something up.
/// 3. **Recent** — the last few meetings with what each came to, so getting
///    back to work is one click.
///
/// Problems that would quietly ruin a recording — a missing permission — jump
/// the queue, because noticing them now beats noticing them afterwards.
struct HomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library
    @Environment(MeetingSession.self) private var session
    @Environment(GoogleConnection.self) private var google

    let newMeeting: () -> Void
    @Binding var destination: Destination

    @ViewState private var checks: [SystemCheck] = []
    @ViewState private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                    .reveal(appeared, order: 0)

                if checks.contains(where: { !$0.isReady }) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Before your next meeting")
                        PermissionsList(checks: checks.filter { !$0.isReady }) {
                            checks = await Diagnostics.all()
                        }
                    }
                    .reveal(appeared, order: 1)
                }

                let upcoming = google.upcomingToday
                if !upcoming.isEmpty {
                    ComingUp(events: Array(upcoming.prefix(4)))
                        .reveal(appeared, order: 1)
                }

                AskComposer { question in
                    AskHandoff.pending = question
                    destination = .ask
                }
                .reveal(appeared, order: 2)

                if library.meetings.isEmpty {
                    FirstMeeting(newMeeting: newMeeting)
                        .reveal(appeared, order: 3)
                } else {
                    attention
                        .reveal(appeared, order: 3)
                    RecentMeetings(meetings: Array(library.meetings.prefix(6)), destination: $destination)
                        .reveal(appeared, order: 4)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: Metrics.readingWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 44)
        }
        .scrollIndicators(.automatic)
        .task {
            checks = await Diagnostics.all()
            appeared = true
        }
        // Coming back from System Settings should reflect what changed there.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { checks = await Diagnostics.all() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(greeting)
                .font(.display(34))
        }
    }

    /// What is waiting on you, as quiet links rather than a wall of tiles.
    private var attention: some View {
        HStack(spacing: 10) {
            AttentionChip(icon: "checklist", text: openItemsLabel) { destination = .actionItems }
            AttentionChip(icon: "hourglass", text: waitingLabel) { destination = .insights(.waiting) }
            AttentionChip(icon: "calendar", text: "This week") { AppSheet.digest.show() }
            Spacer(minLength: 0)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = settings.userName.trimmed.isEmpty
            ? (google.account?.firstName ?? "") : settings.userName.trimmed
        return name.isEmpty ? part : "\(part), \(name)"
    }

    private var waitingLabel: String {
        let count = library.waitingOn.count
        return count == 0 ? "Nobody owes you anything" : "\(count) promised to you"
    }

    private var openItemsLabel: String {
        let open = ActionItems.extract(from: library.meetings).filter { !$0.isDone }.count
        return open == 0 ? "No open action items" : "\(open) open action \(open == 1 ? "item" : "items")"
    }
}

/// Carries a question typed on Home over to the Ask page, which picks it up
/// when it appears. One slot, read once.
@MainActor
enum AskHandoff {
    static var pending: String?
}

private extension View {
    /// Fades and lifts sections in, one after another, when Home first shows.
    func reveal(_ shown: Bool, order: Int) -> some View {
        modifier(Reveal(shown: shown, order: order))
    }
}

private struct Reveal: ViewModifier {
    let shown: Bool
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .animation(
                reduceMotion ? nil : Motion.gentle.delay(Double(order) * 0.05),
                value: shown)
    }
}

/// A Claude-style composer that hands off to the Ask page.
private struct AskComposer: View {
    let ask: (String) -> Void
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .foregroundStyle(Color.grove)
            TextField("Ask anything about your meetings…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(CircleIconStyle(tint: .grove, size: 28))
            .disabled(text.trimmed.isEmpty)
            .opacity(text.trimmed.isEmpty ? 0.4 : 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.groveCard))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? Color.grove.opacity(0.55) : Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(focused ? 0.08 : 0.04), radius: focused ? 12 : 6, y: 2)
        .animation(Motion.hover, value: focused)
    }

    private func submit() {
        let question = text.trimmed
        guard !question.isEmpty else { return }
        ask(question)
    }
}

/// Today's remaining calendar events. A call that is on now gets a button to
/// start taking notes in it, named after the event.
private struct ComingUp: View {
    let events: [CalendarEvent]
    @Environment(MeetingSession.self) private var session
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Coming up")
            VStack(spacing: 8) {
                ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                    row(event)
                }
            }
        }
    }

    private func row(_ event: CalendarEvent) -> some View {
        let isNow = event.start <= Date()
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(event.start, format: .dateTime.hour().minute())
                    .font(.callout.weight(.semibold).monospacedDigit())
                Text(event.end, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 58, alignment: .leading)

            RoundedRectangle(cornerRadius: 2)
                .fill(isNow ? Color.red : Color.grove)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? "Untitled event" : event.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(detail(for: event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isNow {
                Button {
                    session.title = event.title
                    session.templateID = settings.defaultTemplateID
                    Task { await session.start() }
                } label: {
                    Label("Take Notes", systemImage: "record.circle")
                }
                .buttonStyle(ProminentCapsuleStyle(tint: .red))
                .disabled(session.isBusy)
            } else if event.hasVideoLink {
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
                    .help("Has a call link — Grove will offer to take notes when it starts")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surface()
    }

    private func detail(for event: CalendarEvent) -> String {
        let when = event.start <= Date() ? "Happening now" : event.start.formatted(.relative(presentation: .named))
        guard !event.attendees.isEmpty else { return when }
        let people = event.attendees.prefix(3).joined(separator: ", ")
        let more = event.attendees.count > 3 ? " +\(event.attendees.count - 3)" : ""
        return "\(when) · \(people)\(more)"
    }
}

private struct AttentionChip: View {
    let icon: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Color.grove)
                Text(text)
                    .lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(CardButtonStyle(cornerRadius: 999))
    }
}

/// The empty state, as three steps rather than a shrug.
private struct FirstMeeting: View {
    let newMeeting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Your first meeting")
            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, title: "Join a call, or press New Meeting",
                     detail: "Grove notices Zoom, Meet, Teams and FaceTime and offers to take notes.")
                Step(number: 2, title: "Jot down whatever matters to you",
                     detail: "Fragments are fine. Grove hears the rest — nothing joins the call.")
                Step(number: 3, title: "Stop, and get notes worth keeping",
                     detail: "Your headings, filled in from what was actually said, with every line checkable.")
            }
            Button(action: newMeeting) {
                Label("New Meeting", systemImage: "plus")
            }
            .buttonStyle(ProminentCapsuleStyle())
            .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: 16)
    }

    private struct Step: View {
        let number: Int
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.grove)
                    .frame(width: 26, height: 26)
                    .background(Color.grove.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct RecentMeetings: View {
    let meetings: [Meeting]
    @Binding var destination: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Recent")
            VStack(spacing: 2) {
                ForEach(meetings) { meeting in
                    Button {
                        destination = .meeting(meeting.id)
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(DayLabel.label(for: meeting.startedAt))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text(meeting.startedAt, format: .dateTime.hour().minute())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 76, alignment: .leading)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .lineLimit(1)
                                let summary = meeting.resolvedInsights.summary
                                if !summary.isEmpty {
                                    Text(summary)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                HStack(spacing: 8) {
                                    if meeting.duration >= 60 {
                                        Label("\(Int(meeting.duration / 60)) min", systemImage: "clock")
                                    }
                                    if let folder = meeting.folder {
                                        Label(folder, systemImage: "folder")
                                    }
                                    if meeting.enhancedNotes == nil {
                                        Label("Transcript only", systemImage: "text.quote")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .labelStyle(.titleAndIcon)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
    }
}
