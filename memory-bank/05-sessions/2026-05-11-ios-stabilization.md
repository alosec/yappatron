# 2026-05-11 iOS Stabilization Pass

## Scope

User clarified that the iPhone app needs to become a live ambient transcript surface for meetings and lectures, and called out three immediate reliability problems: the keyboard bridge drops/feels unreliable, Deepgram emits too jittery, and Local mode is barely workable.

## Shipped

- Deepgram iOS delivery now accumulates `is_final` fragments into a pending utterance and emits to outputs only after `UtteranceEnd`, `Finalize`, `speech_final`, or a 2.75s silence debounce.
- Deepgram endpointing was raised from 900ms to 2750ms and `utterance_end_ms=2750` was added.
- Local Apple Speech now restarts recognition tasks when Apple ends/fails a task, keeps a committed transcript across restarts, requests punctuation, and falls back to Apple's default recognizer path if strict on-device recognition is unavailable.
- Active recording disables the idle timer so the foreground live transcript remains visible during a session.
- The keyboard bridge now publishes a queue of Yappatron-tagged pasteboard chunks instead of only the latest chunk. The keyboard inserts pending chunks in order and remembers the newest inserted timestamp to avoid duplicate auto-inserts.

## Validation

- `./scripts/build-ios.sh` passed for iPhone simulator.
- Real-device build succeeded for Alex's iPhone using Personal Team `Z3RF5257M2`.
- `devicectl` install succeeded for `com.yappatron.ios`.
- `devicectl` launch was blocked by iOS trust/signing policy: the refreshed Personal Team profile needs to be trusted on-device before launch.

## Follow-Up

- Trust the refreshed developer profile on the iPhone, then test Local, Deepgram endpointing, and keyboard queue insertion on device.
- This is still a stabilization pass, not the final meeting-recorder product shape. The app still needs a true session/history model for saved meeting and lecture transcripts.
