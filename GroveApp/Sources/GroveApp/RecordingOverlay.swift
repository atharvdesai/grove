import AppKit
import GroveKit
import SwiftUI

/// The floating pill shown while a meeting is recording.
///
/// Deliberately tiny and free of anything that is not a control: it sits over
/// whatever you are actually doing, so every pixel is rent.
struct RecordingOverlayView: View {
    @Environment(MeetingSession.self) private var session
    let stop: () async -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Says who is recording. Floating over another app with no window
            // chrome, the pill is otherwise an anonymous timer, and a stranger
            // seeing it on your screen has no idea what is listening.
            GroveLogo(size: 18)
                .accessibilityLabel("Grove")

            PulsingDot(paused: session.isPaused)

            Text(session.elapsed.clockString)
                .font(.system(.callout, design: .rounded).monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)

            if session.isOffRecord {
                Text("OFF THE RECORD")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .help("Nothing said now is kept. Press ⌃⌥O to go back on the record.")
            }

            Divider().frame(height: 16)

            Button {
                session.toggleOffRecord()
            } label: {
                Image(systemName: session.isOffRecord ? "eye.slash.fill" : "eye.slash")
                    .foregroundStyle(session.isOffRecord ? Color.orange : Color.primary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(session.isOffRecord ? "Back on the record (⌃⌥O)" : "Off the record (⌃⌥O)")

            Button {
                NotificationCenter.default.post(name: .toggleQuickNotes, object: nil)
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Quick notes (\(QuickNotesShortcut.label))")

            Button {
                session.togglePause()
            } label: {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(session.isPaused ? "Resume" : "Pause")

            Button {
                Task { await stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Stop and write up the meeting")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        // The whole pill is the drag handle, so there is no grab area to hunt
        // for; the buttons still take their own clicks.
        .contentShape(Capsule())
    }
}

private struct PulsingDot: View {
    let paused: Bool
    @ViewState private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(paused ? Color.orange : Color.red)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .onAppear { start() }
            .onChange(of: paused) { _, _ in start() }
    }

    private func start() {
        dim = false
        guard !paused, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// Hosting view that acts on the very first click.
///
/// Without this the overlay looks like it works and does nothing: Grove is not
/// the active app while you are in a meeting, so a click on the panel is a
/// "first mouse" event, and AppKit swallows it by default. You press Pause,
/// focus correctly stays where it is, and the recording keeps running.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A borderless panel that floats over every app and Space without taking
/// focus. Shared by the recording pill and the meeting-detected prompt.
@MainActor
func makeFloatingPanel(hosting: NSView) -> NSPanel {
    let panel = NSPanel(
        contentRect: .zero,
        // Non-activating is the important flag: clicking Pause must not pull
        // focus out of the meeting app you are typing in.
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false)
    panel.contentView = hosting
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .utilityWindow
    // Follows you between Spaces and sits over full-screen apps, which is
    // where meetings usually are.
    panel.collectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
    ]
    return panel
}

/// Owns the floating panel and keeps it in step with the session.
///
/// A `Window` scene cannot do this: it would sit inside the app's own layer,
/// disappear behind Zoom, and steal focus when clicked. An `NSPanel` that is
/// non-activating, flgrove above normal windows, and joins every Space is the
/// only way for a control to stay reachable while you are working in another
/// app — which is the whole point of it.
@MainActor
final class RecordingOverlayController {
    private var panel: NSPanel?
    private let session: MeetingSession
    private let settings: AppSettings
    private let stop: () async -> Void

    private static let originKey = "overlayOrigin"

    init(session: MeetingSession, settings: AppSettings, stop: @escaping () async -> Void) {
        self.session = session
        self.settings = settings
        self.stop = stop
        observe()
    }

    /// Re-arms after every change, because `withObservationTracking` fires once.
    ///
    /// Observed here rather than from a SwiftUI view on purpose: the overlay has
    /// to keep working when the main window is closed, and a view that is not on
    /// screen is not running.
    private func observe() {
        withObservationTracking {
            _ = session.phase
            _ = settings.showRecordingOverlay
        } onChange: { [weak self] in
            // onChange fires *before* the new value is readable, so sync on the
            // next turn of the loop.
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
        sync()
    }

    private func sync() {
        let wanted = session.isRecording && settings.showRecordingOverlay
        wanted ? show() : hide()
    }

    private func show() {
        if panel != nil { return }

        let content = RecordingOverlayView(stop: stop)
            .environment(session)

        let hosting = FirstMouseHostingView(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]

        let panel = makeFloatingPanel(hosting: hosting)
        // fittingSize is zero until the hosting view has laid out, and a
        // zero-sized panel is indistinguishable from one that never appeared.
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 40 || size.height < 20 {
            size = Self.provisionalSize
        }
        panel.setContentSize(size)
        panel.setFrameOrigin(savedOrigin(for: panel))

        panel.orderFrontRegardless()
        self.panel = panel

        // Correct the guess once SwiftUI has actually measured itself, so the
        // pill fits its contents rather than a hardcoded width that silently
        // clips whenever something is added to it.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, let hosting = panel.contentView else { return }
            hosting.layoutSubtreeIfNeeded()
            let measured = hosting.fittingSize
            guard measured.width > 40, measured.height > 20,
                measured != panel.frame.size
            else { return }
            // Anchor the top-left so the pill grows rightwards and does not
            // appear to jump when it resizes.
            let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setContentSize(measured)
            panel.setFrameTopLeftPoint(topLeft)
        }
    }

    /// Used only until the real measurement lands, a frame later.
    private static let provisionalSize = NSSize(width: 248, height: 42)

    private func hide() {
        guard let panel else { return }
        rememberOrigin(panel.frame.origin)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }

    // MARK: - Position

    private func savedOrigin(for panel: NSPanel) -> NSPoint {
        if let stored = UserDefaults.standard.string(forKey: Self.originKey) {
            let point = NSPointFromString(stored)
            // Only reuse it if that spot still exists — an external display may
            // have been unplugged since, and a panel off-screen is a panel the
            // user cannot find.
            if NSScreen.screens.contains(where: { $0.frame.contains(point) }) {
                return point
            }
        }
        // Default: top centre, below the menu bar. Out of the way of window
        // controls on the left and the status bar items on the right.
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(
            x: screen.midX - panel.frame.width / 2,
            y: screen.maxY - panel.frame.height - 12)
    }

    private func rememberOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.originKey)
    }
}
