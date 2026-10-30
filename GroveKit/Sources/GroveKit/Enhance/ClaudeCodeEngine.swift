import Foundation

/// Writes with Claude through the Claude Code app already installed and signed
/// in on this Mac, so the work comes out of the user's own Claude plan.
///
/// Grove never holds a Claude credential: it runs the official `claude`
/// command in print mode, the way Anthropic documents scripting it, and reads
/// the answer back. Always Claude Haiku 5.5 — the fastest, lightest model,
/// which is plenty for meeting notes and uses the least of the plan.
///
/// This is the one engine that sends a transcript off the Mac (to Anthropic,
/// by way of Claude Code). It is only ever used when the user picks it.
public struct ClaudeCodeEngine: NoteWritingModel {
    public static let model = "claude-haiku-5-5"

    public let name = "Claude Haiku 5.5 (via Claude Code)"
    /// Haiku reads a whole meeting at once, so long meetings skip the
    /// condensing pass the on-device model needs.
    public let singlePassWordLimit = 60_000
    public let chunkWordLimit = 40_000

    let executable: URL?
    let timeout: TimeInterval

    public init(executable: URL? = ClaudeCodeEngine.located, timeout: TimeInterval = 240) {
        self.executable = executable
        self.timeout = timeout
    }

    public var availability: ModelAvailability {
        executable == nil
            ? .unavailable("Claude Code isn't installed. Install it from claude.com/code and sign in.")
            : .available
    }

    public func generate(instructions: String, prompt: String) async throws -> String {
        guard let executable else {
            throw CaptureError.message("Claude Code isn't installed on this Mac.")
        }
        // Tools off and a throwaway working folder: Claude only ever reads the
        // text it is given and writes an answer — it can't touch any files.
        let arguments = [
            "-p", "--model", Self.model, "--output-format", "text",
            "--system-prompt", instructions, "--tools", "",
        ]
        do {
            return try await run(executable, arguments, input: prompt)
        } catch let error as ClaudeCodeError where error.isUnknownOption {
            // Older Claude Code builds lack `--tools`; a working folder with
            // nothing in it is still enough to keep the run read-only.
            return try await run(executable, Array(arguments.dropLast(2)), input: prompt)
        }
    }

    // MARK: - Finding Claude Code

    /// Looked up once per launch: the fallback asks a login shell, which is
    /// too slow to repeat for every note. Settings re-checks with `locate()`.
    public static let located: URL? = locate()

    /// Apps don't inherit the shell's PATH, so look where the installers put
    /// it, then ask a login shell as a last resort.
    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return shell.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path)
            ? URL(fileURLWithPath: path) : nil
    }

    /// `claude --version`, for Settings.
    public static func version(of executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Running it

    private func run(_ executable: URL, _ arguments: [String], input: String) async throws -> String {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Read both pipes concurrently: a long answer fills the pipe buffer,
        // and a process blocked on a full pipe never exits.
        let collector = PipeCollector(stdout: stdout, stderr: stderr)
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw ClaudeCodeError(message: "Claude took longer than \(Int(timeout)) seconds.")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let (out, err) = collector.finish()
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            throw ClaudeCodeError(message: Self.explain(err.isEmpty ? out : err))
        }
        return text
    }

    /// Claude Code's own error text, made actionable.
    static func explain(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("unknown option") || lower.contains("unknown argument") {
            return "unknown option: " + stderr.prefix(200)
        }
        if lower.contains("login") || lower.contains("not logged in") || lower.contains("authenticate") {
            return "Claude Code isn't signed in. Open Terminal, run `claude`, and sign in."
        }
        if lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("limit reached") {
            return "Your Claude plan's usage limit was reached. Grove used the on-device model instead."
        }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
        return detail.isEmpty ? "Claude Code didn't return an answer." : "Claude Code: \(detail)"
    }
}

struct ClaudeCodeError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
    var isUnknownOption: Bool { message.hasPrefix("unknown option") }
}

/// Drains a process's stdout and stderr on background threads.
private final class PipeCollector: @unchecked Sendable {
    private var out = Data()
    private var err = Data()
    private let group = DispatchGroup()
    private let lock = NSLock()

    init(stdout: Pipe, stderr: Pipe) {
        drain(stdout.fileHandleForReading) { self.out.append($0) }
        drain(stderr.fileHandleForReading) { self.err.append($0) }
    }

    private func drain(_ handle: FileHandle, into append: @escaping (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = handle.readDataToEndOfFile()
            self.lock.lock()
            append(data)
            self.lock.unlock()
            self.group.leave()
        }
    }

    func finish() -> (String, String) {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
