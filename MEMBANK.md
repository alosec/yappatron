# Yappatron Memory Bank

## Project Overview
**Yappatron** - Open-source always-on voice dictation app. No hotkeys, no toggles - just talk and text streams into focused inputs.

## Current Status: STREAMING WORKS 🔥
Real-time streaming transcription is **profoundly strong**. Words appear instantly as you speak. Core UX is exactly what we wanted.

## GitHub Repo
https://github.com/alosec/yappatron

## Architecture (Production)
```
Swift (Yappatron.app)
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
- ✅ **Press Enter on complete** - auto-sends when EOU detected (persisted setting)
- ✅ **Pure Swift** - no Python, no WebSocket, single process
- ✅ **Neural Engine** - runs on ANE for efficiency

## CRITICAL BUG: Race Condition Crash (yap-4293)
App crashes randomly with assertion failure in `StreamingEouAsrManager.process()` at `removeFirst(_:)`. This is a thread-safety issue in FluidAudio's internal audio buffer handling.

**Current mitigation:** Serial DispatchQueue + semaphore in `processAudioBuffer()` - NOT SUFFICIENT.

**Real fix needed:** Either FluidAudio needs internal synchronization, or we need proper actor isolation.

## EOU Behavior (Understood)
The model is semantic-aware for End-of-Utterance detection:
- **Long/complete thoughts** → finalizes quickly after you stop
- **Short fragments** → waits longer, thinks you might continue

This is intentional. User adapts speech patterns to signal completion with conclusive language.

## Key Files
```
/Users/alex/Workspace/yappatron/packages/app/Yappatron/
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
cd ~/Workspace/yappatron/packages/app/Yappatron && swift build

# Deploy
cp .build/debug/Yappatron /Applications/Yappatron.app/Contents/MacOS/
codesign --force --deep --sign - /Applications/Yappatron.app

# Run (in tmux)
tmux new-session -d -s yappatron '/Applications/Yappatron.app/Contents/MacOS/Yappatron 2>&1 | tee /tmp/yappatron.log'

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
- **Model:** parakeet-realtime-eou-120m-coreml (120M params, 5x smaller than batch model)
- **Behavior:** Model is conservative on short utterances, waits for complete thoughts

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

## Open Issues (Priority Order)
1. **yap-4293** (P0 bug): App crashes on FluidAudio race condition - FIX NEXT
2. yap-d192: Website deployment
3. yap-d958: Custom vocabulary
4. yap-8e8b: App notarization
5. yap-0f5a: Error handling polish
6. yap-94a6: First-run experience
7. yap-dec5: Liquid glass overlay (macOS 26)
8. yap-19b3: Bottom bar ticker mode
9. yap-12d5: Overlay text scroll
10. yap-0e4f: Bubble status-only mode
11. yap-6b90: Filter hallucinations
12. yap-b856: Press Enter after speech

## User Environment
- macOS 26.2 (Tahoe)
- Apple Silicon M4 MacBook Air, 16GB RAM
- Task tool: `td` at `$HOME/.local/bin`

## Session Summary (Jan 7, 2026)
- Started with slow Python+Whisper batch transcription
- Rewrote in pure Swift with FluidAudio StreamingEouAsrManager
- Achieved instant real-time streaming (160ms latency)
- Consolidated Yappatron2 → Yappatron (single app bundle)
- Added UserDefaults persistence for Enter setting
- Discovered EOU is semantic-aware (works as intended for complete thoughts)
- **Unresolved:** Race condition crash in FluidAudio - needs proper fix

## Git Status
Clean at cb4e577, pushed to origin.
