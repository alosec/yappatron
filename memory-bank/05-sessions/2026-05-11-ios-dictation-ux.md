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

## Hotfix

Live test found that the keyboard still showed `Start Dictation` while the app was already listening, and tapping start gave no visible feedback. Patched the keyboard to remove the redundant globe key, darken the keyboard background toward iOS dark-keyboard gray, show explicit transient launch/status text, attempt a responder-chain URL open fallback, and mirror the Yappatron bridge through a named pasteboard in addition to the general pasteboard. If the keyboard reports `Allow Full Access for live dictation`, the OS is blocking the app/keyboard bridge until full access is enabled for the custom keyboard.

Screenshot from the device confirmed that exact full-access warning was visible. Added a hidden `WKWebView` URL-scheme fallback as a best-effort custom-keyboard app launcher and darkened the keyboard background another small step toward the native dark iOS keyboard strip.

## Live-Test Follow-Up

After Full Access was enabled, manually opening Yappatron and starting listening proved the app-to-keyboard bridge can insert into Notes, but the keyboard's `Start Dictation` action still did not reliably launch/switch to the app. Treat custom-keyboard URL launching as best-effort only for now; the UI should tell the truth and ask the user to open Yappatron manually when iOS blocks the handoff.

Patched a bridge drop case where the keyboard could mark finalized chunks as consumed while recording just because some live text had already streamed. The keyboard now backfills missing finalized text during recording when live transcript deltas stall, while still avoiding duplicate insertion when the live stream already covers a chunk.

Compacted the keyboard toward a Spokenly-style control strip: one short row for start/history/check/undo/space/return/delete, a one-line status/transcript label, no custom globe key, and a shorter keyboard height target.
