# Active Work

**Last Updated:** 2026-05-11

## iOS stabilization & next-phase scope (2026-05-10)

Long planning session after the Callie call. Pulled the iPhone app
direction into focus and named four concrete iOS items plus two
forward-looking directions. Captured here so they don't slip.

### Active iOS work

1. **Ambient listener is the primary mode.** Open the app, turn it
   on, get a diarized transcription right there. No setup flow gating
   it. The Full Send pass (2026-05-08) is the right base; the framing
   sharpens: this is an ambient listener first, with optional routed
   output downstream — not a webhook tool with a transcript view.

2. **Destination as a first-class concept.** Replace the current
   single "Webhook URL + bearer token" config with *named
   destinations* the user can toggle between: Zip (TinyFat agent),
   custom webhook, tmux-pane relay, etc. The mental model is "I am
   listening; this stream is currently going to <named destination>."
   Off by default; toggled per session.

3. **Diarization on iOS.** Port the hybrid Deepgram +
   FluidAudio voiceprint path from Mac. Today the iOS spike is
   Deepgram-IDs-only with a rename UI; voiceprint enrollment was
   deliberately deferred. With enrolled speakers the iPhone gets the
   same `[Alex]`/`[Callie]` quality the Mac has, which makes it real
   for meetings and calls.

4. **Bug: Local mode on iOS is not functional.** Apple on-device
   Speech path is bugging out. Symptoms not yet written up — needs a
   dedicated session to capture exact failure modes before fixing.
   For now, treat local-mode as not working on iOS.

5. **Bug: Deepgram on iOS is too jittery — emits too quickly.** The
   Mac handles this via a pause/debounce boundary before emit; iOS is
   likely missing an equivalent endpointing pass and is firing on
   every interim final instead of waiting for a complete-thought
   boundary. Needs a debounce/pause-detection layer between the
   Deepgram stream and the output router so chunks land at sane turn
   boundaries.

### Forward-looking iOS directions (captured, not active)

6. **Conventional chat experience with TinyFat agents.** iOS app
   conceptualized as a TinyFat *chat client*, not just a dictation
   surface. Likely pure Swift. Scope/shape TBD. The voice piece
   becomes one of several input modes inside a richer client surface,
   not the whole product.

7. **Voice call with your agent.** Live two-way voice conversation
   with a TinyFat agent (Zip, etc.). Shape TBD — no design yet. This
   is the "Jarvis-shaped" direction discussed in the same session.
   Captured as a known want; not on the near-term roadmap.

### Naming/branding (parked)

The Yapatron name fits a dictation tool. If the product becomes
multi-channel — voice + chat + call, with TinyFat agents as the
backing brain — the name no longer fits. TinyFat is the platform
brand and doesn't fit a consumer voice/chat client either. A new
proper-noun brand probably belongs on top of the iOS+Mac client
surface. Reference frame: Jarvis (Iron Man), KITT (Knight Rider) —
named, voice-first, acts on your behalf, ambient. No decision made
this session.

## Current Focus

**RECENTLY SHIPPED: Input focus locking + UX hardening**

Yappatron now has an input focus locking MVP for multi-speaker / meeting-mode use. The user can designate the currently focused text input as the typing destination, and dictation writes are routed back to that destination even if the foreground app changes.

Shipped behavior:
- Captures the focused text input/window through Accessibility.
- Adds an input-focus-lock toggle shortcut and menu item.
- Routes streaming partials, finals, and dual-pass refinement edits through the locked destination.
- Briefly refocuses the locked destination for typing, then restores the previously frontmost app.
- If the locked target disappears, clears the lock and pauses instead of typing into the wrong app.
- Prevents the floating orb overlay from becoming the key window when shown.
- Adds a visible outline around the locked window and keeps it tracking window moves/resizes.
- Tracks the most recent text input so the menu item can lock the intended destination even after the menu opens.
- Changes the lock shortcut to `⌃⌥⌘L` and adds local/global key-monitor fallback in addition to Carbon hotkey registration.
- Adds a continuous bottom-line indicator style for the active display. It is driven by smoothed RMS audio amplitude from captured PCM buffers: silence/noise-gated input stays flat, louder speech adds more thickness and wiggle.
- Adds a short settle delay before auto-enter to improve Codex/paste-fallback behavior.

Validation follow-ups:
- Smoke-test the locked-window outline on multiple displays and with moved/resized windows.
- Bottom indicator live test passed: RMS-reactive motion hits the intended feel. Keep the current calibration unless future room-noise or subtle-speech tests prove otherwise.
- Re-test `Press Enter After Speech` in Codex. A 120ms settle delay was added before Return, but this still needs live confirmation.

Next iteration should prioritize any remaining reliability issues found in live use.

**Prior iOS spike state:** The iOS webhook streaming pipeline (server + DNS + Caddy + iOS scaffolding) is shipped and infrastructure-ready, but the iPhone-side build/install loop on Friday night did not converge into something usable in time for the Callie call. Right call was to stop, sleep, record the call with normal tools, and post-process audio later.

The infrastructure stays live (relay killed for the night, but DNS, Caddy entry, cert, and code all remain). A later session can pick this up with a clear head.

## Current State

### Mac app (main: 690f0e5)

Speaker diarization shipped end-to-end with a hybrid architecture: Deepgram does word-level segmentation, local FluidAudio embeddings handle identity by matching against an enrolled-speaker registry. The override layer eliminates Deepgram's cross-speaker contamination on enrolled speakers; un-enrolled speakers fall through to Deepgram's IDs with the rename UI as backup.

Three modes available via menu:
1. Speaker Labels OFF — original dictation behavior
2. Speaker Labels ON, no enrolled speakers — Deepgram IDs surface as `[Speaker 0]`, rename via menu
3. Speaker Labels ON, enrolled speakers — embedding-based override active, `[Alex]`/`[Mom]`/etc. with high confidence

Speaker turns are separated by a plain newline (the only mode). Live
testing showed inline mode and the backslash+newline (Claude Code)
mode both behaved poorly in practice — terminals and Claude Code's
chat input both handle a real newline correctly, so the variant modes
just added confusion. The `LineBreakStyle` enum, the "Line Breaks
Between Speakers" menu, and the persisted UserDefaults key were all
removed; `SpeakerLabelMap.lineBreakSeparator` is now a single
hardcoded constant.

Validated easy-mode (quiet 1:1) cleanly. Hard-mode (3+ speakers, ambient noise) recoverable but not perfect — fragmentation is fine since override matches against voiceprint not ID, occasional phantom-speaker noise from overlap remains.

### Branches

- `main` — current shipped state
- `feature/speaker-registry` — original pre-STT embedding gate (dead, kept for reference only)
- `feature/local-segmenter` — experimental local-only diarization. FluidAudio segmentation was coarser than Deepgram's in our tests; reverted main, branch preserved for later evaluation if Deepgram regresses or a cloud-free path is needed.

### iPhone app

Native iOS project at `packages/ios/YappatronIOS` installed on the test iPhone via free Personal Team signing.

Latest UX direction: "Full Send" should be the primary mode. The app screen is not a hidden setup flow; it should show the active outputs, a big start/stop control, live transcript text, and a delivery feed.

Current iOS output model:

- Local mode (Apple on-device Speech) is a first-class source. It emits finalized chunks using a pause/debounce boundary and can deliver those chunks to outputs.
- Deepgram mode still supports diarized runs and speaker naming.
- Outputs are configurable independently of the engine:
  - Webhook POST with optional bearer token.
  - Yappatron keyboard auto-insert via the tagged pasteboard bridge.
  - Optional return key after keyboard insertion.
- Keyboard extension now polls while visible and inserts each new delivered chunk once, instead of only doing a one-shot insert when it opens.
- Auto-start on app open is available for the "keep listening, keep sending" workflow, within iOS background-audio limits.

## What's Done This Session

### iOS Full Send UX pass (2026-05-08, late night)

Shipped a comprehensive iPhone UX pass based on user feedback that the previous webhook flow was hidden behind Deepgram mode and did not feel like a usable always-send dictation surface:

- Reworked `ContentView` around a large "Start Full Send" / "Stop Full Send" control, visible output toggles, engine selector, live transcript, and delivery log.
- Webhook configuration is visible regardless of Local vs Deepgram engine. Local mode can now send to webhook too.
- Added `TranscriptOutputRouter`, `TranscriptOutputSettings`, and `TranscriptOutputEvent` to keep output delivery as a clear abstraction instead of wiring webhook and keyboard behavior directly into each recognizer path.
- Local Speech now schedules final-ish chunks via a 1.1s pause debounce and flushes on stop. This gives local mode an end-of-utterance approximation suitable for webhook/keyboard delivery.
- Keyboard payload metadata now includes "press return after insert"; the keyboard extension polls while open and auto-inserts new chunks once.
- Added an "Auto-start on app open" toggle for the full-send workflow.

### iOS webhook streaming spike (2026-05-08, very late)

Shipped a "Stream finals to webhook" mode for the Deepgram backend on
the iOS app, end-to-end:

- `DeepgramStreamingClient` flips `diarize=true` and parses the
  word-level array. Words aggregate into runs (one per speaker change
  inside a finalized turn) via a new `intoRuns()` extension.
- `WebhookClient` POSTs `DiarizedUtterance` JSON to a user-configured
  URL with optional bearer token. One retry on 5xx/network error,
  fail-fast on 4xx, ephemeral session.
- `SpeakerLabelStore` (UserDefaults-backed) tracks seen Deepgram
  speaker IDs and lets the user rename them inline. Renames flow into
  the next webhook payload's `speaker` field.
- `ContentView` adds Webhook URL field, bearer-token field, "Stream
  finals to webhook" toggle, success/failure counters, and a "Name
  Speakers" section that materializes once IDs are seen.
- Voiceprint enrollment (FluidAudio) deliberately deferred. The Mac
  has it; the iOS port doubles spike surface. Wire shape is validated
  with Deepgram-IDs-only first.

Server side: a separate `yapatron-relay` repo at `~/code/yapatron-relay`
runs on `tiny-bat` and pastes `is_final=true` utterances into a target
tmux pane. Bearer-authenticated, runs as `bun run server.ts` in tmux.

Public endpoint: **`https://tinyfat.sh/ingest`** — the `tinyfat.sh`
domain was migrated from Namecheap to Cloudflare DNS and reverse-
proxied via Caddy on the box. Bearer token at
`~/.config/yappatron/webhook-token` (mode 600).

End-to-end pipeline validated locally: `curl -X POST` → Bun server →
tmux paste-buffer → text appears in target pane. Smoke-tested into
the live Claude Code session at `0:1.1` and into a scratch bash
window at `1:1.1`. Public HTTPS test from internet → Caddy → relay →
tmux pane confirmed working before plug-in.

### Tier 1 hardening shipped to relay (2026-05-09 ~00:30)

Quick audit-then-harden pass on the relay before going to bed,
because a static-bearer-token endpoint that pastes arbitrary text
into a live Claude Code window is a real surface — anyone with the
token can effectively talk to Claude as if they were the operator.
Five additive controls, no UX cost:

- Per-IP token bucket. Capacity 30 burst, refill 2/s sustained.
  429s past the limit, audited.
- Sanitize text + speaker fields. Strip C0 controls (incl. \\n \\r
  \\t), DEL, C1 controls. Speech transcripts don't legitimately
  contain control bytes; anything that does is suspicious.
- Length caps: 2KB text, 64 char speaker, 8KB total body. Anything
  larger returns 413 and is audited.
- Authenticate `/health`. No public endpoint that confirms the
  service is live or leaks the tmux target name.
- Append-only audit log at
  `~/.local/share/yapatron-relay/audit.jsonl` with timestamp, event
  type, IP, and a sha256 prefix of pasted text (NOT plaintext) for
  forensic traceability without storing conversation contents.

Shipped as `d1736aa` on `alosec/yapatron-relay`. Each control was
smoke-tested locally before commit.

Tier 2 (HMAC body signing + nonce, replay-proof against token leak)
and Tier 3 #12 (pivot from "paste into Claude Code" to "write to
JSONL file, you tail it" — eliminates the remote-injection-into-AI
surface entirely) are noted as future work, not shipped tonight.

### iOS install + first-run friction (2026-05-09, late)

Real attempt to install and use the spike on iPhone before the
Friday→Saturday flip stalled out. The build/install/permissions/
backgrounding loop didn't converge into a working ambient-recording
experience inside the time window. No specific blocker captured in
detail — too tired to debug carefully, and a Friday-night panic
build is exactly the kind of thing that produces brittle work.

Decision: park the iOS path cleanly. Tomorrow's Callie call will
just use a normal recording (Voice Memos / Zoom built-in), post-hoc
transcription later. The spike's foundation stays:

- iOS app branch with `WebhookClient`, `SpeakerLabelStore`,
  `DiarizedUtterance`, ContentView fields, Deepgram `diarize=true`
- Public endpoint live at `https://tinyfat.sh/ingest`
- Hardened relay, code committed, token in place
- Caddy + DNS + cert all healthy

Restart point on the next iteration:
1. Reproduce the iOS build/install issue with rested eyes
2. Validate ambient-listening behavior (background audio, mic claim
   while another app is active, etc.) before adding any features
3. Decide between continuing to harden the network/auth path
   (Tier 2 HMAC) vs pivoting to Tier 3 #12 (file-based)

### State at end of session (2026-05-09 ~00:35)

- Relay process killed (`tmux kill-session -t relay`). Endpoint is
  inert until restart — Caddy will 502 anything hitting `/ingest`.
- DNS, Cloudflare zone, A record, Caddy block, Let's Encrypt cert
  all remain healthy.
- Bearer token still at `~/.config/yappatron/webhook-token` (mode
  600). Not rotated; no leak suspected.
- iOS code in `c91be75` (spike) + `4ac3ab1` (memory bank) on
  `alosec/yappatron`.
- Relay code in `934b085` (initial) + `d1736aa` (Tier 1 hardening)
  on `alosec/yapatron-relay`.

Restart command (when ready):

```bash
cd ~/code/yapatron-relay && \\
  tmux new-session -d -s relay 'TMUX_TARGET=0:1.1 bun run server.ts'
```

### Live call test (2026-05-08, late evening)

Tested the system-audio-capture build against an actual FaceTime
call. Result: not just the documented "ScreenCaptureKit can't see
FaceTime's audio" issue — **FaceTime appears to hijack the mic input
device entirely while the call is active.** With Yappatron running
and a FaceTime call up, the orb never appeared and no transcription
occurred at all, even though the app was running and the mic
permission was granted. The mic input itself was being claimed by
FaceTime in a way that left Yappatron with no signal to process.

Operational fallout for tomorrow's Callie call (Sat May 9, 11am):

- FaceTime is out as the call mechanism for any session where
  Yappatron is in the loop. Will use **Zoom or Google Meet** instead.
- Whether the dedicated Screen Sharing app (the one that allows
  remote control, separate from FaceTime's built-in screen share)
  has the same mic-hijack problem is **not yet tested.**
- Browser-based meeting tools (Google Meet in Chrome) are the most
  likely path to "Yappatron + call audio + remote viewing all work
  at once," because the system-audio capture spike showed browser
  audio captures cleanly. Worth validating before the call.

This is a meaningful posture change: the previous assumption was
"FaceTime is degraded for system-audio capture." The actual
behavior is "FaceTime is incompatible with Yappatron entirely while
active." Document and route around it.

### Line break simplification (2026-05-08, evening)

Stripped the `LineBreakStyle` enum entirely. Inline (no break) was a
useless default — runs from different speakers blended together. The
backslash+newline "Claude Code" mode also turned out wrong: in Claude
Code's chat input `\<Enter>` doesn't reliably produce a soft line
break the way it does at a raw terminal prompt. Plain newline works
correctly across TextEdit, Notes, terminal, *and* Claude Code, so it
became the only mode. Menu submenu and the persisted UserDefaults key
both removed. Code is meaningfully smaller now.

### Diarization (2026-05-08)

- ✅ **Deepgram `diarize=true`** — word-level speaker tags + start/end timestamps in WebSocket responses
- ✅ **Word-level run aggregation** — consecutive same-speaker words merged into runs with start/end timing
- ✅ **`SpeakerLabelMap`** — UserDefaults-backed `[Int: String]` rename map, seen-IDs tracker, enabled flag
- ✅ **Always-label every utterance** — within-utterance same-speaker dedup preserved, cross-utterance label restart applied
- ✅ **Enrollment registry** — `~/Library/Application Support/Yappatron/enrolled-speakers.json`, JSON-backed `EnrolledSpeaker` records
- ✅ **`SpeakerEmbedder`** — actor wrapping FluidAudio's `extractSpeakerEmbedding` with one-time model load
- ✅ **`EnrollmentRecorder` + `EnrollSpeakerWindow`** — 10s capture flow with floating progress window
- ✅ **`HybridDiarizer`** — per-run override pass; cosine distance against registry, threshold 0.45, min run 0.3s
- ✅ **`StreamAudioBuffer`** — long-lived rolling audio buffer anchored to Deepgram's t=0 for run-slicing
- ✅ **Race fix** — `handleFinalTranscription` awaits the in-flight override task before emitting, so typed text reflects override decisions
- ✅ **`HybridDiagLog`** — append-only diagnostic log of per-run distances and override decisions for debugging
- ✅ **Menu wiring** — Speaker Labels toggle, Name Speakers submenu, Enrolled Speakers submenu (Deepgram-backend gated)
- ✅ **FluidAudio bump** — 0.9.1 → 0.14.4 for Swift 6.3 compatibility, two API call sites updated

## Next Priority

### Input focus locking — P0

See "Current Focus" above. Open design questions to be resolved before implementation.

### Model currency

Research done 2026-05-08. We're on FluidAudio 0.14.4 (current as of 2026-05-04) but using its older `StreamingEouAsrManager` (Parakeet EOU 120M). The same package now exposes `StreamingNemotronAsrManager` (NVIDIA Nemotron streaming with encoder cache, 160ms chunks) which is likely a meaningful upgrade for English dictation latency. NVIDIA also released `parakeet-unified-en-0.6b` in April 2026 — SOTA English fit, needs CoreML port if not yet wrapped. Apple's SpeechAnalyzer in macOS 26 Tahoe is a viable third backend slot. Lowest-effort upgrade: drop in `StreamingNemotronAsrManager` and A/B against current. Captured in nextUp.

### Hybrid diarization tunable: `minRunSeconds = 0.0`

Lowered the gating threshold to zero so every run gets the embedding override pass regardless of duration. Previously runs under 0.3s fell through to Deepgram's IDs, which proved less reliable than even noisy short-audio embeddings. Tradeoff is more variance on tiny utterances ("art", "yeah") but no more silent fallback to Deepgram on short runs.

### Goal State: Advanced Transcription
Captured vision for speaker diarization, voice profiles, multi-model offerings, and optional remote GPU inference (Pi Pods). See: `02-active/future-vision-advanced-transcription.md`.

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
