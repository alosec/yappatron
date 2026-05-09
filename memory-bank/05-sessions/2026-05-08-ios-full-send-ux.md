# 2026-05-08 iOS Full Send UX Pass

## Trigger

After installing the pulled iOS build on the test iPhone, the user correctly called out that the expected UX was missing:

- Webhook configuration was hidden behind Deepgram mode.
- Local mode could transcribe but could not send finalized text to the webhook.
- The keyboard was not usable as a live destination because it only tried to insert once when opened.
- The main screen felt like a generic recorder instead of a "record/listen and send" surface.

## Direction

Treat the iPhone app as a "Full Send" surface:

1. The first screen shows a large start/stop control.
2. Outputs are visible and independently configurable.
3. Local and Deepgram are engines, not UX modes.
4. Every finalized chunk can go to a webhook, the Yappatron keyboard, or both.
5. Optional return insertion is part of the output contract.

## Implementation

- Rebuilt `ContentView` around:
  - `Start Full Send` / `Stop Full Send`
  - always-visible webhook URL and bearer token fields
  - keyboard auto-insert toggle
  - return-after-send toggle
  - auto-start-on-open toggle
  - engine selector
  - live transcript and output event feed
- Added an output abstraction in `DiarizedUtterance.swift`:
  - `TranscriptOutputSettings`
  - `TranscriptOutputDestination`
  - `TranscriptOutputStatus`
  - `TranscriptOutputEvent`
  - `TranscriptOutputRouter`
- Changed `DictationViewModel` so Local mode emits sendable chunks:
  - Apple Speech partial transcript updates still drive the live transcript.
  - A 1.1s debounce approximates an end-of-utterance boundary.
  - Stop flushes the final local transcript delta.
- Deepgram diarized runs now flow through the same output router as Local.
- Updated `SharedTranscriptStore` metadata to include `pressReturnAfterInsert`.
- Updated `KeyboardViewController` to poll every 450ms while visible and auto-insert each new delivered chunk once.

## Notes

iOS still owns the hard platform limitation: custom keyboards cannot record audio directly. The working flow is still:

1. Start Yappatron / Full Send in the main app.
2. Swipe back to the target app.
3. Use the Yappatron keyboard as the insertion surface.

The change here makes that flow feel more automatic: the app keeps delivering chunks, and the keyboard keeps consuming them while it remains visible.

## Immediate UX Correction

First device test showed two regressions:

- The keyboard stayed on "Waiting for Yappatron" if keyboard auto-insert was off, because delivery to the keyboard pasteboard was incorrectly gated by the auto-insert setting.
- The main app rendered too many "Queued" event rows, making the screen feel noisy and debug-like.

Follow-up fix:

- Every delivered chunk is now published for the keyboard. Auto-insert only controls whether the keyboard inserts automatically.
- The app no longer shows the verbose output event feed.
- Keyboard background changed from the default dark system background to system gray.
