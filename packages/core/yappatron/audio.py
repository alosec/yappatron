"""Audio capture and voice activity detection."""

import queue
import threading
import time
import hashlib
from collections.abc import Callable
from dataclasses import dataclass

import numpy as np
import sounddevice as sd
import torch
from silero_vad import load_silero_vad

# Limit torch threads for efficiency
torch.set_num_threads(1)


@dataclass
class AudioConfig:
    """Audio configuration."""

    sample_rate: int = 16000
    channels: int = 1
    blocksize: int = 512  # ~32ms at 16kHz
    dtype: str = "float32"


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

        audio_tensor = torch.from_numpy(audio_chunk).float()

        with torch.no_grad():
            speech_prob = self.model(audio_tensor, sample_rate).item()

        return speech_prob > self.threshold, speech_prob

    def reset(self):
        """Reset VAD state."""
        self.model.reset_states()


class AudioCapture:
    """Continuous audio capture with VAD - emits complete utterances."""

    def __init__(
        self,
        config: AudioConfig | None = None,
        vad_threshold: float = 0.5,
    ):
        self.config = config or AudioConfig()
        self.vad = VoiceActivityDetector(threshold=vad_threshold)
        self.audio_queue: queue.Queue[np.ndarray] = queue.Queue()
        self.speech_queue: queue.Queue[np.ndarray] = queue.Queue()
        self._running = False
        self._stream: sd.InputStream | None = None
        self._processor_thread: threading.Thread | None = None

        # Speech buffering
        self._speech_buffer: list[np.ndarray] = []
        self._silence_chunks = 0
        self._max_silence_chunks = 25  # ~800ms of silence to end utterance
        self._min_speech_chunks = 8  # Minimum chunks (~256ms) to be valid
        self._speech_chunk_count = 0
        
        # Cooldown to prevent re-triggers
        self._cooldown_until = 0.0
        self._cooldown_duration = 1.0  # 1 second cooldown
        
        # Deduplication - track recent utterance hashes
        self._recent_hashes: list[str] = []
        self._max_recent = 5

    def _hash_audio(self, audio: np.ndarray) -> str:
        """Create a hash of audio for deduplication."""
        # Downsample for faster hashing
        downsampled = audio[::100]
        return hashlib.md5(downsampled.tobytes()).hexdigest()[:16]

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info, status):
        """Callback for audio stream."""
        if status:
            print(f"Audio status: {status}")
        self.audio_queue.put(indata.copy().flatten())

    def _process_audio(self):
        """Process audio chunks with VAD."""
        while self._running:
            try:
                chunk = self.audio_queue.get(timeout=0.1)
            except queue.Empty:
                continue

            # Check cooldown
            if time.time() < self._cooldown_until:
                continue

            is_speech, confidence = self.vad.is_speech(chunk, self.config.sample_rate)

            if is_speech:
                self._speech_buffer.append(chunk)
                self._speech_chunk_count += 1
                self._silence_chunks = 0
            else:
                if self._speech_buffer:
                    self._silence_chunks += 1

                    # Buffer a bit of trailing silence
                    if self._silence_chunks <= 3:
                        self._speech_buffer.append(chunk)

                    # End of utterance
                    if self._silence_chunks >= self._max_silence_chunks:
                        if self._speech_chunk_count >= self._min_speech_chunks:
                            full_audio = np.concatenate(self._speech_buffer)
                            
                            # Check for duplicate
                            audio_hash = self._hash_audio(full_audio)
                            if audio_hash not in self._recent_hashes:
                                self._recent_hashes.append(audio_hash)
                                if len(self._recent_hashes) > self._max_recent:
                                    self._recent_hashes.pop(0)
                                
                                # Emit utterance
                                self.speech_queue.put(full_audio)
                                
                                # Start cooldown
                                self._cooldown_until = time.time() + self._cooldown_duration

                        # Reset state
                        self._speech_buffer = []
                        self._speech_chunk_count = 0
                        self._silence_chunks = 0
                        self.vad.reset()

    def start(self):
        """Start audio capture."""
        if self._running:
            return

        self._running = True

        self._stream = sd.InputStream(
            samplerate=self.config.sample_rate,
            channels=self.config.channels,
            dtype=self.config.dtype,
            blocksize=self.config.blocksize,
            callback=self._audio_callback,
        )
        self._stream.start()

        self._processor_thread = threading.Thread(target=self._process_audio, daemon=True)
        self._processor_thread.start()

        print(f"Audio capture started (sample rate: {self.config.sample_rate})")

    def stop(self):
        """Stop audio capture."""
        self._running = False

        if self._stream:
            self._stream.stop()
            self._stream.close()
            self._stream = None

        if self._processor_thread:
            self._processor_thread.join(timeout=1.0)
            self._processor_thread = None

        print("Audio capture stopped")

    def get_speech(self, timeout: float | None = None) -> np.ndarray | None:
        """Get the next complete utterance."""
        try:
            return self.speech_queue.get(timeout=timeout)
        except queue.Empty:
            return None


class StreamingAudioCapture:
    """Audio capture that streams chunks for real-time transcription."""

    def __init__(
        self,
        config: AudioConfig | None = None,
        vad_threshold: float = 0.5,
        on_speech_start: Callable[[], None] | None = None,
        on_speech_end: Callable[[], None] | None = None,
    ):
        self.config = config or AudioConfig()
        self.vad = VoiceActivityDetector(threshold=vad_threshold)
        self.chunk_queue: queue.Queue[np.ndarray] = queue.Queue()
        self._running = False
        self._stream: sd.InputStream | None = None
        self._is_speaking = False
        self._silence_chunks = 0
        self._max_silence_chunks = 30
        self._on_speech_start = on_speech_start
        self._on_speech_end = on_speech_end

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info, status):
        """Callback for audio stream."""
        if status:
            print(f"Audio status: {status}")

        chunk = indata.copy().flatten()
        is_speech, confidence = self.vad.is_speech(chunk, self.config.sample_rate)

        if is_speech:
            if not self._is_speaking:
                self._is_speaking = True
                if self._on_speech_start:
                    self._on_speech_start()

            self._silence_chunks = 0
            self.chunk_queue.put(chunk)
        else:
            if self._is_speaking:
                self._silence_chunks += 1

                if self._silence_chunks <= 5:
                    self.chunk_queue.put(chunk)

                if self._silence_chunks >= self._max_silence_chunks:
                    self._is_speaking = False
                    self._silence_chunks = 0
                    self.vad.reset()
                    if self._on_speech_end:
                        self._on_speech_end()

    def start(self):
        """Start streaming audio capture."""
        if self._running:
            return

        self._running = True
        self._stream = sd.InputStream(
            samplerate=self.config.sample_rate,
            channels=self.config.channels,
            dtype=self.config.dtype,
            blocksize=self.config.blocksize,
            callback=self._audio_callback,
        )
        self._stream.start()
        print(f"Streaming audio capture started (sample rate: {self.config.sample_rate})")

    def stop(self):
        """Stop streaming audio capture."""
        self._running = False
        if self._stream:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        print("Streaming audio capture stopped")

    def get_chunk(self, timeout: float | None = None) -> np.ndarray | None:
        """Get the next audio chunk."""
        try:
            return self.chunk_queue.get(timeout=timeout)
        except queue.Empty:
            return None

    @property
    def is_speaking(self) -> bool:
        """Check if currently detecting speech."""
        return self._is_speaking
