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

### Permission / Input Not Working — P0
- **Status:** Investigating
- **Symptoms:** 
  - No permission prompts when running from standalone terminal
  - Audio chunks flow but no transcription output
  - Keystroke injection not working even after accessibility grant
- **Attempted:**
  - Ad-hoc signing via `scripts/run-dev.sh` — did not resolve
  - Audio capture confirmed working (chunks logged at 50/sec)
- **Likely causes:**
  1. Accessibility permission not actually granted to correct binary
  2. `isTextInputFocused()` returning false (AX query failing)
  3. Model producing empty transcriptions
- **Next steps:**
  - Add debug logging for `isTextInputFocused()` result
  - Check if partials are being generated
  - Verify accessibility in System Settings shows correct binary

## Resolved

(none yet)
