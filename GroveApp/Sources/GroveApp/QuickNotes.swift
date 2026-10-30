import AppKit
import Carbon.HIToolbox
import GroveKit
import SwiftUI

/// A system-wide keyboard shortcut, through Carbon's hot key API.
///
/// Carbon rather than an `NSEvent` monitor because a global monitor needs
/// Accessibility permission just to see key presses — a lot to ask for one
/// shortcut — while a registered hot key needs nothing.
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void
    /// Tells this shortcut's presses apart from Grove's other shortcuts: every
    /// handler sees every hot key, so each checks the ID and passes on the rest.
    private let identifier: UInt32

    init(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        self.identifier = id
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                guard pressed.id == hotKey.identifier else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in hotKey.action() }
                return noErr
            }, 1, &spec, context, &handler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4752_5645), id: id)  // "GRVE"
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// ⌃⌥N: the quick-notes shortcut, shown wherever it is mentioned.
enum QuickNotesShortcut {
    static let keyCode = kVK_ANSI_N
    static let modifiers = controlKey | optionKey
    static let label = "⌃⌥N"
}

/// A panel that can take typing without making Grove the active app, so the
/// call stays frontmost while you jot something down.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The small notepad summoned with ⌃⌥N.
///
/// Most of what you type in a meeting Grove already hears. What it can't hear
/// is what *you* want to remember, so this is a scratchpad for exactly that —
/// out of the way until called, gone again with Esc or the same shortcut.
/// Whatever is typed goes into the meeting's rough notes, which steer the
/// write-up.
@MainActor
final class QuickNotesController {
    private var panel: NSPanel?
    private let session: MeetingSession
    private var hotKey: GlobalHotKey?
    /// ⌃⌥O, off the record. Lives here with the other global shortcut.
    private var offRecordKey: GlobalHotKey?
    private var observer: NSObjectProtocol?

    init(session: MeetingSession) {
        self.session = session
        hotKey = GlobalHotKey(
            id: 1, keyCode: QuickNotesShortcut.keyCode, modifiers: QuickNotesShortcut.modifiers
        ) { [weak self] in self?.toggle() }
        offRecordKey = GlobalHotKey(
            id: 2, keyCode: kVK_ANSI_O, modifiers: controlKey | optionKey
        ) { [session] in session.toggleOffRecord() }
        // The recording pill and the menu bar ask for the notepad this way, so
        // neither has to hold a reference to it.
        observer = NotificationCenter.default.addObserver(
            forName: .toggleQuickNotes, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let content = QuickNotesView(close: { [weak self] in self?.hide() })
            .environment(session)
        let hosting = NSHostingView(rootView: content)

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        _ = panel.setFrameAutosaveName("GroveQuickNotes")
        if panel.frame.origin == .zero, let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 400, y: screen.minY + 40))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct QuickNotesView: View {
    @Environment(MeetingSession.self) private var session
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var session = session

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.isCapturing ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !session.isBusy {
                    Button("Start recording") { Task { await session.start() } }
                        .controlSize(.small)
                }
                Text(QuickNotesShortcut.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .help("Press \(QuickNotesShortcut.label) or Esc to hide")
            }
            .padding(.top, 6)

            TextEditor(text: $session.roughNotes)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .overlay(alignment: .topLeading) {
                    if session.roughNotes.isEmpty {
                        Text("Something to remember…")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 18)
        .background(.regularMaterial)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }

    private var status: String {
        switch session.phase {
        case .recording:
            return "Recording · \(session.elapsed.clockString) — notes steer the write-up"
        case .paused: return "Paused · \(session.elapsed.clockString)"
        case .idle: return "Not recording — notes go into your next meeting"
        default: return session.statusText
        }
    }
}
