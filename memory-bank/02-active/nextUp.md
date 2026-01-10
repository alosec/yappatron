# Next Up

**Last Updated:** 2026-01-09 (late night - post dual-pass implementation)

## Immediate (next session)

1. **Test dual-pass refinement in real usage** — P1
   - Enable "Dual-Pass Refinement (Punctuation)" toggle in menu
   - Test with various dictation scenarios
   - Monitor performance and battery impact
   - Evaluate punctuation quality vs streaming-only mode

2. **Monitor and tune** — P2
   - Watch for any stability issues
   - Consider making EOU debounce configurable
   - Add visual feedback when refinement is processing
   - Profile memory usage over extended sessions

## Monitoring

- **FluidAudio race condition crash** - Believed fixed with actor-based queue and 320ms chunking (Jan 9), but keep an eye out for any recurrence during regular use

## Validation Status

- ✅ **Pure streaming validation** (2026-01-09 evening) - User confirms "feels natural", "wonderful", "blows other tools out of the water"
- ✅ **320ms chunking** - Sweet spot for accuracy and stability
- ✅ **Hands-free UX** - Core differentiator vs button-based tools like Whisper Flow

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

**What Didn't Work (Initially):**
- ❌ Dual-pass audio refinement (always-on): Added UX lag (visible backspace/retype), sometimes worse transcription than streaming
- ❌ Ollama LLM text refinement: Integration issues, didn't trigger reliably, added complexity
- ❌ Text-based surgical editing: Too complex for unclear benefit

**Key Insight:** Streaming transcription is already quite good; post-processing adds complexity and latency without clear wins. **However**, dual-pass is now available as an **optional toggle** for users who want punctuation/capitalization and improved accuracy.

## Recently Completed
- ✓ **Dual-pass optional toggle** (2026-01-09 late night) — Reintroduced as optional menu feature (disabled by default)
- ✓ **Visual effects: Orb animations** (2026-01-09 late evening) — Voronoi Cells (default) + Concentric Rings, psychedelic RGB
- ✓ **SCORCHED EARTH CLEANUP** (2026-01-09 late evening) — Removed ALL always-on refinement infrastructure
- ✓ **Pure streaming commitment** (2026-01-09 evening) — Fast streaming as default mode
- ✓ **Task tracking setup** (2026-01-09 evening) — Fixed td/tv in PATH, organized backlog
- ✓ **320ms chunk upgrade** (2026-01-09) — Improved accuracy to ~5.73% WER
- ✓ **Permission/input issue resolved** (2026-01-09) — Proper .app bundle
