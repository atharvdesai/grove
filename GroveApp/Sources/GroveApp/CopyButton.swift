import AppKit
import SwiftUI

/// Copies text to the clipboard and confirms it did.
///
/// The tick matters more than it looks: copying is silent, and without feedback
/// people click twice and then check the clipboard elsewhere to be sure.
struct CopyButton: View {
    let title: String
    let text: String

    @State private var copied = false

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
            Label(
                copied ? "Copied" : title,
                systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .animation(.easeInOut(duration: 0.15), value: copied)
        .help("Copy to the clipboard")
    }
}
