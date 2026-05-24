# 2026-05-24 - OpenAI Realtime STT Backend

Shipped a third Mac STT backend: **OpenAI Realtime**.

## What Changed

- Added `OpenAIRealtimeSTTProvider`.
- Added `STTBackend.openAIRealtime` with display label `OpenAI Realtime`.
- Wired `TranscriptionEngine.createProvider()` to instantiate the OpenAI provider.
- Added **Set OpenAI API Key...** / **Update OpenAI API Key...** menu entries.
- Generalized cloud-backend API-key prompting from Deepgram-only to any backend with `requiresAPIKey`.
- Updated README and feature docs for OpenAI Realtime.
- Rebuilt, installed, and launched `/Applications/Yappatron.app`.

## Model And API Shape

Latest realtime STT model used: `gpt-realtime-whisper`.

Critical WebSocket detail:

```text
wss://api.openai.com/v1/realtime?intent=transcription
```

Do not include a `model` query parameter for transcription sessions.
The model belongs in the session update:

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": {
          "type": "audio/pcm",
          "rate": 24000
        },
        "transcription": {
          "model": "gpt-realtime-whisper",
          "language": "en",
          "delay": "low"
        },
        "turn_detection": null
      }
    }
  }
}
```

The first implementation used the normal realtime URL with a model
query parameter and failed at runtime:

```text
Passing a transcription session update event to a realtime session is not allowed.
```

Direct smoke testing confirmed the corrected URL returns `session.updated`.

## Audio Handling

Yappatron captures 16kHz mono Float32 PCM. OpenAI realtime transcription
expects 24kHz mono PCM16 for `audio/pcm`, so the provider linearly
resamples and converts each buffer before sending
`input_audio_buffer.append`.

Because `gpt-realtime-whisper` transcription sessions use manual commit
when turn detection is null, the provider commits on local silence and
also on explicit `finishCurrentUtterance()`.

Transcript deltas are treated as locked append-only text so the existing
cloud backend typing behavior streams live text.

## Storage

OpenAI API key is saved with the same `UserDefaults` helper as Deepgram:

```text
apiKey_OpenAI Realtime
```

The bundled app preference domain is `com.yappatron.app`.

## Validation

- `swift build`
- `swift build -c release`
- `./scripts/build-app.sh`
- Direct WebSocket smoke test with stored key returned `session.updated`.
- Installed app live-test succeeded: user spoke, Yappatron transcribed via OpenAI Realtime.

## Follow-Ups

- Consider moving cloud API keys from UserDefaults to Keychain.
- Add a small in-app provider error surface so failures like bad
  Realtime session config do not look like silent listening.
- True hot-swap is still not implemented; backend switch now restarts
  automatically.
