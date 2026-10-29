import AppKit
import GroveKit
import SwiftUI

/// First run: what Grove is, the permissions it needs, and where notes go.
///
/// It exists because the permissions are unusual and failure is silent. Grove
/// needs *system audio*, which almost nothing else asks for, and if the user
/// dismisses that prompt during a real meeting they get a transcript with only
/// their own voice in it and no explanation. Asking up front, with the reason
/// next to the button, is the difference between a tool that works and one that
/// looks broken.
struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @State private var step = 0
    @State private var checks: [SystemCheck] = []

    private let lastStep = 2

    var body: some View {
        VStack(spacing: 0) {
            content
                // Each step needs its own identity. Without it the branches of
                // the switch share one, so SwiftUI cross-fades in place and the
                // previous step stays painted underneath at partial opacity.
                .id(step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 48)

            Divider()

            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PageDots(count: lastStep + 1, current: step)
                Spacer()
                primaryButton
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 640, minHeight: 560)
        .task { await refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: permissions
        default: ready
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            GroveWordmark(size: 104, animated: true, tagline: nil)

            VStack(spacing: 10) {
                Text("Meeting notes that never leave your Mac")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(
                    "Grove listens to your meetings without joining them, transcribes "
                        + "both sides on this machine, and turns the rough notes you type "
                        + "into polished ones that keep your structure."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            }

            HStack(spacing: 26) {
                Promise(icon: "wifi.slash", title: "No cloud", detail: "No account, no uploads")
                Promise(icon: "doc.plaintext", title: "Plain files", detail: "Markdown you can keep")
                Promise(icon: "person.2.slash", title: "No bot", detail: "Nothing joins your call")
            }
            .padding(.top, 6)
            Spacer()
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text("Let Grove hear the meeting")
                    .font(.title2.weight(.semibold))
                Text(
                    "Two streams, kept separate — that is how Grove labels who said "
                        + "what without any speaker-recognition model."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            PermissionsList(checks: checks) { await refresh() }

            if checks.contains(where: { !$0.isReady }) {
                // No bulk "Grant everything" button: each row already offers the
                // right action for its own state, which a single button cannot,
                // since a denied permission can only be fixed in System Settings.
                Text(
                    "macOS asks once for each. You can continue without them and "
                        + "grant them later — Grove will keep telling you what is missing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(maxWidth: 520)
    }

    private var ready: some View {
        VStack(spacing: 20) {
            Spacer()
            GroveLogo(size: 88)
            Text("You're set up")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                Step(number: 1, text: "Press **New Meeting** when your call starts.")
                Step(number: 2, text: "Type rough fragments in the notepad — they do not need to be tidy.")
                Step(number: 3, text: "Press **Stop**. Grove writes them up using what was actually said.")
            }
            .frame(maxWidth: 420, alignment: .leading)

            LabeledContent {
                Text(settings.storageURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Text("Notes are saved to").font(.caption)
            }
            .frame(maxWidth: 420)
            .padding(.top, 4)

            // Seen in testing: macOS raises a third prompt, for the Documents
            // folder, the first time Grove reads its own notes. Unannounced it
            // looks like the app is reaching somewhere it should not.
            Text(
                "macOS may ask for access to your Documents folder — that is Grove "
                    + "reading its own notes. You can change any of this later in Settings."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            Spacer()
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var primaryButton: some View {
        if step < lastStep {
            Button(step == 0 ? "Get Started" : "Continue") {
                withAnimation { step += 1 }
                Task { await refresh() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        } else {
            Button("Start Using Grove") {
                settings.hasCompletedOnboarding = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func refresh() async {
        checks = await Diagnostics.all()
    }

}

// MARK: - Pieces

private struct Promise: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 130)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            Text(.init(text)).font(.callout)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
