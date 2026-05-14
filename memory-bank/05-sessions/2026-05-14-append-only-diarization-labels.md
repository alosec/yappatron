# 2026-05-14 Append-Only Diarization Labels

## Summary

Created GitHub issue #3 and changed Mac speaker-label output from a
retroactive prefix model to an append-only suffix model.

Required suffix:

```text
\n[Speaker]\n\n
```

Rendered:

```text
Spoken words stream normally.
[Alex]

Next utterance starts here.
[Callie]

```

## Problem

Before this change, the cloud/Deepgram path typed `is_final` text
forward as it arrived. At end-of-utterance, diarization returned labeled
text shaped like `[Alex] words...`. Because the label lived at the
front, `YappatronApp.handleFinalTranscription` had to call
`InputSimulator.applyTextUpdate(from:to:)` and replace the already-typed
utterance.

That made diarization the one remaining path that could visibly
backspace/rewrite text. For long utterances it could feel like the text
disappeared or stalled, even if it eventually settled correctly.

## Fix

`TranscriptionEngine` now formats speaker attribution as a suffix:

- plain utterance text stays as the final text prefix,
- `formatSpeakerSuffix` appends `\n[Speaker]\n\n`,
- multiple speaker runs collapse to a bracketed speaker sequence such as
  `[Alex -> Callie]`,
- `InputSimulator.typeString` pastes any multiline string instead of
  turning embedded newlines into Return keypresses, so chat inputs do not
  submit the utterance and speaker label as separate messages,
- `YappatronApp.finishUtteranceTyping` skips the old trailing-space
  insertion when the final text already ends with a newline.

This makes final diarization append-only in the common case because the
already-streamed utterance remains the common prefix and only the suffix
needs to be typed.

## Notes

The suffix label is intentionally metadata after the utterance. It
matches when speaker identity is actually known: after the diarized
final lands. It also makes the next utterance naturally start after two
newlines without requiring a label prefix before speech.
