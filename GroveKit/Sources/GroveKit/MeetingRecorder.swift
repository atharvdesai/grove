import AVFoundation
import Foundation

/// Runs a meeting end to end: both audio streams in, one merged transcript out.
///
/// The microphone feeds the "Me" channel and the system-audio tap feeds "Them",
/// each with its own on-device transcriber, so speaker attribution falls out of
/// the capture topology instead of a diarization model.
@available(macOS 26.0, *)
public final class MeetingRecorder: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case finished
    }

    private let tap = SystemAudioTap()
    private let microphone = MicrophoneCapture()
    private var systemChannel: SpeechChannel?
    private var microphoneChannel: SpeechChannel?

    private let lock = NSLock()
    private var collected: [TranscriptSegment] = []

    public private(set) var state: State = .idle
    public private(set) var startedAt: Date?
    public private(set) var microphoneAvailable = false

    /// Pausing gates ingestion rather than stopping capture.
    ///
    /// The tap and the engine keep running; their buffers are simply not fed to
    /// the transcribers. Tearing the tap down and rebuilding it would be the
    /// obvious approach and is a bad one — building the aggregate device is the
    /// slow part of starting, it re-triggers the whole silent-failure surface,
    /// and the two channels would come back with different time origins.
    ///
    /// Because `SpeechChannel` advances its timeline only for buffers it
    /// actually submits, skipped audio simply does not exist as far as the
    /// transcript is concerned: timestamps stay continuous across a pause
    /// instead of leaving a gap the length of the coffee break.
    private var paused = false
    private let pauseLock = NSLock()
    private var pausedAccumulated: TimeInterval = 0
    private var pausedAt: Date?

    public var isPaused: Bool {
        pauseLock.lock(); defer { pauseLock.unlock() }
        return paused
    }

    /// Seconds recorded so far, excluding paused time.
    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        pauseLock.lock(); defer { pauseLock.unlock() }
        let pausedSoFar = pausedAccumulated + (pausedAt.map { Date().timeIntervalSince($0) } ?? 0)
        return max(0, Date().timeIntervalSince(startedAt) - pausedSoFar)
    }

    /// Called on an arbitrary thread as each final segment lands.
    public var onSegment: (@Sendable (TranscriptSegment) -> Void)?

    public var systemAudioDevice: String { tap.outputDeviceName }
    public var frameLossFraction: Double { tap.frameLossFraction }

    public init() {}

    public func start(locale: Locale) async throws {
        guard state == .idle else { return }

        microphoneAvailable = await MicrophoneCapture.requestAccess()

        let collect: @Sendable (TranscriptSegment) -> Void = { [weak self] segment in
            guard let self else { return }
            self.lock.lock()
            self.collected.append(segment)
            self.lock.unlock()
            self.onSegment?(segment)
        }

        // Prepare the tap before starting anything: building the aggregate
        // device is the slow step, and starting the mic first would skew the
        // two channels' timelines relative to each other.
        try tap.prepare()

        // Voice activity detection runs on the microphone only. The mic hears
        // the room and the transcriber turns room tone into invented sentences;
        // the tap is a clean digital copy with nothing to reject.
        systemChannel = try await SpeechChannel.make(
            speaker: .them, locale: locale, onSegment: collect)
        if microphoneAvailable {
            microphoneChannel = try await SpeechChannel.make(
                speaker: .me, locale: locale, detectVoiceActivity: true, onSegment: collect)
        }

        // One origin shared by both channels, established before either starts.
        let origin = Date()
        systemChannel?.start(origin: origin)
        microphoneChannel?.start(origin: origin)

        startedAt = origin
        state = .recording

        if microphoneAvailable, let channel = microphoneChannel {
            // Echo cancellation stays off: the OS voice-processing unit cannot
            // coexist with the process tap. See `MicrophoneCapture.start`.
            // Speaker bleed is removed downstream by `Transcript.withoutEcho()`.
            try microphone.start { [weak self] buffer in
                guard self?.isPaused == false else { return }
                channel.ingest(buffer)
            }
        }
        if let channel = systemChannel {
            try tap.start { [weak self] buffer in
                guard self?.isPaused == false else { return }
                channel.ingest(buffer)
            }
        }
    }

    public func pause() {
        guard state == .recording else { return }
        pauseLock.lock()
        if !paused {
            paused = true
            pausedAt = Date()
        }
        pauseLock.unlock()
    }

    public func resume() {
        guard state == .recording else { return }
        pauseLock.lock()
        if paused {
            paused = false
            if let pausedAt { pausedAccumulated += Date().timeIntervalSince(pausedAt) }
            pausedAt = nil
        }
        pauseLock.unlock()
    }

    /// Stops capture, drains both transcribers, and returns the merged
    /// transcript ordered by time.
    public func stop() async -> Transcript {
        guard state == .recording else { return currentTranscript() }
        // Close out any open pause first, so `recordedDuration` is not short by
        // however long the meeting sat paused before the user hit stop.
        resume()
        state = .finished

        tap.stop()
        microphone.stop()

        await systemChannel?.finish()
        await microphoneChannel?.finish()
        systemChannel = nil
        microphoneChannel = nil

        return currentTranscript()
    }

    public func currentTranscript() -> Transcript {
        lock.lock()
        let segments = collected
        lock.unlock()

        var transcript = Transcript()
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            transcript.insert(segment)
        }
        return transcript.withoutEcho()
    }
}
