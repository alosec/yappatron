# 2026-05-14 iOS Quiet Listening UI

## Summary

Rebuilt the iOS app around the real product state: quiet armed
listening, active speech detection, transcription, finalization, and
sending.

The first screen is now intentionally sparse:

- one listening indicator,
- one short phase label,
- one start/stop button,
- one small destination strip.

Webhook setup, engine selection, keyboard setup, speaker naming,
transcript actions, and output diagnostics moved behind the gear.

## State Model

`DictationViewModel` now exposes a product-facing `ListeningPhase`:

- `off`
- `connecting`
- `quiet`
- `speechDetected`
- `transcribing`
- `finalizing`
- `sending`
- `attention`

This is separate from the coarse lifecycle `Status`, so the UI can be
honest about quiet armed listening versus active speech.

## Deepgram Speech Gate

The iOS Deepgram backend no longer opens a websocket and streams every
mic buffer immediately when armed.

New flow:

1. Start mic capture locally.
2. Compute RMS level per captured chunk.
3. Keep a short pre-roll buffer while quiet.
4. On local speech onset, open Deepgram and send pre-roll plus live
   chunks.
5. After the configured thought pause of local silence, finalize and
   disconnect the Deepgram segment.
6. Return to quiet armed state.

This does still send a short silence tail after speech so Deepgram can
finalize cleanly, but it should no longer burn API time during long
silent armed periods.

## Notes

Real-device follow-up tuned the first pass:

- Lowered the speech-onset RMS thresholds and added a small adaptive
  ambient noise floor so normal near-field speech flips out of `Quiet`
  promptly.
- Kept live transcription fast, but slowed final submit. The default
  thought pause is now 4.5s, the slider allows 3.0-8.0s, and
  Deepgram `UtteranceEnd` no longer gets a short 1s shortcut around the
  conservative pause policy.
- Replaced the truncated main-screen transcript preview with a small
  scrollable live transcript.
- Added a transcript/history sheet from the top bar so full current,
  last-sent, and delivery event text can be inspected without opening
  settings.
- Stopped using the system pasteboard as the live app/keyboard bridge.
  The bridge now uses only Yappatron's named pasteboard, which should
  avoid repeated iOS "allow paste" prompts while dictating.
- Changed the keyboard live transcript label from single-line ellipsis
  to a 3-line wrapping preview.
