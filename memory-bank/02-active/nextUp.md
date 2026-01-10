# Next Up

**Last Updated:** 2026-01-09 (evening)

## Immediate (next session)

1. **Code Cleanup & Consolidation** — P1 (yap-cleanup)
   - Remove/disable failed Ollama LLM refinement code
   - Remove unused dual-pass audio components (BatchProcessor, TextRefinementManager)
   - Clean up TextEditCommand infrastructure (built but unused)
   - Consolidate on working pattern: pure streaming transcription
   - Document what worked vs what didn't

2. **Current System Validation** — P1 (yap-streaming)
   - Validate pure streaming-only approach in real usage
   - Confirm this is the right direction vs post-processing
   - Streaming ASR quality: ~5.73% WER, good enough without refinement?

## Future Exploration (not urgent)

3. **On-the-fly Re-editing UX** — P3, interesting but not easily forthcoming (yap-live-edit)
   - Concept: Continuous text refinement during streaming (not after)
   - Challenge: Complex to implement, unclear UX benefit
   - Pause until clearer path emerges
   - Components built (unused): TextEditCommand, DiffGenerator, EditApplier

## Learnings from Today

**What Worked:**
- ✅ Pure streaming transcription (fast, accurate, simple)
- ✅ 320ms chunking with actor-based queue (stable, ~5.73% WER)
- ✅ Proper .app bundle for permissions

**What Didn't Work:**
- ❌ Dual-pass audio refinement: Added UX lag (visible backspace/retype), sometimes worse transcription than streaming
- ❌ Ollama LLM text refinement: Integration issues, didn't trigger reliably, added complexity
- ❌ Text-based surgical editing: Too complex for unclear benefit

**Key Insight:** Streaming transcription is already quite good; post-processing adds complexity and latency without clear wins.

## Recently Completed
- ✓ **Pure streaming-only mode** (2026-01-09 evening) — Disabled all refinement, back to basics
- ✓ **Ollama LLM integration attempted** (2026-01-09 evening) — Built but didn't work reliably
- ✓ **Dual-pass audio tested** (2026-01-09 evening) — Worked but caused regressions
- ✓ **TextEditCommand infrastructure** (2026-01-09 evening) — Built for surgical editing (unused)
- ✓ **320ms chunk upgrade** (2026-01-09) — Improved accuracy to ~5.73% WER
- ✓ **Permission/input issue resolved** (2026-01-09) — Proper .app bundle
