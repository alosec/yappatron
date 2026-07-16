# Echo-cancelled SAG barge-in

**Date:** 2026-07-12

## Commits

- `434b1f7` — `Shorten SAG feedback cooldown`
- `b5e356a` — `Add echo-cancelled SAG barge-in`

Both commits were pushed to `alosec/yappatron` main.

## Shipped

- Reduced the fallback post-SAG hard gate from 1.6 seconds to 250ms.
- Enabled macOS Voice Processing I/O acoustic echo cancellation for microphone capture.
- Configured minimum output ducking so SAG remains audible at ordinary system volume.
- Adapted the Voice Processing I/O 48kHz/9-channel stream by selecting its processed first channel before persistent 16kHz mono resampling.
- Kept low-level playback residual out of cloud STT while SAG is active.
- Added sustained near-field voice detection that terminates SAG and its playback descendants for natural interruption.
- Added a rolling 300ms echo-cancelled pre-roll so an interrupted user's first word reaches STT.
- Retained the original process hard gate as a fallback when acoustic echo cancellation is unavailable.

## Verification and live QA

- `swift build` passed.
- `./scripts/build-app.sh` passed and produced a valid ad-hoc signed app bundle.
- Deterministic capture-state check passed: echo hold, retained onset, barge-in trigger, continuation, and cooldown.
- Synthetic process checks passed for SAG detection and termination of its playback descendant.
- Runtime capture logs confirmed Voice Processing I/O enabled and stable 1600-frame, 16kHz output buffers.
- A first prototype exposed two issues and was not retained: generic 9-channel downmix produced silent STT input, and default voice-processing ducking made playback too quiet.
- Repeated live SAG tests confirmed ordinary transcription still works, playback no longer feeds back, minimum ducking is audible, speech interrupts playback, and the 300ms pre-roll preserves the first interrupted word.
- Alex accepted the final behavior as good enough.

## Remaining caveat

Barge-in uses a tuned acoustic level plus short sustain window after hardware echo cancellation. Different microphones, speaker routes, or room acoustics may eventually need per-device threshold tuning. The no-AEC fallback intentionally prevents feedback rather than offering barge-in.
