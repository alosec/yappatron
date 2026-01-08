# Yappatron Memory Bank

## Project Overview
**Yappatron** - Open-source always-on voice dictation. No hotkeys, no toggles - just talk and text streams into focused inputs.

## Links
- **GitHub:** https://github.com/alosec/yappatron
- **Website:** https://yappatron.pages.dev (CF Pages, project: `yappatron`)

## Current Status
Real-time streaming works. 160ms latency. Words appear as you speak.

**P0 blocker:** Race condition crash in FluidAudio (yap-e049)

## Architecture
```
┌─────────────────────────────────────────────────┐
│ Swift (Yappatron.app) - menu bar + overlay      │
├─────────────────────────────────────────────────┤
│ AVFoundation mic (48kHz → 16kHz resampling)     │
│                  ↓                              │
│ FluidAudio StreamingEouAsrManager               │
│   • 160ms chunks → Neural Engine                │
│   • partialCallback → ghost text                │
│   • eouCallback → finalize utterance            │
│                  ↓                              │
│ InputSimulator (CGEvent keystroke injection)    │
│   • Diff-based: backspace corrections           │
│   • Types into focused text field               │
└─────────────────────────────────────────────────┘

packages/
├── app/Yappatron/     # Swift app (PRODUCTION)
├── core/              # Python prototype (DORMANT)
└── website/           # Astro landing page
```

## Licensing
All permissive. No GPL.

| Dependency | License | Notes |
|------------|---------|-------|
| FluidAudio | Apache 2.0 | Core streaming ASR |
| HotKey | MIT | Keyboard shortcuts |
| Parakeet models | MIT/Apache 2.0 | NVIDIA open models |
| Yappatron | MIT | This project |

⚠️ FluidAudioTTS (not used) includes GPL ESpeakNG - avoid if staying permissive.

## Key Files (Mac)
```
~/Workspace/yappatron/packages/app/Yappatron/
├── Package.swift                 # FluidAudio + HotKey deps
└── Sources/
    ├── YappatronApp.swift        # Main app, menu bar, hotkeys
    ├── TranscriptionEngine.swift # StreamingEouAsrManager wrapper
    ├── InputSimulator.swift      # CGEvent + diff-based ghost text
    └── OverlayWindow.swift       # Status bubble (blue/green)
```

## Commands (Mac)
```bash
# Build
cd ~/Workspace/yappatron/packages/app/Yappatron && swift build

# Deploy to /Applications
cp .build/debug/Yappatron /Applications/Yappatron.app/Contents/MacOS/
codesign --force --deep --sign - /Applications/Yappatron.app

# Run
tmux new-session -d -s yappatron '/Applications/Yappatron.app/Contents/MacOS/Yappatron 2>&1 | tee /tmp/yappatron.log'
tail -f /tmp/yappatron.log

# Kill
pkill -9 -f Yappatron
```

## Commands (VPS - deploy website)
```bash
cd ~/code/yappatron/packages/website
npm run build
CLOUDFLARE_API_TOKEN=$(cat ~/.config/cloudflare/pages-token) npx wrangler pages deploy dist --project-name yappatron
```

## Technical Notes

### Streaming ASR
- **Model:** parakeet-realtime-eou-120m (120M params, CoreML)
- **Chunk size:** 160ms (2560 samples at 16kHz)
- **EOU debounce:** 800ms silence confirms end-of-utterance
- **Inference:** Apple Neural Engine (ANE)

### Ghost Text Diffing
```swift
func applyTextUpdate(from oldText: String, to newText: String) {
    let commonPrefix = zip(old, new).prefix(while: ==).count
    deleteChars(old.count - commonPrefix)  // backspace
    typeString(new.dropFirst(commonPrefix)) // append
}
```
Partials accumulate ("hello" → "hello wor" → "hello world"). Backspacing only fires if model revises prediction mid-stream.

### EOU Semantics
Model is semantically aware:
- Complete thoughts → fast finalization
- Fragments ("okay", "um") → waits for continuation

### Models Location (Mac)
```
~/Library/Application Support/FluidAudio/Models/
└── parakeet-eou-streaming/160ms/
```

## Open Issues
Use `td list` in project directory. Key issues:

| ID | Priority | Description |
|----|----------|-------------|
| yap-e049 | P0 | Race condition crash in FluidAudio buffer |
| yap-ac58 | P2 | Custom vocabulary (Swift port) |
| yap-a4df | P2 | App notarization |

## TODO
- [ ] Sync td tasks from Mac ~/Workspace/yappatron
- [ ] Fix race condition (actor isolation or upstream fix)

## Session Log

### Jan 8, 2026 (VPS)
- Cloned repo, explored architecture
- Deployed website to yappatron.pages.dev
- Added sakura styling
- Documented licensing (all permissive)
- Created td tasks for tracking

### Jan 7, 2026 (Mac)
- Rewrote from Python+Whisper to pure Swift+FluidAudio
- Achieved 160ms streaming latency
- Consolidated Yappatron2 → Yappatron
- Hit race condition crash (unresolved)
