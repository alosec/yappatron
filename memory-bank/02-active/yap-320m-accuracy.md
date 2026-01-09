# Task: Improve Transcription Accuracy with 320M Model

**Task ID:** yap-320m
**Priority:** P1
**Status:** Todo
**Created:** 2026-01-09

## Problem
Current transcription using Parakeet EOU 120M (160ms) model has good speed but accuracy needs improvement. The model misses words and phrases during dictation.

## Goal
Evaluate and potentially switch to Parakeet EOU 320M model for improved accuracy.

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

## Notes
- FluidAudio library supports both models via `Repo` enum
- Model will auto-download on first run (user will need to wait longer for 320M)
- Can make model selection configurable in future (user preference)
