import GroveKit
import SwiftUI

/// What you see when no meeting is open.
///
/// Replaces a bare "No meeting selected", which told the user nothing and
/// offered them nothing. A home screen has three jobs here: say what to press,
/// show that the machine is actually ready to record, and get back to recent
/// work in one click.
///
/// The readiness row matters more than it looks. Every failure in this pipeline
/// is silent — a denied permission produces a transcript missing one side and no
/// error — so surfacing it before a meeting is the difference between noticing
/// now and noticing afterwards.
struct HomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library
    @Environment(MeetingSession.self) private var session
    @Environment(GoogleConnection.self) private var google

    let newMeeting: () -> Void
    @Binding var selection: Meeting.ID?

    @ViewState private var checks: [SystemCheck] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if checks.contains(where: { !$0.isReady }) {
                    ReadinessRow(checks: checks) { checks = await Diagnostics.all() }
                }

                let upcoming = google.upcomingToday
                if !upcoming.isEmpty {
                    ComingUp(events: Array(upcoming.prefix(4)))
                }

                if !library.meetings.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12
                    ) {
                        ActionCard(
                            icon: "bubble.left.and.bubble.right", title: "Ask",
                            detail: "Anything across your meetings"
                        ) { AppSheet.chat.show() }
                        ActionCard(
                            icon: "checklist", title: "Action items",
                            detail: openItemsLabel
                        ) { AppSheet.actionItems.show() }
                        ActionCard(
                            icon: "hourglass", title: "Waiting on",
                            detail: waitingLabel
                        ) { AppSheet.waiting.show() }
                        ActionCard(
                            icon: "person.2", title: "People",
                            detail: "Who you meet and what's owed"
                        ) { AppSheet.people.show() }
                        ActionCard(
                            icon: "checkmark.seal", title: "Decisions",
                            detail: "Every decision, current first"
                        ) { AppSheet.decisions.show() }
                        ActionCard(
                            icon: "calendar", title: "This week",
                            detail: "Decisions and what changed"
                        ) { AppSheet.digest.show() }
                        ActionCard(
                            icon: "square.and.pencil", title: "Quick notes",
                            detail: "\(QuickNotesShortcut.label) from any app"
                        ) { NotificationCenter.default.post(name: .toggleQuickNotes, object: nil) }
                    }

                    RecentMeetings(
                        meetings: Array(library.meetings.prefix(5)), selection: $selection)
                } else {
                    EmptyLibrary(newMeeting: newMeeting)
                }

                Spacer(minLength: 20)
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 28)
        }
        .task { checks = await Diagnostics.all() }
        // Coming back from System Settings should reflect what changed there.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { checks = await Diagnostics.all() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            GroveLogo(size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: newMeeting) {
                Label("New Meeting", systemImage: "record.circle.fill")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isBusy)
            .keyboardShortcut("n")
            .help("Name a meeting and start recording (⌘N)")
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
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
        return open == 0 ? "All caught up" : "\(open) open"
    }
}

/// Today's remaining calendar events, so the next meeting is one glance away.
private struct ComingUp: View {
    let events: [CalendarEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("COMING UP")
            VStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(event.start <= Date() ? Color.red : Color.grove)
                            .frame(width: 4, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title.isEmpty ? "Untitled event" : event.title)
                                .lineLimit(1)
                            Text(detail(for: event))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if event.hasVideoLink {
                            Image(systemName: "video")
                                .foregroundStyle(.secondary)
                                .help("Has a call link — Grove will offer to take notes when it starts")
                        }
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    if index < events.count - 1 { Divider().padding(.leading, 28) }
                }
            }
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func detail(for event: CalendarEvent) -> String {
        let time = event.start <= Date()
            ? "Now, until \(event.end.formatted(date: .omitted, time: .shortened))"
            : event.start.formatted(date: .omitted, time: .shortened)
        guard !event.attendees.isEmpty else { return time }
        let people = event.attendees.prefix(3).joined(separator: ", ")
        let more = event.attendees.count > 3 ? " +\(event.attendees.count - 3)" : ""
        return "\(time) · \(people)\(more)"
    }
}

private struct ActionCard: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.grove)
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(hovering ? 0.45 : 0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct EmptyLibrary: View {
    let newMeeting: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(Color.grove)
            Text("Your first meeting goes here").font(.headline)
            Text(
                "Join a call and Grove will offer to take notes, or press New Meeting. "
                    + "Press \(QuickNotesShortcut.label) any time to jot something down.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("New Meeting", action: newMeeting).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct ReadinessRow: View {
    let checks: [SystemCheck]
    let refresh: () async -> Void

    private var problems: [SystemCheck] { checks.filter { !$0.isReady } }

    var body: some View {
        if problems.isEmpty {
            Label("Ready to record", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        } else {
            // Each problem is named individually and carries its own fix, because
            // which one is missing changes what the user loses — and because the
            // previous version pointed at Grove' Settings, which had nothing to
            // say about permissions. A warning must lead somewhere that helps.
            PermissionsList(checks: problems, refresh: refresh)
        }
    }
}

private struct RecentMeetings: View {
    let meetings: [Meeting]
    @Binding var selection: Meeting.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("RECENT")

            VStack(spacing: 0) {
                ForEach(meetings) { meeting in
                    Button {
                        selection = meeting.id
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(
                                        meeting.startedAt,
                                        format: .dateTime.day().month().hour().minute())
                                    if let folder = meeting.folder {
                                        Label(folder, systemImage: "folder")
                                    }
                                    if meeting.enhancedNotes == nil {
                                        Text("· transcript only")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if meeting.id != meetings.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
