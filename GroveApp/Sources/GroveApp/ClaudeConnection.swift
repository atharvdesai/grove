import GroveKit
import SwiftUI

/// Who writes the notes, and whether Claude is connected — in one card.
///
/// Shown in onboarding, behind the sidebar's status chip, and nowhere else
/// needs to re-explain it. Claude runs through the Claude Code app on this Mac
/// on the user's own plan; "connected" means Grove found it and, when asked,
/// got a reply from it.
struct ClaudeConnectionCard: View {
    @Environment(AppSettings.self) private var settings
    @ViewState private var testing = false
    @ViewState private var testResult: TestResult?

    private enum TestResult: Equatable {
        case working
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EngineOption(
                title: "On this Mac",
                detail: "Apple's on-device model. Private and free — nothing leaves your Mac.",
                icon: "lock.laptopcomputer",
                selected: settings.aiEngine == .onDevice
            ) {
                withAnimation(Motion.snappy) { settings.aiEngine = .onDevice }
            }

            EngineOption(
                title: "Claude",
                detail: "Sharper notes from Claude Haiku 5.5, through Claude Code on your own plan. "
                    + "Transcripts go to Anthropic to be written up.",
                icon: "sparkles",
                selected: settings.aiEngine == .claude
            ) {
                withAnimation(Motion.snappy) { settings.aiEngine = .claude }
                settings.recheckClaude()
            }

            if settings.aiEngine == .claude {
                status
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .onAppear { settings.recheckClaude() }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 10) {
            if let path = settings.claudeExecutable {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.callout.weight(.medium))
                    Text(statusDetail(path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(testing ? "Testing…" : "Test Connection") { Task { await test() } }
                    .disabled(testing)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude Code isn't installed").font(.callout.weight(.medium))
                    Text("Install it and sign in, then check again. Until then, notes are written on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Link("Get Claude Code", destination: URL(string: "https://claude.com/product/claude-code")!)
                Button("Check Again") {
                    withAnimation(Motion.snappy) { settings.recheckClaude() }
                }
            }
        }
        .padding(12)
        .surface(cornerRadius: 10)
        .animation(Motion.snappy, value: testResult)
    }

    private var statusColor: Color {
        switch testResult {
        case .failed: return .red
        case .working, .none: return .green
        }
    }

    private var statusTitle: String {
        switch testResult {
        case .working: return "Connected — Claude replied"
        case .failed: return "Claude didn't answer"
        case .none: return "Claude Code found"
        }
    }

    private func statusDetail(_ path: URL) -> String {
        if case .failed(let message) = testResult { return message }
        return ClaudeCodeEngine.version(of: path) ?? path.path
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            _ = try await ClaudeCodeEngine(executable: settings.claudeExecutable)
                .generate(instructions: "Reply with exactly: OK", prompt: "Say OK.")
            testResult = .working
        } catch {
            testResult = .failed(error.localizedDescription)
        }
    }
}

/// A large radio card.
private struct EngineOption: View {
    let title: String
    let detail: String
    let icon: String
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemName: icon, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.grove : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(selected ? Color.grove : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(CardButtonStyle())
    }
}

/// The sidebar's footer chip: which engine is writing, at a glance, and the
/// way into `ClaudeConnectionCard`.
struct EngineStatusChip: View {
    @Environment(AppSettings.self) private var settings
    @ViewState private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.groveWash, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Who writes your notes")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Who writes your notes").font(.headline)
                ClaudeConnectionCard()
            }
            .padding(18)
            .frame(width: 400)
        }
    }

    private var label: String {
        if settings.usesClaude { return "Claude" }
        if settings.aiEngine == .claude { return "Claude · not found" }
        return "On this Mac"
    }

    private var dotColor: Color {
        if settings.usesClaude { return .green }
        if settings.aiEngine == .claude { return .orange }
        return .grove
    }
}
