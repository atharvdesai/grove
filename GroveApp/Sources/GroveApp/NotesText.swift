import GroveKit
import SwiftUI

/// Renders the subset of Markdown the enhancement pass actually emits:
/// `###` headings, `-`/`*` bullets, and paragraphs, with inline emphasis.
///
/// SwiftUI's `Text(.init(markdown:))` handles inline styling but flattens block
/// structure — every heading and bullet collapses into one run-on paragraph,
/// which destroys exactly the structure Grove promises to preserve. Rather than
/// take a Markdown dependency for four constructs, this walks the lines. If the
/// templates ever emit tables or nested lists, revisit that trade.
struct NotesText: View {
    let markdown: String
    /// Called with the timestamp when the reader clicks a line's trailing
    /// `(m:ss)` reference. nil renders references as plain text.
    var onSeek: ((TimeInterval) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 8)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        linkedLine(text)
                    }
                case .paragraph(let text):
                    linkedLine(text)
                }
            }
        }
        .font(.system(size: 14))
        .textSelection(.enabled)
        .frame(maxWidth: 720, alignment: .leading)
    }

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        markdown.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }

            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let text = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                return .heading(level: hashes, text: text)
            }
            for marker in ["- ", "* "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)))
            }
            return .paragraph(line)
        }
    }

    /// A note line, with its trailing `(m:ss)` reference — when it has one —
    /// rendered as a button that jumps into the transcript. The clock text
    /// stays in the Markdown either way, so export and copy are unchanged.
    @ViewBuilder
    private func linkedLine(_ text: String) -> some View {
        if let onSeek, let (body, time) = TimestampLinker.trailingClock(in: text) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(inline(body)).fixedSize(horizontal: false, vertical: true)
                Button(TimestampLinker.clockString(time)) { onSeek(time) }
                    .buttonStyle(.plain)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .help("Jump to this moment in the transcript")
            }
        } else {
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
