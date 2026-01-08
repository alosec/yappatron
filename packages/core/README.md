# Yappatron Core

The Python engine for Yappatron - always-on voice dictation.

## Components

- `audio.py` - Audio capture with voice activity detection (Silero VAD)
- `transcribe.py` - Streaming transcription (faster-whisper)
- `speaker.py` - Speaker identification (SpeechBrain)
- `output.py` - Keystroke simulation and clipboard
- `context.py` - Detect focused text inputs (macOS)
- `vocabulary.py` - Custom vocabulary support
- `main.py` - Main application entry point

## Installation

```bash
pip install -e .
```

## Usage

```bash
yappatron              # Start dictating
yappatron enroll       # Enroll your voice
yappatron --model small  # Use larger model
```
