"""Streaming transcription using faster-whisper."""

import threading
import queue
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from faster_whisper import WhisperModel


@dataclass
class TranscriptionConfig:
    """Transcription configuration."""

    model_size: str = "base"  # tiny, base, small, medium, large-v3
    device: str = "auto"  # auto, cpu, cuda
    compute_type: str = "auto"  # auto, int8, float16, float32
    language: str = "en"
    beam_size: int = 5
    vad_filter: bool = False  # We do our own VAD


class Transcriber:
    """Whisper-based transcription."""

    def __init__(self, config: TranscriptionConfig | None = None, models_dir: Path | None = None):
        self.config = config or TranscriptionConfig()
        self.models_dir = models_dir or Path.home() / ".yappatron" / "models"
        self.models_dir.mkdir(parents=True, exist_ok=True)

        print(f"Loading Whisper model '{self.config.model_size}'...")
        self.model = WhisperModel(
            self.config.model_size,
            device=self.config.device,
            compute_type=self.config.compute_type,
            download_root=str(self.models_dir),
        )
        print("Model loaded.")

    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        """Transcribe audio to text.

        Args:
            audio: Audio data as float32 numpy array
            sample_rate: Sample rate (should be 16000)

        Returns:
            Transcribed text
        """
        segments, info = self.model.transcribe(
            audio,
            language=self.config.language,
            beam_size=self.config.beam_size,
            vad_filter=self.config.vad_filter,
        )

        # Combine all segments
        text_parts = []
        for segment in segments:
            text_parts.append(segment.text)

        return "".join(text_parts).strip()


class RealtimeTranscriber:
    """Real-time transcription - transcribes complete utterances."""

    def __init__(
        self,
        config: TranscriptionConfig | None = None,
        models_dir: Path | None = None,
        on_word: Callable[[str], None] | None = None,
        on_utterance: Callable[[str], None] | None = None,
    ):
        self.config = config or TranscriptionConfig()
        self.transcriber = Transcriber(config, models_dir)
        self._running = False
        self._thread: threading.Thread | None = None
        self._on_word = on_word
        self._on_utterance = on_utterance

        # Queue for complete utterances (audio chunks)
        self._utterance_queue: queue.Queue[np.ndarray | None] = queue.Queue()

    def _process_loop(self):
        """Main processing loop - transcribes complete utterances."""
        while self._running:
            try:
                audio = self._utterance_queue.get(timeout=0.1)
            except queue.Empty:
                continue

            if audio is None:
                continue

            # Skip very short audio
            if len(audio) < 4800:  # Less than 300ms at 16kHz
                continue

            # Transcribe the complete utterance
            text = self.transcriber.transcribe(audio)
            
            if text and text.strip():
                text = text.strip()
                print(f" → \"{text}\"")
                
                # Emit the full utterance
                if self._on_utterance:
                    self._on_utterance(text)
                
                # Also emit word by word for streaming UI
                if self._on_word:
                    words = text.split()
                    for word in words:
                        self._on_word(word)

    def start(self):
        """Start the transcription processor."""
        if self._running:
            return

        self._running = True
        self._thread = threading.Thread(target=self._process_loop, daemon=True)
        self._thread.start()
        print("Transcriber started")

    def stop(self):
        """Stop the transcription processor."""
        self._running = False
        if self._thread:
            self._thread.join(timeout=2.0)
            self._thread = None
        print("Transcriber stopped")

    def transcribe_utterance(self, audio: np.ndarray):
        """Queue a complete utterance for transcription.

        Args:
            audio: Complete utterance audio as numpy array
        """
        self._utterance_queue.put(audio)

    # Keep old interface for compatibility
    def feed(self, audio: np.ndarray):
        """Deprecated - use transcribe_utterance for complete utterances."""
        pass

    def end_utterance(self):
        """Deprecated - utterances are now atomic."""
        pass
