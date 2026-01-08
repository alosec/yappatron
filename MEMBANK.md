# Yappatron Project Memory Bank

## What is Yappatron?
Open-source always-on voice dictation for macOS. No hotkeys, no toggles—just yap.

**Goal**: Replace Wispr Flow with something that:
- Always listens (no push-to-talk)
- Streams text character-by-character in real-time
- Is fully local/offline (Whisper-based)
- Shows streaming text in a floating bubble (AquaVoice-style)
- Supports speaker identification (only YOUR voice triggers)
- Has custom vocabulary support

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Yappatron.app                            │
│  ┌─────────────────────┐    ┌────────────────────────────┐ │
│  │   Swift UI          │───►│   Python Engine            │ │
│  │   - Menu bar icon   │audio│   - VAD (Silero)          │ │
│  │   - Floating bubble │◄───│   - Whisper transcription  │ │
│  │   - Audio capture   │text│   - Speaker ID             │ │
│  │   - Keystroke sim   │    │   - Custom vocabulary      │ │
│  └─────────────────────┘    └────────────────────────────┘ │
│         ▲        │                                          │
│         │        │                                          │
│    Keystrokes  Microphone                                   │
└─────────────────────────────────────────────────────────────┘
```

## Current State (as of 2026-01-07)

### What Works
- ✅ Audio capture in Swift (AVFoundation) - proper app permissions!
- ✅ Audio streaming from Swift → Python via WebSocket
- ✅ VAD (Silero) in Python
- ✅ Whisper transcription (faster-whisper)
- ✅ Swift menu bar app with floating overlay
- ✅ WebSocket communication between Python and Swift
- ✅ App bundle in /Applications/Yappatron.app
- ✅ Custom vocabulary (YAML config)
- ✅ Speaker identification framework
- ✅ Text streaming (fixed race condition)

### Key Files
- `packages/core/yappatron/` - Python engine
  - `audio.py` - VAD + mic capture
  - `transcribe.py` - Whisper wrapper
  - `server.py` - WebSocket server, TextBuffer
  - `main.py` - CLI entry point
- `packages/app/Yappatron/Sources/` - Swift UI
  - `YappatronApp.swift` - Main app, menu bar
  - `OverlayWindow.swift` - Floating bubble
  - `TextBuffer.swift` - Buffer management (BUG HERE?)
  - `WebSocketClient.swift` - Connects to Python
  - `InputSimulator.swift` - Keystroke simulation

### How to Run
```bash
# Launch app (starts both engine + UI)
open /Applications/Yappatron.app

# Or manually:
cd ~/Workspace/yappatron
source .venv/bin/activate
yappatron --no-speaker-id --model base  # Terminal 1
./packages/app/Yappatron/.build/debug/Yappatron  # Terminal 2

# View logs
tail -f ~/.yappatron/engine.log
```

### The Streaming Bug - Investigation Notes

The bug manifests as repeated partial text. Example:
```
All right, but weAll right, but we need toAll right,All right, but we nAll right...
```

**Hypotheses:**
1. Swift `streamNextChar()` timer firing multiple times
2. Race between `handleIncomingWord()` adding to buffer and `streamNextChar()` consuming
3. WebSocket sending duplicate messages
4. Python transcriber emitting words multiple times

**The flow:**
1. Python: `transcriber.transcribe_utterance(audio)` → calls `on_word` for each word
2. Python: `server.emit_word(word)` → sends via WebSocket
3. Swift: `handleIncomingWord(word)` → adds word to `textBuffer`
4. Swift: If input focused, starts `streamTimer` (20ms interval)
5. Swift: `streamNextChar()` → calls `textBuffer.sendChar()` → `inputSimulator.typeChar()`

**Suspect**: Step 4-5 race condition. Multiple words arriving while timer is running.

## Configuration

### Custom Vocabulary
File: `~/.yappatron/vocabulary.yaml`
```yaml
vocabulary:
  - word: Yappatron
    aliases: ["yap a tron", "yapper tron"]
  - word: API
    aliases: ["a p i"]
```

### Settings
File: `~/.yappatron/config/settings.yaml` (not yet implemented in UI)

## Dependencies

### Python
- faster-whisper (Whisper transcription)
- silero-vad (voice activity detection)
- sounddevice (audio capture)
- speechbrain (speaker identification)
- websockets (UI communication)

### Swift
- Starscream (WebSocket client)
- HotKey (global keyboard shortcuts)

## Next Steps (Priority Order)

1. ~~FIX THE STREAMING BUG~~ ✅ Fixed
2. ~~Move audio capture to Swift~~ ✅ Done - mic permissions now attributed to Yappatron.app
3. Add settings UI for model selection, thresholds
4. Launch at login option
5. Website deployment

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘⇧Z | Undo last word |
| ⌘⌥⇧Z | Pull all text back to bubble |
| ⌘⎋ | Toggle pause |
| ⌥Space | Toggle overlay |
