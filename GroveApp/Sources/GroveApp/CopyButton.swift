import AppKit
import SwiftUI

/// Copies text to the clipboard and confirms it did.
///
/// The tick matters more than it looks: copying is silent, and without feedback
/// people click twice and then check the clipboard elsewhere to be sure.
struct CopyButton: View {
    let title: String
    let text: String
    /// A round icon button, with the title as its tooltip.
    var iconOnly = false

    @ViewState private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        } label: {
            if iconOnly {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Label(
                    copied ? "Copied" : title,
                    systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .modifier(CopyButtonChrome(iconOnly: iconOnly, tint: copied ? .grove : nil))
        .animation(Motion.snappy, value: copied)
        .help(copied ? "Copied" : iconOnly ? title : "Copy to the clipboard")
    }
}

private struct CopyButtonChrome: ViewModifier {
    let iconOnly: Bool
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if iconOnly {
            content.buttonStyle(CircleIconStyle(tint: tint, size: 30))
        } else {
            content
        }
    }
}
