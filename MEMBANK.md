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

## Open Tasks (9)
- yap-d192: Website deployment
- yap-d958: Feature: Custom vocabulary UI  
- yap-8e8b: Feature: App notarization
- yap-0f5a: Polish: Error handling
- yap-94a6: Polish: First-run experience
- yap-dec5: UI: Liquid glass overlay style (waiting for macOS 26)
- yap-19b3: UI: Bottom bar ticker mode
- yap-3ed9: Core: Real-time streaming transcription
- yap-12d5: UI: Fix overlay text scroll to end

## Git Commits
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
