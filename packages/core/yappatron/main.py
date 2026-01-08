"""Yappatron - Main entry point."""

import argparse
import signal
import sys
import threading
import time
from pathlib import Path

import numpy as np

from .context import AccessibilityContextDetector
from .output import OutputConfig, OutputMode, StreamingOutput
from .server import JsonRpcServer
from .speaker import SpeakerConfig, SpeakerIdentifier
from .transcribe import RealtimeTranscriber, TranscriptionConfig
from .vocabulary import Vocabulary


# Import VAD separately (we still need it for processing audio from Swift)
import torch
from silero_vad import load_silero_vad
torch.set_num_threads(1)


class VoiceActivityDetector:
    """Silero-based voice activity detection."""

    def __init__(self, threshold: float = 0.5):
        self.threshold = threshold
        self.model = load_silero_vad()
        self.model.eval()

    def is_speech(self, audio_chunk: np.ndarray, sample_rate: int = 16000) -> tuple[bool, float]:
        """Check if audio chunk contains speech."""
        if len(audio_chunk) == 0:
            return False, 0.0

        # Make writable copy to avoid PyTorch warning
        audio_tensor = torch.from_numpy(audio_chunk.copy()).float()

        with torch.no_grad():
            speech_prob = self.model(audio_tensor, sample_rate).item()

        return speech_prob > self.threshold, speech_prob

    def reset(self):
        """Reset VAD state."""
        self.model.reset_states()


class Yappatron:
    """Main Yappatron application - receives audio from Swift UI."""

    def __init__(
        self,
        model_size: str = "base",
        enable_speaker_id: bool = True,
        data_dir: Path | None = None,
    ):
        self.data_dir = data_dir or Path.home() / ".yappatron"
        self.data_dir.mkdir(parents=True, exist_ok=True)

        print("Initializing Yappatron...")

        # Vocabulary
        self.vocabulary = Vocabulary(self.data_dir / "vocabulary.yaml")

        # Speaker identification
        self.enable_speaker_id = enable_speaker_id
        if enable_speaker_id:
            self.speaker = SpeakerIdentifier(
                config=SpeakerConfig(),
                data_dir=self.data_dir / "speaker",
            )
        else:
            self.speaker = None

        # VAD for processing incoming audio
        self.vad = VoiceActivityDetector(threshold=0.5)
        
        # Speech buffering state
        self._speech_buffer: list[np.ndarray] = []
        self._silence_chunks = 0
        self._max_silence_chunks = 25  # ~800ms of silence to end utterance
        self._min_speech_chunks = 8
        self._speech_chunk_count = 0
        self._cooldown_until = 0.0
        self._is_speaking = False

        # WebSocket server
        self.server = JsonRpcServer(port=9876)
        self.server.on_audio_chunk = self._on_audio_chunk
        self.server.on_pause = self._handle_pause
        self.server.on_resume = self._handle_resume

        # Transcriber
        self.transcriber = RealtimeTranscriber(
            config=TranscriptionConfig(model_size=model_size),
            models_dir=self.data_dir / "models",
            on_word=self._on_word,
        )

        # State
        self._running = False
        self._paused = False
        self._lock = threading.Lock()

        print("Yappatron initialized.")

    def _on_audio_chunk(self, audio: np.ndarray):
        """Process audio chunk received from Swift."""
        if self._paused:
            return
        
        # Check cooldown
        if time.time() < self._cooldown_until:
            return
        
        with self._lock:
            is_speech, confidence = self.vad.is_speech(audio, 16000)
            
            if is_speech:
                if not self._is_speaking:
                    self._is_speaking = True
                    self.server.emit_speech_start()
                    print("\n[Speech detected]", end="", flush=True)
                
                self._speech_buffer.append(audio)
                self._speech_chunk_count += 1
                self._silence_chunks = 0
            else:
                if self._speech_buffer:
                    self._silence_chunks += 1
                    
                    # Buffer a bit of trailing silence
                    if self._silence_chunks <= 3:
                        self._speech_buffer.append(audio)
                    
                    # End of utterance
                    if self._silence_chunks >= self._max_silence_chunks:
                        if self._speech_chunk_count >= self._min_speech_chunks:
                            full_audio = np.concatenate(self._speech_buffer)
                            self._process_utterance(full_audio)
                            self._cooldown_until = time.time() + 1.0
                        
                        # Reset
                        self._speech_buffer = []
                        self._speech_chunk_count = 0
                        self._silence_chunks = 0
                        self._is_speaking = False
                        self.vad.reset()
                        self.server.emit_speech_end()

    def _process_utterance(self, audio: np.ndarray):
        """Process a complete utterance."""
        # Speaker verification
        if self.speaker and self.speaker.is_enrolled:
            is_match, score = self.speaker.verify(audio)
            if not is_match:
                print(f" [Not you: {score:.2f}]", flush=True)
                return
        
        print(" [Transcribing...]", end="", flush=True)
        self.transcriber.transcribe_utterance(audio)

    def _on_word(self, word: str):
        """Called when a word is transcribed."""
        if self._paused:
            return
            
        processed = self.vocabulary.process_text(word)
        self.server.emit_word(processed)

    def _handle_pause(self):
        self._paused = True
        print("\n[Paused]")
    
    def _handle_resume(self):
        self._paused = False
        print("\n[Resumed]")

    def start(self):
        """Start Yappatron."""
        if self._running:
            return

        print("\n" + "=" * 50)
        print("YAPPATRON - Just yap!")
        print("=" * 50)

        if self.speaker and not self.speaker.is_enrolled:
            print("\nNo speaker enrolled. Run 'yappatron enroll' first for speaker ID.")
            print("Continuing without speaker verification...\n")

        self._running = True

        # Start server (waits for Swift to connect and send audio)
        self.server.start()
        print("Waiting for Swift UI to connect and send audio...")

        # Start transcriber
        self.transcriber.start()

        print("\nListening... (Ctrl+C to stop)\n")

    def stop(self):
        """Stop Yappatron."""
        if not self._running:
            return

        print("\nShutting down...")
        self._running = False

        self.transcriber.stop()
        self.server.stop()

        print("Yappatron stopped.")

    def enroll_speaker(self, duration: float = 30.0):
        """Enroll the current speaker."""
        if not self.speaker:
            print("Speaker identification is disabled.")
            return

        print(f"\nSpeaker Enrollment")
        print("=" * 50)
        print("This feature requires the Swift UI to be running.")
        print("Please use the Swift UI for enrollment.")


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Yappatron - Always-on voice dictation. Just yap.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  yappatron                    Start dictation
  yappatron --model small      Use larger model for better accuracy
  yappatron --no-speaker-id    Disable speaker verification
        """,
    )

    parser.add_argument(
        "command",
        nargs="?",
        default="run",
        choices=["run", "enroll"],
        help="Command to run (default: run)",
    )
    parser.add_argument(
        "--model",
        "-m",
        default="base",
        choices=["tiny", "base", "small", "medium", "large-v3"],
        help="Whisper model size (default: base)",
    )
    parser.add_argument(
        "--no-speaker-id",
        action="store_true",
        help="Disable speaker identification",
    )

    args = parser.parse_args()

    # Create app
    app = Yappatron(
        model_size=args.model,
        enable_speaker_id=not args.no_speaker_id,
    )

    # Handle Ctrl+C
    def signal_handler(sig, frame):
        app.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)

    # Run command
    if args.command == "enroll":
        app.enroll_speaker()
    else:
        app.start()
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            app.stop()


if __name__ == "__main__":
    main()
