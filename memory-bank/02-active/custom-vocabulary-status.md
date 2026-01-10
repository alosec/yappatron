# Custom Vocabulary Status

**Created:** 2026-01-09
**Status:** Not Implemented

## Summary

Custom vocabulary is **promised in README but NOT implemented**. There is zero code for this feature.

## What Doesn't Exist

- No code for adding/loading custom word lists
- No vocabulary files (`.txt`, `.json`, or `.plist`)
- No user interface for managing custom words
- No persistent storage (UserDefaults or file-based)
- No hotword or keyword spotting functionality
- No domain-specific vocabulary sets
- No phonetic customization

## Architectural Constraints

The **Parakeet EOU 120M ASR model** (via FluidAudio) does not expose:
- Vocabulary customization APIs
- Phonetic lexicon injection
- Domain-specific model adaptation

This is a fundamental limitation of the underlying model, not just the Swift implementation.

## Task Tracking

- **yap-d958** (P2, backlog) - "Feature: Custom vocabulary"
- Description: UI to add/edit custom words and replacements. Auto-correct common mistranscriptions.

## Implementation Options (Future)

If we want to add this feature, we would need to:

1. **Post-processing approach** (more feasible)
   - Use the disabled refinement infrastructure
   - Add custom word replacement rules to PunctuationModel
   - Store custom vocabulary in UserDefaults or JSON file
   - Apply corrections during EOU refinement phase

2. **Model-level approach** (harder)
   - Switch to an ASR model that supports vocabulary injection
   - Would require significant architecture changes

## Recommendation

Keep in backlog as P2. Not trivial to implement given model constraints. Focus on core streaming experience first.

## References

- Task: yap-d958
- README.md line 14 (promises feature)
- Analysis done: 2026-01-09 via Explore agent (acccce8)
