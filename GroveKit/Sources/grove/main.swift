import AVFoundation
import Foundation
import GroveKit

// The Grove command line. The SwiftUI app is the product, but a CLI that runs the
// same GroveKit engine keeps the pipeline testable without a GUI in the loop and
// makes the whole thing scriptable.

struct Arguments {
    var command: String = "help"
    var title: String?
    var template: String = "general"
    var notesPath: String?
    var minutes: Double?
    var locale: String = "en-US"
    var directory: String?
    var positional: [String] = []

    init(_ raw: [String]) {
        var rest = Array(raw.dropFirst())
        if let first = rest.first, !first.hasPrefix("--") {
            command = first
            rest.removeFirst()
        }
        // `grove --version` has no subcommand, so it would otherwise fall through
        // to the usage banner.
        if rest.contains("--version") || rest.contains("-v") { command = "version" }

        var index = 0
        while index < rest.count {
            let flag = rest[index]
            let value = index + 1 < rest.count ? rest[index + 1] : nil
            switch flag {
            case "--title": title = value; index += 1
            case "--template": template = value ?? "general"; index += 1
            case "--notes": notesPath = value; index += 1
            case "--minutes": minutes = value.flatMap(Double.init); index += 1
            case "--locale": locale = value ?? "en-US"; index += 1
            case "--dir": directory = value; index += 1
            default:
                if !flag.hasPrefix("--") { positional.append(flag) }
            }
            index += 1
        }
    }
}

/// Read from the Info.plist embedded in this executable, so the CLI, the app,
/// and the release tag all trace back to one `VERSION` file.
let groveVersion: String = {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}()

func printUsage() {
    print(
        """
        grove — local-first meeting notes. Nothing leaves your Mac.

        USAGE
          grove record [--title T] [--template ID] [--notes FILE] [--minutes N] [--locale L]
          grove list [--dir PATH]
          grove ask QUESTION... [--dir PATH]
          grove templates
          grove doctor
          grove debug-audio

        RECORD
          Captures system audio and your microphone, transcribes both live on-device,
          then merges your rough notes with the transcript into polished notes.
          Press Return to stop, or pass --minutes to stop automatically.

          --notes FILE   Your rough notes. Keep this file open in another window and
                         jot into it during the meeting; Grove reads it when you stop.

        TEMPLATES
          \(NoteTemplate.builtIns.map(\.id).joined(separator: ", "))

        ASK
          Answers a question from your past meetings, on-device. Every claim is
          tied to a transcript excerpt, and the excerpts used are printed as
          sources. When nothing in your meetings covers the question, Grove
          says so instead of composing an answer.

        DEBUG-AUDIO
          Measures mic level and tap callbacks in every capture configuration.
          Use it when a recording comes back empty: every failure mode in this
          pipeline returns success, so only levels and callback counts tell you.
        """)
}

@available(macOS 26.0, *)
func runDoctor() async {
    print("grove doctor")
    print(String(repeating: "─", count: 46))

    let micGranted = MicrophoneCapture.hasAccess
    print("microphone permission   \(micGranted ? "granted" : "not yet granted")")

    do {
        let locale = try await SpeechChannel.supportedLocale()
        print("on-device speech        available (\(locale.identifier))")
    } catch {
        print("on-device speech        UNAVAILABLE — \(error)")
    }

    let enhancer = NoteEnhancer()
    switch enhancer.availability {
    case .available:
        print("on-device language model available (\(enhancer.model.name))")
    case .unavailable(let reason):
        print("on-device language model UNAVAILABLE — \(reason)")
    }

    let tap = SystemAudioTap()
    do {
        try tap.prepare()
        print("system audio tap        ready (\(tap.outputDeviceName))")
        tap.stop()
    } catch {
        print("system audio tap        FAILED — \(error)")
    }

    print(String(repeating: "─", count: 46))
    print("notes are stored in     \(MeetingStore().baseDirectory.path)")
}

@available(macOS 26.0, *)
func runRecord(_ arguments: Arguments) async throws {
    let store = MeetingStore(
        baseDirectory: arguments.directory.map { URL(fileURLWithPath: $0) })
    let title = arguments.title ?? defaultTitle()
    let locale = try await SpeechChannel.supportedLocale(preferring: arguments.locale)

    let recorder = MeetingRecorder()
    recorder.onSegment = { segment in
        let minutes = Int(segment.start) / 60
        let seconds = Int(segment.start) % 60
        let label = segment.speaker == .me ? "Me  " : "Them"
        print(String(format: "  %02d:%02d  %@  %@", minutes, seconds, label, segment.text))
    }

    print("Grove — recording \"\(title)\"")
    print("Preparing on-device models…")
    try await recorder.start(locale: locale)

    print("Capturing \(recorder.systemAudioDevice) + microphone"
        + (recorder.microphoneAvailable ? "" : " (MIC UNAVAILABLE — only their side will be heard)"))
    if let path = arguments.notesPath {
        print("Rough notes: \(path) — jot into it while you talk.")
    }
    print(arguments.minutes.map { "Stopping after \($0) minutes. " } ?? "" + "Press Return to stop.")
    print(String(repeating: "─", count: 60))

    await waitForStop(minutes: arguments.minutes)

    print(String(repeating: "─", count: 60))
    print("Finishing transcription…")
    let transcript = await recorder.stop()

    if recorder.frameLossFraction > 0.001 {
        print(String(format: "warning: dropped %.2f%% of system audio frames",
                     recorder.frameLossFraction * 100))
    }
    guard !transcript.isEmpty else {
        print("Nothing was transcribed. Run `grove doctor` to check permissions.")
        return
    }

    let roughNotes = arguments.notesPath
        .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""

    var meeting = Meeting(
        title: title,
        startedAt: recorder.startedAt ?? Date(),
        endedAt: Date(),
        roughNotes: roughNotes,
        transcript: transcript,
        templateID: arguments.template)

    let spokenWords = NoteEnhancer.spokenWordCount(transcript)
    switch NoteEnhancer.availability {
    case _ where spokenWords < NoteEnhancer.minimumTranscriptWords:
        // A refusal, not a failure. Writing notes from this little means
        // inventing the meeting, which is the one thing Grove must not do.
        print(
            "Only \(spokenWords) words were transcribed — too little to write up "
                + "without inventing the rest. Saving the transcript and your notes.")
    case .available:
        print("Enhancing \(transcript.segments.count) segments with your notes…")
        do {
            let enhanced = try await NoteEnhancer().enhance(
                roughNotes: roughNotes,
                transcript: transcript,
                template: .named(arguments.template),
                meetingTitle: title)
            meeting.enhancedNotes = TimestampLinker.link(notes: enhanced, transcript: transcript)
        } catch {
            print("Enhancement failed (\(error)); saving the raw transcript and your notes.")
        }
    case .unavailable(let reason):
        print("On-device model unavailable (\(reason)); saving transcript and notes only.")
    }

    let folder = try store.save(meeting)
    print(String(repeating: "─", count: 60))
    if let enhanced = meeting.enhancedNotes { print(enhanced) }
    print(String(repeating: "─", count: 60))
    print("Saved to \(folder.path)")
}

/// Returns when the user presses Return, the time limit elapses, or the process
/// is interrupted.
///
/// Only watches stdin when it is a terminal. When Grove is run from a script or
/// with stdin redirected, `readLine()` returns nil immediately at EOF, which
/// would end the meeting the instant it started.
func waitForStop(minutes: Double?) async {
    let interactive = isatty(STDIN_FILENO) == 1

    await withTaskGroup(of: Void.self) { group in
        if interactive {
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        _ = readLine()
                        continuation.resume()
                    }
                }
            }
        }
        if let minutes {
            group.addTask {
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
        // Without a stop signal there is nothing to wait for, and returning
        // immediately would silently record nothing.
        if !interactive && minutes == nil {
            group.addTask {
                print("stdin is not a terminal; recording until interrupted (Ctrl-C).")
                try? await Task.sleep(for: .seconds(60 * 60 * 8))
            }
        }
        await group.next()
        group.cancelAll()
    }
}

/// Measures both capture paths in all four tap × voice-processing combinations.
///
/// Worth keeping as a command because every way this pipeline fails returns
/// `noErr`: a dead tap and a healthy one are distinguishable only by callback
/// count, and a muted mic only by signal level. Play audio while it runs.
///
/// On macOS 26.6 this is what shows that voice processing and the process tap
/// are mutually exclusive — the `tapCallbacks` column goes to zero the moment
/// voice processing is on.
@available(macOS 26.0, *)
func runDebugAudio() async {
    _ = await MicrophoneCapture.requestAccess()
    print("Play audio and talk while this runs; each row samples 3 seconds.")
    print(String(repeating: "─", count: 78))

    // Voice-processing rows run last on purpose. A VPIO engine keeps the audio
    // HAL busy well after `stop()` returns, and a following configuration then
    // fails to start with `canPerformIO` — which looks exactly like the capture
    // regression this command exists to detect. Ordering sidesteps the race
    // instead of guessing at a sleep long enough to hide it.
    let combinations = [(false, false), (true, false), (false, true), (true, true)]

    for (withTap, voiceProcessing) in combinations {
        let tap = SystemAudioTap()
        if withTap {
            do { try tap.prepare() } catch {
                print("tap prepare failed: \(error)")
                continue
            }
        }

        let microphone = MicrophoneCapture()
        let peak = PeakMeter()
        do {
            try microphone.start(echoCancellation: voiceProcessing) { buffer in
                peak.accumulate(buffer)
            }
        } catch {
            print("mic start failed: \(error)")
            tap.stop()
            continue
        }
        if withTap { try? tap.start { _ in } }

        try? await Task.sleep(for: .seconds(3))

        let format = microphone.format
        print(
            "tap=\(withTap ? "yes" : "no ")  voiceProcessing=\(voiceProcessing ? "on " : "off")"
                + "  mic=\(format.map { "\(Int($0.sampleRate))Hz/\($0.channelCount)ch" } ?? "nil")"
                + "  vpActive=\(microphone.voiceProcessingEnabled)"
                + "  micPeak=\(peak.description)"
                + "  tapCallbacks=\(tap.callbackCount)")

        microphone.stop()
        tap.stop()
        try? await Task.sleep(for: .seconds(2))
    }
    print(String(repeating: "─", count: 78))
    print("Expected: tapCallbacks > 0 and micPeak well above -60 dBFS only when")
    print("voice processing is off. Anything else is a capture regression.")
}

/// Peak level across the first channel. Written to from the audio thread.
final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        var local: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            local = max(local, abs(data[0][frame]))
        }
        lock.lock()
        peak = max(peak, local)
        lock.unlock()
    }

    var description: String {
        lock.lock()
        defer { lock.unlock() }
        return peak > 0 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "SILENT"
    }
}

@available(macOS 26.0, *)
func runAsk(_ arguments: Arguments) async throws {
    let question = arguments.positional.joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else {
        print("usage: grove ask QUESTION...")
        return
    }

    let store = MeetingStore(baseDirectory: arguments.directory.map { URL(fileURLWithPath: $0) })
    let meetings = try store.list()
    guard !meetings.isEmpty else {
        print("No meetings yet in \(store.baseDirectory.path)")
        return
    }

    let chat = MeetingChat()
    switch chat.availability {
    case .available:
        break
    case .unavailable(let reason):
        print("On-device model unavailable (\(reason)); cannot answer questions.")
        return
    }

    let answer = try await chat.ask(question: question, meetings: meetings)
    print(answer.text)
    if !answer.excerpts.isEmpty {
        print(String(repeating: "─", count: 60))
        print("Sources:")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for excerpt in answer.excerpts {
            print(String(
                format: "  %@  %@  [%@] %@",
                formatter.string(from: excerpt.startedAt),
                excerpt.meetingTitle as NSString,
                TimestampLinker.clockString(excerpt.start),
                excerpt.speaker.displayName))
        }
    }
}

func defaultTitle() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE HH:mm"
    return "Meeting \(formatter.string(from: Date()))"
}

@available(macOS 26.0, *)
func runList(_ arguments: Arguments) throws {
    let store = MeetingStore(baseDirectory: arguments.directory.map { URL(fileURLWithPath: $0) })
    let meetings = try store.list()
    guard !meetings.isEmpty else {
        print("No meetings yet in \(store.baseDirectory.path)")
        return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    for meeting in meetings {
        print(
            String(
                format: "%@  %-40@  %3d min  %d segments",
                formatter.string(from: meeting.startedAt),
                meeting.title as NSString,
                Int(meeting.duration / 60),
                meeting.transcript.segments.count))
    }
}

// MARK: - Entry point

// Line-buffer stdout so live transcript lines appear immediately when the output
// is piped or redirected, not only when the process exits.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Arguments(CommandLine.arguments)

guard #available(macOS 26.0, *) else {
    print("Grove needs macOS 26 or newer for on-device speech and language models.")
    exit(1)
}

do {
    switch arguments.command {
    case "record": try await runRecord(arguments)
    case "list": try runList(arguments)
    case "ask": try await runAsk(arguments)
    case "doctor": await runDoctor()
    case "debug-audio": await runDebugAudio()
    case "version", "--version", "-v": print("grove \(groveVersion)")
    case "templates":
        for template in NoteTemplate.builtIns {
            print("\(template.id.padding(toLength: 16, withPad: " ", startingAt: 0))\(template.name)")
            print("  sections: \(template.sections.joined(separator: ", "))")
        }
    default: printUsage()
    }
} catch {
    print("error: \(error)")
    exit(1)
}
