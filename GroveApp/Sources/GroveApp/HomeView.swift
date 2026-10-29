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

    let newMeeting: () -> Void
    @Binding var selection: Meeting.ID?

    @State private var checks: [SystemCheck] = []
    @State private var showingChat = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 18) {
                    GroveWordmark(size: 76)

                    Button(action: newMeeting) {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle.fill").foregroundStyle(.red)
                            Text("New Meeting").font(.body.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary.opacity(0.08))
                    .foregroundStyle(.primary)
                    .disabled(session.isBusy)
                    .keyboardShortcut("n")

                    Text("or press ⌘N any time, even from another app's menu bar")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 36)

                if !checks.isEmpty {
                    ReadinessRow(checks: checks) { checks = await Diagnostics.all() }
                        .frame(maxWidth: 560)
                }

                if !library.meetings.isEmpty {
                    RecentMeetings(
                        meetings: Array(library.meetings.prefix(4)), selection: $selection)
                        .frame(maxWidth: 560)

                    Button {
                        showingChat = true
                    } label: {
                        Label("Ask your meetings", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Ask a question across every saved meeting")
                }

                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .sheet(isPresented: $showingChat) { ChatView() }
        .task { checks = await Diagnostics.all() }
        // Coming back from System Settings should reflect what changed there.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { checks = await Diagnostics.all() }
        }
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
            Text("RECENT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

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
