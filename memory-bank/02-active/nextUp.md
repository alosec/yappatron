# Next Up

**Last Updated:** 2026-03-24

## Immediate

1. **Investigate ghost text diffing with Deepgram** — P1
   - Deepgram partials may behave differently than Parakeet partials
   - Backspacing/correction UX may need tuning for cloud streaming
   - User reports it may not be working great with Deepgram

2. **Hot-swap backends without restart** — P2
   - Currently requires app restart when switching STT backend
   - Should tear down old provider and create new one on the fly

3. **Add Soniox as third backend** — P3
   - $0.12/hr — cheapest true realtime streaming option
   - Good long-term cost alternative to Deepgram after free credits expire

## Monitoring

- **Deepgram WebSocket stability** — Monitor for disconnects, reconnection handling
- **FluidAudio race condition** — Believed fixed with actor-based queue (Jan 9)

## Validation Status

- ✅ **Deepgram Nova-3** (2026-03-24) — User confirms "almost too fast and too good", "incredible UX", "nice as fuck"
- ✅ **Pure local streaming** (2026-01-09) — "feels natural", "blows other tools out of the water"
- ✅ **Dual-pass refinement** (2026-01-10) — Fixed and working for local mode

## Recently Completed
- ✓ **Deepgram Nova-3 cloud STT** (2026-03-24) — WebSocket streaming, punctuation, smart formatting
- ✓ **Pluggable STTProvider architecture** (2026-03-24) — Swappable backends via protocol
- ✓ **API key management** (2026-03-24) — UserDefaults storage, menu bar UI
- ✓ **Fixed utterance_end_ms param** (2026-03-24) — Was causing HTTP 400 on WS handshake
- ✓ **Dual-pass accuracy fixes** (2026-01-10) — Audio buffer timing bug fixed
- ✓ **Orb animations** (2026-01-09) — Voronoi Cells + Concentric Rings
