import AppKit
import GroveKit
import Observation
import SwiftUI

/// Notices calls starting and ending, and offers — or starts — a recording.
///
/// Polls rather than registering Core Audio listeners: two seconds is quick
/// enough to catch the start of a call, the check is a handful of property
/// reads, and a poll cannot silently stop firing the way a dropped listener can.
@MainActor
@Observable
final class MeetingWatcher {
    /// A call that is on and waiting for an answer; drives the prompt.
    private(set) var pendingApp: MeetingApp? {
        didSet {
            guard pendingApp != oldValue else { return }
            pendingEvent = pendingApp != nil ? session.calendarLookup?() : nil
        }
    }
    /// The calendar event the pending call is probably for, to name it in the
    /// prompt: "Acme sync" says more than "Zoom call detected".
    private(set) var pendingEvent: CalendarEvent?

    private let session: MeetingSession
    private let settings: AppSettings
    private let stop: () async -> Void
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var prompt: MeetingPromptController?

    /// Apps holding the mic on the previous poll. A call has to be seen twice
    /// before it counts, so a two-second mic check in Slack prompts nobody.
    private var lastSeen: Set<String> = []
    /// Calls already dealt with — declined, or recorded — until the app lets go
    /// of the mic. Without this, stopping a recording mid-call would offer to
    /// start a new one two seconds later.
    private var handled: Set<String> = []
    /// The app whose call detection started recording, and so may also end.
    private var recordingFor: String?
    private var releasedAt: Date?

    private static let interval: Duration = .seconds(2)
    /// How long a call app must have let go of the mic before the meeting
    /// counts as over. Long enough to ride out a device switch mid-call.
    private static let endGrace: TimeInterval = 10

    init(session: MeetingSession, settings: AppSettings, stop: @escaping () async -> Void) {
        self.session = session
        self.settings = settings
        self.stop = stop
        prompt = MeetingPromptController(watcher: self)
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// From the prompt's "Take notes".
    func accept() {
        guard let app = pendingApp else { return }
        Task { await begin(app) }
    }

    /// From the prompt's close button: not this call.
    func decline() {
        guard let app = pendingApp else { return }
        handled.insert(app.name)
        pendingApp = nil
    }

    private func tick() async {
        guard settings.hasCompletedOnboarding, settings.meetingDetection != .off else {
            pendingApp = nil
            lastSeen = []
            recordingFor = nil
            return
        }

        let active = await Task.detached { MeetingDetector.activeMeetingApps() }.value
        let names = Set(active.map(\.name))
        handled.formIntersection(names)

        if let app = recordingFor { await followCallEnd(of: app, active: names) }

        let confirmed = active.filter { lastSeen.contains($0.name) && !handled.contains($0.name) }
        lastSeen = names

        if session.isBusy {
            // Whatever call is on is being recorded, however that started.
            handled.formUnion(names)
            pendingApp = nil
            return
        }

        guard let app = confirmed.first else {
            pendingApp = nil
            return
        }
        // A browser on the mic might be a voice memo, so it always asks.
        if settings.meetingDetection == .automatic, !app.isBrowser {
            await begin(app)
        } else {
            pendingApp = app
        }
    }

    private func followCallEnd(of app: String, active: Set<String>) async {
        // "Take notes" starts recording outside the poll, so a tick can land
        // while the models are still loading.
        if session.phase == .starting { return }
        guard session.isRecording else {
            // Stopped by hand; nothing left to end.
            recordingFor = nil
            releasedAt = nil
            return
        }
        if active.contains(app) {
            releasedAt = nil
        } else if let releasedAt, Date().timeIntervalSince(releasedAt) >= Self.endGrace {
            recordingFor = nil
            self.releasedAt = nil
            await stop()
        } else if releasedAt == nil {
            releasedAt = Date()
        }
    }

    private func begin(_ app: MeetingApp) async {
        guard !session.isBusy else { return }
        pendingApp = nil
        handled.insert(app.name)
        recordingFor = app.name
        await session.start(detectedApp: app.name)
        if !session.isRecording { recordingFor = nil }
    }
}

// MARK: - Prompt

/// "Zoom call detected — Take notes?", floating over the call.
struct MeetingPromptView: View {
    let app: MeetingApp
    var event: CalendarEvent?
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GroveLogo(size: 18)
                .accessibilityLabel("Grove")

            VStack(alignment: .leading, spacing: 1) {
                if let event, !event.title.isEmpty {
                    Text(event.title)
                        .font(.callout.weight(.medium))
                    Text(app.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(app.isBrowser ? "\(app.name) is using the mic" : "\(app.name) call detected")
                        .font(.callout.weight(.medium))
                }
            }
            .lineLimit(1)

            Button("Take notes", action: accept)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button(action: decline) {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Not this call")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

/// Shows the prompt while a call is waiting for an answer.
///
/// A panel rather than a notification: it needs no notification permission,
/// and it stays put for as long as the call is on instead of sliding away
/// while you are still saying hello.
@MainActor
final class MeetingPromptController {
    private weak var watcher: MeetingWatcher?
    private var panel: NSPanel?
    private var shownFor: MeetingApp?

    init(watcher: MeetingWatcher) {
        self.watcher = watcher
        observe()
    }

    private func observe() {
        guard let watcher else { return }
        withObservationTracking {
            _ = watcher.pendingApp
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
        sync()
    }

    private func sync() {
        let wanted = watcher?.pendingApp
        guard wanted != shownFor else { return }
        hide()
        if let wanted { show(wanted) }
    }

    private func show(_ app: MeetingApp) {
        guard let watcher else { return }
        let hosting = FirstMouseHostingView(
            rootView: MeetingPromptView(
                app: app, event: watcher.pendingEvent,
                accept: { watcher.accept() }, decline: { watcher.decline() }))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.layoutSubtreeIfNeeded()

        let panel = makeFloatingPanel(hosting: hosting)
        var size = hosting.fittingSize
        if size.width < 40 || size.height < 20 { size = NSSize(width: 320, height: 42) }
        panel.setContentSize(size)

        // Top right, under the menu bar — where macOS puts notifications, and
        // clear of the recording pill's top-centre spot.
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(
            NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12))
        panel.orderFrontRegardless()
        self.panel = panel
        shownFor = app
    }

    private func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        shownFor = nil
    }
}
