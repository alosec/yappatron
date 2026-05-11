# 2026-05-11 — Input Focus Locking MVP

## Shipped

Implemented the first Mac input focus locking pass for Yappatron.

- Added a focused-input capture path through Accessibility.
- Added an input focus lock toggle shortcut and menu bar actions.
- Routed streaming partials, final transcriptions, and dual-pass refinement updates through the locked destination.
- When locked, Yappatron briefly refocuses the target before typing and then restores the previously frontmost app.
- If the locked target disappears, Yappatron clears the lock and pauses instead of falling back to whichever app is currently focused.
- Changed the floating orb overlay so showing it does not make it the key keyboard window.
- Rebuilt, ad-hoc signed, installed, and launched `/Applications/Yappatron.app`.

## Live-Test Notes

- The lock hotkey did not appear to work in the user's live test. This needs follow-up before the feature feels dependable.
- There is no visual indication of what window is locked. User wants a visible indicator around the locked window whenever Yappatron locks to it.
- Codex auto-enter bug: "Press Enter After Speech" does not seem to work reliably in Codex. Investigate Codex-specific input behavior, paste fallback timing, and focus-lock interactions.
- User wants an alternate indicator style: a line at the bottom of the active display instead of the psychedelic floating orb.

## Next Actions

- Smoke-test lock behavior in the installed app, especially Codex.
- Verify the locked-window outline tracks moved/resized windows and multi-display setups.
- Verify the continuous bottom-line indicator feels better than the floating orb for overlay-assistant workflows.
- Re-test Codex auto-enter with and without focus lock enabled.

## Follow-Up Shipped Same Day

- Added a non-interactive outline window around the locked target.
- Added a 0.25s polling loop to keep the outline tracking the target frame and to remember the most recent non-Yappatron text input.
- Changed the lock shortcut to `⌃⌥⌘L`.
- Added local/global key-monitor fallback in addition to the Carbon hotkey registration.
- Updated the menu item to lock the most recent text input when opening the menu steals focus.
- Added `Bottom Line` as an indicator style alongside the two orb styles.
- Added a 120ms delay before auto-enter after a final utterance to give paste-fallback surfaces such as Codex time to accept the inserted text before Return.

## Indicator Correction

The segmented fake waveform looked wrong and implied real voice responsiveness that was not actually wired. Replaced it with a single continuous rainbow bar that subtly pulses and wiggles as one piece. Speaking state only increases motion/intensity; true audio-reactive visualization remains a separate future feature that would need a real audio-level signal from the capture pipeline.
