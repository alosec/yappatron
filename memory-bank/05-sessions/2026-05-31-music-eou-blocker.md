# 2026-05-31 - Background Music EOU Blocker

## Summary

While preparing the local Troublemaker/Yappatron demo, a new Yappatron-side
issue surfaced: music/audio playback appears to keep EOU from completing.
When Spotify or other music is playing, Yappatron can keep waiting instead of
finalizing and sending the webhook turn.

## Demo Impact

This is a P0 demo-path blocker because the intended flow is:

- Speak into Yappatron.
- Yappatron detects end of utterance.
- Yappatron submits the webhook turn to local Troublemaker.
- Troublemaker manipulates the Mac, including Spotify.

If music playback prevents EOU completion, follow-up voice commands can stall
right at the handoff.

## Working Hypothesis

The EOU/speech-gate path is probably letting non-speech audio activity reset or
block finalization. Background music should not count as continuing speech. EOU
should be gated on speech probability or recognized speech activity, not generic
audio energy while music is playing.

## Next Pass

Reproduce with Spotify/music playing, then inspect the Local/Nemotron + Silero
VAD finalization path and any Deepgram/local silence timers. The desired
behavior is that music may keep the input noisy, but it does not prevent EOU
once the user's speech has ended.
