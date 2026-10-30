import Foundation

/// Sends mail as the signed-in user, through Gmail's API.
///
/// Uses the `gmail.send` scope only: Grove can send, and cannot read, list or
/// delete anything in the mailbox.
public enum Gmail {
    public static func send(_ message: SummaryEmail, accessToken: String) async throws {
        var request = URLRequest(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["raw": PKCE.base64URL(Data(message.mime().utf8))])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw GoogleError.server(
                status == 403
                    ? "Gmail refused to send. Sign out and back in to grant send access."
                    : "Gmail returned HTTP \(status). \(detail.prefix(200))")
        }
    }
}

/// A meeting's notes as an email: plain text and HTML in one message.
public struct SummaryEmail: Sendable, Equatable {
    public var to: [String]
    public var subject: String
    public var markdown: String

    public init(to: [String], subject: String, markdown: String) {
        self.to = to
        self.subject = subject
        self.markdown = markdown
    }

    /// The notes of a finished meeting, ready to send. Nil when the meeting has
    /// nothing worth sending — an email of a bare transcript helps nobody.
    public init?(meeting: Meeting, to recipients: [String]) {
        let notes = (meeting.enhancedNotes ?? meeting.roughNotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty, !recipients.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        var lines = ["*\(formatter.string(from: meeting.startedAt))*"]
        if let attendees = meeting.attendees, !attendees.isEmpty {
            lines.append("With \(attendees.joined(separator: ", "))")
        }
        // The (m:ss) references only mean something inside the app.
        let body = notes.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in TimestampLinker.trailingClock(in: String(line))?.text ?? String(line) }
            .joined(separator: "\n")
        lines += ["", body, "", "—", "Written on-device by Grove."]

        self.init(to: recipients, subject: "Notes: \(meeting.title)", markdown: lines.joined(separator: "\n"))
    }

    /// RFC 2822 with a multipart/alternative body, so mail clients that do not
    /// render HTML still get readable Markdown.
    public func mime(boundary: String = "grove-\(UUID().uuidString)") -> String {
        let encodedSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        let headers = [
            "To: \(to.joined(separator: ", "))",
            "Subject: \(encodedSubject)",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"\(boundary)\"",
        ]
        let parts = [
            part(type: "text/plain", body: markdown, boundary: boundary),
            part(type: "text/html", body: Self.html(from: markdown), boundary: boundary),
        ]
        return (headers + [""] + parts + ["--\(boundary)--", ""]).joined(separator: "\r\n")
    }

    private func part(type: String, body: String, boundary: String) -> String {
        let encoded = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return [
            "--\(boundary)",
            "Content-Type: \(type); charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
            encoded,
        ].joined(separator: "\r\n")
    }

    /// The handful of Markdown the notes use — headings, bullets, emphasis,
    /// paragraphs — as simple HTML. Everything is escaped first.
    public static func html(from markdown: String) -> String {
        var html: [String] = []
        var inList = false
        func closeList() {
            if inList { html.append("</ul>"); inList = false }
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                closeList()
                let level = min(3, max(1, line.prefix(while: { $0 == "#" }).count))
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level + 1)>\(inline(text))</h\(level + 1)>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { html.append("<ul>"); inList = true }
                html.append("<li>\(inline(String(line.dropFirst(2))))</li>")
            } else if line.isEmpty {
                closeList()
            } else {
                closeList()
                html.append("<p>\(inline(line))</p>")
            }
        }
        closeList()
        return """
            <div style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1d1d1f">
            \(html.joined(separator: "\n"))
            </div>
            """
    }

    private static func inline(_ text: String) -> String {
        var escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        escaped = escaped.replacingOccurrences(
            of: #"\*(.+?)\*"#, with: "<em>$1</em>", options: .regularExpression)
        return escaped
    }
}
