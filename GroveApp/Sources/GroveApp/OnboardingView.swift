import AppKit
import GroveKit
import SwiftUI

/// First run, in five short steps: hello, account, permissions, folders, and
/// how Grove behaves in a meeting.
///
/// The permissions step stays because the permissions are unusual and failure
/// is silent: Grove needs *system audio*, which almost nothing else asks for,
/// and a user who dismisses that prompt mid-meeting gets a transcript with only
/// their own voice in it and no explanation.
struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library
    @Environment(GoogleConnection.self) private var google

    @ViewState private var step = Step.welcome
    @ViewState private var checks: [SystemCheck] = []
    @ViewState private var chosenFolders: Set<String> = ["Work", "Personal"]
    @ViewState private var customFolder = ""
    @ViewState private var extraFolders: [String] = []

    enum Step: Int, CaseIterable {
        case welcome, account, permissions, folders, howItWorks
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                // Each step needs its own identity. Without it the branches of
                // the switch share one, so SwiftUI cross-fades in place and the
                // previous step stays painted underneath at partial opacity.
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 56)

            HStack {
                if step != .welcome {
                    Button("Back") { go(-1) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PageDots(count: Step.allCases.count, current: step.rawValue)
                Spacer()
                primaryButton
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(.bar)
        }
        .frame(minWidth: 680, minHeight: 580)
        .background(OnboardingBackground())
        .task { await refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .account: account
        case .permissions: permissions
        case .folders: folders
        case .howItWorks: howItWorks
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            GroveLogo(size: 112, animated: true)
            VStack(spacing: 10) {
                Text("Welcome to Grove")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(
                    "It listens to your meetings without joining them, and turns what was "
                        + "said — plus anything you jot down — into notes you'll actually use."
                )
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            }
            HStack(spacing: 14) {
                Promise(icon: "person.2.slash", title: "No bot", detail: "Nothing joins your call")
                Promise(icon: "cpu", title: "AI on your Mac", detail: "Transcripts never upload")
                Promise(icon: "doc.plaintext", title: "Your files", detail: "Plain Markdown, yours to keep")
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private var account: some View {
        VStack(spacing: 22) {
            Spacer()
            StepHeader(
                title: google.isSignedIn ? "You're signed in" : "Connect your Google account",
                detail: "Grove uses your calendar to name meetings and show what's next, and "
                    + "Gmail to send you the notes when a meeting ends. It can't read your inbox.")

            if let account = google.account {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(account.name ?? account.email).font(.headline)
                        Text(account.email).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out") { google.signOut() }
                }
                .padding(16)
                .frame(maxWidth: 420)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            } else if google.isConfigured {
                Button {
                    Task {
                        await google.signIn()
                        if let name = google.account?.firstName { settings.userName = name }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "g.circle.fill").font(.title2)
                        Text(google.isSigningIn ? "Waiting for Google…" : "Sign in with Google")
                            .font(.headline)
                    }
                    .frame(width: 280, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(google.isSigningIn)
            } else {
                Text(
                    "Google sign-in isn't set up in this build. Add a client ID (see the README) "
                        + "and rebuild — or carry on without it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if let error = google.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if !google.isSignedIn {
                VStack(spacing: 6) {
                    Text("Or just tell Grove your name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("First name", text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
            }
            Spacer()
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            StepHeader(
                title: "Let Grove hear the meeting",
                detail: "Your microphone is you; your Mac's audio is everyone else. Keeping "
                    + "them separate is how Grove knows who said what.",
                alignment: .leading)
            PermissionsList(checks: checks) { await refresh() }
            if checks.contains(where: { !$0.isReady }) {
                Text(
                    "macOS asks once for each. You can continue and grant them later — "
                        + "Grove will keep telling you what's missing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(maxWidth: 540)
    }

    private var folders: some View {
        VStack(spacing: 20) {
            Spacer()
            StepHeader(
                title: "Where do your meetings belong?",
                detail: "Pick the folders you want. Grove files each meeting into the right "
                    + "one when it ends — you can always move it.")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(FolderPreset.all + extraFolders.map(FolderPreset.custom)) { preset in
                    FolderChip(preset: preset, selected: chosenFolders.contains(preset.name)) {
                        if chosenFolders.contains(preset.name) {
                            chosenFolders.remove(preset.name)
                        } else {
                            chosenFolders.insert(preset.name)
                        }
                    }
                }
            }
            .frame(maxWidth: 520)

            HStack {
                TextField("Add your own…", text: $customFolder)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCustomFolder)
                Button("Add", action: addCustomFolder)
                    .disabled(customFolder.trimmed.isEmpty)
            }
            .frame(maxWidth: 320)
            Spacer()
        }
    }

    private var howItWorks: some View {
        @Bindable var settings = settings

        return VStack(alignment: .leading, spacing: 18) {
            Spacer()
            StepHeader(
                title: "How Grove works in a meeting",
                detail: "Set it up once and forget it's there.",
                alignment: .leading)

            Feature(
                icon: "waveform.badge.mic",
                title: "It notices your calls",
                detail: "When Zoom, Meet, Teams or FaceTime starts, Grove offers to take notes.") {
                Picker("", selection: $settings.meetingDetection) {
                    ForEach(AppSettings.MeetingDetection.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            Feature(
                icon: "square.and.pencil",
                title: "Quick notes, only when you want them",
                detail: "Press \(QuickNotesShortcut.label) from any app for a small notepad. "
                    + "Write what you want to remember; Grove hears the rest.") {
                Text(QuickNotesShortcut.label)
                    .font(.title3.monospaced().weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Feature(
                icon: "envelope",
                title: "Notes in your inbox",
                detail: google.isSignedIn
                    ? "When a meeting ends, the notes are emailed to \(google.account?.email ?? "you")."
                    : "Sign in with Google to get your notes by email.") {
                Toggle("", isOn: $settings.emailSummaries)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!google.isSignedIn)
            }

            Feature(
                icon: "brain",
                title: "Sharper notes with Claude",
                detail: settings.claudeExecutable == nil
                    ? "Install Claude Code to have Claude Haiku 5.5 write your notes on your own plan."
                    : "Use Claude Haiku 5.5 through Claude Code on this Mac, on your own plan. "
                        + "Off means everything stays on this Mac.") {
                Toggle("", isOn: Binding(
                    get: { settings.aiEngine == .claude },
                    set: { settings.aiEngine = $0 ? .claude : .onDevice }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(settings.claudeExecutable == nil)
            }

            Feature(
                icon: "sparkles",
                title: "Named and filed for you",
                detail: "Untitled meetings get a real name and land in the right folder.") {
                Toggle("", isOn: $settings.autoOrganize)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Spacer()
        }
        .frame(maxWidth: 560)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var primaryButton: some View {
        if step == .howItWorks {
            Button("Start Using Grove", action: finish)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(continueLabel) { go(1) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var continueLabel: String {
        switch step {
        case .welcome: return "Get Started"
        case .account where !google.isSignedIn: return "Skip for Now"
        default: return "Continue"
        }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { settings.userName }, set: { settings.userName = $0 })
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
        Task { await refresh() }
    }

    private func addCustomFolder() {
        let name = customFolder.trimmed
        guard !name.isEmpty else { return }
        if !extraFolders.contains(name) && !FolderPreset.all.contains(where: { $0.name == name }) {
            extraFolders.append(name)
        }
        chosenFolders.insert(name)
        customFolder = ""
    }

    private func finish() {
        for name in chosenFolders.sorted() {
            library.createFolder(named: name)
        }
        if settings.userName.trimmed.isEmpty, let name = google.account?.firstName {
            settings.userName = name
        }
        settings.hasCompletedOnboarding = true
    }

    private func refresh() async {
        checks = await Diagnostics.all()
    }
}

// MARK: - Pieces

struct FolderPreset: Identifiable, Hashable {
    let name: String
    let icon: String
    let detail: String
    var id: String { name }

    static let all = [
        FolderPreset(name: "Work", icon: "briefcase", detail: "Team syncs, standups"),
        FolderPreset(name: "School", icon: "graduationcap", detail: "Classes, study groups"),
        FolderPreset(name: "Personal", icon: "person", detail: "Everything else"),
        FolderPreset(name: "1:1s", icon: "person.2", detail: "Manager and reports"),
        FolderPreset(name: "Clients", icon: "building.2", detail: "Customer calls"),
        FolderPreset(name: "Interviews", icon: "person.badge.plus", detail: "Hiring loops"),
        FolderPreset(name: "Projects", icon: "hammer", detail: "Side projects"),
        FolderPreset(name: "Research", icon: "magnifyingglass", detail: "User interviews"),
    ]

    static func custom(_ name: String) -> FolderPreset {
        FolderPreset(name: name, icon: "folder", detail: "Your folder")
    }
}

private struct FolderChip: View {
    let preset: FolderPreset
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: preset.icon)
                    .font(.title3)
                    .frame(width: 24)
                    .foregroundStyle(selected ? Color.white : Color.grove)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).font(.callout.weight(.semibold))
                    Text(preset.detail)
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.white : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.grove) : AnyShapeStyle(.background.opacity(0.6))))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.clear : Color.secondary.opacity(0.2)))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

private struct StepHeader: View {
    let title: String
    let detail: String
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .frame(maxWidth: 480, alignment: alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Feature<Control: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.grove)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(14)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct Promise: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.grove)
            Text(title).font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 150, height: 96)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.grove : Color.secondary.opacity(0.25))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
        .accessibilityHidden(true)
    }
}

/// A soft wash of the icon's greens behind the onboarding steps.
private struct OnboardingBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.grove.opacity(0.10), Color.clear, Color.grove.opacity(0.05)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}
