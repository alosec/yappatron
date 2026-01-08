# Yappatron Memory Bank

## Project Overview
**Yappatron** - Open-source always-on voice dictation app. No hotkeys, no toggles - just talk and text streams into focused inputs.

## Current Status: REAL-TIME STREAMING ACHIEVED 🎉🚀
**THE HOLY GRAIL:** Words appear AS YOU SPEAK THEM. 160ms latency. Instant.

## GitHub Repo
https://github.com/alosec/yappatron

## Architecture (Production)
```
Swift (Yappatron2.app)
┌─────────────────────────────────────────────────┐
│ AVFoundation mic (48kHz → 16kHz)                │
│ StreamingEouAsrManager (160ms chunks)           │
│   ├── partialCallback → ghost text (live)      │
│   └── eouCallback → finalize on speech end     │
│ InputSimulator (backspace corrections)          │
│ Menu bar UI + status bubble overlay             │
└─────────────────────────────────────────────────┘
```

## Key Achievements
- **160ms latency** - words appear as you speak
- **EOU detection** - model knows when you stop talking (no manual VAD)
- **AC noise immune** - EOU model ignores background noise
- **Ghost text** - updates live with backspace corrections
- **Pure Swift** - no Python, no WebSocket, single process

## Key Files
```
/Users/alex/Workspace/yappatron/packages/app/Yappatron2/
├── Package.swift                 # FluidAudio + HotKey deps
└── Sources/
    ├── YappatronApp.swift        # Main app, menu bar, hotkeys
    ├── TranscriptionEngine.swift # StreamingEouAsrManager integration
    ├── InputSimulator.swift      # CGEvent + ghost text updates
    └── OverlayWindow.swift       # Status bubble UI
```

## Commands
```bash
# Build
cd ~/Workspace/yappatron/packages/app/Yappatron2 && swift build

# Deploy
cp .build/debug/Yappatron /Applications/Yappatron2.app/Contents/MacOS/
codesign --force --deep --sign - /Applications/Yappatron2.app

# Run (in tmux)
tmux new-session -d -s yappatron '/Applications/Yappatron2.app/Contents/MacOS/Yappatron 2>&1 | tee /tmp/yappatron.log'

# Watch
tail -f /tmp/yappatron.log

# Kill
pkill -9 -f Yappatron

# Tasks
export PATH="$HOME/.local/bin:$PATH" && td list
```

## Technical Details

### StreamingEouAsrManager
- **Chunk size:** 160ms (2560 samples at 16kHz)
- **EOU debounce:** 800ms silence to confirm end
- **Model:** parakeet-realtime-eou-120m-coreml
- **Callbacks:** partialCallback (live updates), eouCallback (finalize)

### Ghost Text Flow
1. partialCallback fires with new text
2. InputSimulator.applyTextUpdate() calculates diff
3. Backspaces delete divergent suffix
4. Types new suffix
5. Result: seamless live updates

### Models Location
```
~/Library/Application Support/FluidAudio/Models/
├── parakeet-eou-streaming/160ms/  # Streaming models
└── parakeet-tdt-0.6b-v2-coreml/   # Batch models (unused now)
```

## Remaining Tasks (Backlog)
- yap-d192: Website deployment
- yap-d958: Custom vocabulary
- yap-8e8b: App notarization
- yap-0f5a: Error handling polish
- yap-94a6: First-run experience
- yap-dec5: Liquid glass overlay (macOS 26)
- yap-19b3: Bottom bar ticker mode
- yap-12d5: Overlay text scroll
- yap-0e4f: Bubble status-only mode
- yap-6b90: Filter hallucinations
- yap-b856: Press Enter after speech

## User Environment
- macOS 26.2 (Tahoe)
- Apple Silicon M4 MacBook Air, 16GB RAM
- Task tool: `td` at `$HOME/.local/bin`

## Git Log
- 3d8fd95: 🚀 Real-time streaming transcription!
- 6b5ec3e: MEMBANK: Document v2 success
- dea9b12: Yappatron2: Working batch transcription
- c383b9a: WIP: Swift-only rewrite with FluidAudio
