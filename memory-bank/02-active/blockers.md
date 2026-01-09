# Blockers

**Last Updated:** 2026-01-09

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

### Permission / Input Not Working — P0 ✓ RESOLVED 2026-01-09
- **Problem:** Permissions didn't persist across rebuilds when running bare Swift executable
- **Root cause:** Running from `.build/debug/` meant binary hash changed on every rebuild, breaking permission tracking
- **Solution:** Created proper .app bundle with stable bundle ID + location
  - Enhanced Info.plist with complete metadata and permission descriptions
  - Built proper `Yappatron.app` bundle structure
  - Ad-hoc signed entire bundle (free, no Developer Program needed)
  - Installed to `/Applications/` for stable location
  - Bundle ID `com.yappatron.app` provides stable identity
- **Result:** Permissions now persist across rebuilds. Transcription confirmed working.
- **Scripts:** `./scripts/run-dev.sh` builds and installs automatically
- **Documentation:** See BUILD.md
