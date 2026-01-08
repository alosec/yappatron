# Yappatron Memory Bank

## Project Overview
**Yappatron** - Open-source always-on voice dictation app. No hotkeys, no toggles - just talk and text streams into focused inputs.

## Current Status: Implementing Real-time Streaming 🚧
Batch transcription working (92-98% accuracy). Now implementing true streaming with `StreamingEouAsrManager`.

## GitHub Repo
https://github.com/alosec/yappatron

## Active Task: yap-3ed9 (Real-time Streaming)

### Architecture Change
```
BEFORE (Batch):
Audio → Accumulate → Silence detected → Transcribe whole buffer → Paste

AFTER (Streaming):  
Audio → 160ms chunks → StreamingEouAsrManager → partialCallback (ghost text)
                                               → eouCallback (commit final)
```

### Key Components
- **StreamingEouAsrManager**: 160ms chunk processing, EOU detection built-in
- **partialCallback**: Fires after each chunk with current transcript
- **eouCallback**: Fires when utterance ends (replaces our RMS VAD + silence timeout)
- **eouDebounceMs**: 1280ms default silence before confirming end

### Files to Modify
```
packages/app/Yappatron2/Sources/
├── TranscriptionEngine.swift  # Rewrite with StreamingEouAsrManager
├── InputSimulator.swift       # Add ghost text update (backspace + retype)
└── YappatronApp.swift         # Wire up partial vs final callbacks
```

## Architecture (Target)
```
Swift (Yappatron2.app)
┌─────────────────────────────────────────────────┐
│ AVFoundation mic (48kHz)                        │
│ vDSP resampling to 16kHz mono                   │
│ StreamingEouAsrManager (160ms chunks)           │
│   ├── partialCallback → ghost text updates      │
│   └── eouCallback → final commit                │
│ CGEvent keystrokes (with backspace correction)  │
│ Menu bar UI + status bubble overlay             │
└─────────────────────────────────────────────────┘
```

## Key Files
```
/Users/alex/Workspace/yappatron/
├── packages/app/Yappatron2/          # Pure Swift version
│   ├── Package.swift                 # FluidAudio + HotKey deps
│   └── Sources/
│       ├── YappatronApp.swift        # Main app, menu bar, hotkeys
│       ├── TranscriptionEngine.swift # Audio capture + streaming ASR
│       ├── InputSimulator.swift      # CGEvent keystrokes + ghost text
│       └── OverlayWindow.swift       # Status bubble UI
└── MEMBANK.md
```

## Commands
```bash
# Build
cd ~/Workspace/yappatron/packages/app/Yappatron2 && swift build

# Update app bundle
cp .build/debug/Yappatron /Applications/Yappatron2.app/Contents/MacOS/
codesign --force --deep --sign - /Applications/Yappatron2.app

# Run with logging (in tmux!)
tmux new-session -d -s yappatron '/Applications/Yappatron2.app/Contents/MacOS/Yappatron 2>&1 | tee /tmp/yappatron.log'

# Watch logs
tail -f /tmp/yappatron.log

# Kill
pkill -9 -f Yappatron

# Tasks
cd ~/Workspace/yappatron && export PATH="$HOME/.local/bin:$PATH" && td list
```

## Technical Notes

### FluidAudio Streaming Models
- Located in: `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Streaming/`
- `StreamingEouAsrManager.swift` - main streaming interface
- Requires separate streaming encoder models (different from batch)
- Chunk sizes: 160ms (default), 320ms, 1600ms

### Ghost Text Strategy
When partial transcript changes:
1. Calculate common prefix between old and new
2. Send backspaces to delete divergent suffix
3. Type new suffix
Example: "hello wor" → "hello world" = type "ld"
Example: "hello word" → "hello world" = backspace, type "ld"

### EOU vs VAD
- Old: RMS threshold (0.015) + 1.2s silence timeout
- New: EOU token predicted by model + 1280ms debounce
- EOU is smarter - trained on speech patterns, not just energy

## User Environment
- macOS 26.2 (Tahoe)
- Apple Silicon M4 MacBook Air, 16GB RAM
- Uses `td` tool for tasks (PATH: `$HOME/.local/bin`)
- Has AC unit causing noise - RMS VAD was triggering on it

## Recent Commits
- 6b5ec3e: MEMBANK: Document v2 success and next steps
- dea9b12: Yappatron2: Working transcription with FluidAudio!
- c383b9a: WIP: Swift-only rewrite with FluidAudio
