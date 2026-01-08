# Yappatron Memory Bank

## Project Overview
**Yappatron** - Open-source always-on voice dictation app (Wispr Flow replacement). No hotkeys, no toggles - just talk and text streams into focused inputs.

## Current Status: BROKEN - PASTING NOT WORKING
Text is transcribing but not being typed into focused inputs. Need to debug.

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
- **Audio format**: 16kHz mono float32, base64 encoded chunks (512 samples)
- **Model**: Currently using `small` (~500MB, good quality)

## GitHub Repo
https://github.com/alosec/yappatron

## Key File Paths
```
/Users/alex/Workspace/yappatron/
├── packages/core/yappatron/
│   ├── main.py          # Python entry - VAD, transcription, WebSocket server
│   ├── server.py        # WebSocket server - receives audio, sends text
│   ├── transcribe.py    # faster-whisper wrapper
│   └── vocabulary.py    # Custom vocabulary processing
├── packages/app/Yappatron/Sources/
│   ├── YappatronApp.swift      # Main app delegate
│   ├── AudioCapture.swift      # AVFoundation mic capture
│   ├── WebSocketClient.swift   # Connects to Python engine
│   ├── EngineManager.swift     # Spawns/manages Python subprocess
│   ├── Settings.swift          # Settings UI + AppSettings class
│   ├── InputSimulator.swift    # CGEvent keystroke simulation + accessibility
│   └── OverlayWindow.swift     # Floating bubble UI
├── packages/app/Yappatron/Yappatron.app/  # App bundle
├── .venv/                       # Python 3.12 venv
└── MEMBANK.md                   # This file
```

## Commands
```bash
# Build Swift app
cd ~/Workspace/yappatron/packages/app/Yappatron && swift build

# Update app bundle
cp .build/debug/Yappatron /Applications/Yappatron.app/Contents/MacOS/

# Launch
open /Applications/Yappatron.app

# Kill all
pkill -9 -f yappatron; pkill -9 -f Yappatron

# View engine log
tail -f ~/.yappatron/engine.log

# Task management
cd ~/Workspace/yappatron && export PATH="$HOME/.local/bin:$PATH" && td list

# Watch Swift logs
log show --predicate 'process == "Yappatron"' --last 1m | grep "\[Yappatron\]"
```

## Known Issues
1. **CURRENT BUG**: Text not pasting to focused inputs
   - Transcription works (see engine.log)
   - WebSocket connected
   - Issue likely in: InputSimulator.isTextInputFocused() or streamPendingToInput()

## Recent Git Commits
- 5122021: Add proper accessibility permission handling
- 6ef5079: Initial commit - MVP

## User Preferences
- macOS 15.6 Sequoia (upgrading to macOS 26 for Liquid Glass)
- Apple Silicon M4 MacBook Air, 16GB RAM
- Uses `td` tool for task tracking (PATH: `$HOME/.local/bin`)
- Prefers committing working states frequently

## Open Tasks (8)
- yap-d192: Website deployment
- yap-d958: Feature: Custom vocabulary UI
- yap-8e8b: Feature: App notarization
- yap-0f5a: Polish: Error handling
- yap-94a6: Polish: First-run experience
- yap-dec5: UI: Liquid glass overlay style (waiting for macOS 26)
- yap-19b3: UI: Bottom bar ticker mode
- yap-3ed9: Core: Real-time streaming transcription

## Completed (10)
- Settings UI, model selection, launch at login, quit function
- Settings window, status indicators, overlay improvements, keyboard shortcuts
- Undo support, audio capture reliability
