# Blockers

**Last Updated:** 2026-01-09 14:45 UTC

## Active Blockers

None currently - monitoring for regressions.

## Resolved

### Race Condition Crash (yap-e049) — P0 ✓ RESOLVED 2026-01-09
- **Problem:** App crashes randomly during use due to thread-unsafe buffer access
- **Root cause:** FluidAudio's internal audio buffer accessed from multiple threads simultaneously
- **Location:** `StreamingEouAsrManager.process()` → `removeFirst(_:)`
- **Failed approach:** Serial DispatchQueue + semaphore blocked audio thread, causing glitches
- **Solution:** Actor-based buffer queue pattern
  - Created `AudioBufferQueue` actor for thread-safe buffer management
  - Audio callback enqueues buffers asynchronously (non-blocking)
  - Separate processing task dequeues and processes buffers serially
  - Proper buffer copying prevents data races
  - Max queue size (100) prevents unbounded memory growth
- **Implementation:** `TranscriptionEngine.swift:17-57`, `363-387`
- **Result:** Audio thread never blocks, serial processing guaranteed, no race conditions

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
