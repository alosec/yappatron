# Blockers

**Last Updated:** 2026-01-08

## Active Blockers

### Race Condition Crash (yap-e049) — P0
- **Status:** Investigating
- **Impact:** App crashes randomly during use
- **Location:** `StreamingEouAsrManager.process()` → `removeFirst(_:)`
- **Cause:** FluidAudio's internal audio buffer isn't thread-safe
- **Current mitigation:** Serial DispatchQueue + semaphore in `processAudioBuffer()` — NOT SUFFICIENT
- **Real fix options:**
  1. Upstream fix in FluidAudio
  2. Swift actor isolation around the manager
  3. Different threading model for audio callback

## Resolved

### Permission Resets on Every Launch — FIXED
- **Cause:** Unsigned Swift PM executable; macOS tracks permissions by code signature
- **Fix:** `scripts/run-dev.sh` — ad-hoc signs binary after build
- **Resolution Date:** 2026-01-09
