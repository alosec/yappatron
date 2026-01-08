# Yappatron Memory Bank

## Project Overview
**Yappatron** - Open-source always-on voice dictation app (Wispr Flow replacement). No hotkeys, no toggles - just talk and text streams into focused inputs.

## Current Status: WORKING ✅
MVP functional. Audio → VAD → Whisper → Text → Type into focused input.

## GitHub Repo
https://github.com/alosec/yappatron

## Architecture
```
Swift (Yappatron.app)              Python Engine
┌──────────────────────┐           ┌──────────────────────┐
│ AVFoundation mic     │──audio──► │ Silero VAD           │
│ Menu bar UI          │  (WS)     │ faster-whisper       │
│ Floating overlay     │◄──text─── │ Speaker ID (optional)│
│ Keystroke simulation │           │                      │
└──────────────────────┘           └──────────────────────┘
```

- **WebSocket port**: 9876
- **Audio format**: 16kHz mono float32, base64 encoded chunks
- **Model**: `small` by default (~500MB)

## Key Insights & Gotchas

### Accessibility Permissions (CRITICAL)
- `AXIsProcessTrusted()` returns false when binary changes inside app bundle
- macOS ties accessibility permission to **code signature hash**
- **After every build**: must re-sign app AND user must re-grant permission
- Debug binary (`.build/debug/Yappatron`) vs app bundle (`/Applications/Yappatron.app`) are **separate apps** for permissions
- Fix workflow:
  ```bash
  # After building, re-sign:
  codesign --force --deep --sign - /Applications/Yappatron.app
  # Then user must: System Settings > Privacy & Security > Accessibility
  # Remove and re-add Yappatron.app
  ```

### Engine Management
- EngineManager spawns Python subprocess
- App checks if engine already running (port 9876) before starting another
- Stale engine processes can cause conflicts - always clean kill before testing

---

## Real-Time Streaming Transcription Research (Jan 2026)

### The UX Goal
Words appearing in real-time as you speak (like Aqua Voice), not batch processing after speech ends.

### The Core Constraint
We can only "paste" via CGEvent keystrokes - can't edit text already typed. Once a character is sent, it's sent.

### The Problem with Naive Streaming + Live Paste
- Streaming models emit *provisional* text that changes as context arrives
- "I want to" → "I want to go" → "I want to go home"
- If we paste immediately, we can't un-paste when model refines

### Possible Approaches

1. **Aqua Voice style:** Stream words to bubble in real-time, but only paste on trigger (silence detected or hotkey release). User sees live preview, paste is "committed" version.

2. **Aggressive streaming with backspace corrections:** Paste words as they're confirmed, use backspace to correct when model refines. Could be glitchy but would be an amazing party trick if smooth.

3. **Hybrid:** Show streaming preview in bubble, paste batches every N words once stable.

### Best Open Source STT Models (2026 Benchmarks)

| Model | WER | RTFx (Speed) | Params | Use Case |
|-------|-----|--------------|--------|----------|
| **Canary Qwen 2.5B** | 5.63% | 418x | 2.5B | Max accuracy (English) |
| **IBM Granite Speech 3.3 8B** | 5.85% | - | ~9B | Enterprise English |
| **Whisper Large V3** | 7.4% | varies | 1.55B | Multilingual (99+ langs) |
| **Whisper Large V3 Turbo** | 7.75% | 216x | 809M | Fast multilingual |
| **Distil-Whisper** | ~7.4% | 6x Whisper | 756M | Fast English |
| **Parakeet TDT 1.1B** | ~8% | **>2000x** | 1.1B | **Ultra low-latency streaming** |
| **Moonshine** | varies | fast | 27M | Edge/mobile |

**WER** = Word Error Rate (lower = more accurate). 5% = 1 error per 20 words.
**RTFx** = Real-Time Factor (higher = faster). 2000x = processes 33 min of audio in 1 second.

### Top Candidates for Real-Time Streaming

1. **Parakeet TDT** (NVIDIA) - RTFx >2000, RNN-Transducer architecture enables streaming with minimal latency. Purpose-built for live captioning. Trade-off: 23rd in accuracy.

2. **Moonshine** - 27M params, designed for edge devices, has live captions demo. 5-15x faster than Whisper. Last commit Nov 2025.

3. **Distil-Whisper** - 6x faster than Whisper, stays in Whisper ecosystem. English only.

### Likely Implementation Plan
- Keep Whisper as "high quality" batch option
- Add Parakeet TDT or Moonshine for real-time streaming
- Aggressive streaming approach: paste words as confident, backspace to correct
- This would be the differentiating "party trick" feature

---

## Key File Paths
```
/Users/alex/Workspace/yappatron/
├── packages/core/yappatron/
│   ├── main.py          # Python entry - VAD, transcription, WebSocket
│   ├── server.py        # WebSocket server
│   ├── transcribe.py    # faster-whisper wrapper
│   └── vocabulary.py    # Custom vocabulary
├── packages/app/Yappatron/Sources/
│   ├── YappatronApp.swift      # Main app delegate
│   ├── AudioCapture.swift      # AVFoundation mic
│   ├── WebSocketClient.swift   # Connects to Python
│   ├── EngineManager.swift     # Spawns Python subprocess
│   ├── InputSimulator.swift    # CGEvent keystrokes + accessibility
│   ├── OverlayWindow.swift     # Floating bubble UI
│   └── Settings.swift          # Settings UI
├── .venv/                       # Python 3.12 venv
└── MEMBANK.md                   # This file
```

## Commands
```bash
# Build
cd ~/Workspace/yappatron/packages/app/Yappatron && swift build

# Update app bundle (MUST re-sign after!)
cp .build/debug/Yappatron /Applications/Yappatron.app/Contents/MacOS/
codesign --force --deep --sign - /Applications/Yappatron.app

# Launch
open /Applications/Yappatron.app

# Kill all
pkill -9 -f yappatron; pkill -9 -f Yappatron

# View engine log
tail -f ~/.yappatron/engine.log

# Task management
cd ~/Workspace/yappatron && export PATH="$HOME/.local/bin:$PATH" && td list
```

## User Environment
- macOS 15.6 Sequoia (upgrading to macOS 26 for Liquid Glass)
- Apple Silicon M4 MacBook Air, 16GB RAM
- Uses `td` tool for tasks (PATH: `$HOME/.local/bin`)

## Open Tasks (11)
- yap-d192: Website deployment
- yap-d958: Feature: Custom vocabulary UI  
- yap-8e8b: Feature: App notarization
- yap-0f5a: Polish: Error handling
- yap-94a6: Polish: First-run experience
- yap-dec5: UI: Liquid glass overlay style (waiting for macOS 26)
- yap-19b3: UI: Bottom bar ticker mode
- yap-3ed9: Core: Real-time streaming transcription
- yap-12d5: UI: Fix overlay text scroll to end
- yap-0e4f: UI: Bubble as status-only when input focused
- yap-6b90: Core: Filter Whisper hallucinations
- yap-b856: Feature: Press Enter after speech

## Git Commits
- 6fc6b6b: Update MEMBANK with accessibility insights
- ddd5a6a: Fix paste - accessibility permission tied to app bundle signature
- 5122021: Add proper accessibility permission handling
- 6ef5079: Initial commit - MVP

## What's Working
- ✅ Audio capture (Swift AVFoundation)
- ✅ VAD + Whisper transcription (Python)
- ✅ WebSocket communication
- ✅ Text typing into focused inputs
- ✅ Overlay bubble (shows pending/sent text)
- ✅ Menu bar with status icons
- ✅ Settings UI (model selection)
- ✅ Keyboard shortcuts (undo, pause, toggle overlay)
- ✅ Accessibility permission handling (prompts once)

## Known Issues
- Overlay text doesn't scroll to end properly (shows middle)
- Transcription is batch (waits for speech end) not real-time streaming
- Whisper occasionally hallucinates (e.g., "bye bye bye bye")
