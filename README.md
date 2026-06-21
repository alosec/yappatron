# Yappatron

Open-source voice dictation for macOS. Use always-on listening or configurable push-to-talk.

## What is this?

Yappatron is a voice dictation app that:

- **🎙️ Streams in real-time** — Characters appear as you speak with cloud or local STT
- **☁️ Cloud STT** — OpenAI Realtime (`gpt-realtime-whisper`) and Deepgram Nova-3
- **🏠 Local STT** — Optional macOS 14+ build mode via Nemotron/Qwen3 (Neural Engine, nothing leaves your machine)
- **🎨 Beautiful visualizations** — Psychedelic orb animations respond to your voice
- **⚡ Hands-free operation** — Optional auto-send for AI assistants and command-line tools
- **🎙️ Dictation modes** — Always-on listening by default, with configurable push-to-talk for noisy spaces

## Why?

Current dictation apps often force:
- Clunky UX
- Rigid hotkey workflows
- Closed source "trust us" privacy

Yappatron keeps the simple always-on flow, and lets you switch to push-to-talk when the room gets messy.

## Quick Start

```bash
# Clone the repo
git clone https://github.com/alosec/yappatron
cd yappatron

# Build & run (macOS only, requires Swift 5.9+)
./scripts/run-dev.sh
```

**First launch:**
1. Grant microphone permission when prompted
2. Grant accessibility permission in System Settings → Privacy & Security → Accessibility
3. Start talking—text appears in your focused application

## Key Features

### Cloud STT (OpenAI Realtime)
- **Latest realtime STT model**: Uses `gpt-realtime-whisper`
- **Low-latency deltas**: Streams transcript text while audio is still arriving
- **Punctuation & capitalization**: Built-in formatting for dictated text

### Cloud STT (Deepgram Nova-3)
- **Sub-300ms latency**: Near-instant transcription via WebSocket streaming
- **Punctuation & capitalization**: Built-in smart formatting
- **5.26% WER**: Best-in-class accuracy
- **$200 free credit**: Months of free use on signup

### Local STT (Nemotron/Qwen3)
- **Nemotron Speech Streaming 0.6B**: Fast streaming ASR with inline punctuation & capitalization
- **Silero VAD gating**: Neural voice-activity detection so silence/noise never reaches the model (no hallucinated phantoms)
- **100% on-device**: Runs on the Neural Engine, nothing leaves your machine
- **Build-gated**: Requires `YAPPATRON_ENABLE_FLUIDAUDIO=1` and macOS 14+ because FluidAudio currently targets macOS 14

### Swappable Backends
Switch between OpenAI Realtime, Deepgram, and local STT via the menu bar. API keys are stored in app preferences.

### Ghost Text Diffing
- Smooth updates with intelligent backspacing
- Semantic EOU detection: Waits for complete thoughts, handles natural pauses

### Visual Feedback
- **Voronoi Cells** (default): Psychedelic shifting patterns during speech
- **Concentric Rings**: Alternative RGB animation style
- **Green orb**: Signals utterance completion

### Hands-Free Mode
Enable "Auto-Send with Enter" for completely hands-free operation with:
- Claude Code
- ChatGPT
- Terminal/CLI
- Any text input

## Structure

```
yappatron/
├── packages/
│   ├── app/Yappatron/     # Swift macOS app (active)
│   ├── ios/YappatronIOS/  # SwiftUI iOS app + keyboard extension
│   ├── core/              # Python prototype (dormant)
│   └── website/           # Astro landing page
├── memory-bank/           # Development documentation
├── scripts/               # Build and dev scripts
└── FEATURES.md            # Detailed feature documentation
```

## Documentation

- **[FEATURES.md](FEATURES.md)** — Complete feature documentation and technical details
- **[BUILD.md](BUILD.md)** — Build instructions and architecture notes
- **[memory-bank/](memory-bank/)** — Development history and design decisions

## System Requirements

- macOS 12.0+ (Monterey or later) for the default cloud STT build
- macOS 14.0+ (Sonoma or later) for the FluidAudio local STT build
- Apple Silicon recommended (M1/M2/M3/M4)
- Microphone + Accessibility permissions
- Internet connection (for cloud STT; not needed for local mode)

## Development

```bash
# Navigate to Swift app
cd packages/app/Yappatron

# Build
swift build

# Run
.build/debug/Yappatron
```

Default builds target Monterey and expose OpenAI Realtime and Deepgram. To build the local FluidAudio-backed STT path:

```bash
YAPPATRON_ENABLE_FLUIDAUDIO=1 swift build
YAPPATRON_ENABLE_FLUIDAUDIO=1 ./scripts/run-dev.sh
```

### iPhone App

The iOS companion lives at `packages/ios/YappatronIOS`. It includes a SwiftUI recorder app and a custom keyboard extension that inserts the latest synced transcript into the active iOS text field.

Full Xcode is required:

```bash
open packages/ios/YappatronIOS/YappatronIOS.xcodeproj
```

See `packages/ios/YappatronIOS/README.md` for signing, device install, and TestFlight steps.

## License

MIT

---

**Website**: [yappatron.pages.dev](https://yappatron.pages.dev)
**GitHub**: [github.com/alosec/yappatron](https://github.com/alosec/yappatron)
