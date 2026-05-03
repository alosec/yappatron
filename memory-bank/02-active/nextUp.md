# Next Up

**Last Updated:** 2026-05-02

## TOP PRIORITY (next session)

**Test iPhone Local mode** — P0
- Current state: Yappatron is installed and launches on a connected test iPhone via free Personal Team signing.
- Local mode is now implemented with Apple's on-device Speech framework and is the default backend.
- Goal: Verify that recording on iPhone produces a transcript without a Deepgram key.
- Validation: grant microphone/speech permissions, record on iPhone, see transcript appear, then enable keyboard and insert transcript into another app via the Yappatron keyboard.
- If Apple Speech is not good enough, evaluate FluidAudio/Parakeet iOS/Core ML integration next.

## Other Priorities

1. **Voice isolation in noisy environments** — P1
- GitHub issue: https://github.com/alosec/yappatron/issues/1
- Problem: In cafes/hallways/meetings, Yappatron picks up background voices and pollutes the user's dictation
- Goal: Only transcribe the primary speaker (the user), filter out everyone else
- Approaches to evaluate:
  1. Speaker enrollment + voice print matching (local model: pyannote, SpeechBrain ECAPA-TDNN)
  2. Deepgram diarization + filter by speaker ID
  3. Apple's Voice Processing audio unit (AVAudioEngine built-in)
  4. Hybrid: VAD + speaker verification per chunk
- Open questions: enrollment vs auto-detect? Strictness? Toggle on/off?
- Pairs well with future diarization/meeting-mode features

2. **Enable/test iOS type-anywhere keyboard flow** — P1
   - On iPhone: Settings > General > Keyboard > Keyboards > add Yappatron Keyboard
   - Turn on Allow Full Access so the keyboard can read the Yappatron-tagged pasteboard item
   - Test insertion in Notes/Messages/Claude/etc.
   - Note: third-party keyboards are unavailable in secure text fields and some restricted inputs

3. **Normal Xcode/iOS platform completion** — P2
   - Current ASAP install bypassed `Assets.xcassets` at build time because `actool` complained about missing simulator runtimes.
   - Finish Xcode's iOS 26.4 platform/runtime component later so normal Xcode Run uses app icons and standard destinations.

4. **Real-time character-level streaming** — P2
   - Currently text appears in sentence-level chunks (is_final segments only)
   - Goal: character-by-character streaming while speaking
   - Backspacing approach tried extensively — doesn't work with Deepgram's interim revisions
   - Ideas: stable prefix of interims, word-level confidence, hybrid approach

5. **Speaker diarization for meeting mode** — P3
   - Add `diarization=true` to Deepgram params
   - Format output with speaker labels (Alex: ..., Speaker 2: ...)
   - Voice trigger for naming ("Hey Yappatron, this is Alex")
   - Different output target than dictation (file/window vs keystroke sim)

6. **Hot-swap backends without restart** — P3

7. **Add Soniox as third backend** — P3
   - $0.12/hr — long-term cost alternative after Deepgram free credits expire

## Monitoring

- **Deepgram WebSocket stability** — Watch for disconnects
- **EOU timing** — Currently endpointing=1500ms, local timer=2500ms, speech_final disabled

## Validation Status

- ✅ **is_final chunk streaming** (2026-03-24) — "pretty fucking great", clean forward-only typing, no backspacing
- ✅ **Deepgram Nova-3** (2026-03-24) — "almost too fast and too good", "incredible UX"
- ✅ **Orb decoupled from typing** (2026-03-24) — Interims trigger orb, only finals type

## Key Learnings (2026-03-24 session)

- Deepgram interims revise aggressively — any diffing/backspacing approach causes text loss
- `utterance_end_ms` is not a valid Deepgram streaming param (causes HTTP 400)
- `speech_final` cuts users off mid-thought — disable it, use silence timeout only
- URLSessionWebSocketTask works with auth headers despite initial concerns
- Keychain doesn't work well with ad-hoc signed apps — use UserDefaults for API keys
- The right streaming architecture: is_final only for typing, interims for speech detection

## Recently Completed
- ✓ **iPhone app installed and launched** (2026-05-02) — Free Xcode Personal Team, Developer Mode, trusted profile
- ✓ **Local iOS transcription mode** (2026-05-02) — Apple on-device Speech framework, Local default, Deepgram optional
- ✓ **Free-device iOS bridge** (2026-05-02) — Removed App Group entitlement, replaced with Yappatron-tagged local pasteboard item
- ✓ **iOS custom keyboard extension scaffold** (2026-05-02) — Inserts latest transcript with `textDocumentProxy.insertText`
- ✓ **Forward-only chunk streaming** (2026-03-24) — is_final segments typed, interims for orb only
- ✓ **EOU timing tuned** (2026-03-24) — Multiple rounds of tuning, landed on 1500ms/2500ms
- ✓ **Deepgram Nova-3 cloud STT** (2026-03-24) — Full WebSocket integration
- ✓ **Pluggable STTProvider architecture** (2026-03-24) — Swappable backends via protocol
