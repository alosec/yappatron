# 2026-05-11 iOS Dictation UX Pass

## Scope

User clarified the target iPhone workflow by comparing against Spokenly: the Yappatron keyboard should be a real dictation surface for any focused input, while the companion app owns microphone capture and transcription. The important product shift is live speech flowing into the current input, not "record now, paste later" as the only path.

## Shipped

- Captured the requested iOS dictation UX in `memory-bank/02-active/ios-dictation-ux-spec.md`.
- Added a `yappatron://dictation/start` URL path so the keyboard can launch the companion app and request recording.
- The app now starts listening from that URL path and shows a clean "Dictation enabled" handoff message telling the user to swipe back to the previous app.
- The app publishes live dictation state to the shared keyboard bridge while recording, with a heartbeat so stale recording state expires if iOS kills the app.
- The keyboard now exposes a dictation-focused control surface: start dictation, finish/checkmark, history, undo, space, return, delete, and next-keyboard.
- While recording, the keyboard streams live transcript deltas into the active input instead of waiting only for finalized chunks.
- The checkmark inserts any remaining live text and requests stop from the companion app.
- Finalized queued chunks are marked consumed when live streaming has already inserted them, avoiding duplicate auto-inserts after recording stops.
- The main app now prioritizes the big mic/listening control and live transcript; engine/output settings are moved behind a compact disclosure section.

## Follow-Up

- Real-device test the URL handoff from the keyboard into the app and back to the target input.
- Confirm the pasteboard bridge remains reliable with the keyboard's full-access setting enabled.
- Longer-term: replace the pasteboard bridge with an App Group container under a paid Apple Developer account for cleaner companion-app/keyboard state sharing.
- Add a real session/history model for meeting and lecture transcripts after the live-input loop feels solid.
