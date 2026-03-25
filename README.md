# Yappatron

Open-source always-on voice dictation for macOS. No hotkeys, no toggles—just yap.

## What is this?

Yappatron is a voice dictation app that:

- **🎙️ Streams in real-time** — Characters appear as you speak (sub-300ms latency with Deepgram)
- **☁️ Cloud STT** — Deepgram Nova-3 for best-in-class accuracy with punctuation & capitalization
- **🏠 Local STT** — Optional fully local mode via Parakeet (Neural Engine, nothing leaves your machine)
- **✨ Dual-pass refinement** — Optional enhanced accuracy for local mode
- **🎨 Beautiful visualizations** — Psychedelic orb animations respond to your voice
- **⚡ Hands-free operation** — Optional auto-send for AI assistants and command-line tools
- **🚫 No push-to-talk** — Always listening, semantically aware of when you're done speaking

## Why?

Current dictation apps require:
- Push-to-talk or toggle hotkeys
- Clunky UX
- Closed source "trust us" privacy

Yappatron just works. Speak and it types. That's it.

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

### Cloud STT (Deepgram Nova-3)
- **Sub-300ms latency**: Near-instant transcription via WebSocket streaming
- **Punctuation & capitalization**: Built-in smart formatting
- **5.26% WER**: Best-in-class accuracy
- **$200 free credit**: Months of free use on signup

### Local STT (Parakeet)
- **Parakeet EOU 120M**: Fast, accurate streaming ASR (~5.73% WER)
- **100% on-device**: Nothing leaves your machine
- **Optional dual-pass**: Enable batch refinement for punctuation & improved accuracy

### Swappable Backends
Switch between cloud and local STT via the menu bar. API keys stored securely in app preferences.

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

- macOS 14.0+ (Sonoma or later)
- Apple Silicon recommended (M1/M2/M3/M4)
- Microphone + Accessibility permissions
- Internet connection (for Deepgram cloud STT; not needed for local mode)

## Development

```bash
# Navigate to Swift app
cd packages/app/Yappatron

# Build
swift build

# Run
.build/debug/Yappatron
```

## License

MIT

---

**Website**: [yappatron.pages.dev](https://yappatron.pages.dev)
**GitHub**: [github.com/alosec/yappatron](https://github.com/alosec/yappatron)
