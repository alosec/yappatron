# Active Work

**Last Updated:** 2026-05-08

## Current Focus

**TOP PRIORITY: Input focus locking**

Yappatron currently types into whatever app/field has focus at the moment a final lands. For multi-speaker / meeting-mode use, the user often wants the transcript to flow into a *specific* destination (e.g., a Claude Code chat) regardless of where the cursor moves during the conversation. Right now, alt-tabbing or clicking another window mid-conversation splits the transcript across destinations.

Goal: a "lock onto this input" mode where the user designates a target text field (or window), and Yappatron continues typing there even if focus moves elsewhere.

Open design questions (no decisions yet):
- How does the user designate the target? Click-to-pick, hotkey-while-focused, menu listing recent inputs?
- Do we re-acquire focus before typing each chunk (briefly steals focus, types, returns), or do we type using accessibility APIs that don't require focus?
- What happens if the locked target disappears (window closed, app quit)? Pause? Fall back to dictation? Notify the user?
- Should the lock survive across utterances only, or across an entire session?

Initial sketch: enumerate distinct text inputs we've typed into (by app + window + field role) and present them in a menu as "lock to this input" options. Simplest possible MVP — we don't need click-to-pick for the first cut.

## Current State

### Mac app (main: 690f0e5)

Speaker diarization shipped end-to-end with a hybrid architecture: Deepgram does word-level segmentation, local FluidAudio embeddings handle identity by matching against an enrolled-speaker registry. The override layer eliminates Deepgram's cross-speaker contamination on enrolled speakers; un-enrolled speakers fall through to Deepgram's IDs with the rename UI as backup.

Three modes available via menu:
1. Speaker Labels OFF — original dictation behavior
2. Speaker Labels ON, no enrolled speakers — Deepgram IDs surface as `[Speaker 0]`, rename via menu
3. Speaker Labels ON, enrolled speakers — embedding-based override active, `[Alex]`/`[Mom]`/etc. with high confidence

Three line-break styles between speaker turns: none (inline), newline (TextEdit/Notes), backslash+newline (Claude Code multi-line input).

Validated easy-mode (quiet 1:1) cleanly. Hard-mode (3+ speakers, ambient noise) recoverable but not perfect — fragmentation is fine since override matches against voiceprint not ID, occasional phantom-speaker noise from overlap remains.

### Branches

- `main` — current shipped state
- `feature/speaker-registry` — original pre-STT embedding gate (dead, kept for reference only)
- `feature/local-segmenter` — experimental local-only diarization. FluidAudio segmentation was coarser than Deepgram's in our tests; reverted main, branch preserved for later evaluation if Deepgram regresses or a cloud-free path is needed.

### iPhone app (unchanged this session)

Native iOS project at `packages/ios/YappatronIOS` still installed on test iPhone via free Personal Team signing. Local mode (Apple on-device Speech) is the default backend. Awaiting first-run user validation. Companion keyboard extension scaffolded with Yappatron-tagged pasteboard bridge.

## What's Done This Session

### Diarization (2026-05-08)

- ✅ **Deepgram `diarize=true`** — word-level speaker tags + start/end timestamps in WebSocket responses
- ✅ **Word-level run aggregation** — consecutive same-speaker words merged into runs with start/end timing
- ✅ **`SpeakerLabelMap`** — UserDefaults-backed `[Int: String]` rename map, seen-IDs tracker, enabled flag, line-break style
- ✅ **`LineBreakStyle`** — three styles (none / newline / Claude-Code), persisted, exposed via menu
- ✅ **Always-label every utterance** — within-utterance same-speaker dedup preserved, cross-utterance label restart applied
- ✅ **Enrollment registry** — `~/Library/Application Support/Yappatron/enrolled-speakers.json`, JSON-backed `EnrolledSpeaker` records
- ✅ **`SpeakerEmbedder`** — actor wrapping FluidAudio's `extractSpeakerEmbedding` with one-time model load
- ✅ **`EnrollmentRecorder` + `EnrollSpeakerWindow`** — 10s capture flow with floating progress window
- ✅ **`HybridDiarizer`** — per-run override pass; cosine distance against registry, threshold 0.45, min run 0.3s
- ✅ **`StreamAudioBuffer`** — long-lived rolling audio buffer anchored to Deepgram's t=0 for run-slicing
- ✅ **Race fix** — `handleFinalTranscription` awaits the in-flight override task before emitting, so typed text reflects override decisions
- ✅ **`HybridDiagLog`** — append-only diagnostic log of per-run distances and override decisions for debugging
- ✅ **Menu wiring** — Speaker Labels toggle, Line Breaks submenu, Name Speakers submenu, Enrolled Speakers submenu (Deepgram-backend gated)
- ✅ **FluidAudio bump** — 0.9.1 → 0.14.4 for Swift 6.3 compatibility, two API call sites updated

## Next Priority

### Input focus locking — P0

See "Current Focus" above. Open design questions to be resolved before implementation.

### Model currency

Research done 2026-05-08. We're on FluidAudio 0.14.4 (current as of 2026-05-04) but using its older `StreamingEouAsrManager` (Parakeet EOU 120M). The same package now exposes `StreamingNemotronAsrManager` (NVIDIA Nemotron streaming with encoder cache, 160ms chunks) which is likely a meaningful upgrade for English dictation latency. NVIDIA also released `parakeet-unified-en-0.6b` in April 2026 — SOTA English fit, needs CoreML port if not yet wrapped. Apple's SpeechAnalyzer in macOS 26 Tahoe is a viable third backend slot. Lowest-effort upgrade: drop in `StreamingNemotronAsrManager` and A/B against current. Captured in nextUp.

### Hybrid diarization tunable: `minRunSeconds = 0.0`

Lowered the gating threshold to zero so every run gets the embedding override pass regardless of duration. Previously runs under 0.3s fell through to Deepgram's IDs, which proved less reliable than even noisy short-audio embeddings. Tradeoff is more variance on tiny utterances ("art", "yeah") but no more silent fallback to Deepgram on short runs.

### Other Backlog

- [ ] Auto-clear speaker rename map on new transcription session (Mom's foot-gun risk: yesterday's Mom can become today's Callie if reused)
- [ ] Confirm local Parakeet backend still works under FluidAudio 0.14.4 (smoke test pending)
- [ ] Address backspacing UX (flagged as disliked, untouched this session)
- [ ] Retroactive rename rewriting of already-typed transcript (open question — worth it?)
- [ ] Ensemble diarization (Deepgram + local segmentation + local identity) for harder real-world conditions
- [ ] Test iPhone Local mode on device end-to-end
- [ ] Enable / test iOS type-anywhere keyboard flow
- [ ] Hot-swap backends without restart
- [ ] App notarization

## Quick Commands

```bash
# Mac - build & run
cd ~/Workspace/yappatron
./scripts/run-dev.sh

# Tail diarization diagnostics during a session
tail -F ~/Library/Application\ Support/Yappatron/hybrid-diag.log

# VPS - deploy website
cd ~/code/yappatron/packages/website
npm run build
CLOUDFLARE_API_TOKEN=$(cat ~/.config/cloudflare/pages-token) npx wrangler pages deploy dist --project-name yappatron
```
