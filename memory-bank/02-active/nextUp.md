# Next Up

**Last Updated:** 2026-01-09 (late evening - post-cleanup)

## Immediate (next session)

1. **Visual Effects: Siri-like Orb Animation** — P2 (yap-dec5)
   - Integrate metasidd/Orb library
   - Audio-reactive morphing animations
   - Psychedelic color palette
   - Satisfying finalization effects

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

**What Didn't Work:**
- ❌ Dual-pass audio refinement: Added UX lag (visible backspace/retype), sometimes worse transcription than streaming
- ❌ Ollama LLM text refinement: Integration issues, didn't trigger reliably, added complexity
- ❌ Text-based surgical editing: Too complex for unclear benefit

**Key Insight:** Streaming transcription is already quite good; post-processing adds complexity and latency without clear wins.

## Recently Completed
- ✓ **SCORCHED EARTH CLEANUP** (2026-01-09 late evening) — Removed ALL refinement infrastructure (~1,175 lines, 55% reduction)
- ✓ **Pure streaming commitment** (2026-01-09 evening) — 100% streaming only, zero complexity
- ✓ **Task tracking setup** (2026-01-09 evening) — Fixed td/tv in PATH, organized backlog
- ✓ **Visual effects research** (2026-01-09 evening) — Found metasidd/Orb library, ready to implement
- ✓ **320ms chunk upgrade** (2026-01-09) — Improved accuracy to ~5.73% WER
- ✓ **Permission/input issue resolved** (2026-01-09) — Proper .app bundle
