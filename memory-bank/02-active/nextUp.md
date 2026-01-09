# Next Up

**Last Updated:** 2026-01-09

## Immediate (next session)
1. **Explore Continuous Diff-Based Editing** — P1, alternative to current dual-pass (yap-diff-edit)
   - Research text processing models (LLM vs specialized punctuation)
   - Design TextEditCommand API (Navigate, Select, Replace, Insert)
   - Prototype diff generator with simple rules
   - Test command reliability across apps (VSCode, Terminal, Browser, etc.)
   - Compare UX with current audio re-processing approach

2. **Current System Status Quo** — P2, working well but could be tighter (yap-dual-pass)
   - Optional: Make EOU debounce configurable
   - Optional: Add visual feedback for refinement processing
   - Optional: Benchmark exact latency and memory metrics
   - Optional: Implement toggle for fast-only mode

## Soon (next few sessions)
- **Extend InputSimulator** — Required for diff-based editing (yap-input-api)
  - Add navigation primitives (Home, End, Cmd+Arrow)
  - Add selection commands (Shift+Arrow, select word/line)
  - Add replace-selection operation
  - Test across different text input contexts
- Custom vocabulary support (Swift port from Python) (yap-ac58)
- First-run experience / onboarding
- App notarization for distribution (yap-a4df) — only needed if distributing publicly

## Later
- Speaker identification (port from Python)
- Liquid glass overlay (macOS 26 feature)
- Bottom bar ticker mode
- Hallucination filtering

## Recently Completed
- ✓ **Dual-pass ASR tested & validated** (2026-01-09 evening) — "Really quite impressive", UX "really close to exactly what we were hoping" (yap-dual-pass)
- ✓ **Dual-pass ASR implemented** (2026-01-09 evening) — stream + batch refinement with punctuation (yap-dual-pass)
- ✓ **TDT punctuation verified** (2026-01-09) — Parakeet TDT outputs punctuation natively
- ✓ Race condition crash fixed (2026-01-09) — actor-based buffer queue (yap-e049)
- ✓ 320ms chunk upgrade (2026-01-09) — improved accuracy from ~8-9% to ~5.73% WER (yap-320m)
- ✓ Permission/input issue resolved (2026-01-09) — proper .app bundle implementation
- ✓ Accuracy research completed (2026-01-09) — surveyed larger models, punctuation approaches
