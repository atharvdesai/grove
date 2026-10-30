import AppKit
import GroveKit
import SwiftUI

/// First run: one question per screen, then everything set up.
///
/// Modelled on onboarding that people actually finish (Opal's is the
/// reference): a thin progress bar instead of a step count, one large question
/// at a time, answers that visibly shape the app — your folders, your name,
/// who writes your notes — and a closing screen that shows what was set up, so
/// the first view of the app feels prepared rather than empty.
///
/// The permissions screen primes before it asks. Grove needs *system audio*,
/// which almost nothing else asks for; a user who dismisses that prompt
/// mid-meeting gets a transcript with only their own voice in it and no
/// explanation. Saying what the dialog will be, and why, before macOS shows it
/// is the difference between Allow and Don't Allow.
struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library
    @Environment(GoogleConnection.self) private var google
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewState private var step = Step.welcome
    @ViewState private var movingForward = true
    @ViewState private var checks: [SystemCheck] = []
    @ViewState private var uses: Set<UseCase> = [.work]

    enum Step: Int, CaseIterable {
        case welcome, uses, name, permissions, writer, calls, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, 14)
                .padding(.horizontal, 22)

            ZStack {
                content
                    // Each step needs its own identity. Without it the branches
                    // of the switch share one, so SwiftUI cross-fades in place
                    // and the previous step stays painted underneath.
                    .id(step)
                    .transition(stepTransition)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 48)
            }

            primaryButton
                .padding(.bottom, 34)
        }
        .frame(minWidth: 760, minHeight: 640)
        .background(OnboardingBackground(step: step.rawValue))
        .ignoresSafeArea()
        .task { await refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await refresh() }
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: movingForward ? 40 : -40)),
            removal: .opacity.combined(with: .offset(x: movingForward ? -40 : 40)))
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            // Clear of the traffic lights.
            Color.clear.frame(width: 60, height: 1)
            Button {
                go(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(CircleIconStyle(size: 28))
            .foregroundStyle(.secondary)
            .opacity(step == .welcome || step == .ready ? 0 : 1)
            .disabled(step == .welcome || step == .ready)
            .help("Back")

            Spacer()
            ProgressBar(progress: Double(step.rawValue) / Double(Step.allCases.count - 1))
                .frame(width: 240)
                .opacity(step == .welcome ? 0 : 1)
            Spacer()

            Color.clear.frame(width: 88, height: 1)
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private var primaryButton: some View {
        Button(action: advance) {
            Text(primaryLabel)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 260)
                .padding(.vertical, 4)
        }
        .buttonStyle(ProminentCapsuleStyle())
        .keyboardShortcut(.defaultAction)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get Started"
        case .uses: return uses.isEmpty ? "Skip" : "Continue"
        case .name: return settings.userName.trimmed.isEmpty ? "Skip" : "Continue"
        case .permissions: return checks.contains(where: { !$0.isReady }) ? "I'll Do This Later" : "Continue"
        case .ready: return "Open Grove"
        default: return "Continue"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .uses: usesStep
        case .name: nameStep
        case .permissions: permissionsStep
        case .writer: writerStep
        case .calls: callsStep
        case .ready: readyStep
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 28) {
            GroveLogo(size: 104, animated: true)
            VStack(spacing: 12) {
                Text("Meetings, remembered.")
                    .font(.display(44))
                Text(
                    "Grove listens without joining the call, and turns what was said — "
                        + "plus whatever you jot down — into notes worth keeping.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            HStack(spacing: 10) {
                PromiseChip(icon: "person.2.slash", text: "No bot in the call")
                PromiseChip(icon: "lock", text: "Private by default")
                PromiseChip(icon: "doc.plaintext", text: "Plain files you own")
            }
        }
    }

    private var usesStep: some View {
        VStack(spacing: 26) {
            Question(
                title: "What will you use Grove for?",
                detail: "Pick all that apply. Grove makes a folder for each and files meetings into them.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(UseCase.allCases) { use in
                    ChoiceCard(
                        icon: use.icon, title: use.title, detail: use.detail,
                        selected: uses.contains(use)
                    ) {
                        withAnimation(Motion.snappy) {
                            if uses.contains(use) { uses.remove(use) } else { uses.insert(use) }
                        }
                    }
                }
            }
        }
    }

    private var nameStep: some View {
        VStack(spacing: 26) {
            Question(
                title: "What should Grove call you?",
                detail: "So your notes know which promises are yours.")

            TextField("Your first name", text: nameBinding)
                .textFieldStyle(.plain)
                .font(.display(30))
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .frame(maxWidth: 360)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.grove.opacity(0.5)).frame(height: 1.5)
                }
                .onSubmit(advance)

            VStack(spacing: 10) {
                if let account = google.account {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.grove)
                        Text("Connected as \(account.email)")
                        Button("Sign Out") { google.signOut() }
                            .buttonStyle(.borderless)
                    }
                    .font(.callout)
                } else if google.isConfigured {
                    Button {
                        Task {
                            await google.signIn()
                            if settings.userName.trimmed.isEmpty, let name = google.account?.firstName {
                                settings.userName = name
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar.badge.checkmark")
                            Text(google.isSigningIn ? "Waiting for Google…" : "Connect Google Calendar & Gmail")
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(CardButtonStyle(cornerRadius: 999))
                    .disabled(google.isSigningIn)
                    Text("Optional. Names meetings from your calendar, shows what's next, and emails you the notes. It can't read your inbox.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                if let error = google.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
            .padding(.top, 8)
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Question(
                title: "Let Grove hear the meeting",
                detail: "Two permissions, asked once. Your microphone is you; your Mac's audio "
                    + "is everyone else — keeping them apart is how Grove knows who said what.")

            HStack(spacing: 12) {
                SourceCard(icon: "mic.fill", title: "You", detail: "Microphone")
                Image(systemName: "plus")
                    .foregroundStyle(.tertiary)
                SourceCard(icon: "speaker.wave.2.fill", title: "Everyone else", detail: "Mac audio")
            }

            PermissionsList(checks: checks) { await refresh() }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.point.up.left.fill")
                    .foregroundStyle(Color.grove)
                Text("macOS will show its own dialog for each — choose **Allow**. Mac audio is listed under Screen & System Audio Recording; Grove never records your screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 480, alignment: .leading)
        }
    }

    private var writerStep: some View {
        VStack(spacing: 24) {
            Question(
                title: "Who should write your notes?",
                detail: "You can change this any time from the bottom of the sidebar.")
            ClaudeConnectionCard()
        }
    }

    private var callsStep: some View {
        @Bindable var settings = settings

        return VStack(spacing: 24) {
            Question(
                title: "When a call starts…",
                detail: "Grove notices Zoom, Meet, Teams and FaceTime. What should it do?")

            VStack(spacing: 10) {
                ForEach(AppSettings.MeetingDetection.allCases) { option in
                    ChoiceCard(
                        icon: icon(for: option), title: option.label, detail: detail(for: option),
                        selected: settings.meetingDetection == option
                    ) {
                        withAnimation(Motion.snappy) { settings.meetingDetection = option }
                    }
                }
            }

            HStack(spacing: 14) {
                Toggle(isOn: $settings.autoOrganize) {
                    Text("Name and file untitled meetings for me")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                HStack(spacing: 6) {
                    Text(QuickNotesShortcut.label)
                        .font(.callout.monospaced().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.groveWash, in: RoundedRectangle(cornerRadius: 5))
                    Text("quick notes, anywhere")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var readyStep: some View {
        VStack(spacing: 26) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.grove)
                .symbolEffect(.bounce, value: step)
            Question(
                title: settings.userName.trimmed.isEmpty ? "You're all set" : "You're all set, \(settings.userName.trimmed)",
                detail: "Here's how Grove is set up. All of it lives in Settings.")
            VStack(alignment: .leading, spacing: 12) {
                SummaryRow(
                    done: true,
                    text: chosenFolders.isEmpty
                        ? "Meetings saved to your Documents folder"
                        : "Folders for \(chosenFolders.joined(separator: ", "))")
                SummaryRow(
                    done: !checks.contains(where: { !$0.isReady }),
                    text: checks.contains(where: { !$0.isReady })
                        ? "Permissions still needed — Home will remind you"
                        : "Microphone and Mac audio allowed")
                SummaryRow(
                    done: settings.aiEngine == .onDevice || settings.usesClaude,
                    text: settings.usesClaude
                        ? "Claude writes your notes"
                        : settings.aiEngine == .claude
                            ? "Claude chosen, but Claude Code isn't installed yet"
                            : "Notes written on this Mac")
                SummaryRow(done: true, text: "When a call starts: \(settings.meetingDetection.label.lowercased())")
                if google.isSignedIn {
                    SummaryRow(done: true, text: "Calendar and Gmail connected")
                }
            }
            .padding(20)
            .frame(maxWidth: 440, alignment: .leading)
            .surface(cornerRadius: 14)
        }
    }

    // MARK: - Actions

    private var nameBinding: Binding<String> {
        Binding(get: { settings.userName }, set: { settings.userName = $0 })
    }

    private var chosenFolders: [String] {
        UseCase.allCases.filter { uses.contains($0) }.map(\.folder)
    }

    private func advance() {
        if step == .ready {
            finish()
        } else {
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        movingForward = delta > 0
        withAnimation(Motion.respecting(reduceMotion, Motion.gentle)) { step = next }
        Task { await refresh() }
    }

    private func finish() {
        for name in chosenFolders {
            library.createFolder(named: name)
        }
        // Someone who only records lectures should not have to pick the
        // lecture template every time.
        if uses == [.school] {
            settings.defaultTemplateID = NoteTemplate.lecture.id
        }
        if settings.userName.trimmed.isEmpty, let name = google.account?.firstName {
            settings.userName = name
        }
        withAnimation(Motion.gentle) { settings.hasCompletedOnboarding = true }
    }

    private func refresh() async {
        checks = await Diagnostics.all()
    }

    private func icon(for option: AppSettings.MeetingDetection) -> String {
        switch option {
        case .off: return "hand.raised"
        case .ask: return "bell.badge"
        case .automatic: return "record.circle"
        }
    }

    private func detail(for option: AppSettings.MeetingDetection) -> String {
        switch option {
        case .off: return "Start every recording yourself."
        case .ask: return "A small prompt offers to take notes. Recommended — the others on the call may not have agreed."
        case .automatic: return "Recording starts on its own when a call does."
        }
    }
}

// MARK: - Use cases

/// What someone records, and the folder that becomes.
enum UseCase: String, CaseIterable, Identifiable, Hashable {
    case work, school, oneOnOnes, clients, interviews, personal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: return "Work calls"
        case .school: return "Classes & lectures"
        case .oneOnOnes: return "1:1s"
        case .clients: return "Client calls"
        case .interviews: return "Interviews"
        case .personal: return "Personal"
        }
    }

    var detail: String {
        switch self {
        case .work: return "Standups, syncs, reviews"
        case .school: return "Lectures and study groups"
        case .oneOnOnes: return "Your manager, your reports"
        case .clients: return "Sales and customer calls"
        case .interviews: return "Hiring and user research"
        case .personal: return "Everything else"
        }
    }

    var icon: String {
        switch self {
        case .work: return "briefcase"
        case .school: return "graduationcap"
        case .oneOnOnes: return "person.2"
        case .clients: return "building.2"
        case .interviews: return "person.badge.plus"
        case .personal: return "heart"
        }
    }

    var folder: String {
        switch self {
        case .work: return "Work"
        case .school: return "School"
        case .oneOnOnes: return "1:1s"
        case .clients: return "Clients"
        case .interviews: return "Interviews"
        case .personal: return "Personal"
        }
    }
}

// MARK: - Pieces

private struct Question: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.display(34))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ChoiceCard: View {
    let icon: String
    let title: String
    let detail: String
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                IconTile(systemName: icon, size: 32, tint: selected ? .white : .grove)
                    .background(
                        selected ? Color.white.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.white : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(selected ? Color.grove : Color.clear))
        }
        .buttonStyle(CardButtonStyle())
        .animation(Motion.snappy, value: selected)
    }
}

private struct PromiseChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.grove)
            Text(text)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .surface(cornerRadius: 999)
    }
}

private struct SourceCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.grove)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 150, height: 96)
        .surface(cornerRadius: 14)
    }
}

private struct SummaryRow: View {
    let done: Bool
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(done ? Color.grove : Color.orange)
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.groveWash)
                Capsule()
                    .fill(Color.grove)
                    .frame(width: max(6, proxy.size.width * progress))
            }
        }
        .frame(height: 5)
        .animation(Motion.gentle, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Setup progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// The canvas colour with a slow green glow that drifts as you move through
/// the steps — enough to feel alive, not enough to distract.
private struct OnboardingBackground: View {
    let step: Int

    var body: some View {
        ZStack {
            Color.groveCanvas
            RadialGradient(
                colors: [Color.grove.opacity(0.22), Color.clear],
                center: UnitPoint(x: 0.2 + 0.1 * Double(step % 4), y: 0.15),
                startRadius: 0, endRadius: 520)
            RadialGradient(
                colors: [Color.grove.opacity(0.1), Color.clear],
                center: UnitPoint(x: 0.9 - 0.08 * Double(step % 3), y: 0.95),
                startRadius: 0, endRadius: 460)
        }
        .animation(.easeInOut(duration: 1.2), value: step)
        .ignoresSafeArea()
    }
}
