# 2026-05-24 - Deepgram Latency Tuning

## Summary

Deepgram felt dramatically slower than OpenAI Realtime because Yappatron was
mostly waiting on app-side utterance policy, not raw Deepgram transcription.
The Mac path had `endpointing=2750`, a 3.5s local EOU timer, and an explicit
disabled `speech_final` branch. The iOS path also used 2.75s Deepgram
endpointing, a conservative commit policy, and a fixed 1.2s sleep after
`Finalize`.

## Changes

- Mac Deepgram now uses `endpointing=650` and `utterance_end_ms=1000`.
- Mac fallback EOU debounce is now 900ms instead of 3.5s.
- Mac now honors Deepgram `speech_final`, but with a 450ms grace window so a
  brief pause can be cancelled by the next words instead of cutting the phrase.
- iOS Deepgram now uses the same `endpointing=650` and `utterance_end_ms=1000`.
- iOS responsive mode uses `silenceDebounceMs=900` and
  `speechFinalGraceMs=450`.
- iOS `finish()` now waits for Deepgram's `from_finalize` response with a
  short timeout instead of always sleeping for 1.2s.
- Mac typing updates are now append-only. `InputSimulator.applyTextUpdate`
  no longer has a delete-key path; divergent recognition corrections are
  ignored instead of rewriting the active input.
- Mac typed-state tracking now only advances after append-only updates, so a
  skipped divergent correction cannot make later updates act on text that was
  never inserted.

## Live Validation

After installing and restarting `/Applications/Yappatron.app`, the user tested
Deepgram live and confirmed finalization is much faster. Immediate
`speech_final` was a little too aggressive and cut off natural continuation
phrases, so the follow-up tuning keeps the fast feel while adding a small
450ms grace before committing speech-final turns. The user also flagged
remaining visible backspacing as unwanted; the app now preserves forward-only
typing even when partial/final text diverges, and source search shows no
remaining delete/backspace key event path in the Mac typing code.

## Next Slice

Partials still deserve a separate pass. The likely first lever is audio chunk
size: Mac mic capture and iOS capture both use 4096-frame AVAudioEngine taps,
which is coarse for realtime partial display. Do not mix that change into the
finalization tuning unless the current commit behavior has stabilized.
