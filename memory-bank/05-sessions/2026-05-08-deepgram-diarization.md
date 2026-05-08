# 2026-05-08 Deepgram Diarization Session

## Goal

Add speaker labels to dictation output so two-person conversations type as `[Alex] ... [Callie] ...` directly into the focused app. Driven by an upcoming working session where the dictation surface is a Claude Code chat — Claude needs to know who said what to be a useful real-time partner.

The bigger picture: this is intended as a core foundation for additional product surfaces. "Works in easy mode only" is not acceptable as a long-term answer; the system needs to hold up in real-world conversational conditions.

## Final Architecture (on main)

A hybrid: Deepgram does what it's good at (transcription + word-level speaker segmentation), local FluidAudio embeddings do what they're better at (matching audio against an enrolled-voiceprint registry). The two layers compose without consulting each other.

End-to-end pipeline for one utterance:

1. **Deepgram streams transcription with `diarize=true`** over its WebSocket. Each word comes back with a `speaker` integer, a `start`, and an `end`.
2. **Word-level segmentation by Deepgram.** `DeepgramSTTProvider.appendDiarizedRuns` walks the words and merges consecutive same-`speaker` words into runs. Run boundaries = wherever Deepgram's per-word ID changes. Run timing = first start to last end.
3. **At EOU**, Deepgram emits `onDiarizedFinal` with `[(speakerId, text, startSec, endSec)]` — pre-grouped, timed, but identity not trusted.
4. **TranscriptionEngine slices audio per run** out of a long-lived `StreamAudioBuffer`, which is anchored to Deepgram's t=0 (the moment the first audio buffer was successfully sent to the provider) so its sample indices line up with Deepgram's word timestamps.
5. **HybridDiarizer extracts an embedding per run** via FluidAudio's `extractSpeakerEmbedding`. The embedding is *blind* to Deepgram's speaker ID — it only looks at audio.
6. **Match against the enrolled registry** via cosine distance. If the closest match is below `threshold = 0.45`, that enrolled name overrides Deepgram's ID. Above threshold, Deepgram's ID is kept and the rename UI / "Speaker N" naming applies.
7. **handleFinalTranscription awaits** the override task before emitting, so the typed text reflects the override decisions, not the raw Deepgram IDs (this race was the early "1:1 flipped" bug).
8. **formatLabeled** writes `[Alex] words... [Mom] words...` with optional newline / `\<Enter>` separators between turns, then it goes through the existing forward-only keystroke pipeline unchanged.

Key division of labor:

- **Deepgram → segmentation.** Word-level boundary detection. Empirically much sharper than FluidAudio's 3-second-window-based segmentation in our environment, especially for catching mid-sentence speaker changes.
- **FluidAudio → identity.** Embedding-based matching against enrolled voiceprints. Cosine distances on enrolled audio land around -3 to -9 (well below threshold), so override fires almost every time on runs ≥ 0.3s. Below `minRunSeconds = 0.3s`, runs fall through to Deepgram's ID since short audio produces noisy embeddings.

## Three Modes

The labeling system is layered, and each layer can be turned off:

1. **Speaker Labels OFF.** Original Yappatron behavior. No labels, no diarization processing. Toggle in menu.
2. **Speaker Labels ON, no enrolled speakers.** Deepgram's IDs win. Output is `[Speaker 0] ... [Speaker 1] ...`. The rename UI lets the user map IDs to names per session.
3. **Speaker Labels ON, enrolled speakers exist.** Embedding-based override active. Empty registry = mode 2 behavior, so deleting all enrolled speakers reverts cleanly.

## Line Break Styles

`LineBreakStyle` setting persisted in UserDefaults, exposed via "Line Breaks Between Speakers" submenu:

- `none` — inline brackets, single line. Compact, terminal-safe.
- `newline` — plain `\n` between turns. Best for TextEdit, Notes, plain text fields.
- `claudeCode` — `\` + `\n` between turns. Targets Claude Code's `\<Enter>` soft-line-break input convention so multi-speaker transcripts render as multi-line prompts in the chat.

## Always-Label Every Utterance

Every utterance always leads with `[Name]`. Within an utterance, consecutive same-speaker runs do not re-label (no `[Alex] [Alex] [Alex]` spam). `lastLabeledLabel` is tracked across utterances to decide whether to insert a leading line-break separator on the next utterance.

## What Was Considered And Rejected

- Resurrecting the original `feature/speaker-registry` branch (FluidAudio embedding gate that *blocks* audio pre-STT). Failed open in the YouTube test; debugging that decorator architecture would have been a detour, and PTT already covers personal isolation. The hybrid approach achieves the same goal post-STT, more robustly.
- Building a separate "meeting mode" window with a transcript view. Cut — the Claude Code chat IS the transcript surface, no second window needed.
- Local-backend (Parakeet) support for speaker labels. Out of scope; meeting use case is cloud-only.
- Tuning Deepgram's `diarize_version` parameter. Research confirmed the parameter is effectively deprecated; Deepgram silently rolls improvements into the default diarizer and explicit values route to older models. We're already on the best path.
- Going local-only for both segmentation AND identity (drop Deepgram diarization entirely). Implemented and tested as `feature/local-segmenter`. Local FluidAudio segmentation operates on coarser ~3s windows and was empirically worse than Deepgram's word-level segmentation in our acoustic conditions. Reverted main; experimental work preserved on the branch for later revisit.

## Files Changed (on main)

- `[C] Sources/SpeakerLabelMap.swift` — UserDefaults-backed `[Int: String]` map, seen-IDs tracker, `enabled` flag, `lineBreakStyle`, helpers, plus the `LineBreakStyle` enum
- `[M] Sources/STTProvider.swift` — added `onDiarizedFinal: (([(speakerId: Int, text: String, startSec: Double, endSec: Double)]) -> Void)?`
- `[M] Sources/DeepgramSTTProvider.swift` — added `diarize=true` query param, parses `alternatives[0].words[].speaker`, accumulates runs across `is_final` segments with timing, emits at EOU/UtteranceEnd alongside `onFinal`
- `[M] Sources/LocalSTTProvider.swift` — protocol conformance stub for `onDiarizedFinal`
- `[M] Sources/TranscriptionEngine.swift` — captures runs, slices per-run audio from `StreamAudioBuffer` (anchored to Deepgram's t=0), runs HybridDiarizer override, awaits override task before emitting, formats `[Name] ` prefixes by display label so override-bridged speakers don't re-label mid-stream
- `[C] Sources/SpeakerEnrollment/` — new directory:
  - `SpeakerRegistry.swift` — JSON-backed `EnrolledSpeaker` list at `~/Library/Application Support/Yappatron/enrolled-speakers.json`
  - `SpeakerEmbedder.swift` — actor wrapping FluidAudio's `extractSpeakerEmbedding` with one-time model load
  - `EnrollmentRecorder.swift` — 10s mic capture with its own AVAudioEngine
  - `HybridDiarizer.swift` — per-run override pass; threshold 0.45, min run 0.3s
  - `EnrollSpeakerWindow.swift` — floating SwiftUI window with progress bar
  - `HybridDiagLog.swift` — append-only diagnostic log at `~/Library/Application Support/Yappatron/hybrid-diag.log` showing per-run distances and override decisions
- `[M] Sources/YappatronApp.swift` — "Speaker Labels (Diarization)" toggle, "Line Breaks Between Speakers" submenu, "Name Speakers" submenu (rename via NSAlert), "Enrolled Speakers (Hybrid)" submenu with "Enroll New Speaker…" and per-speaker remove items, "Reset All Names" — all gated to Deepgram backend
- `[M] Package.swift` — bumped FluidAudio 0.9.1 → 0.14.4 (see toolchain note)

## Branches

- `main` — `9e0c205` Lower hybrid diarizer minRunSeconds 0.6 → 0.3
- `feature/local-segmenter` — `cb23a69` experimental local-only diarization architecture; preserved for later evaluation if Deepgram's segmentation regresses or if a cloud-free path becomes necessary

## Toolchain Note

Local Swift toolchain advanced to 6.3.1 since the last Mac build. FluidAudio 0.9.1 fails to compile under 6.3 with `SendingRisksDataRace` errors in `StreamingAsrManager.swift`. Bumped FluidAudio to 0.14.4. Two API call sites needed updating:

- `LocalSTTProvider.loadModels(modelDir:)` → `loadModels(from:)`
- `BatchProcessor`: `AsrManager()` + `manager.initialize(models:)` collapsed into `AsrManager(config:models:)`; `transcribe(_, source: .system)` → `transcribe(_, decoderState: &state)` with a cached `TdtDecoderState` on the actor

Both debug and release builds clean. Local backend behavior unchanged from a public-API standpoint, but not yet smoke-tested under the new FluidAudio version.

## Bugs Hit And Fixed (in order)

1. **No diarization at all.** `diarize=true` param was missing; word-level speaker fields didn't appear in Deepgram responses.
2. **Per-utterance label suppression.** Original `formatLabeled` carried `lastLabeledSpeakerId` across utterances, suppressing labels when the speaker hadn't changed. Reworked to always lead each utterance with `[Name]` and only suppress within an utterance for consecutive same-speaker runs.
3. **1:1 flipped attribution.** Override was confidently labeling Alex's audio as Mom and vice versa. Two compounding causes:
   - **Audio slice misalignment.** `StreamAudioBuffer` was buffering audio that was captured before the Deepgram WebSocket finished its handshake; Deepgram's t=0 didn't match our sample-zero. Fixed by anchoring the buffer to the moment the first audio buffer is *successfully sent* to the provider.
   - **Override race.** Both `onDiarizedFinal` and `onFinal` were dispatched to main in order; `handleFinalTranscription` was emitting the typed text before the async embedding override task had a chance to update `pendingDiarizedRuns`. Fixed by tracking the in-flight override Task on the engine and having `handleFinalTranscription` await it.
4. **Short-utterance fallback was unreliable.** `minRunSeconds = 0.6` was skipping common backchannel utterances ("yeah", "mhm") and falling back to Deepgram's IDs which are flaky on short audio. Lowered to 0.3.
5. **Local-segmenter detour.** Built a full local-only diarizer (`feature/local-segmenter`); FluidAudio's segmentation was coarser than Deepgram's word-level boundaries in our environment. Reverted main, preserved branch.

## Test Results

### Easy mode (quiet indoor, two speakers, taking turns)

After the race fix and audio alignment fix: cosine distances between Alex audio and Alex voiceprint are landing around -7 to -9; against Mom voiceprint around -0.1 to 0.5. Strong separation. Multi-run utterances (e.g., back-and-forth Q&A in one stream) get correctly attributed per-run, including very short turns once `minRunSeconds` was lowered to 0.3.

### Hard mode (outdoor, 3+ speakers, ambient power tools, water running, overlap)

Diarization quality degrades but is recoverable:

1. **ID fragmentation.** Single physical speakers split across 2–4 IDs. Recoverable via the rename UI by mapping all observed IDs for a given person to the same display name; with embedding override active, fragmentation matters less because every run gets matched to the registry directly.
2. **Cross-speaker contamination.** Significantly improved by the override layer — when Deepgram tags Mom's words with Alex's ID, the embedding match correctly attributes them to Mom. Failure modes that remain: short ambiguous runs where neither voiceprint matches confidently (kept Deepgram's ID), and overlapping speech where the audio slice contains both voices.
3. **Phantom speakers from overlap.** Brief simultaneous speech still produces phantom IDs. Override declines low-confidence matches rather than guessing wrong; cost is `[Speaker 3]`-style labels showing up occasionally.

## Identified Followup Architecture: Ensemble

If Deepgram-only-segmentation + local-only-identity isn't enough for harder real-world conditions, the next architectural step is an **ensemble**: use Deepgram's word-level boundaries as one signal, FluidAudio's segment boundaries as another, vote per word. Cost: continuous local diarization in real time. Benefit: corrected segmentation when Deepgram misses a mid-sentence speaker change. Not implemented; on the followup list.

## Known UX Quirks

- The "Name Speakers" submenu only populates after at least one diarized final has been observed (seen-IDs are recorded on the fly). Empty until the user starts talking.
- Renames are forward-only — already-typed text doesn't get rewritten when an ID gets re-mapped. Mom suggested retroactive rewrite during the test; not implemented because the typing pipeline is forward-only into a focused app and reaching back to edit prior output would require selection / replacement gymnastics.
- Backspacing behavior on labeled output is the same as today's pipeline. Flagged as disliked but not addressed in this session.
- Speaker name persistence is global, not per-session. If Speaker 0 = Alex today and Callie joins as Speaker 1 tomorrow, she could get typed as the previous Speaker 1 name. Mom flagged this; mitigation today is "Reset All Names" before a new conversation. Followup: auto-clear on new session.

## Followups

- Auto-clear speaker names on new transcription session (mom's foot-gun)
- Confirm local backend still works under FluidAudio 0.14.4 (smoke test pending)
- Output piping to a fixed destination regardless of focused app (separate work item brought up during testing — would let dictation always go to a chosen window/file rather than wherever the cursor is)
- Retroactive rename rewriting of already-typed transcript (open question whether this is worth the engineering)
- Ensemble diarization (Deepgram + local segmentation, local identity) for hardening hard-mode quality
- Address backspacing UX
