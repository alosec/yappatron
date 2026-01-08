# Yappatron

Open-source always-on voice dictation. No hotkeys, no toggles—just yap.

## What is this?

Yappatron is a fully local, privacy-respecting voice dictation system that:

- **Always listens** — No push-to-talk, no toggle. Just start talking.
- **Streams in real-time** — Characters appear as you speak.
- **Knows your voice** — Speaker identification so others can't hijack your input.
- **Context-aware** — Streams into focused text inputs, or collects in a floating bubble.
- **Fully offline** — All processing on-device. Nothing leaves your machine.
- **Custom vocabulary** — Add your own words, names, acronyms.

## Why?

Current dictation apps (Wispr Flow, etc.) require:
- Push-to-talk or toggle hotkeys
- Cloud processing
- Closed source "trust us" privacy

Yappatron is the dictation app that just works. Speak and it types. That's it.

## Installation

```bash
# Clone the repo
git clone https://github.com/yourusername/yappatron
cd yappatron

# Install dependencies
./scripts/install.sh

# Run
yappatron
```

## Structure

```
yappatron/
├── packages/
│   ├── core/          # Python engine (audio, transcription, output)
│   └── website/       # Astro landing page
├── models/            # Whisper models (downloaded on first run)
└── scripts/           # Installation and dev scripts
```

## Development

```bash
# Install dev dependencies
cd packages/core
pip install -e ".[dev]"

# Run in dev mode
python -m yappatron
```

## License

MIT
