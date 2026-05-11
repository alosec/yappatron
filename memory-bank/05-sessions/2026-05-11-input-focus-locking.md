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

- Add visible lock feedback first: window outline on lock, clear unlock state, and failure feedback when capture does not happen.
- Revisit the default lock shortcut or provide a non-hotkey locking flow if global hotkeys remain unreliable.
- Add a bottom-line indicator option as an orb-style alternative.
- Reproduce Codex auto-enter with and without focus lock enabled.
