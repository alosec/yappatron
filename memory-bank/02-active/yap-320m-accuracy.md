# Task: Improve Transcription Accuracy with 320ms Chunk Size

**Task ID:** yap-320m
**Priority:** P1
**Status:** ✅ Complete - Tested & Confirmed Working
**Created:** 2026-01-09
**Completed:** 2026-01-09 15:45 UTC

## Problem
Current transcription using Parakeet EOU 120M (160ms chunks) model has good speed but accuracy needs improvement. The model misses words and phrases during dictation.

## Goal
Switch to 320ms chunk size for improved accuracy (same 120M model, larger context window).

## Current Implementation
- **Model:** Parakeet EOU 120M (via `Repo.parakeetEou160`)
- **Location:** `TranscriptionEngine.swift:138`
- **Download:** Uses `DownloadUtils.loadModels(.parakeetEou160, ...)`

## Proposed Change
Test `Repo.parakeetEou320` to compare:
- **Accuracy:** Word/phrase recognition quality
- **Latency:** Real-time performance impact
- **Memory:** RAM and Neural Engine usage

## Trade-offs to Consider
| Aspect | 120M (current) | 320M (proposed) |
|--------|----------------|-----------------|
| Speed | Fast | Potentially slower |
| Accuracy | Good, but misses words | Likely better |
| Model size | Smaller download | Larger download |
| Memory usage | Lower | Higher |

## Implementation Steps
1. Change `Repo.parakeetEou160` to `Repo.parakeetEou320` in `downloadStreamingModels()`
2. Test transcription quality with real-world usage
3. Measure latency impact (does ghost text lag?)
4. Check memory usage and Neural Engine utilization
5. Compare transcription quality on difficult phrases
6. Decide whether accuracy improvement is worth any performance cost

## Success Criteria
- Noticeable improvement in word recognition
- No significant degradation in real-time responsiveness
- Ghost text updates smoothly without lag

## Files to Modify
- `packages/app/Yappatron/Sources/TranscriptionEngine.swift` (line 138, 157)

## Implementation Details

**CLARIFICATION:** "320M" is misleading - it's actually the same 120M parameter model with 320ms chunks (not a 320M parameter model).

**Changes made:**
1. Updated `downloadStreamingModels()` in `TranscriptionEngine.swift:141`
   - Changed `Repo.parakeetEou160` → `Repo.parakeetEou320`
   - Model path now uses `parakeet-eou-streaming/320ms/`

2. Updated `StreamingEouAsrManager` initialization in `TranscriptionEngine.swift:147`
   - Changed `chunkSize: .ms160` → `chunkSize: .ms320`
   - **Critical:** Chunk size must match the model variant

**Testing results (user feedback - 2026-01-09):**
- ✅ System working after chunk size fix
- Slightly slower latency (expected with 2x chunk size) - **acceptable trade-off**
- **Accuracy improvement confirmed meaningful:**
  - Better context-aware decisions (e.g., "to do" vs "todo")
  - Model waits to decide word boundaries with more context
  - "Quite accurate now" - passes user's quality bar
- Speed/accuracy balance is good
- Heavy logging activity observed (needs cleanup)
- **Verdict:** 320ms is worthwhile upgrade from 160ms

## Notes
- Same 120M parameter model, just different chunk sizes
- 320ms provides more context per inference (potentially better accuracy)
- 320ms has 2x latency vs 160ms (ghost text appears slower)
- Can make chunk size configurable in future (user preference)
- Build successful after chunk size correction
