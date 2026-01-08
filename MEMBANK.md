# Yappatron Memory Bank

## Project Overview
**Yappatron** - Open-source always-on voice dictation app (Wispr Flow replacement). No hotkeys, no toggles - just talk and text streams into focused inputs.

## Current Status: WORKING v2 ✅ 🎉
**Major milestone achieved!** Pure Swift implementation with FluidAudio is working:
- Parakeet TDT v2 transcription with 92-98% confidence
- ~85-100ms transcription latency after speech ends
- No Python, no WebSocket, no subprocess
- Runs on Apple Neural Engine

## GitHub Repo
https://github.com/alosec/yappatron

## Architecture (v2 - Current)
```
Swift (Yappatron2.app) - EVERYTHING IN ONE PROCESS
┌─────────────────────────────────────────────────┐
│ AVFoundation mic (48kHz)                        │
│ vDSP resampling to 16kHz mono                   │
│ RMS-based speech detection (threshold: 0.015)  │
│ FluidAudio ASR (Parakeet TDT v2 on ANE)        │
│ CGEvent keystrokes                              │
│ Menu bar UI + status bubble overlay             │
└─────────────────────────────────────────────────┘
```

## Key Files (v2)
```
/Users/alex/Workspace/yappatron/
├── packages/app/Yappatron2/          # NEW - Pure Swift version
│   ├── Package.swift                 # FluidAudio + HotKey deps
│   └── Sources/
│       ├── YappatronApp.swift        # Main app, menu bar, hotkeys
│       ├── TranscriptionEngine.swift # Audio capture + ASR
│       ├── InputSimulator.swift      # CGEvent keystrokes
│       └── OverlayWindow.swift       # Status bubble UI
├── packages/app/Yappatron/           # OLD - Python/WebSocket version
├── packages/core/yappatron/          # OLD - Python engine
└── MEMBANK.md
```

## Commands (v2)
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

## User Feedback (Jan 7, 2026)
- "This is shockingly great"
- "This is definitely a major improvement"
- "I'm already sold - this is so much better"
- "The coolest thing is the visual bubble showing status"
- BUT: Still chunk-based, not real-time streaming
- INSIGHT: If batch processing, paste whole chunk at once (char-by-char streaming is artificial delay)

## Key Technical Insights

### Audio Pipeline
- Input: 48kHz mono from MacBook Air mic
- Resampling: vDSP-based linear interpolation to 16kHz (like FluidVoice does)
- VAD: Simple RMS threshold (0.015) - room noise is ~0.009-0.01
- Silence timeout: 1.2 seconds triggers end of speech

### FluidAudio Integration
- Uses `AsrModels.downloadAndLoad(version: .v2)` for English-only model
- `AsrManager.transcribe(samples, source: .microphone)` for batch transcription
- Models cached at `~/Library/Application Support/FluidAudio/Models/`
- Runs on cpuAndNeuralEngine compute units

### Chunk vs Streaming Transcription
**Current (Chunk/Batch):**
1. Accumulate audio while speaking
2. Detect silence (1.2s timeout)
3. Transcribe entire buffer at once
4. Paste result

**Goal (Real-time Streaming):**
1. Transcribe incrementally as audio arrives
2. Words appear as you speak them
3. May need to backspace/correct as context changes
4. FluidAudio has `StreamingEouAsrManager` for this

### Paste Strategy
- Current: char-by-char with 2ms delay (feels slow)
- Should do: paste whole chunk at once for batch mode
- Future: word-by-word streaming for real-time mode

## Open Tasks (13)
- yap-d192: Website deployment
- yap-d958: Feature: Custom vocabulary
- yap-8e8b: Feature: App notarization
- yap-0f5a: Polish: Error handling
- yap-94a6: Polish: First-run experience
- yap-dec5: UI: Liquid glass overlay style (needs macOS 26)
- yap-19b3: UI: Bottom bar ticker mode
- yap-3ed9: Core: Real-time streaming transcription ⭐ (the holy grail)
- yap-12d5: UI: Fix overlay text scroll to end
- yap-0e4f: UI: Bubble as status-only when input focused
- yap-6b90: Core: Filter Whisper hallucinations
- yap-b856: Feature: Press Enter after speech
- yap-9724: Perf: Paste whole chunk instead of char-by-char

## Next Steps
1. **Quick win:** Paste whole chunk at once (yap-9724) - remove artificial char-by-char delay
2. **Holy grail:** Real-time streaming with `StreamingEouAsrManager` (yap-3ed9)
3. **Polish:** Reduce silence timeout, tune RMS threshold

## User Environment
- macOS 26.2 (Sequoia successor)
- Apple Silicon M4 MacBook Air, 16GB RAM
- Uses `td` tool for tasks (PATH: `$HOME/.local/bin`)

## Git History
- dea9b12: Yappatron2: Working transcription with FluidAudio!
- c383b9a: WIP: Swift-only rewrite with FluidAudio
- ee84801: MEMBANK: Add real-time streaming research
- 6fc6b6b: Update MEMBANK with accessibility insights
