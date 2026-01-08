"""Custom vocabulary handling."""

import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml


@dataclass
class VocabularyEntry:
    """A custom vocabulary entry."""

    word: str  # The word as it should appear
    aliases: list[str] = field(default_factory=list)  # Alternative spellings/transcriptions
    description: str = ""  # Optional description


@dataclass
class VocabularyConfig:
    """Vocabulary configuration."""

    entries: list[VocabularyEntry] = field(default_factory=list)


class Vocabulary:
    """Custom vocabulary for improving transcription accuracy."""

    def __init__(self, config_path: Path | None = None):
        self.config_path = config_path or Path.home() / ".yappatron" / "vocabulary.yaml"
        self._entries: dict[str, VocabularyEntry] = {}
        self._alias_map: dict[str, str] = {}  # alias -> canonical word
        self._load()

    def _load(self):
        """Load vocabulary from config file."""
        if not self.config_path.exists():
            self._create_default()
            return

        try:
            with open(self.config_path) as f:
                data = yaml.safe_load(f) or {}

            entries = data.get("vocabulary", [])
            for entry_data in entries:
                if isinstance(entry_data, str):
                    # Simple word entry
                    entry = VocabularyEntry(word=entry_data)
                elif isinstance(entry_data, dict):
                    entry = VocabularyEntry(
                        word=entry_data.get("word", ""),
                        aliases=entry_data.get("aliases", []),
                        description=entry_data.get("description", ""),
                    )
                else:
                    continue

                if entry.word:
                    self._entries[entry.word.lower()] = entry
                    # Map aliases to canonical word
                    for alias in entry.aliases:
                        self._alias_map[alias.lower()] = entry.word

            print(f"Loaded {len(self._entries)} vocabulary entries")
        except Exception as e:
            print(f"Failed to load vocabulary: {e}")

    def _create_default(self):
        """Create default vocabulary file."""
        self.config_path.parent.mkdir(parents=True, exist_ok=True)

        default_config = {
            "vocabulary": [
                {
                    "word": "Yappatron",
                    "aliases": ["yap a tron", "yapper tron", "yaptron"],
                    "description": "The name of this application",
                },
                {
                    "word": "API",
                    "aliases": ["a p i", "A.P.I."],
                },
                {
                    "word": "CLI",
                    "aliases": ["c l i", "C.L.I."],
                },
                {
                    "word": "OAuth",
                    "aliases": ["o auth", "O.Auth"],
                },
            ]
        }

        with open(self.config_path, "w") as f:
            yaml.dump(default_config, f, default_flow_style=False, allow_unicode=True)

        print(f"Created default vocabulary at {self.config_path}")
        self._load()

    def save(self):
        """Save current vocabulary to config file."""
        entries_data = []
        for entry in self._entries.values():
            entry_dict = {"word": entry.word}
            if entry.aliases:
                entry_dict["aliases"] = entry.aliases
            if entry.description:
                entry_dict["description"] = entry.description
            entries_data.append(entry_dict)

        with open(self.config_path, "w") as f:
            yaml.dump({"vocabulary": entries_data}, f, default_flow_style=False, allow_unicode=True)

    def add_entry(self, word: str, aliases: list[str] | None = None, description: str = ""):
        """Add a vocabulary entry.

        Args:
            word: The canonical word
            aliases: Alternative spellings/transcriptions
            description: Optional description
        """
        entry = VocabularyEntry(
            word=word,
            aliases=aliases or [],
            description=description,
        )
        self._entries[word.lower()] = entry
        for alias in entry.aliases:
            self._alias_map[alias.lower()] = word
        self.save()

    def remove_entry(self, word: str):
        """Remove a vocabulary entry.

        Args:
            word: The word to remove
        """
        key = word.lower()
        if key in self._entries:
            entry = self._entries[key]
            # Remove alias mappings
            for alias in entry.aliases:
                self._alias_map.pop(alias.lower(), None)
            del self._entries[key]
            self.save()

    def process_text(self, text: str) -> str:
        """Process text, replacing aliases with canonical words.

        Args:
            text: Input text

        Returns:
            Text with aliases replaced
        """
        result = text

        # Replace multi-word aliases first (longer matches first)
        sorted_aliases = sorted(self._alias_map.keys(), key=len, reverse=True)
        for alias in sorted_aliases:
            if " " in alias:  # Multi-word alias
                pattern = re.compile(re.escape(alias), re.IGNORECASE)
                result = pattern.sub(self._alias_map[alias], result)

        # Replace single-word aliases
        words = result.split()
        processed_words = []
        for word in words:
            # Preserve punctuation
            prefix = ""
            suffix = ""
            clean_word = word

            # Extract leading/trailing punctuation
            while clean_word and not clean_word[0].isalnum():
                prefix += clean_word[0]
                clean_word = clean_word[1:]
            while clean_word and not clean_word[-1].isalnum():
                suffix = clean_word[-1] + suffix
                clean_word = clean_word[:-1]

            # Check for alias
            if clean_word.lower() in self._alias_map:
                clean_word = self._alias_map[clean_word.lower()]

            processed_words.append(prefix + clean_word + suffix)

        return " ".join(processed_words)

    def get_prompt_words(self) -> list[str]:
        """Get list of words to use as Whisper initial prompt.

        This helps Whisper recognize custom vocabulary.

        Returns:
            List of vocabulary words
        """
        return [entry.word for entry in self._entries.values()]

    def get_entries(self) -> list[VocabularyEntry]:
        """Get all vocabulary entries.

        Returns:
            List of vocabulary entries
        """
        return list(self._entries.values())
