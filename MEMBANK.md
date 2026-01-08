# Yappatron Memory Bank

## Project Overview
**Yappatron** - Open-source always-on voice dictation app. No hotkeys, no toggles - just talk and text streams into focused inputs.

## Current Status: STREAMING WORKS 🔥
Real-time streaming transcription is **profoundly strong**. Words appear instantly as you speak. Core UX is exactly what we wanted.

## GitHub Repo
https://github.com/alosec/yappatron

## Architecture (Production)
```
Swift (Yappatron2.app)
┌─────────────────────────────────────────────────┐
│ AVFoundation mic (48kHz → 16kHz)                │
│ StreamingEouAsrManager (160ms chunks)           │
│   ├── partialCallback → ghost text (instant!)   │
│   └── eouCallback → finalize + Enter            │
│ InputSimulator (backspace corrections)          │
│ Menu bar UI + status bubble overlay             │
│   └── Blue=listening, Green=done                │
└─────────────────────────────────────────────────┘
```

## What's Working
- ✅ **Instant streaming** - words appear as you speak (160ms latency)
- ✅ **Ghost text** - updates live with backspace corrections
- ✅ **Status bubble** - blue while speaking, green when done
- ✅ **Press Enter on complete** - auto-sends when EOU detected
- ✅ **Pure Swift** - no Python, no WebSocket, single process
- ✅ **Neural Engine** - runs on ANE for efficiency

## Known Issue: EOU Timing (yap-ddf5)
The End-of-Utterance detection can hang for 5-7 seconds after speech ends. Root cause: the model intermittently produces tokens during silence, which resets the 800ms debounce timer. This is a FluidAudio model behavior, not easily fixable on our end.

**Attempted fixes that caused regressions:**
- Silero VAD as gate → race conditions, worse behavior
- Lowering debounce → cuts off speech mid-sentence

**The 800ms debounce is correct** - shorter would cause false triggers during natural pauses.

## Key Files
```
/Users/alex/Workspace/yappatron/packages/app/Yappatron2/
├── Package.swift                 # FluidAudio + HotKey deps
└── Sources/
    ├── YappatronApp.swift        # Main app, menu bar, hotkeys
    ├── TranscriptionEngine.swift # StreamingEouAsrManager
    ├── InputSimulator.swift      # CGEvent + ghost text
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

# Watch logs
tail -f /tmp/yappatron.log

# Kill
pkill -9 -f Yappatron

# Tasks
export PATH="$HOME/.local/bin:$PATH" && td list
```

## Technical Notes

### StreamingEouAsrManager
- **Chunk size:** 160ms (2560 samples)
- **EOU debounce:** 800ms (in FluidAudio code)
- **Model:** parakeet-realtime-eou-120m-coreml
- **Issue:** Model produces tokens during silence, resetting debounce

### Ghost Text Flow
1. partialCallback fires with updated text
2. InputSimulator.applyTextUpdate() diffs old vs new
3. Backspaces delete divergent suffix, types new suffix
4. Result: seamless live updates

### Models Location
```
~/Library/Application Support/FluidAudio/Models/
├── parakeet-eou-streaming/160ms/   # Streaming models (in use)
├── silero-vad-coreml/              # VAD (downloaded, not used)
└── parakeet-tdt-0.6b-v2-coreml/    # Batch models (not used)
```

## Open Issues
- **yap-ddf5** (bug): EOU detection hangs 5-7 seconds sometimes
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

## Session Summary (Jan 7, 2026)
Started with slow Python+Whisper batch transcription. Ended with instant real-time streaming via FluidAudio's StreamingEouAsrManager. The core UX is "profoundly strong" - words appear as you speak them. EOU timing needs work but the foundation is solid.

## Git Log
- 15f23fa: MEMBANK: Document real-time streaming achievement
- 3d8fd95: 🚀 Real-time streaming transcription!
- dea9b12: Yappatron2: Working batch transcription
- c383b9a: WIP: Swift-only rewrite with FluidAudio
