# Exploration: Text-Based Incremental Refinement

**Created:** 2026-01-09 (post dual-pass implementation)
**Status:** 🤔 Conceptual exploration, needs further clarity

## The Question

After implementing and testing the dual-pass audio re-processing system, a question emerged:

> "If we're backspacing it all and retyping it with the final post-processing, then the streaming is largely irrelevant. But if we're pointing another local model at the text itself, that would enable incremental text refinement during streaming."

## Current System Analysis

### What Happens Now (Dual-Pass Audio)

```
Audio stream → Parakeet EOU 120M (fast)
           ↓
  Unpunctuated text displayed immediately
           ↓
  User sees: "this is a test sentence"
           ↓
     [EOU detected]
           ↓
  Audio re-processed with Parakeet TDT 0.6b
           ↓
  DELETE all streamed text
           ↓
  RETYPE refined version
           ↓
  User sees: "This is a test sentence."
```

### The Philosophical Problem

**Key observation:**
> "The streaming is sometimes better than the second post-process. It just doesn't have punctuation or capitalization."

This raises questions:
1. If we delete everything, why show streaming text at all?
2. What if the streaming transcription is MORE accurate than batch?
3. Are we throwing away good data just to get punctuation?
4. Does this make the streaming "feel" pointless?

## Alternative Vision: Text-Based Incremental Refinement

### Concept

Instead of re-processing audio, process the streaming TEXT incrementally with a lightweight editing model:

```
Audio stream → Parakeet EOU 120M (fast)
           ↓
  "this is a test" (unpunctuated)
           ↓
  Text editing model (lightweight)
           ↓
  "This is a test" (formatted)
           ↓
  Display formatted text
           ↓
  Continue streaming...
           ↓
  "sentence with multiple words"
           ↓
  Text editing model (with context)
           ↓
  ", sentence with multiple words."
           ↓
  Append to previous text
```

### Key Characteristics

**Timing:**
- Refinement happens DURING streaming, not after EOU
- Process text in smaller chunks as it arrives
- Potentially no visible "correction" phase

**Source of truth:**
- Streaming transcription IS the final output (word-level)
- Text model ONLY adds formatting (punctuation, capitalization)
- Preserves streaming accuracy

**Model requirements:**
- Lightweight punctuation restoration model (text → text)
- Must handle partial/incomplete sentences
- Needs context from previous chunks
- Lower latency than full ASR re-processing

## Comparison Table

| Aspect | Current (Audio Re-processing) | Proposed (Text Refinement) |
|--------|-------------------------------|----------------------------|
| **Input for refinement** | Audio samples | Streaming text |
| **When refinement happens** | After EOU (batch) | During streaming (incremental) |
| **Word accuracy** | May improve or worsen | Preserves streaming accuracy |
| **Formatting** | From larger ASR model | From dedicated text model |
| **Streaming relevance** | Discarded after EOU | Final output (formatted) |
| **Visible effect** | Delete/retype | Continuous formatting |
| **Latency** | Wait for EOU + batch | Incremental (potentially faster perceived) |
| **Model size** | Large ASR (600M) | Small text model (<100M?) |
| **Accuracy tradeoff** | Batch ASR might be better/worse | Keeps streaming (no re-transcription) |

## Potential Benefits

**Preserves streaming quality:**
- Keeps the transcription you already have
- Avoids potential regressions from batch model
- User observation: "streaming is sometimes better"

**True streaming feel:**
- Text appears formatted from the start (or very quickly)
- No delete/retype effect needed
- Streaming remains relevant throughout

**Lower latency:**
- Lightweight text model vs. full ASR
- Incremental processing (don't wait for full utterance)
- Could feel more responsive

**Flexibility:**
- Text model can be swapped/customized
- Could support style variants (formal, casual)
- Easier to fine-tune for specific use cases

## Potential Challenges

**Incomplete context:**
- Mid-sentence processing might add incorrect punctuation
- "This is a" → model might add period too early
- Need to track context and potentially revise

**No accuracy improvements:**
- Can't fix word-level errors from streaming model
- If streaming says "there" instead of "their", text model won't fix it
- Limited to formatting improvements only

**Model selection:**
- Need to find/train appropriate punctuation model
- Must handle streaming/partial text well
- CoreML compatibility required

**Context management:**
- How much previous text to consider?
- When to finalize punctuation decisions?
- Handling sentence boundaries mid-stream

## Hybrid Approach: Both Options?

Potentially offer TWO refinement modes:

### Mode 1: Text-Only Refinement (Default)
- Stream → Lightweight text editing model → Formatted output
- Preserves streaming transcription
- Fast, lightweight, true streaming feel
- Use when: Speed priority, streaming quality is good

### Mode 2: Audio Re-transcription (Accuracy Focus)
- Stream → Batch audio re-processing → Replace text
- What we built today
- Better word-level accuracy potential
- Use when: Accuracy priority, willing to wait

**User choice:**
- Could be automatic (heuristic based on confidence scores?)
- Could be manual toggle
- Could be per-context (code vs. prose vs. chat)

## Open Questions

1. **When to finalize punctuation?**
   - Do we wait for EOU even with text model?
   - Or continuously refine as text streams?
   - How to handle revisions to already-displayed text?

2. **How much context to provide?**
   - Just current chunk?
   - Last N words?
   - Entire utterance so far?
   - Multiple utterances?

3. **What text model to use?**
   - Find pre-trained CoreML punctuation model?
   - Train custom model?
   - Use small language model (distilled BERT/GPT)?
   - Latency requirements?

4. **Is streaming "good enough"?**
   - Need to measure streaming vs. batch accuracy
   - Is the batch model actually better on average?
   - Or just better at punctuation?

5. **Can we do both?**
   - Text refinement during streaming (formatting)
   - PLUS audio re-processing on EOU (accuracy)
   - Best of both worlds? Or too complex?

## Next Steps (When Ready)

1. **Gather data on quality comparison**
   - Measure streaming vs. batch word accuracy
   - Quantify: "streaming is sometimes better" - how often?
   - Identify cases where each model excels

2. **Research text editing models**
   - Survey available punctuation restoration models
   - Check CoreML compatibility
   - Benchmark latency on target hardware

3. **Prototype text-based approach**
   - Implement simple version with stub model
   - Test incremental refinement UX
   - Compare feel to current dual-pass system

4. **User testing**
   - Try both approaches in real usage
   - Evaluate which feels better
   - Determine if hybrid mode is worth complexity

## Refined Vision: Continuous Diff-Based Text Editing

**Updated:** 2026-01-09 (evening, after clarification)

### Core Concept

**A continuous diff editor that applies incremental surgical edits to streaming text, using native text manipulation commands.**

Not:
- Wait for EOU → delete all → retype all

Instead:
- Text streams → model generates diffs → apply targeted edits continuously
- Use proper text editor commands (Shift+Arrow, Home/End, etc.)
- Minimal disruption, surgical changes only

### Architecture Components

**1. Text Processing Model (Text → Text)**
- Input: Streaming unpunctuated text
- Output: Diffs/edits to apply
- Runs continuously (decoupled from EOU)
- Can handle:
  - Punctuation insertion
  - Capitalization changes
  - Spelling corrections
  - Style transformations (casual → formal)
  - General cleanup

**2. Diff Editor API**
```swift
protocol TextEditCommand {
    func execute(via simulator: InputSimulator)
}

struct NavigateCommand: TextEditCommand {
    enum Position {
        case home, end
        case wordForward, wordBackward
        case characterForward(count: Int)
        case characterBackward(count: Int)
    }
    let to: Position
}

struct SelectCommand: TextEditCommand {
    enum SelectionType {
        case characters(count: Int, direction: Direction)
        case word(direction: Direction)
        case toEnd, toStart
    }
    let type: SelectionType
}

struct ReplaceCommand: TextEditCommand {
    let selection: Range<Int>  // What to select first
    let replacement: String     // What to type
}

struct InsertCommand: TextEditCommand {
    let at: Position
    let text: String
}
```

**3. Diff Generator**
```swift
actor DiffGenerator {
    private let textModel: MLModel  // Lightweight text processing model

    func generateEdits(
        from original: String,
        context: String,
        style: EditStyle = .default
    ) async -> [TextEditCommand] {
        // Model produces desired output
        let refined = await textModel.process(original, context: context, style: style)

        // Compute minimal edit sequence
        let diffs = computeDiff(from: original, to: refined)

        // Convert to text editor commands
        return diffsToCommands(diffs)
    }
}

enum EditStyle {
    case `default`
    case formal
    case casual
    case technical
}
```

**4. Edit Applier**
```swift
class EditApplier {
    private let simulator: InputSimulator

    func apply(_ commands: [TextEditCommand]) {
        for command in commands {
            command.execute(via: simulator)
        }
    }
}
```

### Example Flow

**Scenario:** Capitalize first letter and add period

**Current approach:**
```
Text: "this is a test"  (24 chars typed)
→ Delete 14 characters (backspace 14 times)
→ Type "This is a test."  (15 chars typed)
Total: 24 + 14 + 15 = 53 operations
```

**Diff editor approach:**
```
Text: "this is a test"
→ Home (1 operation)
→ Shift+Right (select "t")
→ Type "T" (replaces selection)
→ End (1 operation)
→ Type "."
Total: 5 operations
```

### Integration with Streaming

**Continuous refinement:**
```swift
// As text streams in
engine.onPartialTranscription = { partial in
    // Type the raw streaming text
    inputSimulator.typeString(newWords)

    // Trigger diff generation (async, non-blocking)
    Task {
        let edits = await diffGenerator.generateEdits(
            from: partial,
            context: previousText
        )
        editApplier.apply(edits)
    }
}
```

**Key characteristics:**
- Edits happen continuously, not just at EOU
- Text model processes streaming output (not audio)
- Surgical changes preserve most typed text
- Streaming transcription is the source of truth (for words)
- Model adds punctuation, fixes spelling, transforms style

### API Design Considerations

**1. Command Sequence Optimization**
- Batch related operations
- Minimize cursor movement
- Use most efficient selection method

**2. Error Handling**
- What if text editor doesn't support certain commands?
- Fallback to simpler operations
- Detect when text has changed unexpectedly

**3. Context Tracking**
- Track what text is currently displayed
- Know cursor position
- Handle concurrent edits

**4. Performance**
- Commands should be fast (<10ms each)
- Batch operations when possible
- Async diff generation doesn't block

### Benefits Over Current Approach

**Preserves streaming quality:**
- Words from streaming model stay
- Only formatting/corrections applied
- No wholesale replacement

**Tighter integration:**
- Streaming and refinement are interleaved
- Continuous process, not two-phase
- "Rifle on the wall" fires continuously

**More flexible:**
- Can apply style transformations
- User can request different formatting
- Works with partial sentences

**Better UX:**
- Minimal visual disruption
- Looks like smart editing, not replacement
- Works better with editor undo/redo

### Open Questions

1. **Model selection:** What text processing model to use?
   - Small LLM (distilled GPT/Llama)?
   - Specialized punctuation + spelling model?
   - Multiple models for different tasks?

2. **Edit frequency:** How often to generate diffs?
   - Every N words?
   - Time-based throttling?
   - Only on natural boundaries?

3. **Command reliability:** Do all editors support these commands?
   - Test across different apps
   - Build fallback strategies
   - Document known limitations

4. **Latency budget:** How fast must edits apply?
   - Target <50ms per edit?
   - Queue vs immediate execution?
   - Prioritize visible changes?

### Next Steps (When Ready)

1. **Design full API surface** for text editing commands
2. **Extend InputSimulator** with navigation and selection primitives
3. **Research text processing models** suitable for continuous editing
4. **Prototype diff generator** with simple rules
5. **Test command reliability** across target applications
6. **Compare UX** with current dual-pass audio approach

## User's Current State

**Status:** Vision is now clearer. The goal is continuous diff-based editing with proper text manipulation commands, decoupled from EOU detection, using a lightweight text processing model that runs incrementally.

**Key insight:** The "tightness" comes from streaming and refinement being interleaved through a proper text editing API, not bolted together through delete/retype.

## References

- Current implementation: [dual-pass-approach.md](./dual-pass-approach.md)
- Original punctuation research: [punctuation-post-processing.md](./punctuation-post-processing.md)
- Implementation session: [2026-01-09-dual-pass-implementation.md](../05-sessions/2026-01-09-dual-pass-implementation.md)
