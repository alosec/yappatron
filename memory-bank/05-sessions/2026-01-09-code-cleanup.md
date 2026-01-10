# Session: Code Cleanup - Pure Streaming Only (Scorched Earth)

**Date:** 2026-01-09 (evening)
**Status:** Completed
**Task:** yap-87cd

## Summary

**SCORCHED EARTH APPROACH:** Removed ALL refinement infrastructure (~1,175 lines total). 100% committed to pure streaming. Codebase now 55% smaller and laser-focused on what works best.

## What Was Removed

### 1. TextEditing Suite (376 lines)
**Deleted entire directory:** `/Sources/TextEditing/`

- `DiffGenerator.swift` (127 lines)
- `EditApplier.swift` (76 lines)
- `TextEditCommand.swift` (140 lines)
- `TextStateTracker.swift` (33 lines)

**Reason:** Built for sophisticated dual-pass text editing with surgical commands (Navigate, Select, Replace, etc.). Never used - current system only needs simple diff-based replacement via `InputSimulator.applyTextUpdate()`.

### 2. Dual-Pass Infrastructure (143 lines)

- `BatchProcessor.swift` (75 lines) - Parakeet TDT 0.6b batch ASR model
- `TextRefinementManager.swift` (68 lines) - Coordinator for dual-pass workflow

**Reason:** Dual-pass creates visible backspace/retype effect that's distracting on long dictations. Sometimes worse transcription than streaming. User feedback: "the backspacing thing is cute but I don't think it's any better."

### 3. TranscriptionEngine Cleanup (~80 lines)

**Removed from `TranscriptionEngine.swift`:**
- `AudioChunkBuffer` actor (48 lines) - saved audio for batch re-processing
- `audioChunkBuffer` property
- `onUtteranceComplete` callback - never wired up in YappatronApp
- Audio buffer initialization in `setupAudioCapture()`
- Audio sample retrieval in `handleFinalTranscription()`
- Buffer append call in `processAudioBuffer()`

**Reason:** These support dual-pass audio re-processing only. Not needed for streaming-only or LLM refinement.

### 4. InputSimulator Cleanup (~85 lines)

**Removed unused extensions:**
- Navigation extension - cursor movement commands
- Selection extension - text selection commands
- Delete extension - deletion commands

**Reason:** Referenced deleted `TextEditCommand` types. Not used by current streaming system which only needs `applyTextUpdate()`.

## What Was Also Removed (Round 2: Scorched Earth)

### 5. LLM Refinement System (326 lines)

**Deleted entire directory:** `/Sources/Refinement/`

- `PunctuationModel.swift` (199 lines) - Ollama/phi3:mini integration
- `ContinuousRefinementManager.swift` (92 lines) - LLM coordinator
- `RefinementConfig.swift` (35 lines) - Config struct

**Removed from YappatronApp.swift:**
- `continuousRefinementManager` property
- `refinementConfig` property
- `enableRefinement` UserDefaults property
- Refinement initialization in `setup()`
- Refinement reset call in `onSpeechEnd`
- All refinement logic from `handleFinalTranscription()`
- "Enable LLM Refinement" menu item
- `toggleRefinementAction()` method

**Reason:** User decision - "fuck it actually let's just go ahead and commit to the streaming only." 100% pure streaming, no optional features.

## Code Changes

### YappatronApp.swift

**Added settings property:**
```swift
var enableRefinement: Bool {
    get { UserDefaults.standard.bool(forKey: "enableRefinement") }
    set {
        UserDefaults.standard.set(newValue, forKey: "enableRefinement")
        refinementConfig.isEnabled = newValue
    }
}
```

**Updated refinement config:**
```swift
refinementConfig = RefinementConfig(
    isEnabled: enableRefinement,  // Load from UserDefaults (default: false)
    throttleInterval: 0.5,
    enabledApps: [],  // All apps when enabled
    fallbackOnError: true
)
```

**Added menu item:**
```swift
let refinementItem = NSMenuItem(title: "Enable LLM Refinement", action: #selector(toggleRefinementAction), keyEquivalent: "")
refinementItem.state = enableRefinement ? .on : .off
menu.addItem(refinementItem)
```

**Added action:**
```swift
@objc func toggleRefinementAction() {
    enableRefinement.toggle()
}
```

## Impact

**Lines removed:** ~1,175 (55% of original codebase!)
**Files deleted:** 9
**Directories deleted:** 2 (TextEditing/, Refinement/)
**Build status:** ✅ Successful

**User-facing changes:**
- **PURE STREAMING ONLY**
- No refinement, no post-processing, no optional features
- Streaming text appears exactly as ASR produces it
- Optional trailing space + Enter (configurable)

## Before vs After

**Before:**
- 2,150 lines of code
- Three refinement approaches (streaming, dual-pass, LLM)
- Complex architecture with multiple paths
- Dual-pass never activated but code present
- TextEditing suite built but unused
- LLM refinement with Ollama integration

**After:**
- 975 lines of code (55% reduction!)
- ONE approach ONLY: pure streaming
- Zero refinement infrastructure
- Radically simple architecture
- Nothing to configure, nothing to break

## Philosophy

**Scorched earth:** Commit 100% to what works. No optional features, no complexity, no "maybe someone will want this."

**User feedback:** "feels natural", "wonderful", "blows other tools out of the water" - pure streaming wins.

**KISS principle:** The best code is the code you don't write. Streaming ASR is already great at ~5.73% WER.

## What's Next

With codebase cleaned up, ready for visual effects implementation (yap-dec5):
- Integrate metasidd/Orb library
- Audio-reactive animations
- Psychedelic color morphing
- Satisfying finalization effects

## References

- Task: yap-87cd
- Analysis agent: a8ceb5a (code cleanup analysis)
- Plan: [code-cleanup-plan.md](../02-active/code-cleanup-plan.md)
