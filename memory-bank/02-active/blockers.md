# Blockers

**Last Updated:** 2026-05-31

## Active Blockers

### Background Music Prevents EOU Completion — P0
- **Problem:** During the Troublemaker/Yappatron live demo path, any music/audio playing appears to keep Yappatron from finishing EOU. The practical result is that webhook delivery can stall because the app keeps waiting for the utterance to end.
- **Observed context:** Reproduced while using Yappatron to drive a local Troublemaker webhook demo involving Spotify. The agent itself was coming along, but music playback interfered with Yappatron's end-of-utterance completion.
- **Likely shape:** The EOU/speech-gate path is treating background music as continuing audio activity, or otherwise not separating speech probability from non-speech/music energy. EOU should be driven by detected speech ending, not by generic loudness or ongoing playback.
- **Next investigation:** Reproduce with Spotify/music playing, inspect Local/Nemotron + Silero VAD finalization behavior and any Deepgram/local silence timers, then make background music stop resetting or blocking EOU unless speech is actually detected.

### iPhone First-Run Transcription Validation — P0
- **Problem:** Local mode is implemented but not yet user-validated on device.
- **Current path:** Apple on-device Speech recognition is the default iOS backend, so no Deepgram key is needed for the next test.
- **Fallback direction:** If Apple Speech is unavailable or not good enough, evaluate FluidAudio/Parakeet on iOS next.

### iOS Keyboard Enablement — P1
- **Problem:** The keyboard extension is installed with the app, but the user still needs to enable it in iOS settings and allow Full Access before type-anywhere insertion can be tested.
- **Path:** Settings > General > Keyboard > Keyboards > Add New Keyboard > Yappatron Keyboard, then enable Allow Full Access.
- **Tradeoff:** The free Personal Team build uses a Yappatron-tagged `UIPasteboard` bridge instead of App Groups. This is less clean than App Groups but avoids paid provisioning capabilities.

### Normal Xcode Run Destination — P2
- **Problem:** Full Xcode Run still wanted the iOS 26.4 platform/runtime component. The ASAP install succeeded by using a CLI build that excluded `Assets.xcassets`.
- **Path:** Finish Xcode's iOS platform/runtime install later if normal Xcode Run, simulator builds, and app icon asset compilation matter.
- **Current workaround:** Signed device build/install works from CLI with build overrides and free Personal Team signing.

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
