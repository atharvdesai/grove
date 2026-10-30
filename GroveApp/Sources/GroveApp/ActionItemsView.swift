import GroveKit
import SwiftUI

/// Every follow-up from every meeting, in one list you can tick off.
///
/// Read from each meeting's notes, so it is never out of step with them, and
/// ticks are saved into the meeting's own meeting.json rather than a separate
/// database Grove would have to keep in sync.
struct ActionItemsView: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @ViewState private var showDone = false

    var body: some View {
        let items = ActionItems.extract(from: library.meetings)
            .filter { showDone || !$0.isDone }
        let grouped = Dictionary(grouping: items, by: \.meetingID)
        let order = items.map(\.meetingID).reduce(into: [UUID]()) { seen, id in
            if !seen.contains(id) { seen.append(id) }
        }

        VStack(spacing: 0) {
            HStack {
                Text("Action Items").font(.headline)
                Spacer()
                Toggle("Show done", isOn: $showDone)
                    .toggleStyle(.checkbox)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    showDone ? "No action items" : "All caught up",
                    systemImage: "checkmark.circle",
                    description: Text(
                        "Action items come from the “Action items” and “Next steps” "
                            + "sections of your written-up notes."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(order, id: \.self) { meetingID in
                        if let first = grouped[meetingID]?.first {
                            Section {
                                ForEach(grouped[meetingID] ?? []) { item in
                                    ActionItemRow(item: item) { done in
                                        library.setActionItem(item, done: done)
                                    } open: {
                                        open(item)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(first.meetingTitle)
                                    Spacer()
                                    Text(first.meetingDate, format: .dateTime.day().month())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 520)
    }

    /// Opens the meeting at the moment the item was said, the same way a chat
    /// citation does.
    private func open(_ item: ActionItem) {
        var info: [String: Any] = ["meetingID": item.meetingID]
        if let time = item.time { info["time"] = time }
        NotificationCenter.default.post(name: .navigateToMeeting, object: nil, userInfo: info)
        dismiss()
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let toggle: (Bool) -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                toggle(!item.isDone)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? Color.green : Color.secondary)
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
    @Environment(\.dismiss) private var dismiss
    @ViewState private var digest: String?
    @ViewState private var writing = false
    @ViewState private var failure: String?

    private var weeksMeetings: [Meeting] { MeetingDigest.meetings(library.meetings) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Week").font(.headline)
                    Text("\(weeksMeetings.count) \(weeksMeetings.count == 1 ? "meeting" : "meetings") in the last 7 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let digest {
                    CopyButton(title: "Copy", text: digest)
                    ShareLink(item: digest, subject: Text("This week's meetings")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

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
                            Button("Write This Week's Digest") { Task { await write() } }
                                .buttonStyle(.borderedProminent)
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
                digest = text
            } else {
                failure = "None of this week's meetings has notes to summarise yet."
            }
        } catch {
            failure = "Could not write the digest: \(error.localizedDescription)"
        }
    }
}
