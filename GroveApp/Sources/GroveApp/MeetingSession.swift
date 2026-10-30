import Foundation
import GroveKit
import Observation

/// The live meeting, as the UI sees it.
///
/// This is the only place the app touches `MeetingRecorder`. It exists because
/// the engine is deliberately UI-agnostic: `onSegment` fires on whatever thread
/// the speech analyzer happens to be on, and SwiftUI needs main-actor state, so
/// something has to own that hop. Keeping it in one class means no view ever has
/// to think about threading.
@MainActor
@Observable
final class MeetingSession {
    enum Phase: Equatable {
        case idle
        /// Building the tap and loading speech models — slow enough to show.
        case starting
        case recording
        case paused
        /// Draining both transcribers. Bounded, but can take seconds.
        case finishing
        case enhancing
        /// Choosing a title and folder for an untitled meeting.
        case naming
    }

    private(set) var phase: Phase = .idle
    var title: String = ""
    var roughNotes: String = ""
    var templateID: String = NoteTemplate.general.id
    /// Folder the finished meeting is filed under, chosen before recording.
    var folder: String?
    /// True when nobody chose a folder, so Grove may file the meeting itself.
    /// Distinct from `folder == nil`, which can also be a deliberate choice of
    /// the top level.
    var folderIsAutomatic = true
    /// The call app that prompted this recording, when detection started it.
    /// Feeds the fallback title and gives the namer a hint.
    private(set) var meetingApp: String?

    /// Echo-deduplicated, so the panel shows what will actually be saved rather
    /// than the microphone's copy of the far end.
    private(set) var segments: [TranscriptSegment] = []
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var systemAudioDevice = ""
    private(set) var microphoneAvailable = true
    /// Set when a meeting has just been saved, so the library can select it.
    private(set) var lastSaved: Meeting?

    /// The saved meeting this session is continuing, if any.
    ///
    /// Resuming keeps the original meeting's identity — same id, same start
    /// time, same folder — so it saves back over itself instead of spawning a
    /// second folder for what the user thinks of as one meeting.
    private(set) var resuming: Meeting?

    private var recorder: MeetingRecorder?
    private var startedAt = Date()
    private var ticker: Task<Void, Never>?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Resolved each time rather than captured, so changing the storage folder
    /// in Settings takes effect on the next meeting without a restart.
    private var store: MeetingStore { settings.store }

    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording || phase == .paused }
    var isPaused: Bool { phase == .paused }
    /// True while audio is genuinely being captured, which is what the recording
    /// dot and the menu-bar icon should reflect.
    var isCapturing: Bool { phase == .recording }

    var statusText: String {
        switch phase {
        case .idle: return "Ready"
        case .starting:
            return resuming == nil
                ? "Preparing on-device models…" : "Resuming — preparing models…"
        case .recording: return elapsed.clockString
        case .paused: return "Paused · \(elapsed.clockString)"
        case .finishing: return "Finishing transcription…"
        case .enhancing: return "Writing your notes…"
        case .naming: return "Naming the meeting…"
        }
    }

    /// Continues a saved meeting: new audio is appended to its transcript and
    /// its notes are rewritten over the whole thing.
    func resume(_ meeting: Meeting) async {
        guard phase == .idle else { return }
        resuming = meeting
        title = meeting.title
        roughNotes = meeting.roughNotes
        templateID = meeting.templateID
        folder = meeting.folder
        folderIsAutomatic = false
        await start()
    }

    /// `detectedApp` is the call app that prompted this recording, if any.
    func start(detectedApp: String? = nil) async {
        guard phase == .idle else { return }
        meetingApp = detectedApp
        phase = .starting
        errorMessage = nil
        lastSaved = nil
        segments = []
        elapsed = 0

        let recorder = MeetingRecorder()
        recorder.onSegment = { [weak self] _ in
            // Audio-thread adjacent: hop before touching any observable state.
            Task { @MainActor [weak self] in self?.refreshSegments() }
        }
        self.recorder = recorder

        do {
            let locale = try await SpeechChannel.supportedLocale()
            try await recorder.start(locale: locale)
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            self.recorder = nil
            phase = .idle
            return
        }

        startedAt = recorder.startedAt ?? Date()
        systemAudioDevice = recorder.systemAudioDevice
        microphoneAvailable = recorder.microphoneAvailable
        phase = .recording
        startTicker()
    }

    /// Pausing keeps the tap and the transcribers alive and simply stops feeding
    /// them. Timestamps stay continuous across the gap, so a paused break does
    /// not show up as dead air in the transcript.
    func togglePause() {
        guard let recorder else { return }
        switch phase {
        case .recording:
            recorder.pause()
            phase = .paused
        case .paused:
            recorder.resume()
            phase = .recording
        default:
            break
        }
        elapsed = recorder.elapsed
    }

    /// Stops capture, enhances against the rough notes, and saves.
    @discardableResult
    func stop() async -> Meeting? {
        guard phase == .recording || phase == .paused, let recorder else { return nil }
        let recordedDuration = recorder.elapsed
        phase = .finishing
        ticker?.cancel()
        ticker = nil

        let captured = await recorder.stop()
        self.recorder = nil

        // A resumed session records from zero again, so shift it past what the
        // meeting already had rather than interleaving two timelines.
        let transcript = resuming.map { $0.transcript.appending(captured) } ?? captured
        segments = transcript.segments

        // Resuming and capturing nothing must not overwrite a good meeting with
        // a re-run of the enhancement over identical evidence.
        if let resuming, captured.isEmpty {
            errorMessage =
                "Nothing new was captured, so “\(resuming.title)” was left as it was."
            phase = .idle
            self.resuming = nil
            return nil
        }

        // A meeting with neither a transcript nor notes is not worth a folder,
        // and silently writing an empty one would look like data loss later.
        guard !transcript.isEmpty || !roughNotes.trimmed.isEmpty else {
            errorMessage =
                "Nothing was captured. Check microphone and audio permissions, "
                + "or run `grove debug-audio` to see whether audio is reaching Grove."
            phase = .idle
            return nil
        }

        // Nobody named it, so the title is Grove's to choose. A resumed meeting
        // keeps the name it already has.
        let titleIsAutomatic = resuming == nil && title.trimmed.isEmpty

        // Keep the original identity when resuming, so this overwrites the same
        // folder on disk instead of creating a second one.
        var meeting = Meeting(
            id: resuming?.id ?? UUID(),
            title: resolvedTitle,
            startedAt: resuming?.startedAt ?? startedAt,
            endedAt: Date(),
            roughNotes: roughNotes,
            transcript: transcript,
            templateID: templateID,
            folder: folder,
            recordedDuration: (resuming?.recordedDuration ?? 0) + recordedDuration)

        // Never skip this silently. A meeting that comes back as "transcript
        // only" with no explanation looks like the app quietly did half its job,
        // and the reason is exactly what the user needs to fix it.
        let spokenWords = NoteEnhancer.spokenWordCount(transcript)
        switch NoteEnhancer.availability {
        case .available where transcript.isEmpty:
            break
        case _ where spokenWords < NoteEnhancer.minimumTranscriptWords:
            // Deliberate refusal rather than a failure: writing notes from this
            // little means inventing what the meeting concluded.
            errorMessage =
                "Only \(spokenWords) \(spokenWords == 1 ? "word was" : "words were") "
                + "transcribed — too little to write up without inventing the rest.\n\n"
                + "Your transcript and notes are saved."
        case .available:
            phase = .enhancing
            do {
                let enhanced = try await NoteEnhancer().enhance(
                    roughNotes: roughNotes,
                    transcript: transcript,
                    template: .named(templateID),
                    // A placeholder like "Meeting Thursday 14:00" tells the
                    // model nothing and invites it to echo the date back.
                    meetingTitle: titleIsAutomatic ? nil : meeting.title)
                meeting.enhancedNotes = TimestampLinker.link(
                    notes: enhanced, transcript: transcript)
            } catch {
                // The transcript and the user's own notes are the irreplaceable
                // part; a failed polish must never cost them.
                errorMessage = "Could not write up the notes: \(error.localizedDescription)\n\nYour transcript and notes are saved."
            }
        case .unavailable(let reason):
            errorMessage = "The on-device writing model is unavailable (\(reason)).\n\nYour transcript and notes are saved."
        }

        if settings.autoOrganize, resuming == nil,
            titleIsAutomatic || (folderIsAutomatic && folder == nil)
        {
            phase = .naming
            await organize(
                &meeting, nameIt: titleIsAutomatic, fileIt: folderIsAutomatic && folder == nil)
        }

        do {
            _ = try store.save(meeting)
            lastSaved = meeting
        } catch {
            errorMessage = "Could not save the meeting: \(error.localizedDescription)"
        }

        phase = .idle
        roughNotes = ""
        title = ""
        folder = nil
        folderIsAutomatic = true
        meetingApp = nil
        resuming = nil
        templateID = settings.defaultTemplateID
        return meeting
    }

    /// Names the meeting and files it into an existing folder, on-device.
    ///
    /// Best effort by design: a meeting saved under its fallback title is fine,
    /// and nothing about naming is worth an error message on top of the notes.
    private func organize(_ meeting: inout Meeting, nameIt: Bool, fileIt: Bool) async {
        let namer = MeetingNamer()
        guard namer.availability == .available else { return }

        let existing = (try? store.list()) ?? []
        let folders = ((try? store.folders()) ?? []).map { name in
            MeetingNamer.FolderContext(
                name: name,
                recentTitles: existing.filter { $0.folder == name }.prefix(3).map(\.title))
        }

        guard
            let suggestion = try? await namer.suggest(
                transcript: meeting.transcript,
                notes: meeting.enhancedNotes ?? meeting.roughNotes,
                folders: fileIt ? folders : [],
                appName: meetingApp)
        else { return }

        if nameIt { meeting.title = suggestion.title }
        if fileIt, let folder = suggestion.folder { meeting.folder = folder }
    }

    func dismissError() { errorMessage = nil }

    private var resolvedTitle: String {
        let trimmed = title.trimmed
        if !trimmed.isEmpty { return trimmed }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        let kind = meetingApp.map { "\($0) meeting" } ?? "Meeting"
        return "\(kind) \(formatter.string(from: startedAt))"
    }

    private func refreshSegments() {
        guard let recorder else { return }
        let live = recorder.currentTranscript()
        // Show what the meeting already had above the new audio, so a resumed
        // session reads as a continuation rather than starting from a blank panel.
        segments = (resuming.map { $0.transcript.appending(live) } ?? live).segments
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await MainActor.run {
                    // The recorder owns elapsed time because it owns the pause
                    // bookkeeping; computing it from `startedAt` here would count
                    // paused minutes.
                    guard self.phase == .recording, let recorder = self.recorder else { return }
                    self.elapsed = recorder.elapsed
                }
            }
        }
    }
}

extension TimeInterval {
    /// mm:ss, or h:mm:ss once a meeting runs past an hour.
    var clockString: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
