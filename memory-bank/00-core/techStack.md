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
| Styling | Custom CSS (sakura-inspired) |
| Hosting | Cloudflare Pages |
| Project | `yappatron` |

## Development (Mac)

```bash
# Build
swift build

# Deploy website (from VPS)
npm run build && wrangler pages deploy dist --project-name yappatron
```

## Dormant (Python Prototype)

Not used in production. Kept for reference.

- faster-whisper (batch ASR)
- silero-vad (VAD)
- speechbrain (speaker ID)
- pynput (keystrokes)
