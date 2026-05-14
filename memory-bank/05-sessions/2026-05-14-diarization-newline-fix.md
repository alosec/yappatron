# 2026-05-14 Diarization Newline Input Fix

## Summary

Fixed GitHub issue #2: when speaker labels were enabled, Yappatron typed
a stray lowercase `a` immediately before `[Alex]`/speaker labels on
labeled runs.

## Root Cause

The diarized text and hybrid override path were clean. The issue was in
the final typing path.

`formatLabeled` prepends the hardcoded speaker-turn separator (`"\n"`)
before later utterance labels. `InputSimulator.typeString` treated that
newline like any other character and passed it to `typeChar`.

`typeChar` creates a `CGEvent` with `virtualKey: 0` and then attaches a
Unicode payload. On macOS, virtual key `0` is the physical A key. For
normal letters this mostly works because the Unicode payload wins. For
newline, some targets interpreted the event as key code A instead of
accepting the newline payload, so the target received:

```text
a[Alex] ...
```

## Fix

`InputSimulator.typeString` now special-cases newline characters:

- `\n` -> `pressEnter()`
- `\r` -> `pressEnter()`
- all other characters -> existing `typeChar` path

This keeps the speaker-turn newline as a real Return key event and
avoids routing it through the generic Unicode event whose key code is A.

## Validation

- `swift build` passed.
- `./scripts/run-dev.sh` rebuilt the release binary, created and
  ad-hoc signed `build/Yappatron.app`, installed it to
  `/Applications/Yappatron.app`, and launched it.
- Live test after launch: multiple separate speaker-labeled utterances
  produced `[Alex] ...` / newline + `[Alex] ...` with no leading `a`.

Existing build warnings remain unrelated:

- SwiftPM warns that the resource files under `Sources/Resources` are
  not explicitly declared as resources or excluded.
- Swift emits pre-existing actor/sendability warnings in
  `EnrollmentRecorder` / `TranscriptionEngine`.
