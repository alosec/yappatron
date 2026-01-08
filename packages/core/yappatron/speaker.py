"""Speaker identification and enrollment."""

import json
import threading
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch

# Lazy import to avoid torchaudio compatibility issues
SpeakerRecognition = None


def _get_speaker_recognition():
    """Lazily import SpeakerRecognition to avoid startup issues."""
    global SpeakerRecognition
    if SpeakerRecognition is None:
        try:
            from speechbrain.inference.speaker import SpeakerRecognition as SR
            SpeakerRecognition = SR
        except Exception as e:
            print(f"Warning: Could not load speaker recognition: {e}")
            return None
    return SpeakerRecognition


@dataclass
class SpeakerConfig:
    """Speaker identification configuration."""

    threshold: float = 0.25  # Similarity threshold for verification
    enrollment_duration: float = 30.0  # Seconds of audio for enrollment
    sample_rate: int = 16000


class SpeakerIdentifier:
    """Speaker identification using SpeechBrain."""

    def __init__(
        self,
        config: SpeakerConfig | None = None,
        data_dir: Path | None = None,
    ):
        self.config = config or SpeakerConfig()
        self.data_dir = data_dir or Path.home() / ".yappatron" / "speaker"
        self.data_dir.mkdir(parents=True, exist_ok=True)

        self.embeddings_file = self.data_dir / "embeddings.json"
        self._enrolled_embedding: np.ndarray | None = None
        self._model: SpeakerRecognition | None = None
        self._model_lock = threading.Lock()

        # Load existing enrollment if available
        self._load_enrollment()

    def _ensure_model(self):
        """Lazily load the speaker recognition model."""
        if self._model is None:
            with self._model_lock:
                if self._model is None:
                    SR = _get_speaker_recognition()
                    if SR is None:
                        print("Speaker recognition not available.")
                        return False
                    print("Loading speaker recognition model...")
                    self._model = SR.from_hparams(
                        source="speechbrain/spkrec-ecapa-voxceleb",
                        savedir=str(self.data_dir / "model"),
                    )
                    print("Speaker model loaded.")
        return True

    def _load_enrollment(self):
        """Load enrolled speaker embedding from disk."""
        if self.embeddings_file.exists():
            try:
                with open(self.embeddings_file) as f:
                    data = json.load(f)
                self._enrolled_embedding = np.array(data["embedding"])
                print("Loaded enrolled speaker profile.")
            except Exception as e:
                print(f"Failed to load speaker enrollment: {e}")
                self._enrolled_embedding = None

    def _save_enrollment(self):
        """Save enrolled speaker embedding to disk."""
        if self._enrolled_embedding is not None:
            with open(self.embeddings_file, "w") as f:
                json.dump({"embedding": self._enrolled_embedding.tolist()}, f)

    def _get_embedding(self, audio: np.ndarray) -> np.ndarray | None:
        """Extract speaker embedding from audio.

        Args:
            audio: Audio data as float32 numpy array (16kHz)

        Returns:
            Speaker embedding as numpy array, or None if model unavailable
        """
        if not self._ensure_model():
            return None

        # Convert to torch tensor
        audio_tensor = torch.from_numpy(audio).float().unsqueeze(0)

        # Get embedding
        with torch.no_grad():
            embedding = self._model.encode_batch(audio_tensor)

        return embedding.squeeze().numpy()

    @property
    def is_enrolled(self) -> bool:
        """Check if a speaker is enrolled."""
        return self._enrolled_embedding is not None

    def enroll(self, audio: np.ndarray) -> bool:
        """Enroll a speaker from audio.

        Args:
            audio: Audio data as float32 numpy array (should be ~30 seconds)

        Returns:
            True if enrollment successful
        """
        try:
            # Get embedding from the audio
            embedding = self._get_embedding(audio)
            if embedding is None:
                print("Enrollment failed: Speaker recognition not available.")
                return False
            self._enrolled_embedding = embedding
            self._save_enrollment()
            print("Speaker enrolled successfully.")
            return True
        except Exception as e:
            print(f"Enrollment failed: {e}")
            return False

    def verify(self, audio: np.ndarray) -> tuple[bool, float]:
        """Verify if audio matches enrolled speaker.

        Args:
            audio: Audio data as float32 numpy array

        Returns:
            Tuple of (is_match, similarity_score)
        """
        if not self.is_enrolled:
            # If no enrollment, allow all (permissive mode)
            return True, 1.0

        try:
            # Get embedding for input audio
            embedding = self._get_embedding(audio)
            if embedding is None:
                # Model not available, be permissive
                return True, 1.0

            # Compute cosine similarity
            similarity = np.dot(self._enrolled_embedding, embedding) / (
                np.linalg.norm(self._enrolled_embedding) * np.linalg.norm(embedding)
            )

            is_match = similarity >= self.config.threshold
            return is_match, float(similarity)
        except Exception as e:
            print(f"Verification error: {e}")
            # On error, be permissive
            return True, 0.0

    def clear_enrollment(self):
        """Clear the enrolled speaker."""
        self._enrolled_embedding = None
        if self.embeddings_file.exists():
            self.embeddings_file.unlink()
        print("Speaker enrollment cleared.")


class SpeakerVerificationFilter:
    """Filter that only passes audio from the enrolled speaker."""

    def __init__(
        self,
        identifier: SpeakerIdentifier,
        min_audio_for_verification: float = 0.5,  # seconds
        sample_rate: int = 16000,
    ):
        self.identifier = identifier
        self.min_samples = int(min_audio_for_verification * sample_rate)
        self.sample_rate = sample_rate
        self._audio_buffer: list[np.ndarray] = []
        self._buffer_samples = 0
        self._last_verified = False
        self._verification_interval = int(2.0 * sample_rate)  # Re-verify every 2 seconds
        self._samples_since_verification = 0

    def process(self, audio_chunk: np.ndarray) -> tuple[bool, np.ndarray | None]:
        """Process an audio chunk.

        Args:
            audio_chunk: Audio data

        Returns:
            Tuple of (is_verified_speaker, audio_to_transcribe)
        """
        self._audio_buffer.append(audio_chunk)
        self._buffer_samples += len(audio_chunk)
        self._samples_since_verification += len(audio_chunk)

        # Not enough audio yet for verification
        if self._buffer_samples < self.min_samples:
            return False, None

        # Check if we need to verify
        if (
            not self._last_verified
            or self._samples_since_verification >= self._verification_interval
        ):
            full_audio = np.concatenate(self._audio_buffer)
            is_match, score = self.identifier.verify(full_audio)
            self._last_verified = is_match
            self._samples_since_verification = 0

            if not is_match:
                # Not the enrolled speaker, clear buffer
                self._audio_buffer = []
                self._buffer_samples = 0
                return False, None

        # Return the audio for transcription
        if self._last_verified:
            result = np.concatenate(self._audio_buffer)
            # Keep some overlap for continuous verification
            if len(self._audio_buffer) > 5:
                self._audio_buffer = self._audio_buffer[-3:]
                self._buffer_samples = sum(len(c) for c in self._audio_buffer)
            return True, result

        return False, None

    def reset(self):
        """Reset the filter state."""
        self._audio_buffer = []
        self._buffer_samples = 0
        self._last_verified = False
        self._samples_since_verification = 0
