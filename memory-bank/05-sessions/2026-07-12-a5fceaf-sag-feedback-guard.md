# SAG feedback guard

**Date:** 2026-07-12
**Code commit:** `a5fceaf` (`Prevent sag speech feedback in dictation`)

## Shipped

- Added a lightweight macOS `libproc` monitor for the local `sag` process.
- Applied the existing assistant-speech audio gate even when webhook output is disabled.
- Held captured microphone buffers before cloud STT while SAG is active and during a post-playback cooldown.
- Kept the existing localhost assistant-state guard as a separate fallback.

## Verification and deployment

- `swift build` passed.
- `./scripts/build-app.sh` passed for the release bundle; only the repository's pre-existing Swift concurrency/resource warnings remain.
- Process detection was checked against both a synthetic executable named `sag` and the installed SAG binary.
- The gate's `active -> cooldown -> idle` transition was checked with an injected process probe.
- Installed the clean release bundle at `/Applications/Yappatron.app`, verified its signature, and relaunched exactly one process.
- Runtime logs confirmed that mic buffers were held before STT in both active and cooldown phases.
- Repeated live ElevenLabs playback did not feed back into Yappatron dictation.
- Commit `a5fceaf` was pushed to `alosec/yappatron` main.

## Live QA finding / next work

The initial 1.6-second local cooldown is too aggressive: immediate speech after SAG finishes can be lost. Alex also wants barge-in while SAG is speaking. The next pass should shorten the hard tail and add echo-aware interruption; raw volume by itself cannot distinguish a person from loud speaker playback.
