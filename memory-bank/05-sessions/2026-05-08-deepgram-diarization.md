# 2026-05-08 Deepgram Diarization Session

## Goal

Add speaker labels to dictation output so two-person conversations type as `[Alex] ... [Callie] ...` directly into the focused app. Driven by an upcoming working session where the dictation surface is a Claude Code chat — Claude needs to know who said what to be a useful real-time partner.

The bigger picture: this is intended as a core foundation for additional product surfaces. "Works in easy mode only" is not acceptable as a long-term answer; the system needs to hold up in real-world conversational conditions.

## Approach Chosen

Deepgram-side diarization with a manual menu mapping from speaker IDs to names. No voice enrollment, no embeddings, no pre-STT audio gating in the first pass.

- Turn on Deepgram's `diarize=true`
- Parse word-level `speaker` integers out of the WebSocket response
- Group consecutive same-speaker words into runs
- In the engine, prepend `[Name]` on every utterance and on every within-utterance speaker change, where `Name` comes from a UserDefaults map (defaults to `Speaker N`)
- Existing forward-only keystroke pipeline is unchanged downstream — the labeled string flows through the same `onTranscription` path as plain dictation

## Line Break Styles

Added a `LineBreakStyle` setting persisted in UserDefaults with three options, exposed via a "Line Breaks Between Speakers" submenu under Speaker Labels:

- `none` — inline brackets, single line. Compact, terminal-safe.
- `newline` — plain `\n` between turns. Best for TextEdit, Notes, plain text fields.
- `claudeCode` — `\` + `\n` between turns. Targets Claude Code's `\<Enter>` soft-line-break input convention so dictated multi-speaker transcripts render as multi-line prompts in the chat.

Implemented as a string separator inserted in `formatLabeled`; no separate keystroke callbacks needed. Both newlines and the backslash + newline sequence pass through the existing `applyTextUpdate` diff/typing pipeline as ordinary characters.

## Always-Label Every Utterance

Initially `formatLabeled` carried `lastLabeledSpeakerId` across utterances and suppressed the label when the speaker hadn't changed. In testing this read as broken — solo dictation produced one label and then a wall of unlabeled text, and any reader (or LLM) downstream couldn't attribute later lines.

Reworked so every utterance always leads with `[Name]`. Within an utterance, consecutive same-speaker runs still don't re-label (no `[Alex] [Alex] [Alex]` spam). `lastLabeledSpeakerId` is now used only to decide whether to insert a leading line-break separator at the start of a fresh utterance.

## What Was Considered And Rejected

- Resurrecting the `feature/speaker-registry` branch (FluidAudio embedding gate). Failed open in a YouTube test; debugging it would have been a detour. PTT already covers personal isolation.
- Building a separate "meeting mode" window with a transcript view. Cut — the Claude Code chat IS the transcript surface, no second window needed.
- Local-backend (Parakeet) support for speaker labels. Out of scope; meeting use case is cloud-only.

## Files Changed

- `[C] Sources/SpeakerLabelMap.swift` — UserDefaults-backed `[Int: String]` map, seen-IDs tracker, `enabled` flag, `lineBreakStyle`, helpers, plus the `LineBreakStyle` enum
- `[M] Sources/STTProvider.swift` — added `onDiarizedFinal: (([(speakerId: Int, text: String)]) -> Void)?`
- `[M] Sources/DeepgramSTTProvider.swift` — added `diarize=true` query param, parses `alternatives[0].words[].speaker`, accumulates runs across `is_final` segments, emits at EOU/UtteranceEnd alongside `onFinal`
- `[M] Sources/LocalSTTProvider.swift` — protocol conformance stub for `onDiarizedFinal`
- `[M] Sources/TranscriptionEngine.swift` — captures runs, formats `[Name] ` prefixes on every utterance, inserts line-break separator on speaker change, tracks `lastLabeledSpeakerId` for cross-utterance separator decisions
- `[M] Sources/YappatronApp.swift` — "Speaker Labels (Diarization)" toggle, "Line Breaks Between Speakers" submenu, "Name Speakers" submenu (Deepgram only); rename via NSAlert with text input; "Reset All Names"; `selectLineBreakStyle` action
- `[M] Package.swift` — bumped FluidAudio 0.9.1 → 0.14.4 (see toolchain note)

## Toolchain Note

Local Swift toolchain advanced to 6.3.1 since the last Mac build. FluidAudio 0.9.1 fails to compile under 6.3 with `SendingRisksDataRace` errors in `StreamingAsrManager.swift`. Bumped FluidAudio to 0.14.4. Two API call sites needed updating:

- `LocalSTTProvider.loadModels(modelDir:)` → `loadModels(from:)`
- `BatchProcessor`: `AsrManager()` + `manager.initialize(models:)` collapsed into `AsrManager(config:models:)`; `transcribe(_, source: .system)` → `transcribe(_, decoderState: &state)` with a cached `TdtDecoderState` on the actor

Both debug and release builds clean. Local backend behavior unchanged from a public-API standpoint, but not yet smoke-tested under the new FluidAudio version.

## Test Results

### Easy mode (quiet indoor, two speakers, taking turns)

Works. Two participants, alternating turns, no overlap, clean room mic. Speaker IDs stayed stable across most of the session, renaming Speaker 0 → Alex and Speaker 1 → Mom held throughout, mis-attribution rate roughly 5–10% on the boundary words of turn changes. Output is genuinely usable as a transcript. The line-break Claude Code style produced clean multi-line input formatting suitable for piping into a chat session.

### Hard mode (outdoor, 3+ speakers, ambient power tools, water running, overlap)

Diarization quality degrades significantly under realistic stress conditions:

1. **ID fragmentation.** Single physical speakers split across 2–4 IDs (e.g., mom showed up as Speakers 1, 2, 3, and 4 within the same conversation). Recoverable via the rename UI by mapping all observed IDs for a given person to the same display name, but this requires the user to chase IDs as they appear.
2. **Cross-speaker contamination.** The harder problem. Some of mom's utterances were tagged with Alex's ID (and vice versa) — meaning the data at the source is wrong, and no amount of rename mapping can fix it because the same ID is now serving two physical people. This is the actual blocker on broader product use.
3. **Over-segmentation under overlap.** Brief simultaneous speech produces phantom IDs that don't correspond to any real speaker.

This is a Deepgram streaming-diarization limitation, not a code-side bug. Their batch API is more accurate than their streaming API, and accuracy is sensitive to per-speaker SNR. AirPods on the user closes the gap considerably (close-mic the user, room-mic everyone else), but "wear AirPods" is not a viable product answer for end users.

## Identified Followup Architecture: Hybrid Diarization

The right long-term path is layering local speaker-print embeddings on top of Deepgram's word-level IDs as a sanity check, not as a gate. Deepgram does the heavy lifting (transcription + initial speaker IDs); a FluidAudio-style local embedding pass runs alongside, and when Deepgram's ID disagrees with the embedding match, the embedding wins. This addresses cross-speaker contamination without throwing away Deepgram's strengths.

This is the path discussed and skipped earlier in the session in favor of getting something shipped fast. The skip was correct for the demo; the rebuild is correct for the product. Estimated work: half a day to a day, with real design decisions around enrollment vs auto-clustering, embedding window length, override thresholds, and how to update IDs already typed (or not) when the embedding pass disagrees retroactively.

## Status

- Build: passes (debug + release)
- Install: `./scripts/run-dev.sh` produces and launches `/Applications/Yappatron.app`
- Diarization: live on Deepgram backend
- Easy-mode validation: passed
- Hard-mode validation: documented failure modes, not yet addressed

## Known UX Quirks

- The "Name Speakers" submenu only populates after at least one diarized final has been observed (seen-IDs are recorded on the fly). Empty until the user starts talking.
- Renames are forward-only — already-typed text doesn't get rewritten when an ID gets re-mapped. Mom suggested retroactive rewrite during the test; not implemented because the typing pipeline is forward-only into a focused app and reaching back to edit prior output would require selection / replacement gymnastics.
- Backspacing behavior on labeled output is the same as today's pipeline. Flagged as disliked but not addressed in this session.

## Followups

- Hybrid Deepgram + local embedding diarization (the real fix for cross-speaker contamination)
- Confirm local backend still works under FluidAudio 0.14.4 (smoke test pending)
- Output piping to a fixed destination regardless of focused app (separate work item brought up during testing — would let dictation always go to a chosen window/file rather than wherever the cursor is)
- Retroactive rename rewriting of already-typed transcript (open question whether this is worth the engineering)
- Try Deepgram model/diarize_version variants to see if any tuning helps streaming diarization quality before investing in the hybrid layer
