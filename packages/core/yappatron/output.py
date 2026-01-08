"""Output handling - keystroke simulation and clipboard."""

import subprocess
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum

from pynput.keyboard import Controller, Key


class OutputMode(Enum):
    """How to output transcribed text."""

    KEYSTROKE = "keystroke"  # Simulate keystrokes (character by character)
    PASTE = "paste"  # Paste from clipboard
    CALLBACK = "callback"  # Just call a callback (for UI)


@dataclass
class OutputConfig:
    """Output configuration."""

    mode: OutputMode = OutputMode.KEYSTROKE
    keystroke_delay: float = 0.01  # Delay between keystrokes (seconds)
    word_delay: float = 0.05  # Delay between words


class KeystrokeSimulator:
    """Simulate keystrokes to type text."""

    def __init__(self, config: OutputConfig | None = None):
        self.config = config or OutputConfig()
        self.keyboard = Controller()
        self._lock = threading.Lock()

    def type_character(self, char: str):
        """Type a single character."""
        with self._lock:
            try:
                self.keyboard.type(char)
            except Exception as e:
                print(f"Failed to type character '{char}': {e}")

    def type_text(self, text: str, delay: float | None = None):
        """Type text character by character.

        Args:
            text: Text to type
            delay: Optional delay between characters (overrides config)
        """
        delay = delay if delay is not None else self.config.keystroke_delay

        for char in text:
            self.type_character(char)
            if delay > 0:
                time.sleep(delay)

    def type_word(self, word: str, add_space: bool = True):
        """Type a word, optionally followed by a space.

        Args:
            word: Word to type
            add_space: Whether to add a trailing space
        """
        self.type_text(word.strip())
        if add_space:
            self.type_character(" ")


class ClipboardPaster:
    """Paste text via clipboard."""

    def __init__(self):
        self._lock = threading.Lock()

    def paste(self, text: str):
        """Copy text to clipboard and paste it.

        Args:
            text: Text to paste
        """
        with self._lock:
            try:
                # Use pbcopy on macOS to set clipboard
                process = subprocess.Popen(
                    ["pbcopy"],
                    stdin=subprocess.PIPE,
                    env={"LANG": "en_US.UTF-8"},
                )
                process.communicate(text.encode("utf-8"))

                # Simulate Cmd+V to paste
                keyboard = Controller()
                keyboard.press(Key.cmd)
                keyboard.press("v")
                keyboard.release("v")
                keyboard.release(Key.cmd)
            except Exception as e:
                print(f"Failed to paste: {e}")


class TextOutput:
    """Unified text output handler."""

    def __init__(
        self,
        config: OutputConfig | None = None,
        on_output: Callable[[str], None] | None = None,
    ):
        self.config = config or OutputConfig()
        self.keystroke = KeystrokeSimulator(config)
        self.clipboard = ClipboardPaster()
        self._on_output = on_output
        self._queue: list[str] = []
        self._lock = threading.Lock()
        self._output_thread: threading.Thread | None = None
        self._running = False

    def _output_loop(self):
        """Background loop for outputting text."""
        while self._running:
            with self._lock:
                if not self._queue:
                    time.sleep(0.01)
                    continue
                word = self._queue.pop(0)

            # Output the word
            if self.config.mode == OutputMode.KEYSTROKE:
                self.keystroke.type_word(word)
            elif self.config.mode == OutputMode.PASTE:
                self.clipboard.paste(word + " ")
            elif self.config.mode == OutputMode.CALLBACK:
                if self._on_output:
                    self._on_output(word)

            # Small delay between words
            if self.config.word_delay > 0:
                time.sleep(self.config.word_delay)

    def start(self):
        """Start the output handler."""
        if self._running:
            return

        self._running = True
        self._output_thread = threading.Thread(target=self._output_loop, daemon=True)
        self._output_thread.start()

    def stop(self):
        """Stop the output handler."""
        self._running = False
        if self._output_thread:
            self._output_thread.join(timeout=1.0)
            self._output_thread = None

    def output_word(self, word: str):
        """Queue a word for output.

        Args:
            word: Word to output
        """
        with self._lock:
            self._queue.append(word)

    def output_text(self, text: str):
        """Queue text for output (splits into words).

        Args:
            text: Text to output
        """
        words = text.split()
        with self._lock:
            self._queue.extend(words)

    def clear(self):
        """Clear the output queue."""
        with self._lock:
            self._queue = []


class StreamingOutput:
    """Character-by-character streaming output for real-time feel."""

    def __init__(
        self,
        char_delay: float = 0.02,
        on_char: Callable[[str], None] | None = None,
    ):
        self.char_delay = char_delay
        self.keyboard = Controller()
        self._on_char = on_char
        self._lock = threading.Lock()
        self._buffer = ""
        self._running = False
        self._thread: threading.Thread | None = None

    def _stream_loop(self):
        """Stream characters from buffer."""
        while self._running:
            char = None
            with self._lock:
                if self._buffer:
                    char = self._buffer[0]
                    self._buffer = self._buffer[1:]

            if char:
                try:
                    self.keyboard.type(char)
                    if self._on_char:
                        self._on_char(char)
                except Exception as e:
                    print(f"Stream error: {e}")

                time.sleep(self.char_delay)
            else:
                time.sleep(0.01)

    def start(self):
        """Start streaming."""
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._stream_loop, daemon=True)
        self._thread.start()

    def stop(self):
        """Stop streaming."""
        self._running = False
        if self._thread:
            self._thread.join(timeout=1.0)
            self._thread = None

    def feed(self, text: str):
        """Add text to the stream buffer.

        Args:
            text: Text to add
        """
        with self._lock:
            self._buffer += text

    def clear(self):
        """Clear the stream buffer."""
        with self._lock:
            self._buffer = ""
