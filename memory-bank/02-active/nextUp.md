# Next Up

**Last Updated:** 2026-01-09

## Immediate (next session)
1. **Test Dual-Pass System** — P0, implementation complete, needs testing (yap-dual-pass)
   - Build and run app with dual-pass ASR
   - Verify both models load (streaming + batch)
   - Test transcription quality (punctuation, capitalization, accuracy)
   - Benchmark latency (target <200ms for batch processing)
   - Evaluate UX (is text replacement smooth or jarring?)
   - Monitor memory usage with both models loaded

## Soon (next few sessions)
- **Further accuracy improvements** — P2, good but not perfect (yap-320m)
  - Monitor FluidAudio for streaming TDT support (600M params)
  - Consider dual-pass approach (stream EOU 120M → batch TDT 0.6b)
- Custom vocabulary support (Swift port from Python) (yap-ac58)
- First-run experience / onboarding
- App notarization for distribution (yap-a4df) — only needed if distributing publicly

## Later
- Speaker identification (port from Python)
- Liquid glass overlay (macOS 26 feature)
- Bottom bar ticker mode
- Hallucination filtering

## Recently Completed
- ✓ **Dual-pass ASR implemented** (2026-01-09 evening) — stream + batch refinement with punctuation (yap-dual-pass)
- ✓ **TDT punctuation verified** (2026-01-09) — Parakeet TDT outputs punctuation natively
- ✓ Race condition crash fixed (2026-01-09) — actor-based buffer queue (yap-e049)
- ✓ 320ms chunk upgrade (2026-01-09) — improved accuracy from ~8-9% to ~5.73% WER (yap-320m)
- ✓ Permission/input issue resolved (2026-01-09) — proper .app bundle implementation
- ✓ Accuracy research completed (2026-01-09) — surveyed larger models, punctuation approaches
