# Yappatron Features

**Current Version:** Swift 1.1 (2026-03-24)

## Overview

Yappatron is an always-on voice dictation app for macOS with swappable cloud and local STT backends. No push-to-talk—just speak and it types.

## Core Features

### ☁️ Cloud STT — Deepgram Nova-3 (Recommended)

Real-time streaming transcription via Deepgram's WebSocket API.

- **Sub-300ms latency**: Near-instant transcription as you speak
- **5.26% WER**: Best-in-class accuracy
- **Punctuation & capitalization**: Smart formatting built-in (no dual-pass needed)
- **Smart formatting**: Numbers, currency, and other entities formatted naturally
- **$200 free credit**: ~430 hours of streaming free on signup at deepgram.com

**Technical Details:**
- WebSocket streaming to `wss://api.deepgram.com/v1/listen`
- 16kHz mono linear16 PCM audio encoding
- `endpointing=800` for natural utterance boundary detection
- API key stored in app preferences (UserDefaults)
- Automatic keep-alive and reconnection handling

### 🏠 Local STT — Parakeet EOU 120M

Fully local, privacy-first transcription via Apple Neural Engine.

- **~80-160ms latency**: Fast on-device streaming
- **~5.73% WER**: Excellent accuracy for natural speech
- **100% local**: Nothing leaves your machine
- **No internet required**: Works completely offline

**Technical Details:**
- Parakeet EOU 120M model (320ms chunks)
- 16kHz mono audio capture via AVAudioEngine
- Actor-based buffer queue prevents race conditions
- Semantic end-of-utterance detection (waits for complete thoughts)

### 🔀 Swappable STT Backends

Switch between cloud and local STT via the menu bar:
- Right-click menu bar → **STT Backend** → choose provider
- API keys managed via **Set Deepgram API Key...** menu item
- Backend selection persists across sessions
- Requires app restart when switching

### ✨ Dual-Pass Refinement (Local Mode Only, Optional)

Enable via menu bar → "Dual-Pass Refinement (Punctuation)"

Only available when using Local (Parakeet) backend — cloud backends already return punctuated text.

**How it works:**
1. **First pass**: Fast streaming model shows unpunctuated text immediately
2. **On utterance end**: Larger batch model re-processes the complete audio
3. **Refinement**: Text updated with punctuation, capitalization, and improved accuracy

**Benefits:**
- **Better accuracy**: 600M parameter model vs 120M streaming model (5x larger)
- **Punctuation & capitalization**: Natural sentence formatting
- **Optional**: Disabled by default

**Technical Details:**
- Batch model: Parakeet TDT 0.6b v3 (600M params)
- Unconditional audio buffering captures complete utterances
- Diff-based text replacement (delete old, type new)
- ~50-100ms batch processing latency for typical utterances

### 🎨 Visual Feedback

**Psychedelic Orb Animations:**
- **Voronoi Cells** (default): Beautiful shifting patterns during speech
- **Concentric Rings**: Alternative RGB palette animation
- **Green orb**: Visual confirmation when utterance completes
- **Menu bar presence**: Always visible, unobtrusive

**Orb Selection:**
- Right-click menu bar orb
- Choose between Voronoi Cells or Concentric Rings
- Settings persist across sessions

### ⚡ Hands-Free Operation

**Auto-Send with Enter** (Optional):
- **Enabled**: Automatically presses Enter after each utterance
- **Perfect for**: Claude Code, ChatGPT, terminal commands
- **Disabled by default**: Better for document editing where you control when to send
- **Toggle**: Right-click menu bar → "Auto-Send with Enter"

**Use Cases:**
- Coding with AI assistants (completely hands-free)
- Writing documents (manual control)
- Terminal/CLI interaction
- Form filling

### 🔒 Privacy Options

- **Local mode**: 100% on-device, nothing leaves your machine
- **Cloud mode**: Audio streamed to Deepgram (see their privacy policy)
- **No telemetry**: Zero data collection by Yappatron itself
- **Your choice**: Switch between local and cloud anytime

## Menu Bar Controls

Right-click the orb to access:
- Status display with current backend indicator
- Pause / Resume
- ✓ Press Enter After Speech - Toggle hands-free operation
- ✓ Dual-Pass Refinement (local mode only) - Toggle enhanced accuracy
- **STT Backend** submenu - Switch between Deepgram / Local (Parakeet)
- **Set Deepgram API Key...** - Configure cloud STT credentials
- Orb Style Selector - Choose animation style
- Quit - Exit application

**Note**: Backend and dual-pass toggles require app restart to take effect.

## System Requirements

- macOS 14.0+ (Sonoma or later)
- Apple Silicon (M1/M2/M3/M4) recommended for best performance
- Microphone access permission
- Accessibility permission (for typing simulation)
- Internet connection (for Deepgram cloud STT; not needed for local mode)

## Models & Performance

### Cloud: Deepgram Nova-3
- **Latency**: Sub-300ms
- **Accuracy**: ~5.26% WER
- **Features**: Punctuation, capitalization, smart formatting, endpointing
- **Cost**: $0.46/hr ($200 free credit on signup)

### Local: Parakeet EOU 120M (Streaming)
- **Size**: 120M parameters
- **Latency**: ~80-160ms
- **Accuracy**: ~5.73% WER
- **Features**: End-of-utterance detection, semantic awareness

### Local: Parakeet TDT 0.6b v3 (Batch, Optional)
- **Size**: 600M parameters
- **Latency**: ~50-100ms (post-utterance)
- **Features**: Punctuation, capitalization, improved accuracy
- **Performance**: ~110× RTF on M4 Pro

## Build & Run

```bash
# Navigate to Swift app directory
cd ~/Workspace/yappatron/packages/app/Yappatron

# Build
swift build

# Run
.build/debug/Yappatron

# Or use the convenience script (builds, signs, installs)
cd ~/Workspace/yappatron
./scripts/run-dev.sh
```

## Architecture

**Single Process Design:**
- Pure Swift app (no Python, no daemon)
- Menu bar app with background audio processing
- SwiftUI for UI components
- Pluggable STT backends via `STTProvider` protocol
- FluidAudio for local ASR (Apache 2.0 license)
- Native `URLSessionWebSocketTask` for Deepgram streaming

**Audio Pipeline:**
```
Microphone → AVAudioEngine → 16kHz Resample → AudioBufferQueue
    ↓
STTProvider (swappable backend)
    ├── DeepgramSTTProvider: WebSocket → Deepgram Nova-3 (cloud)
    └── LocalSTTProvider: StreamingEouAsrManager → Parakeet EOU 120M (local)
    ↓
Partial Transcriptions (real-time ghost text)
    ↓
End-of-Utterance Detection (endpointing / 800ms silence)
    ↓
[Local only, optional] BatchProcessor (Parakeet TDT 0.6b)
    ↓
InputSimulator (diff-based typing)
```

## Technical Highlights

### Ghost Text Diffing
Partials are cumulative ("hello" → "hello wor" → "hello world"). The `InputSimulator.applyTextUpdate()` function:
1. Diffs old vs new text
2. Backspaces divergent suffix (only if model revises)
3. Types new suffix
4. Efficient: Only changes what's different

### Actor-Based Concurrency
- `AudioBufferQueue`: Thread-safe buffer management
- `AudioChunkBuffer`: Stores audio for batch re-processing
- Prevents race conditions in audio pipeline
- Clean async/await patterns

### EOU Semantic Awareness
The model understands complete thoughts:
- Fast finalization for complete sentences
- Waits for continuation on fragments
- 800ms silence debounce (reduced from 1280ms)
- Natural pause handling ("um", "uh" don't trigger premature EOU)

## Known Limitations

- **macOS only**: No Windows/Linux support (uses macOS-specific APIs)
- **No custom vocabulary**: Not yet ported from Python prototype
- **No speaker diarization**: Single-user dictation only
- **English-focused**: Primary testing in English (Deepgram supports 60+ languages)
- **Backend switch requires restart**: Cannot hot-swap between cloud/local yet

## Recent Changes

### Cloud STT Backend (2026-03-24)
- Added Deepgram Nova-3 as a cloud STT backend
- Pluggable `STTProvider` protocol for swappable backends
- WebSocket streaming with punctuation, smart formatting
- API key management via menu bar
- Automatically skips dual-pass when using cloud (already punctuated)

### Dual-Pass Audio Buffer Timing Bug Fix (2026-01-10)
- Fixed incomplete audio capture for batch model
- Unconditional audio buffering from utterance start

## Roadmap

### In Consideration
- Hot-swap backends without restart
- Additional cloud providers (Soniox, AssemblyAI)
- Visual feedback when refinement is processing
- Custom vocabulary (Swift port from Python prototype)
- App notarization for easier distribution

## License

MIT

## Links

- **Website**: [yappatron.pages.dev](https://yappatron.pages.dev)
- **GitHub**: [github.com/alosec/yappatron](https://github.com/alosec/yappatron)
- **FluidAudio**: [github.com/FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)
