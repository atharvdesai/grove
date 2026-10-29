import AVFoundation
import Foundation

/// Captures the user's own voice, kept deliberately separate from the system
/// audio stream. That separation is what gives Grove "Me / Them" labelling with
/// no diarization model at all.
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    public private(set) var format: AVAudioFormat?
    /// Whether the OS echo canceller actually engaged.
    public private(set) var voiceProcessingEnabled = false

    public init() {}

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static var hasAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Whether macOS will still show a prompt.
    ///
    /// Matters for what the UI can offer: once denied, an app cannot ask again,
    /// and a "Grant" button that silently does nothing is worse than no button.
    /// The only route back is System Settings.
    public static var canRequestAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    /// - Parameter echoCancellation: Enables the OS voice-processing unit.
    ///
    ///   **Leave this off while the system-audio tap is running.** It is the
    ///   obvious fix for the mic re-hearing the speakers, it was tried, and on
    ///   macOS 26.6 it breaks the two things Grove depends on:
    ///
    ///   1. The process tap stops dead — `AudioDeviceStart` still returns
    ///      `noErr` and the IOProc then never fires once (measured: 297
    ///      callbacks with voice processing off, 0 with it on, same run).
    ///      VPIO takes over the output path the aggregate device is built on,
    ///      so turning it on silently costs the entire "Them" channel.
    ///   2. The input node switches to a 7-channel format. Channel 0 still
    ///      carries real audio, but `AVAudioConverter` renders that layout to
    ///      the analyzer's mono format as pure digital silence, so the "Me"
    ///      channel transcribes nothing either.
    ///
    ///   Echo is instead handled after the fact by `Transcript.withoutEcho()`,
    ///   which is why that dedup is a correctness requirement and not a nicety.
    ///   Headphones remain the real fix; a proper AEC using the tap signal as
    ///   the reference is the principled long-term answer.
    public func start(
        echoCancellation: Bool = false,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        let input = engine.inputNode

        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                // Not fatal: some aggregate/virtual input devices refuse it. The
                // transcript stays usable, just echo-prone on speakers.
                voiceProcessingEnabled = false
            }
            voiceProcessingEnabled = input.isVoiceProcessingEnabled
        }

        // Read the format only after voice processing is enabled — turning it on
        // changes the input node's output format.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CaptureError.message(
                "Microphone reported a zero sample rate — permission is likely denied")
        }
        format = inputFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            handler(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit { stop() }
}
