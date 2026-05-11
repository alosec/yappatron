# iOS Dictation UX Spec

**Captured:** 2026-05-11

## Product Goal

Yappatron iOS should become an open-source, good-faith counterpart to the best iPhone dictation apps: a keyboard-driven dictation surface backed by the main app as the microphone/transcription engine. The core promise is not "copy a transcript later." The promise is: open any text field, switch to the Yappatron keyboard, start dictation, and see speech flow into that input.

## Primary Mode

Always-on live dictation is the target mode.

- The keyboard is the control surface when the user is in another app.
- The main Yappatron app owns microphone permission, audio capture, and transcription because iOS keyboards cannot use the microphone directly.
- When the keyboard is open and Yappatron is recording, live transcript deltas should stream into the active text field in near real time.
- The visible live transcript in the app is the model: the same append-only text should be what the keyboard streams into the destination input.

## Keyboard Flow

Reference flow from Spokenly:

1. User opens a target app and focuses an input.
2. User switches to the Yappatron keyboard.
3. Keyboard shows an obvious `Start Dictation` / mic action when the companion app is not recording.
4. Pressing start opens the Yappatron app through a URL/deep-link.
5. Yappatron immediately starts recording and shows a clean success screen: dictation is enabled, swipe back to the previous app.
6. User swipes back to the target app.
7. Keyboard now shows recording state and streams transcript deltas into the focused input.
8. Checkmark acts like iPhone push-to-talk completion: stop/finish the current dictation and insert/commit remaining text.

## Keyboard Controls

Expected controls:

- Mic / start dictation action.
- Checkmark action to finish/commit current dictation.
- History action for previous snippets.
- Basic editing buttons: undo, space, return, backspace.
- Clear state language: when the companion app is not available, do not pretend to be recording. Show `Start Dictation` or equivalent.

## Failure Mode To Avoid

Never show confident recording UI if audio is not actually being captured. A prior app failure case was showing recording, accepting a long spoken passage, then dropping all audio on commit because the companion app had been killed. Yappatron should prefer an honest "Start Dictation" state over fake active recording.

## Main App Shape

The main app should not feel like a settings screen. It should prioritize:

- Large central mic / stop control.
- Live transcript surface.
- Clear listening/recording state.
- Lightweight access to engine/output settings without making settings the whole first screen.

Existing features should remain available: Local/Deepgram engine selection, webhook output, keyboard output, auto-enter/return, speaker naming for Deepgram, copy/share/clear.

## Near-Term Implementation Direction

- Add a URL/deep-link start path from keyboard to app.
- Publish live dictation state from the app to the keyboard through the current pasteboard bridge.
- Let the keyboard stream append-only transcript deltas into the active input while recording.
- Let checkmark insert any remaining text and request stop.
- Keep queued finalized chunks/history as a fallback, but do not confuse that with the primary live insertion mode.
