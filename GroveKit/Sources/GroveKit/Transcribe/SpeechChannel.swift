import AVFoundation
import Foundation
import Speech

/// One live, on-device transcription stream for one speaker.
///
/// Grove runs two of these concurrently — one fed by the microphone, one by the
/// system-audio tap — and merges their output into a single timeline. Nothing
/// leaves the machine; the only network access Apple's speech stack makes is a
/// one-time model asset install handled in `prepareAssets`.
@available(macOS 26.0, *)
public final class SpeechChannel: @unchecked Sendable {
    public let speaker: Speaker

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let onSegment: @Sendable (TranscriptSegment) -> Void

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzeTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    /// Rebuilt whenever the incoming format changes (e.g. the user switches
    /// input device mid-meeting).
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private let converterLock = NSLock()

    /// Shared meeting start, so both channels report a common timeline.
    private var origin = Date()
    /// Seconds between the meeting origin and this channel's first audio.
    private var channelOffset: TimeInterval?
    private var framesSubmitted: Double = 0
    private let timelineLock = NSLock()

    private init(
        speaker: Speaker,
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        analyzerFormat: AVAudioFormat,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void
    ) {
        self.speaker = speaker
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        self.onSegment = onSegment
    }

    public static func supportedLocale(preferring identifier: String = "en-US") async throws
        -> Locale
    {
        guard SpeechTranscriber.isAvailable else {
            throw CaptureError.message("On-device speech transcription is unavailable")
        }
        guard
            let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier))
        else {
            throw CaptureError.message("Locale \(identifier) is not supported for transcription")
        }
        return locale
    }

    /// - Parameters:
    ///   - detectVoiceActivity: Adds Apple's `SpeechDetector` module, so the
    ///     analyzer only transcribes audio it believes contains speech.
    ///
    ///     Required on the microphone. Fed a continuous bed of room tone, the
    ///     transcriber does not return nothing — it returns fluent, confident,
    ///     invented sentences, which then reach the enhancement prompt as if
    ///     they had been said. An energy gate cannot separate these: measured on
    ///     this machine, room noise reaches -30 dBFS while speech picked up from
    ///     the speakers sits at a median of -31 dBFS. The distributions overlap,
    ///     so the discrimination has to be acoustic rather than merely loud.
    ///
    ///     Left off for the tap, which is a bit-exact copy of what the Mac
    ///     played and has no room tone to reject.
    public static func make(
        speaker: Speaker,
        locale: Locale,
        detectVoiceActivity: Bool = false,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void
    ) async throws -> SpeechChannel {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])

        // `reportResults: false` because Grove only wants the detector's gating
        // effect on the transcriber, not a second results stream to consume.
        let detector: SpeechDetector? =
            detectVoiceActivity
            ? SpeechDetector(
                detectionOptions: .init(sensitivityLevel: .medium), reportResults: false)
            : nil

        let modules: [any SpeechModule] = detector.map { [$0, transcriber] } ?? [transcriber]

        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }

        // Must be negotiated against every module, not just the transcriber, or
        // the detector may be handed audio it cannot read.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        else {
            throw CaptureError.message("No compatible audio format for the speech analyzer")
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        return SpeechChannel(
            speaker: speaker, transcriber: transcriber, analyzer: analyzer,
            analyzerFormat: format, onSegment: onSegment)
    }

    /// - Parameter origin: Shared wall-clock zero for the meeting. Both channels
    ///   must be given the same value, otherwise each analyzer times segments
    ///   from its own first buffer and the merged transcript interleaves the two
    ///   speakers at the wrong offsets.
    public func start(origin: Date) {
        self.origin = origin
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [transcriber, speaker, onSegment] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    onSegment(
                        TranscriptSegment(
                            speaker: speaker,
                            text: text,
                            start: CMTimeGetSeconds(result.range.start),
                            end: CMTimeGetSeconds(result.range.end)))
                }
            } catch {
                // A failed channel must not take the meeting down: the other
                // speaker's transcript and the user's own notes still stand.
            }
        }

        analyzeTask = Task { [analyzer] in
            _ = try? await analyzer.analyzeSequence(stream)
        }
    }

    /// Called from an audio thread. Converts into the analyzer's preferred
    /// format and hands the buffer off; `AVAudioConverter` deals with both the
    /// sample-rate change and the tap's interleaved layout.
    public func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation,
            let converted = convert(buffer)
        else { return }

        timelineLock.lock()
        // Anchor to the shared meeting origin once, when audio actually starts
        // flowing on this channel, then advance by real buffer durations.
        //
        // Stamping each buffer with the wall clock instead looks equivalent and
        // is not: those times drift and overlap relative to the audio, and the
        // analyzer responds by emitting nothing and never completing finalize.
        if channelOffset == nil {
            channelOffset = max(0, Date().timeIntervalSince(origin))
        }
        let startSeconds = (channelOffset ?? 0) + framesSubmitted / analyzerFormat.sampleRate
        framesSubmitted += Double(converted.frameLength)
        timelineLock.unlock()

        continuation.yield(
            AnalyzerInput(
                buffer: converted,
                bufferStartTime: CMTime(seconds: startSeconds, preferredTimescale: 48_000)))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        converterLock.lock()
        defer { converterLock.unlock() }

        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            converterSourceFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Flushes buffered audio and waits for the last segments to arrive.
    ///
    /// Bounded on purpose. Whatever has already been transcribed is worth
    /// saving, so a wedged analyzer must cost a few trailing seconds rather than
    /// the entire meeting.
    public func finish(timeout: Duration = .seconds(20)) async {
        inputContinuation?.finish()
        inputContinuation = nil

        // The drain runs *detached* rather than as a child task, and the timeout
        // is a one-shot signal rather than a racing sibling in a task group.
        //
        // A task group is the obvious shape here and it does not work:
        // `withTaskGroup` awaits every child before it returns, so when the
        // timeout child wins the race, the group still blocks on the drain child
        // until it completes. `finalizeAndFinishThroughEndOfInput()` does not
        // honour cancellation, so `cancelAll()` cannot free it either, and the
        // supposed 20 s bound became an unbounded hang.
        let done = OneShotSignal()
        let drain = Task.detached { [analyzer, analyzeTask, resultsTask] in
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await analyzeTask?.value
            await resultsTask?.value
            await done.signal()
        }
        let deadline = Task.detached {
            try? await Task.sleep(for: timeout)
            await done.signal()
        }

        await done.wait()
        deadline.cancel()
        // `drain` is deliberately not awaited: if it is wedged, abandoning it is
        // the entire point. Segments already delivered are safe in `collected`.
        _ = drain

        analyzeTask?.cancel()
        resultsTask?.cancel()
        analyzeTask = nil
        resultsTask = nil
    }
}

/// Resumes every waiter the first time it is signalled, and ignores signals
/// after that. Used to put a genuine upper bound on work that cannot be
/// cancelled.
private actor OneShotSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !fired else { return }
        fired = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
