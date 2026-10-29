# Grove

Locally sourced meeting notes. An open-source, local-first alternative to
[Granola](https://granola.ai) for macOS: it listens to your meetings without
joining them, transcribes both sides on-device, and turns the rough notes you
typed during the call into polished notes that keep your own structure.

**Nothing leaves your Mac.** No transcription service, no cloud model, no
account. You can verify that with Little Snitch.

Grove is built on [Oats](https://github.com/yuvrajadhikari/oats) by Yuvraj
Adhikari (MIT) — see [Attribution](#attribution).

> **Status: unbuilt.** This code has been written and reviewed but not yet
> compiled or run anywhere — no Apple frameworks exist off a Mac. The first
> build below is the real test. The capture → transcribe → enhance pipeline
> Grove inherits from Oats was verified end to end by Oats' author on macOS 26;
> Grove's own additions (meeting chat, timestamped notes) are new code and are
> not yet verified on-device.

## What it does

- **Records both sides of a call without a bot** — a Core Audio process tap
  hears your meeting apps; your microphone hears you. The two streams are the
  speaker split: mic = you, system audio = everyone else. (It separates you
  from the other side; it does not identify individual guests.)
- **Transcribes live, on-device** with Apple's `SpeechAnalyzer`.
- **Writes the notes when you stop** — Apple Foundation Models merges your
  rough notes (the outline) with the transcript (the evidence), keeping *your*
  headings. Too little transcript and Grove refuses rather than inventing a
  meeting.
- **Timestamps in the notes** — each line of the written-up notes gets a
  `(mm:ss)` reference to the transcript moment it rests on, computed by
  matching, never generated.
- **Ask your meetings** — chat across every saved meeting, on-device. Every
  answer lists the exact transcript excerpts it was written from, and when
  nothing in your meetings covers the question, Grove says so instead of
  composing an answer.
- **Plain files, no lock-in** — Markdown + JSON in `~/Documents/Grove`.
  Greppable, syncable, Obsidian-friendly.
- Menu bar recording, pause/resume, folders, templates, meeting resume,
  light/dark, CLI for everything the engine does.

## Requirements

- **macOS 26 or newer, Apple Silicon.** Hard requirement: `SpeechAnalyzer` and
  Foundation Models do not exist earlier. Developed against macOS 26;
  macOS 27 clears the same floor but has not been tested.
- **Apple Intelligence enabled** — without it you still get transcripts, just
  not written-up notes or chat answers.
- **Xcode or the Command Line Tools** (`xcode-select --install`) for building.
- Microphone and system-audio permission, prompted on first run.

Two things use the network, both at setup and neither for AI: Apple's speech
models install themselves on first use if not already present, and cloning
this repo is a download. Inference never leaves the machine.

## Setup

```bash
git clone https://github.com/atharvdesai/grove.git && cd grove

# Engine + CLI
swift build -c release --package-path GroveKit

# App (builds Grove.app and opens it)
cd GroveApp && ./scripts/bundle.sh release --run
```

Then:

```bash
./GroveKit/.build/release/grove doctor   # checks permissions, speech, and the model
```

`grove doctor` must show the mic granted, on-device speech available, the
on-device language model available, and the system audio tap ready before the
first meeting. Every failure in the macOS audio stack reports success, so
trust the doctor, not silence.

Or run `./install.sh` from the repo root to build and install Grove.app and
the `grove` CLI in one go.

## Usage

In the app: ⌘N names a meeting and starts recording, ⇧⌘P pauses, ⇧⌘R stops and
writes the notes. Type rough fragments while you talk — they steer the notes.
"Ask your meetings" on the home screen opens chat across the library.

In the terminal:

```bash
grove record --title "Standup" --notes ~/notes.md
grove list
grove ask what budget was agreed
grove templates
grove doctor
grove debug-audio   # when a recording comes back empty
```

## Repository

- `GroveKit/` — the engine (capture, transcribe, enhance, chat, storage) plus
  the CLI. Zero dependencies, deliberately usable on its own.
- `GroveApp/` — the SwiftUI app. A plain SwiftPM package plus
  `scripts/bundle.sh`, which wraps the binary into `Grove.app`; no Xcode
  project to keep in sync.

Tests run with `swift test --package-path GroveKit`. They cover transcript
merging, echo dedup, chunking, the enhancement refusal floor, chat retrieval
and its relevance floor, timestamp linking, and storage — pure logic that
needs neither audio hardware nor Apple Intelligence. Capture, transcription,
and enhancement can only be verified by hand on a real Mac.

## Roadmap

- Calendar awareness: start notes from upcoming events instead of naming them.
- Optional larger local models through the existing engine seam.
- Per-guest speaker identification (real diarization) is deliberately out of
  scope for now.

## Attribution

Grove is built on [Oats](https://github.com/yuvrajadhikari/oats) by Yuvraj
Adhikari, used under the MIT License. The original license text is retained in
[LICENSE](LICENSE). Grove's changes — meeting chat with cited sources,
timestamped notes, the rename and repackage — are by Atharv Desai, also MIT.

## License

MIT — see [LICENSE](LICENSE). One edition, no paid tier, no open-core.
