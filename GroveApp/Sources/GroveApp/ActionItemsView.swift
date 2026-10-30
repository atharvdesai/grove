import GroveKit
import SwiftUI

/// Every follow-up from every meeting, in one list you can tick off.
///
/// Read from each meeting's notes, so it is never out of step with them, and
/// ticks are saved into the meeting's own meeting.json rather than a separate
/// database Grove would have to keep in sync.
struct ActionItemsView: View {
    @Environment(MeetingLibrary.self) private var library
    @ViewState private var showDone = false

    var body: some View {
        let items = ActionItems.extract(from: library.meetings)
            .filter { showDone || !$0.isDone }
        let grouped = Dictionary(grouping: items, by: \.meetingID)
        let order = items.map(\.meetingID).reduce(into: [UUID]()) { seen, id in
            if !seen.contains(id) { seen.append(id) }
        }

        VStack(spacing: 0) {
            PageHeader("Action Items", subtitle: openCountLabel) {
                Toggle("Show done", isOn: $showDone.animation(Motion.snappy))
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 16)

            if items.isEmpty {
                ContentUnavailableView(
                    showDone ? "No action items" : "All caught up",
                    systemImage: "checkmark.circle",
                    description: Text(
                        "Action items come from the “Action items” and “Next steps” "
                            + "sections of your written-up notes."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(order, id: \.self) { meetingID in
                            if let first = grouped[meetingID]?.first {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(first.meetingTitle)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(DayLabel.label(for: first.meetingDate))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    VStack(spacing: 0) {
                                        ForEach(grouped[meetingID] ?? []) { item in
                                            ActionItemRow(item: item) { done in
                                                library.setActionItem(item, done: done)
                                            } open: {
                                                open(item)
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .transition(.opacity)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .surface()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    /// Opens the meeting at the moment the item was said, the same way a chat
    /// citation does.
    private func open(_ item: ActionItem) {
        var info: [String: Any] = ["meetingID": item.meetingID]
        if let time = item.time { info["time"] = time }
        NotificationCenter.default.post(name: .navigateToMeeting, object: nil, userInfo: info)
    }

    private var openCountLabel: String {
        let open = ActionItems.extract(from: library.meetings).filter { !$0.isDone }.count
        return open == 0 ? "All caught up" : "\(open) open across your meetings"
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let toggle: (Bool) -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                withAnimation(Motion.snappy) { toggle(!item.isDone) }
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.isDone ? Color.grove : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(item.isDone ? "Mark as not done" : "Mark as done")

            Text(item.text)
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: open) {
                if let time = item.time {
                    Text(time.clockString).font(.caption.monospacedDigit())
                } else {
                    Image(systemName: "arrow.up.forward.square")
                }
            }
            .buttonStyle(.borderless)
            .help("Open the meeting where this was said")
        }
        .padding(.vertical, 2)
    }
}

/// A summary of the last seven days of meetings, written on-device.
struct DigestView: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @ViewState private var digest: String?
    @ViewState private var writing = false
    @ViewState private var failure: String?

    private var weeksMeetings: [Meeting] { MeetingDigest.meetings(library.meetings) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                "This Week",
                subtitle: "\(weeksMeetings.count) \(weeksMeetings.count == 1 ? "meeting" : "meetings") in the last 7 days",
                icon: "calendar"
            ) {
                if let digest {
                    CopyButton(title: "Copy", text: digest)
                    ShareLink(item: digest, subject: Text("This week's meetings")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Divider()

            ScrollView {
                Group {
                    if let digest {
                        NotesText(markdown: digest)
                    } else if writing {
                        ProgressView("Reading this week's notes…")
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 14) {
                            Text(
                                "Grove reads the notes from this week's meetings and lists "
                                    + "what was decided, what's owed, what's still open, and "
                                    + "what changed along the way — on this Mac.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button {
                                Task { await write() }
                            } label: {
                                Label("Write This Week's Digest", systemImage: "sparkles")
                            }
                            .buttonStyle(ProminentCapsuleStyle())
                            .disabled(weeksMeetings.isEmpty)
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 520)
    }

    private func write() async {
        let writer = MeetingDigest(model: settings.writingModel)
        if case .unavailable(let reason) = writer.availability {
            failure = "The writing model is unavailable (\(reason))."
            return
        }
        writing = true
        defer { writing = false }
        do {
            if let text = try await writer.write(for: weeksMeetings) {
                withAnimation(Motion.gentle) { digest = text }
            } else {
                failure = "None of this week's meetings has notes to summarise yet."
            }
        } catch {
            failure = "Could not write the digest: \(error.localizedDescription)"
        }
    }
}
