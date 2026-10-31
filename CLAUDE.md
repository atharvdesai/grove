# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Grove is a macOS 26+ / Apple Silicon meeting-notes app written in Swift. It records both sides of a call without a bot, transcribes on-device, and merges the user's rough notes with the transcript into finished notes. Read `CONTRIBUTING.md` before changing capture, transcription, or prompting code.

## Commands

Everything needs macOS 26 SDK (Xcode or Command Line Tools). Nothing builds on Linux; SpeechAnalyzer and Foundation Models don't exist there.

```bash
swift build --package-path GroveKit                      # engine + `grove` CLI
swift test  --package-path GroveKit                      # all tests (XCTest)
swift test  --package-path GroveKit --filter ChunkingTests                 # one test class
swift test  --package-path GroveKit --filter ChunkingTests/testSomething   # one test
swift build --package-path GroveApp                      # app, compile only
cd GroveApp && ./scripts/bundle.sh debug --run           # build Grove.app and launch it
./scripts/sync-version.sh --check                        # CI fails if plists drift from VERSION
./install.sh                                             # build + install app and CLI
```

The CLI runs the same engine and is the fastest way to iterate: `./GroveKit/.build/debug/grove doctor | record --title X --minutes 0.3 --dir /tmp/x | debug-audio | detect | ask … | actions | digest | list | templates`.

CI (`.github/workflows/ci.yml`) is manual-dispatch only. It runs the steps above plus a bundle/codesign check on `macos-26`.

## Architecture

There are two SwiftPM packages and no Xcode project:

- **`GroveKit/`**: the engine library plus the `grove` CLI (`Sources/grove/main.swift`). It has zero dependencies. All audio, speech, AI, storage, and Google/Calendar logic lives here.
- **`GroveApp/`**: a thin SwiftUI shell that depends on `../GroveKit`. `scripts/bundle.sh` wraps the executable into `build/Grove.app`. The bundle is required because TCC reads the usage strings from `Info.plist`. The Google OAuth client ID is injected at bundle time from `GroveApp/google-client-id.txt` or `GROVE_GOOGLE_CLIENT_ID`. That file is git-ignored.

### Pipeline (`GroveKit/Sources/GroveKit`)

1. **Capture**: `MeetingRecorder` owns `SystemAudioTap` (a Core Audio process tap on meeting apps) and `MicrophoneCapture`. Speaker attribution comes from capture topology, not diarization: mic = `Speaker.me`, system audio = `Speaker.them`. In-person mode uses the mic only and labels it `.them`. Pause gates ingestion rather than tearing down the tap, which keeps timestamps continuous.
2. **Transcribe**: each stream gets its own `SpeechChannel` (SpeechAnalyzer). The segments merge into a `Transcript`, with echo dedup between channels.
3. **Enhance**: `NoteEnhancer` drives any `NoteWritingModel` (`Enhance/NoteWritingModel.swift`). Implementations:
   - `FoundationModelsEngine`: Apple's on-device model and the default. Its window is small, so long transcripts are chunked (`TopicSegmenter`) and condensed into a `FactSheet` first.
   - `ClaudeCodeEngine`: opt-in. It shells out to the user's installed `claude` CLI (`-p --model claude-haiku-5-5 --tools ""`), with a large single-pass limit. It is the only engine that sends data off the Mac.

   The app always falls back to `FoundationModelsEngine` when the chosen engine fails (`[settings.writingModel, FoundationModelsEngine()]`). Other model-driven features (`MeetingNamer`, `NoteReview` for note/transcript conflicts and Polish & Cite, `MeetingDigest`, `MeetingInsights`, `MeetingChat`) go through the same protocol. `TimestampLinker` adds `(mm:ss)` references by matching text, never by generating them.
4. **Store**: `MeetingStore` writes plain files to `~/Documents/Grove/[<folder>/]<meeting>/`: `meeting.json` (canonical), `notes.md`, and `transcript.md`. The filesystem is the source of truth for folder membership, so a meeting moved in Finder moves in Grove. Templates also live in the library folder.
5. **Insights**: `Insights/` (`LibraryIndex`, `MeetingQuery`) builds people pages, a decision log, "waiting on", and search from per-meeting `MeetingInsights`.

On the app side, `MeetingSession` is the single owner of a recording's lifecycle: start, pause, off-the-record spans, stop → enhance → name/file → insights → save. `MeetingWatcher` and `Detect/MeetingDetector` notice when call apps take the mic. `AppSettings` chooses the writing model.

## Rules that matter here

- **Refusals are enforced in code, not prompts.** The on-device model will write confident notes about meetings that never happened. Keep and extend the hard floors (`NoteEnhancer.minimumTranscriptWords`, `MeetingNamer.minimumTranscriptWords`, chat's relevance floor, stripping of citation numbers that point at nothing real). Don't replace them with prompt instructions.
- **Local by default.** AI must not reach the network unless the user explicitly picked Claude, and the on-device zero-download path must always work. No telemetry. Data stays in plain Markdown/JSON, never an opaque or encrypted store.
- **A new engine should only need a new `NoteWritingModel` conformance.** It should not require changes to prompting, chunking, or callers. Tests use stub engines through this seam (see `NoteEnhancerEngineTests`). Don't require a real model or audio hardware in tests.
- **Audio failures report success.** A dead tap, wrong buffer layout, or muted mic all return `noErr`. Known traps:
  - The voice-processing unit kills the tap.
  - The tap delivers *interleaved* stereo.
  - SpeechAnalyzer wants 1 ch / 16 kHz / **Int16**, so `floatChannelData` comes back nil.

  Changes under `Capture/` or `Transcribe/` can only be verified by hand on a real Mac, with `grove debug-audio` and a real `grove record` round trip. CI and tests cannot cover them.
- **Comments explain *why*,** especially where the obvious approach failed. Preserve them and match that style.

## Releasing

`echo X.Y.Z > VERSION && ./scripts/sync-version.sh`, commit, tag `vX.Y.Z`, and push the tags. `release.yml` builds the DMG and zip via `scripts/release.sh`, publishes a GitHub Release, and updates the cask in `atharvdesai/homebrew-grove`. Signing and notarization run only if those secrets are set.

`scripts/load-sample-meetings.py [--remove]` loads invented meetings from `samples/` into the library for testing chat and insights.
