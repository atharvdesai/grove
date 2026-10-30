# Contributing to Grove

Thanks for looking. Grove is a local-first alternative to Granola: it listens to
your meetings without joining them, transcribes both sides on-device, and turns
the rough notes you typed during the call into polished notes that keep your
structure.

## The commitments

These are why the project exists. A change that breaks one will not be merged,
however good it is otherwise.

- **Strictly local.** No network calls for AI. Not for transcription, not for
  enhancement, not "just for the hard cases". The only acceptable network
  traffic is one-time setup — Apple's speech assets, or downloading a local
  model the user explicitly asked for — and it must be obvious in the UI.
- **No open-core.** MIT, one edition. Nothing gets moved behind a paid tier.
- **Your data stays readable without us.** Plain Markdown and JSON on disk.
  Never an encrypted cache.
- **No telemetry.** No analytics, no crash reporting phoning home, no "anonymous
  usage statistics".
- **The zero-download path keeps working.** Apple's on-device model is the
  default because it is already on the machine. A better local model is welcome
  as an *option*; it must never become a prerequisite for the app doing anything.

## Requirements

- **macOS 26 or newer, Apple Silicon.** Hard requirement — `SpeechAnalyzer`,
  `SpeechDetector`, and Foundation Models are what make the local promise
  possible, and they do not exist on earlier versions.
- **Xcode** (or the Command Line Tools) for the macOS 26 SDK.
- **Apple Intelligence enabled**, or note enhancement reports itself
  unavailable and you will only get transcripts.

## Getting it running

If you only want to *use* Grove, the one-line installer in the README is easier.
For development, work from a checkout:

```bash
git clone https://github.com/atharvdesai/grove.git && cd grove

# The app
cd GroveApp && ./scripts/bundle.sh debug --run

# The CLI, which runs the same engine and is much faster to iterate on
cd GroveKit && swift build
./.build/debug/grove doctor
./.build/debug/grove record --title "Test" --minutes 1
```

`grove doctor` should report four green subsystems. If it does not, fix that
before anything else.

## Tests

```bash
cd GroveKit && swift test
```

## What CI does and does not prove

CI builds both packages and runs the unit tests on a `macos-26` runner. That
covers the pure logic: transcript merging, echo dedup, chunking, the
enhancement refusal floor, storage.

**CI cannot test the things most likely to break.** A GitHub runner has no
audio devices, no microphone, and no Apple Intelligence, so capture,
transcription, and enhancement are all unexercised. A green tick means "it
compiles and the logic holds", never "audio works".

If you touch anything under `Capture/` or `Transcribe/`, you must verify by
hand on a real Mac and say so in the PR. The minimum:

```bash
# Levels and callback counts in every capture configuration. Play audio while it runs.
./.build/debug/grove debug-audio

# A real round trip
( sleep 3; say -r 178 "About forty percent bail at the invite screen." ) &
./.build/debug/grove record --title "Check" --minutes 0.3 --dir /tmp/grove-check
```

## Before you touch the audio code

Every failure mode in this pipeline returns success. A dead tap, a muted mic, a wrong buffer
layout, and a perfectly healthy system are indistinguishable unless you look at
signal levels and callback counts. Several of these cost hours each:

- Enabling the OS voice-processing unit kills the process tap outright, and
  `AudioDeviceStart` still returns `noErr`.
- The tap delivers **interleaved** stereo. Reading it as non-interleaved
  produces a garbled transcript that looks like a bad ASR model.
- The speech analyzer's format is 1 ch / 16 kHz / **Int16**. Buffer code reading
  `floatChannelData` gets `nil` and silently does nothing.
- `grove doctor` reported everything green through an entire session in which
  nothing was transcribed at all.

The `spike/AudioCaptureSpike` binary is a known-good reference. When capture
misbehaves, run it first — it separates "my environment broke" from "the code
regressed" in about thirty seconds.

## A note on the model

Apple's on-device model is small and **eager to please**. Given thin evidence it
does not decline; it writes confident, well-formatted notes about a meeting that
did not happen. Real reports of this have included a transcript of "let's talk
about the OKRs" producing notes claiming the team had discussed and finalised
them.

Treat prompt instructions as mitigation, never as a guarantee. Where an empty
answer is the correct answer, enforce it in code — see
`NoteEnhancer.minimumTranscriptWords`.

## Pull requests

- Branch off `main`.
- Keep the diff focused. One change per PR.
- Match the surrounding style. Comments explain *why*, especially where the
  obvious approach was tried and failed — this codebase has several of those and
  they are the most valuable lines in it.
- Add tests for logic that can be tested without hardware. The
  `NoteWritingModel` seam exists so enhancement can be tested against a stub
  engine; use it rather than requiring a real model.
- Say what you verified by hand, and on what hardware and macOS version.

## Reporting bugs

Include the output of `grove doctor`, your macOS version and Mac model, and
whether you were on speakers or headphones. For anything about missing or wrong
transcript text, include `grove debug-audio` output too — without levels and
callback counts, a capture bug cannot be diagnosed from a description.
