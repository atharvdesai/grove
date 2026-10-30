import SwiftUI

/// The Grove mark: four bars in a warm squircle, drawn to match `Grove.icns`.
///
/// Redrawn in SwiftUI rather than loading the `.icns` so it can animate and pick
/// up crisp rendering at any size. The proportions are deliberately the same as
/// `scripts/make-icon.swift` — if you change one, change the other, or the app
/// icon and the app stop looking like the same product.
struct GroveLogo: View {
    var size: CGFloat = 96
    /// Bars breathe like a level meter. Used on the welcome screen; off
    /// everywhere else, because a permanently animating logo is a distraction.
    var animated = false

    @ViewState private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let restingHeights: [CGFloat] = [0.30, 0.52, 0.40, 0.20]
    private let activeHeights: [CGFloat] = [0.48, 0.26, 0.56, 0.38]

    var body: some View {
        let radius = size * 0.2237  // Apple's continuous-corner ratio.
        let barWidth = size * 0.088
        let gap = size * 0.072

        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.99, green: 0.93, blue: 0.79),
                        Color(red: 0.91, green: 0.74, blue: 0.40),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay {
                HStack(spacing: gap) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.26, green: 0.17, blue: 0.08))
                            .frame(
                                width: barWidth,
                                height: size * height(at: index))
                    }
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.02)
            .onAppear {
                guard animated, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
            .accessibilityHidden(true)
    }

    private func height(at index: Int) -> CGFloat {
        animating ? activeHeights[index] : restingHeights[index]
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
