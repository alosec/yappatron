# Code Cleanup Plan

**Created:** 2026-01-09
**Status:** Ready for Implementation
**Task:** yap-87cd

## Philosophy

Keep LLM refinement as **optional feature** (default disabled) rather than deleting completely. Some users may prefer it despite the trade-offs.

## What to Remove (~750 lines)

### 1. TextEditing Suite (yap-87cd.1)
**DELETE entirely:**
- `/Sources/TextEditing/DiffGenerator.swift` (127 lines)
- `/Sources/TextEditing/EditApplier.swift` (76 lines)
- `/Sources/TextEditing/TextEditCommand.swift` (140 lines)
- `/Sources/TextEditing/TextStateTracker.swift` (33 lines)

**Reason:** Built for dual-pass refinement, never used, zero external references.

### 2. Dual-Pass Infrastructure (yap-87cd.2)
**DELETE entirely:**
- `/Sources/BatchProcessor.swift` (75 lines)
- `/Sources/TextRefinementManager.swift` (68 lines)

**Reason:** Dual-pass creates visible backspace/retype effect that's distracting for long dictations. Sometimes worse than streaming.

### 3. TranscriptionEngine Cleanup (yap-87cd.3)
**REMOVE from TranscriptionEngine.swift:**
- `AudioChunkBuffer` actor (48 lines) - orphaned, only used for dual-pass
- `audioChunkBuffer` property
- `onUtteranceComplete` callback - never wired up in YappatronApp
- Audio buffer initialization in setupAudioCapture()
- Audio sample retrieval in handleFinalTranscription()

**Reason:** These support dual-pass audio re-processing. Not needed for streaming-only or LLM-based refinement.

## What to Keep (Optional Features)

### 4. LLM Refinement - Make Optional (yap-87cd.4)

**KEEP these files:**
- `Refinement/PunctuationModel.swift` (199 lines)
- `Refinement/ContinuousRefinementManager.swift` (92 lines)
- `Refinement/RefinementConfig.swift` (35 lines)

**Changes needed:**

1. **Add menu toggle:**
```swift
// In YappatronApp.showMenu()
let refinementItem = NSMenuItem(
    title: "Enable LLM Refinement",
    action: #selector(toggleRefinement),
    keyEquivalent: ""
)
refinementItem.state = refinementConfig.isEnabled ? .on : .off
menu.addItem(refinementItem)
```

2. **Default to disabled:**
```swift
// In YappatronApp.setup()
refinementConfig = RefinementConfig(
    isEnabled: false,  // Default disabled
    throttleInterval: 0.5,
    enabledApps: [],  // All apps when enabled
    fallbackOnError: true
)
```

3. **Persist preference:**
```swift
var enableRefinement: Bool {
    get { UserDefaults.standard.bool(forKey: "enableRefinement") }
    set {
        UserDefaults.standard.set(newValue, forKey: "enableRefinement")
        refinementConfig.isEnabled = newValue
    }
}
```

**Why keep it:**
- Some users may prefer punctuation/capitalization post-processing
- Ollama + phi3:mini provides decent results when it works
- Trade-off is latency, but that's user choice
- Can always delete later if nobody uses it

## YappatronApp Simplification

**Current handleFinalTranscription():**
- 30 lines of refinement setup
- Complex async coordination with completion callbacks

**After cleanup:**
- Check refinement toggle
- If enabled: Call ContinuousRefinementManager (keep as-is)
- If disabled: Simple spacing + Enter (current default)

## Documentation (yap-87cd.5)

**Create session note:**
- What was removed: TextEditing suite, dual-pass audio
- Why: Unused complexity, distracting UX
- What was kept: LLM refinement as optional feature
- Default behavior: Pure streaming (winner!)

## Impact Summary

**Lines removed:** ~750 (35% of codebase)
**Files deleted:** 6
**Directories deleted:** 1 (TextEditing/)
**User-facing changes:**
- Default: Pure streaming (no change from current user experience)
- Optional: LLM refinement toggle in menu

## Migration Notes

**Users upgrading:**
- LLM refinement will be OFF by default
- Can enable via menu: "Enable LLM Refinement"
- Requires Ollama + phi3:mini for full features
- Falls back to rule-based when Ollama unavailable

## References

- Analysis agent: a8ceb5a (full code cleanup analysis)
- Task: yap-87cd
- Related: yap-cbf8 (Settings menu fix)
