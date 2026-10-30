import AppKit
import SwiftUI

// The shared look and feel: motion, surfaces, button styles, and the plumbing
// that lets every sheet close reliably. Views reach for these instead of
// re-deriving paddings, radii and springs locally, which is how a dozen
// screens drift into a dozen slightly different apps.

// MARK: - Palette

extension Color {
    /// Builds a colour that follows the window's light or dark appearance.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
    }

    /// The window itself, behind the sidebar and around the content card: a
    /// warm, faintly green neutral rather than system grey, so the app reads
    /// as its own place — the way Arc tints its frame and Claude warms its page.
    static let groveCanvas = adaptive(
        light: NSColor(srgbRed: 0.925, green: 0.933, blue: 0.906, alpha: 1),
        dark: NSColor(srgbRed: 0.098, green: 0.106, blue: 0.098, alpha: 1))

    /// The content card: warm paper in light mode, soft charcoal in dark.
    static let groveCard = adaptive(
        light: NSColor(srgbRed: 0.992, green: 0.990, blue: 0.979, alpha: 1),
        dark: NSColor(srgbRed: 0.149, green: 0.157, blue: 0.149, alpha: 1))

    /// Sidebar selection and hover wash.
    static let groveWash = adaptive(
        light: NSColor(white: 0, alpha: 0.06),
        dark: NSColor(white: 1, alpha: 0.08))
}

extension Font {
    /// Page titles and greetings. A serif for the moments that should feel
    /// written rather than computed — Claude and Notion do the same.
    static func display(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .medium, design: .serif)
    }
}

/// A page's heading inside the content card: serif title, a line of context,
/// and room for controls on the right.
struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.display(26))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Motion

/// The app's springs. Springs rather than ease curves because they can be
/// interrupted mid-flight without a visible jolt — a hover that ends halfway
/// through its animation reverses smoothly instead of snapping.
enum Motion {
    /// State changes the user caused: tab switches, panels opening.
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Larger moves: whole screens crossfading, drawers sliding.
    static let gentle = Animation.spring(response: 0.48, dampingFraction: 0.9)
    /// Hover feedback — fast enough to feel attached to the pointer.
    static let hover = Animation.easeOut(duration: 0.14)
    /// Button press-down.
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)

    /// `animation`, or none when the user asked for reduced motion.
    static func respecting(_ reduceMotion: Bool, _ animation: Animation = snappy) -> Animation? {
        reduceMotion ? nil : animation
    }
}

enum Metrics {
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    /// Reading width for notes and transcripts. Past ~72 characters a line
    /// stops being read and starts being scanned.
    static let readingWidth: CGFloat = 720
}

// MARK: - Closing sheets

/// Closes the sheet it was handed to, then optionally runs `then` once the
/// sheet has actually finished going away.
///
/// SwiftUI's own `dismiss()` was the source of "Done does nothing": it is a
/// request against whatever presentation SwiftUI believes is current, and it
/// silently no-ops when a sheet was presented while another was still
/// animating out, or when a sheet tries to close its parent while a child
/// sheet is up. Clearing the presenter's own binding has no such failure mode,
/// and running follow-ups from `onDismiss` means "close this, then open that"
/// never overlaps two presentations.
struct CloseSheetAction {
    let perform: (_ then: (() -> Void)?) -> Void

    init(_ perform: @escaping (_ then: (() -> Void)?) -> Void) {
        self.perform = perform
    }

    func callAsFunction(then: (() -> Void)? = nil) {
        perform(then)
    }
}

private struct CloseSheetKey: EnvironmentKey {
    static let defaultValue: CloseSheetAction? = nil
}

extension EnvironmentValues {
    /// Set by `managedSheet` and by `RootView`'s sheet slot. Read it through
    /// `@CloseSheet` rather than directly.
    var closeSheet: CloseSheetAction? {
        get { self[CloseSheetKey.self] }
        set { self[CloseSheetKey.self] = newValue }
    }
}

/// `@CloseSheet private var close` — then `close()`, or `close { … }` to act
/// once the sheet is gone. Falls back to `dismiss()` for a sheet presented
/// some other way, so it is always safe to use.
@propertyWrapper
struct CloseSheet: DynamicProperty {
    @Environment(\.closeSheet) private var managed
    @Environment(\.dismiss) private var dismiss

    init() {}

    var wrappedValue: CloseSheetAction {
        if let managed { return managed }
        let dismiss = dismiss
        return CloseSheetAction { then in
            dismiss()
            if let then {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: then)
            }
        }
    }
}

extension View {
    /// `.sheet(item:)` whose content can close itself with `@CloseSheet`.
    ///
    /// Every sheet in the app goes through this or `RootView`'s slot. A plain
    /// `.sheet` nested inside a managed one would inherit the parent's close
    /// action from the environment, and its Done would close the wrong sheet.
    func managedSheet<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        modifier(ManagedItemSheet(item: item, sheet: content))
    }

    /// `.sheet(isPresented:)` whose content can close itself with `@CloseSheet`.
    func managedSheet<Sheet: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        modifier(
            ManagedItemSheet(
                item: Binding(
                    get: { isPresented.wrappedValue ? PresentedFlag() : nil },
                    set: { isPresented.wrappedValue = $0 != nil }),
                sheet: { _ in content() }))
    }
}

/// The single identity an `isPresented` sheet needs.
private struct PresentedFlag: Identifiable {
    var id: Int { 0 }
}

private struct ManagedItemSheet<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let sheet: (Item) -> Sheet
    @ViewState private var afterDismiss: (() -> Void)?

    init(item: Binding<Item?>, sheet: @escaping (Item) -> Sheet) {
        _item = item
        self.sheet = sheet
    }

    func body(content: Content) -> some View {
        content.sheet(item: $item, onDismiss: runAfterDismiss) { value in
            sheet(value)
                .environment(
                    \.closeSheet,
                    CloseSheetAction { then in
                        afterDismiss = then
                        item = nil
                    })
        }
    }

    private func runAfterDismiss() {
        guard let next = afterDismiss else { return }
        afterDismiss = nil
        DispatchQueue.main.async(execute: next)
    }
}

// MARK: - Sheet chrome

/// The top of every sheet: an icon, a title, optional controls, and Done.
///
/// Done is bound to Escape rather than Return. Return belongs to whatever the
/// sheet is for — asking a question, sending an email — and a Done that
/// grabbed it would close the sheet out from under someone mid-sentence.
struct SheetHeader<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let icon: String?
    let accessory: Accessory

    @CloseSheet private var close

    init(
        _ title: String, subtitle: String? = nil, icon: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                IconTile(systemName: icon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            accessory
            Button("Done") { close() }
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, icon: String? = nil) {
        self.init(title, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}

/// A symbol on a soft tinted square — the app's icon treatment for headers
/// and cards.
struct IconTile: View {
    let systemName: String
    var size: CGFloat = 30
    var tint: Color = .grove

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.13),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Small caps section heading.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }
}

/// A row of capsule tabs with a sliding selection — the page-level
/// alternative to a segmented control, which reads as a settings panel.
struct PillTabs<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    @Namespace private var namespace

    init(selection: Binding<Option>, options: [Option], label: @escaping (Option) -> String) {
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(Motion.snappy) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.groveWash)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Surfaces

extension View {
    /// A quiet raised surface: a faint fill and a hairline edge. Reads in both
    /// light and dark mode, where a flat grey fill disappears in one of them.
    func surface(cornerRadius: CGFloat = Metrics.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// A floating control surface: material, hairline, and a soft shadow.
    func floatingSurface<S: Shape>(_ shape: S) -> some View {
        background(.regularMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }
}

// MARK: - Button styles

/// A card that responds: lifts its fill on hover, sinks a little on press.
struct CardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Metrics.cardRadius

    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }
}

private struct CardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    @ViewState private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .background(shape.fill(Color.primary.opacity(hovering ? 0.075 : 0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.08), lineWidth: 0.5))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 && isEnabled }
            .animation(Motion.hover, value: hovering)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A list row: no chrome at rest, a soft highlight under the pointer.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.055 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
    }
}

/// The one loud button on a screen: a solid green capsule.
struct ProminentCapsuleStyle: ButtonStyle {
    var tint: Color = .grove

    func makeBody(configuration: Configuration) -> some View {
        ProminentCapsuleBody(configuration: configuration, tint: tint)
    }
}

private struct ProminentCapsuleBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @ViewState private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [tint.opacity(hovering ? 1 : 0.94), tint.opacity(hovering ? 0.88 : 0.8)],
                        startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: tint.opacity(hovering ? 0.35 : 0.2), radius: hovering ? 8 : 4, y: 2)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 && isEnabled }
            .animation(Motion.hover, value: hovering)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A round icon button for floating bars.
struct CircleIconStyle: ButtonStyle {
    var tint: Color? = nil
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        CircleIconBody(configuration: configuration, tint: tint, size: size)
    }
}

private struct CircleIconBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    let size: CGFloat
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .modifier(OptionalForeground(color: tint))
            .frame(width: size, height: size)
            .background(
                Circle().fill((tint ?? .primary).opacity(configuration.isPressed ? 0.2 : hovering ? 0.12 : 0)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Applies a foreground colour only when there is one, so an untinted
/// control inherits whatever style its parent set.
private struct OptionalForeground: ViewModifier {
    let color: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let color {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}

// MARK: - Live activity

/// Bars that move while Grove is listening.
///
/// Not a level meter — the capture pipeline does not expose levels to the app
/// — so it does not pretend to be one. The bars idle low while recording and
/// swell each time new speech is transcribed (`activity` changes), so they
/// still tell the truth about the one thing that matters: words are arriving.
/// Paused or stopped, they lie flat.
struct ListeningBars: View {
    var active: Bool
    /// Anything that changes when new speech lands — the segment count works.
    var activity: Int = 0
    var color: Color = .red
    var barCount = 4
    var height: CGFloat = 14

    @ViewState private var lastActivity = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let speeds: [Double] = [2.1, 2.9, 2.4, 3.3, 2.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let sinceSpeech = context.date.timeIntervalSince(lastActivity)
            let energy = 0.3 + 0.7 * exp(-max(sinceSpeech, 0) / 1.4)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: barHeight(index, time: time, energy: energy))
                }
            }
            .frame(height: height)
        }
        .onChange(of: activity) { _, _ in lastActivity = Date() }
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int, time: TimeInterval, energy: Double) -> CGFloat {
        let floor: CGFloat = 3
        guard active, !reduceMotion else { return floor }
        let speed = Self.speeds[index % Self.speeds.count]
        let phase = Double(index) * 1.3
        // Two incommensurate waves, so the pattern never visibly repeats.
        let wave = (sin(time * speed + phase) + sin(time * speed * 0.53 + phase * 2)) / 4 + 0.5
        return floor + CGFloat(wave * energy) * (height - floor)
    }
}

// MARK: - Dates

enum DayLabel {
    /// "Today", "Yesterday", a weekday within the week, else a date.
    static func label(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide).day())
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }
}
