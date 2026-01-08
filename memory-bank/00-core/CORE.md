# Core Constraints

## What This Is

Always-on voice dictation for macOS. No push-to-talk. Just yap.

## Architecture (Non-Negotiable)

- **Pure Swift** — No Python in production. Python code in `packages/core/` is dormant prototype.
- **Single process** — Menu bar app, no daemon, no WebSocket bridge.
- **Fully local** — All inference on-device. No cloud. No data leaves machine.
- **Neural Engine** — ASR runs on ANE for efficiency, not GPU.

## Tech Stack

| Layer | Technology | License |
|-------|------------|---------|
| App | Swift 5.9+, SwiftUI | — |
| ASR | FluidAudio (StreamingEouAsrManager) | Apache 2.0 |
| Model | Parakeet EOU 120M (CoreML) | MIT/Apache 2.0 |
| Hotkeys | soffes/HotKey | MIT |
| Hosting | Cloudflare Pages | — |

## Critical Patterns

### Streaming ASR Flow
```
Mic → 16kHz resample → 160ms chunks → FluidAudio → partialCallback/eouCallback
```

### Ghost Text Diffing
Partials are cumulative ("hello" → "hello wor" → "hello world"). `InputSimulator.applyTextUpdate()` diffs old vs new, backspaces divergent suffix, types new suffix. Only backspaces if model revises mid-stream.

### EOU Semantics
Model is semantically aware. Complete thoughts finalize fast. Fragments wait for continuation.

## Licensing Constraint

**All permissive.** Do NOT use FluidAudioTTS — it includes GPL ESpeakNG.

## File Locations (Mac)

```
~/Workspace/yappatron/packages/app/Yappatron/  # Swift app
~/Library/Application Support/FluidAudio/Models/  # Downloaded models
```
