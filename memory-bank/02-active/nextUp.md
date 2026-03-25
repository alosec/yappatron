# Next Up

**Last Updated:** 2026-03-24

## Next Priority

1. **Real-time character-level streaming** — P1
   - Currently text appears in sentence-level chunks (is_final segments only)
   - Goal: character-by-character streaming while speaking
   - Backspacing approach tried extensively — doesn't work with Deepgram's interim revisions
   - Ideas: stable prefix of interims, word-level confidence, hybrid approach
   - This is the #1 UX improvement to chase

2. **Hot-swap backends without restart** — P2

3. **Add Soniox as third backend** — P3
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
- ✓ **Forward-only chunk streaming** (2026-03-24) — is_final segments typed, interims for orb only
- ✓ **EOU timing tuned** (2026-03-24) — Multiple rounds of tuning, landed on 1500ms/2500ms
- ✓ **Deepgram Nova-3 cloud STT** (2026-03-24) — Full WebSocket integration
- ✓ **Pluggable STTProvider architecture** (2026-03-24) — Swappable backends via protocol
