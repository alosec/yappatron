# Next Up

**Last Updated:** 2026-05-24

## TOP PRIORITY (next session)

### Deepgram partial latency — P0

Deepgram finalization is now much faster after the 2026-05-24 tuning
pass. The next slice is partial display speed. First likely lever:
Mac mic capture and iOS capture both use 4096-frame AVAudioEngine taps,
which is coarse for realtime partials. Evaluate lowering capture chunk
size toward the 20-100ms streaming range, then compare partial arrival
time without destabilizing final EOU behavior.

### iPhone efficacy and usability — P0

After the Mac diarization suffix cleanup, return to iOS. The iPhone app
is the best near-term path for live conversations where the Mac app
cannot listen, especially FaceTime scenarios where the Mac-side mic
stream is unavailable.

Immediate focus:
- Real-device validate the new minimal iOS listening surface and
  Deepgram speech-gated flow: quiet armed state should stay calm, speech
  should flip visibly active, EOU should finalize/send once, and quiet
  time should not continuously stream silence to Deepgram. First live
  tuning pass is shipped: onset flips faster and final submit now waits
  longer by default, but this should still be tested under normal
  conversation pacing.
- Real-device validate the new iOS webhook shape: stable text streams
  during speech, EOU submits only the missing remainder plus suffix, and
  diarized speaker labels appear after the utterance in Mac style.
- Verify the remote relay receives `append_text` payloads, pastes stream
  deltas immediately, and preserves legacy final-only payload behavior.
- Add clearer pending/queued/sent/failed state if the current feed still
  feels too opaque after device testing. A first transcript/history sheet
  exists now; next pass should decide whether it needs search, export, or
  a clearer per-destination status model.
- Harden keyboard and webhook delivery semantics around duplicates and
  visible failure.
- Validate the current Deepgram EOU policy on device. If `speech_final`
  is too aggressive for chat-bound destinations, prefer `UtteranceEnd`,
  explicit stop/finalize, or a longer destination-specific silence
  debounce.
- Tune issue #5 thresholds after broader real-device testing: current
  local speech gate uses adaptive RMS start/continue thresholds plus
  pre-roll. It worked better in the first iPhone test, but noisy rooms
  and far-field speech still need validation.
- Continue research on real-time meeting transcription / agent routing
  tools to decide whether Yappatron stays a dictation layer, becomes a
  Granola-like live conversation transcript, or later needs first-party
  voice calls.

### Validate input focus lock hardening — P1

Input focus locking MVP and first UX hardening pass shipped on 2026-05-11. The hardening pass addressed the first live-test gaps: visible lock state, shortcut fallback, recent-input menu locking, continuous bottom-line indicator, and a Codex auto-enter timing improvement.

Follow-up items:
- Smoke-test `⌃⌥⌘L` plus the local/global monitor fallback in Codex and other target apps.
- Verify the locked-window outline tracks window moves/resizes and behaves correctly on multiple displays.
- Re-test `Press Enter After Speech` in Codex after the new pre-Return settle delay.
- Consider click-to-lock only if hotkey + recent-input menu locking still feel unreliable.

Pairs naturally with the broader "build this into the agent product" plan — once the typing destination is stable, dictating into an agent session is robust.

## Other Priorities

1. **Auto-clear speaker rename map on new session** — P1
   - Mom's foot-gun: today's "Mom" mapping persists into tomorrow's "Callie" conversation
   - Auto-clear on transcription start, OR add a prominent "new session" menu action

2. **Confirm local Parakeet backend works under FluidAudio 0.14.4** — P1
   - We bumped the dep and updated the two API call sites; release builds clean but local mode hasn't been smoke-tested under the new version
   - Quick verification: enable Local backend, dictate, confirm transcript is correct

3. **Model currency check (research done 2026-05-08)** — P1
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

4. **Ensemble diarization** — P2
   - Deepgram + local segmentation as parallel signals, vote per word
   - Local identity (FluidAudio embedding) remains the source of truth for who
   - Cost: continuous local diarization in real time
   - Benefit: catches mid-sentence speaker changes Deepgram misses
   - Only worth doing if hard-mode quality on Deepgram alone proves insufficient for the agent product use case

5. **Append-only typing smoke test** — P2
   - 2026-05-24 Mac code now has no delete-key text correction path; retest
     a correction-heavy Deepgram session after the rebuilt app is installed.
   - If visible rewriting remains, suspect target-app selection replacement
     or paste fallback behavior rather than Yappatron sending backspace.

6. **Retroactive rename rewriting** — P3
   - Open question whether reaching back to edit already-typed text is worth the engineering vs. just typing forward and cleaning up post-session

7. **iPhone validation backlog** — P2
   - First-run Local-mode test on device after the 2026-05-11 recognition-task restart patch
   - Deepgram endpointing test: confirm chunks now land at complete-thought boundaries, not every short final fragment
   - Type-anywhere keyboard flow: confirm queued chunks insert in order and no earlier utterances are dropped
   - Spokenly-style keyboard dictation flow: tap `Start Dictation`, launch Yappatron, start recording, swipe back, and confirm live transcript deltas stream into the active input
   - Treat keyboard-to-app launch as best-effort until proven otherwise on device; if iOS blocks the launch, keep the honest flow as "start listening in Yappatron, then swipe back"
   - Confirm checkmark finish does not duplicate finalized chunks after live streaming has already inserted them
   - Re-test the latest keyboard bridge patch: finalized chunks should now backfill missed live text instead of being marked consumed during recording
   - If keyboard shows `Allow Full Access for live dictation`, enable Full Access for the Yappatron keyboard and retest the named/general pasteboard bridge
   - Trust the refreshed Personal Team profile on device if direct launch is blocked after install
   - Eventually a paid Apple Developer Program path with App Group entitlement for cleaner companion-app/keyboard sharing

8. **Hot-swap backends without restart** — P3
9. **Real-time character-level streaming** — P3
10. **Add Soniox as third backend** — P3

## Recently Completed

- ✓ **Input focus locking MVP shipped** (2026-05-11) — capture focused input via Accessibility, lock/unlock affordance, route partial/final/refinement typing through locked destination, pause if target disappears
- ✓ **Input focus lock UX hardening shipped** (2026-05-11) — locked-window outline, recent-input menu locking, `⌃⌥⌘L` plus key-monitor fallback, continuous bottom-line indicator style, Codex auto-enter settle delay
- ✓ **RMS-reactive bottom indicator validated** (2026-05-11) — live test confirmed the continuous bar now stays calm on silence and responds correctly to speech amplitude
- ✓ **iOS keyboard dictation UX pass** (2026-05-11) — URL handoff from keyboard to app, live dictation state bridge with stale-state heartbeat, live delta insertion into active input, checkmark stop/commit, and simplified main app
- ✓ **iOS webhook append_text refactor** (2026-05-14) — stable text deltas stream during speech, EOU sends a suffix/submit final payload, and diarized labels are suffixes matching the Mac app's append-only model
- ✓ **iOS quiet/active listening UI + Deepgram speech gate** (2026-05-14) — main screen rebuilt around quiet/active/finalizing/sending phases, with settings moved behind the gear and Deepgram opened only after local speech onset
- ✓ **Mac backspacing removed** (2026-05-24) — typing updates are append-only; delete-key helpers removed; divergent recognition corrections no longer rewrite the active input or advance typed-state tracking
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
