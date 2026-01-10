# Tech Stack

## Production (Swift App)

| Component | Technology | Purpose |
|-----------|------------|---------|
| Language | Swift 5.9+ | Native macOS |
| UI | SwiftUI | Menu bar + overlay |
| Audio | AVFoundation | Mic capture, resampling |
| ASR | FluidAudio | Streaming transcription |
| Input | CGEvent | Keystroke injection |
| Hotkeys | HotKey | Global shortcuts |

## Models

| Model | Size | Latency | Use |
|-------|------|---------|-----|
| Parakeet EOU 120M | ~250MB | 160ms | Streaming ASR |

Models auto-download to `~/Library/Application Support/FluidAudio/Models/`

## Website

| Component | Technology |
|-----------|------------|
| Framework | Astro 4 |
| Styling | Custom CSS (RGB orb, light/dark mode) |
| Hosting | Cloudflare Pages |
| Project | `yappatron` |
| URL | https://yappatron.pages.dev |

### Website Deployment (from VPS)

**IMPORTANT:** The Cloudflare Pages project name is `yappatron` (not `yappa` or anything else from wrangler.toml).

```bash
cd /home/alex/code/yappatron/packages/website
npm run build
CLOUDFLARE_API_TOKEN=$(cat ~/.config/cloudflare/pages-token) npx wrangler pages deploy dist --project-name yappatron
```

### Local Development

```bash
cd /home/alex/code/yappatron/packages/website
npm run dev
# Runs on http://localhost:4321
# SSH tunnel: ssh -L 4321:localhost:4321 tiny-bat
```

## Development (Mac)

```bash
# Build
swift build

# Run dev script
./scripts/run-dev.sh
```

## Dormant (Python Prototype)

Not used in production. Kept for reference.

- faster-whisper (batch ASR)
- silero-vad (VAD)
- speechbrain (speaker ID)
- pynput (keystrokes)
