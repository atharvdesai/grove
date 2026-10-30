import AppKit
import SwiftUI

extension Color {
    /// The icon's leaf green, used as the app's accent so buttons, toggles and
    /// highlights belong to the same product as the icon in the Dock.
    static let grove = Color(red: 0.12, green: 0.52, blue: 0.36)
}

/// The Grove mark — the app icon itself, so the logo inside the app and the
/// one in the Dock can never drift apart. `scripts/make-icon.py` draws both.
struct GroveLogo: View {
    var size: CGFloat = 96
    /// A slow breathe, like something listening. Used on the welcome screen;
    /// off everywhere else, because a permanently moving logo is a distraction.
    var animated = false

    @ViewState private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .scaleEffect(breathing ? 1.04 : 1)
            .onAppear {
                guard animated, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// Logo plus wordmark, for the welcome screen and the home header.
struct GroveWordmark: View {
    var size: CGFloat = 72
    var animated = false
    var tagline: String? = "Locally sourced meeting notes"

    var body: some View {
        VStack(spacing: 14) {
            GroveLogo(size: size, animated: animated)
            VStack(spacing: 4) {
                Text("Grove")
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                if let tagline {
                    Text(tagline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
