# Next Up

**Last Updated:** 2026-05-11

## TOP PRIORITY (next session)

### Input focus lock UX hardening — P0

Input focus locking MVP shipped on 2026-05-11, but the first live test showed UX gaps that should be addressed before treating it as solid.

Follow-up items:
- Fix or replace the current lock hotkey. The shipped shortcut did not appear to trigger in the live test; likely causes include shortcut conflict, global registration failure, or stale app process confusion.
- Add a visual outline around the locked window whenever a lock is active.
- Add explicit lock/unlock success/failure feedback so the user is never guessing whether Yappatron captured the target.
- Consider a click-to-lock or menu-listed recent-input flow if hotkeys remain unreliable.

Pairs naturally with the broader "build this into the agent product" plan — once the typing destination is stable, dictating into an agent session is robust.

## Other Priorities

1. **Codex auto-enter bug** — P1
   - User observed that "Press Enter After Speech" does not seem to work reliably in Codex.
   - Spelled Codex. Do not file as "codecs."
   - Investigate whether this is due to Codex's input surface, paste fallback timing, focus restoration, or Enter being sent before Codex accepts the inserted text.

2. **Bottom-line indicator option** — P1
   - Add an option for the indicator to be a line along the bottom of the active display instead of the floating psychedelic orb.
   - Should track the active display and stay out of the way during overlay-assistant workflows.

3. **Auto-clear speaker rename map on new session** — P1
   - Mom's foot-gun: today's "Mom" mapping persists into tomorrow's "Callie" conversation
   - Auto-clear on transcription start, OR add a prominent "new session" menu action

4. **Confirm local Parakeet backend works under FluidAudio 0.14.4** — P1
   - We bumped the dep and updated the two API call sites; release builds clean but local mode hasn't been smoke-tested under the new version
   - Quick verification: enable Local backend, dictate, confirm transcript is correct

5. **Model currency check (research done 2026-05-08)** — P1
   - Currently using `StreamingEouAsrManager` with `parakeetEou320` (EOU 120M). FluidAudio 0.14.4 we're on is itself current.
   - Available upgrades within FluidAudio (no dep bump needed):
     - `StreamingNemotronAsrManager` — NVIDIA Nemotron streaming with encoder cache, 160/320/1600ms chunks. New in 0.13.7. Likely a measurable upgrade in latency / accuracy for English dictation.
     - `SlidingWindowAsrManager` — overlap+cancellation, smoother chunk boundaries.
   - Outside FluidAudio:
     - NVIDIA `parakeet-unified-en-0.6b` (April 2026) — single English model for both offline + streaming with 160ms minimum latency, native punctuation/caps. SOTA fit for dictation; needs CoreML port if not yet wrapped.
     - Moonshine v2 Medium Streaming (Feb 2026) — 107ms latency CPU-only, 26-34MB. Lightweight but less accurate than Parakeet.
     - Apple SpeechAnalyzer / SpeechTranscriber (macOS 26 Tahoe) — "55% faster than Whisper" per Apple, fully on-device, zero deps. Worth a third-backend slot.
   - Suggested first move: drop in `StreamingNemotronAsrManager` as the local backend, A/B against current `StreamingEouAsrManager`. Same package, same install path.
   - WhisperKit is no longer competitive for sub-300ms streaming on Apple Silicon (Parakeet is 2–3x faster).

6. **Ensemble diarization** — P2
   - Deepgram + local segmentation as parallel signals, vote per word
   - Local identity (FluidAudio embedding) remains the source of truth for who
   - Cost: continuous local diarization in real time
   - Benefit: catches mid-sentence speaker changes Deepgram misses
   - Only worth doing if hard-mode quality on Deepgram alone proves insufficient for the agent product use case

7. **Backspacing UX** — P2
   - User flagged as disliked but punted in this session
   - Need to clarify the actual failure mode before iterating

8. **Retroactive rename rewriting** — P3
   - Open question whether reaching back to edit already-typed text is worth the engineering vs. just typing forward and cleaning up post-session

9. **iPhone validation backlog** — P2
   - First-run Local-mode test on device
   - Type-anywhere keyboard flow
   - Eventually a paid Apple Developer Program path with App Group entitlement for cleaner companion-app/keyboard sharing

10. **Hot-swap backends without restart** — P3
11. **Real-time character-level streaming** — P3
12. **Add Soniox as third backend** — P3

## Recently Completed

- ✓ **Input focus locking MVP shipped** (2026-05-11) — capture focused input via Accessibility, lock/unlock affordance, route partial/final/refinement typing through locked destination, pause if target disappears
- ✓ **Hybrid diarization shipped** (2026-05-08) — Deepgram word-level segmentation + local FluidAudio embedding override, 0.45 cosine threshold, 0.3s min run, race-fix for typing waiting on override task
- ✓ **`feature/local-segmenter` branched** (2026-05-08) — experimental local-only diarization preserved off-main; FluidAudio segmentation was coarser than Deepgram's word-level boundaries in real testing
- ✓ **FluidAudio 0.9.1 → 0.14.4** (2026-05-08) — Swift 6.3 toolchain compatibility; updated `LocalSTTProvider.loadModels(from:)` and `BatchProcessor` decoder-state API
- ✓ **iPhone app installed and launched** (2026-05-02) — Free Xcode Personal Team, Developer Mode, trusted profile
- ✓ **Local iOS transcription mode** (2026-05-02) — Apple on-device Speech framework, Local default, Deepgram optional
- ✓ **Forward-only chunk streaming** (2026-03-24) — is_final segments typed, interims for orb only
- ✓ **Deepgram Nova-3 cloud STT** (2026-03-24) — Full WebSocket integration
- ✓ **Pluggable STTProvider architecture** (2026-03-24) — Swappable backends via protocol

## Validation Status

- ✅ **Hybrid diarization easy-mode** (2026-05-08) — quiet 1:1, two enrolled speakers, multi-run utterances cleanly attributed, cosine separation -7 to -9 vs -0.5 makes overrides confident
- ⚠️ **Hybrid diarization hard-mode** (2026-05-08) — 3+ speakers outdoors with ambient noise, fragmentation handled by per-run embedding match, but phantom-speaker noise from overlap remains. Recoverable, not perfect.
- ✅ **is_final chunk streaming** (2026-03-24) — clean forward-only typing, no backspacing
- ✅ **Deepgram Nova-3** (2026-03-24) — "incredible UX"
- ✅ **Orb decoupled from typing** (2026-03-24) — interims for orb, finals for typing

## Key Learnings (2026-05-08 session)

- Deepgram streaming diarization is great at *segmentation* (word-level boundaries) but flaky on *identity* (cross-speaker contamination, ID drift across sessions)
- Local FluidAudio embedding extraction is great at *identity* against an enrolled registry (cosine distances were dramatically separated) but its native segmentation is coarser than Deepgram's
- The right architecture is hybrid: each layer doing what it's better at, no consultation between them — local override blindly looks at audio, then replaces Deepgram's tag if confident
- Audio alignment matters: if the local audio buffer's t=0 doesn't match Deepgram's t=0, every slice is wrong by the offset and the override produces a clean 1:1 flip
- Race conditions matter: `onDiarizedFinal` and `onFinal` both dispatch to main in order, but if the override is async, typing fires before override lands. Engine has to await the override task before emitting
- "Don't pin diarize_version" — Deepgram's parameter is effectively deprecated; default routing gets you the latest improved diarizer
- Going local-only (drop Deepgram diarization entirely) was tested and lost — preserved as `feature/local-segmenter`
- Mom's product instinct ("you don't have to know how to make it blue, AI is making it blue for you") was the line of the night
