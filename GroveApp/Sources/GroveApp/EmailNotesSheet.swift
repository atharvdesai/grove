import GroveKit
import SwiftUI

/// Sends a meeting's notes through the signed-in Gmail account.
///
/// Always a deliberate step with the recipients in view: the automatic email
/// only ever goes to the user themselves, so anything addressed to other people
/// passes through here.
struct EmailNotesSheet: View {
    let meeting: Meeting
    @Environment(GoogleConnection.self) private var google
    @Environment(\.dismiss) private var dismiss

    @ViewState private var recipients = ""
    @ViewState private var sending = false
    @ViewState private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Email Notes").font(.headline)

            if google.isSignedIn {
                Form {
                    TextField("To", text: $recipients, prompt: Text("name@example.com, …"))
                    LabeledContent("Subject", value: "Notes: \(meeting.title)")
                }
                .formStyle(.columns)

                if let result {
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(result.hasPrefix("Sent") ? Color.green : Color.red)
                }

                HStack {
                    Text("Sent from \(google.account?.email ?? "your Gmail")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button(sending ? "Sending…" : "Send") { Task { await send() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(sending || addresses.isEmpty)
                }
            } else {
                Text("Sign in with Google in Settings → Account to email your notes.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if recipients.isEmpty { recipients = google.account?.email ?? "" }
        }
    }

    private var addresses: [String] {
        recipients.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map(String.init)
            .filter { $0.contains("@") }
    }

    private func send() async {
        guard let email = SummaryEmail(meeting: meeting, to: addresses) else {
            result = "This meeting has no notes to send yet."
            return
        }
        sending = true
        defer { sending = false }
        do {
            try await google.send(email)
            result = "Sent to \(addresses.joined(separator: ", "))"
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        } catch {
            result = error.localizedDescription
        }
    }
}
