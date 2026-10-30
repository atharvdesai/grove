# Build plan: who said what, and your own AI

Status: proposal, October 2026. Nothing here is built yet.

This plan covers three things:

1. **Speaker identification.** Name the people on a call, starting with a
   "who's speaking?" prompt at the start of the meeting.
2. **Voiceprints.** Make speaker identification accurate enough to trust, and
   remember voices across meetings.
3. **Bring your own AI.** Let users write or rewrite notes with a stronger
   model than Apple's on-device one.

---

## 1. What accuracy to expect

### 1a. Splitting the transcript from text alone

Here the idea is to have Apple's on-device model guess who said each line, with
no voice analysis.

**Verdict: not good enough to rely on.** Expect 50–70% of lines right with
three or more other speakers. With one or two others and clear back-and-forth
it does better, but voice analysis beats it everywhere.

- The best published work on this, Google's DiarizationLM, uses a language
  model only to *correct* the output of a voice-based system, and not from
  scratch.
  - Even then, it needed a fine-tuned model to help (an 8B-parameter Llama 3).
    Used without fine-tuning, a large model made the errors *worse* on one
    dataset (7.7 → 12.3 word diarization error rate).
  - Every test call had exactly 2 speakers.
- Apple's on-device model is about 3B parameters and not fine-tuned for this.
  It would do worse than that.

**Where text does help:** putting names on voices. If a transcript line says
"Thanks, Priya", the voice that answers next is probably Priya. Grove should use
the model for that kind of naming hint, and not to split the transcript.

### 1b. Voiceprints, which analyse the audio itself

**Published results:**
- **Matching a voice to a known person:** the best open models get under 0.5%
  equal error rate on clean audio (VoxCeleb).
- **Splitting a meeting by speaker, with no help:** open systems make 10–20%
  errors.
  - pyannote community-1: 17.0% on AMI and 11.2% on VoxConverse.
  - FluidAudio (Core ML, runs on the Mac): 15–18% on AMI, and 10.4% with its
    offline "VBx" clustering on one test file.
- **Call compression hurts:** low-bitrate codecs measurably raise error rates.
  No published study covers Zoom specifically, so we have to measure it.

**What Grove has that those benchmarks don't:**
- **Your own voice is already separate.** Your microphone is a separate stream,
  so only "Them" needs splitting.
- **The calendar says how many people are on the call.** A known speaker count
  is one of the biggest single improvements for these systems.
- **Each remote person speaks into their own microphone.** That is cleaner than
  the room recordings used in AMI.
- **You confirm voices.** Once you've confirmed a voice ("that's Priya"), it
  becomes *identification against known people* rather than open-ended
  splitting. Research on enrolled-speaker detection (personal VAD, TS-VAD)
  consistently shows that is the easier, more accurate problem.

**Estimates.** Share of speaking time credited to the right person, to be
replaced by real measurements in phase 0:

| Meeting | Before you label anyone | After you label voices once |
|---|---|---|
| 1:1 | ~100% | ~100% |
| 2–4 others | 85–92% | 92–97% |
| 5–6 others | 78–88% | 88–93% |
| 7+ others, crosstalk, one shared room mic | 70–80% | not attempted, see below |

---

## 2. The "who's speaking?" prompt

Your idea, made concrete:

1. **When recording starts**, Grove reads the calendar invite's attendees. It
   only uses the prompt when there are **2–6 other people** (adjustable). Above
   that, voiceprints aren't reliable enough to be worth interrupting you.
2. **While recording**, every few seconds of "Them" audio becomes a voiceprint.
   Voiceprints are grouped live.
3. **When a new group has about 8 seconds of speech**, Grove first checks it
   against voices it already knows.
   - If it confidently matches someone in the invite, it labels them silently.
   - If not, a small pill appears beside the recording pill:

     > **Who's talking?** ○ Priya ○ Marcus ○ Janet ○ Someone else
     > *(goes away on its own after 15 seconds)*

4. **One click** labels that voice for the rest of the meeting and saves it to
   your local voice library. Next time Priya is on a call, nobody is asked.
5. **Limits:** at most one question per new voice and at most 5 per meeting.
   Never while you are typing in quick notes.
6. **Anything not labelled** is marked "Speaker 2" and so on. You can rename it
   afterwards from the transcript, and the new name applies to every line from
   that voice.

**Privacy:** voiceprints are lists of numbers, not audio. They are stored in
`~/Documents/Grove/.grove/voices.json`, never leave the Mac, and can be deleted
per person in Settings.

---

## 3. Making voiceprints more accurate

These are research-backed techniques, in the order to try them. Each is kept
only if it improves the phase 0 measurements.

1. **Pick the embedding model by measurement, not reputation.** Candidates:
   - CAM++ (small; a Core ML build already exists)
   - WeSpeaker ResNet
   - ReDimNet, which degraded least under audio codecs in a 2025 Interspeech
     study

   Test each on our own recorded calls.
2. **Use the calendar's speaker count** as a cap on how many groups the
   clustering may form.
3. **Enrol from confirmed audio.** Once you've confirmed a voice, average
   several confirmed clips into one centroid. Keep refining it during the
   meeting from confident matches; a 2026 paper on short enrollments got close
   to full-enrollment accuracy this way.
4. **Run a second, offline pass when the meeting ends** (VBx clustering over
   the whole recording). Live grouping is greedy; the offline pass fixes its
   mistakes. FluidAudio's own numbers show this cutting errors by about a
   third.
5. **Don't build voiceprints from very short segments.** Ignore clips under 1
   second ("yeah", "right") and give them the label of the surrounding
   speaker.
6. **Calibrate the "same person" threshold** from your labelled meetings,
   rather than using a published default.
7. **Treat overlapping speech separately.** Keep clips where two people talk
   at once out of the voice library entirely.
8. **Use the language model for naming hints only.** Cues like "Thanks,
   Priya" can suggest an answer for the prompt, but never override a voice
   match.

---

## 4. Bring your own AI

### What's possible today

- **Sign in with ChatGPT** exists, but OpenAI's own documentation describes it
  as a limited trial for selected partners with a waitlist. We would apply,
  and build it once accepted.
- **Signing in with a Claude plan is not an option.** Anthropic's terms, as
  updated in February 2026 and reported widely, say third-party apps may not
  offer Claude.ai login or use people's Pro or Max plans. Apps that appear to
  do this (YAB is described as using Claude plans) are taking a risk Grove
  should not take. Claude through an **API key** is fine.
- **API keys** work today with every provider: Anthropic, OpenAI and Google
  Gemini.
- **Local larger models** through Ollama or LM Studio keep everything on the
  Mac. This option fits Grove's promise best.

### Design

- Grove already has a `NoteWritingModel` seam. Each provider becomes one more
  engine behind it, so prompting, chunking and the refusal floor don't change.
- **Settings → AI** offers:
  - Apple on-device (the default)
  - Local model (Ollama or LM Studio; Grove finds them if installed)
  - OpenAI, Anthropic or Gemini with your API key, stored in the Keychain
  - Sign in with ChatGPT, once approved
- **"Rewrite with…"** on any saved meeting regenerates its notes with a
  different engine. The original notes are kept so you can compare.
- **Per-feature choice:** for example, Apple on-device for live work and
  Claude for the final write-up.
- **Honesty in the interface:** every cloud engine is clearly labelled "sends
  the transcript to <provider>". The default never changes without the user
  choosing.

---

## 5. Phases

| Phase | What | Size | Needs your Mac for |
|---|---|---|---|
| **0. Measure** | Keep "Them" audio until processing finishes (plus an opt-in "keep recordings" setting); `grove speakers` command; you record 3–5 real calls and mark who spoke; scoring script | S | Recording the test calls |
| **1. Speaker labels after the meeting** | Add FluidAudio (or sherpa-onnx if it measures better); split speakers using the attendee count; offline VBx pass; "Speaker 2" labels in the transcript; click to rename; names flow into chat and notes | M | Accuracy runs |
| **2. Who's speaking prompt** | Live voiceprints; the prompt for 2–6 attendees; voice library; silent auto-labelling of known voices; Settings → Voices to delete | M | Real calls |
| **3. Accuracy push** | Techniques 1–8 above, each kept only if it measurably helps; threshold calibration | M | Re-running the labelled calls |
| **4. Bring your own AI** | Provider engines (local, OpenAI, Anthropic, Gemini via API key); Rewrite with…; per-feature choice; apply for Sign in with ChatGPT | M | API keys you choose |
| **Backlog** | Reminders before meetings, drafted follow-up emails to attendees, Notion and Slack export, in-person rooms with several people on one mic | — | — |

**Order:** 0 → 1 → 2, with 3 woven in as measurements arrive. Phase 4 is
independent and can run in parallel at any point.

## 6. Decisions

1. **Recordings — decided:** offer "Keep recordings". It is off by default,
   with automatic deletion after 30 days when on. Recordings are saved
   compressed (AAC, about 15–30 MB per hour), not as raw audio (about 1 GB per
   hour). Settings shows the total space used, with a "Delete all recordings"
   button.
2. **Size limit for the prompt — decided:** 6 other attendees, adjustable once
   phase 0 measurements say whether it should move.

Still open:

3. **Cloud AI:** allowed as opt-in, given CONTRIBUTING.md currently promises
   "no network calls for AI"? If yes, update that file to say "on-device by
   default; cloud only when you choose it".
4. **Model licences:** the pyannote-derived Core ML models are CC BY 4.0,
   which requires attribution in the About screen. Confirm that's acceptable.
   The FluidAudio code itself is Apache 2.0.

---

## Shipped since: clarity and finding things

Built: meeting insights (summary, decisions, commitments, questions, terms),
people pages, decision log with "replaced by", waiting on, open questions,
glossary, ⌘K command bar, plain-English search, Spotlight, summary line per
meeting, "From last time" carry-over, changes since last time, recurring
folder and template, deadline reminders, off-the-record shortcut, copy as
quote, Friday digest email.

Not yet:

- **Flag uncertain words.** This needs per-word confidence from the speech
  analyser threaded through the transcript format.
- **Notes written into the calendar event.** This needs the
  `calendar.events` write scope, so every user would be asked for consent
  again.
