# Active Work

**Last Updated:** 2026-05-02

## Current Focus

**TOP PRIORITY: Test the installed iPhone app's local transcription path**

The iPhone app is now installed and launched on a connected test iPhone via free Xcode Personal Team signing. It now has a Local mode that uses Apple's on-device Speech framework, so first-run testing no longer requires a Deepgram API key.

## Current State

Mac app: Deepgram Nova-3 cloud STT is live and working well. Text streams in as clean sentence-level chunks during speech (is_final segments only — no backspacing). Orb animates from interims. EOU timing tuned to endpointing=2750ms server-side, 3500ms local fallback.

iPhone app: Native iOS project exists at `packages/ios/YappatronIOS`, with app target `YappatronIOS` and keyboard extension target `YappatronKeyboard`. It installs and launches on a physical iPhone. Current iOS transcription backends are Local (Apple on-device Speech, default) and Deepgram (optional).

### Key UX Features
- **☁️ Deepgram Nova-3 cloud STT**: Punctuation, smart formatting, sentence-level streaming
- **🏠 Local Parakeet STT**: Fully offline fallback option
- **🔀 Swappable backends**: Switch via menu bar → STT Backend submenu
- **Forward-only typing**: Only is_final segments get typed — zero backspacing
- **Orb animation**: Fires on interims for immediate speech feedback
- **EOU tuning**: Deepgram endpointing 1500ms, local fallback timer 2500ms, speech_final disabled
- **Auto-send with Enter**: Optional hands-free mode for Claude Code etc.

### iPhone UX / Architecture
- **Native SwiftUI iPhone app**: API key field, record/stop, transcript view, copy/share
- **Local mode default**: Uses Apple on-device Speech recognition; no Deepgram key required for first test
- **Custom keyboard extension**: Inserts latest transcript into active iOS text field with `textDocumentProxy.insertText`
- **Free-device bridge**: Yappatron-tagged `UIPasteboard` item instead of App Group, to avoid paid App Group provisioning
- **Background audio mode**: Declared for the companion-app recording workflow, subject to iOS suspension behavior
- **Signing path**: Free Personal Team direct install works; no paid Apple Developer Program required for personal device testing

### What's Done
- ✅ **Cloud STT (Deepgram Nova-3)** — WebSocket streaming, punctuation, smart formatting
- ✅ **Forward-only chunk streaming** — is_final segments typed as they arrive, no backspacing
- ✅ **Decoupled orb from typing** — interims trigger orb, only finals trigger typing
- ✅ **EOU timing tuned** — speech_final disabled, endpointing 1500ms, local timer 2500ms
- ✅ **Pluggable STTProvider protocol** — Swappable backends
- ✅ **API key management** — UserDefaults storage, menu bar UI
- ✅ Orb animations: Voronoi Cells (default) + Concentric Rings
- ✅ Dual-pass refinement: Optional toggle for local mode
- ✅ **iPhone app installed and launched** — Free Personal Team, Developer Mode enabled, profile trusted
- ✅ **Local iOS transcription mode implemented** — Apple on-device Speech framework, Local default, Deepgram optional
- ✅ **iOS keyboard extension scaffold** — Pasteboard bridge for type-anywhere insertion
- ✅ **Public repo hygiene** — No Apple team ID, device ID, Deepgram key, or App Group entitlement committed

### Landing Page (2026-01-10)
- ✅ Deployed to yappatron.pages.dev

## Next Priority

### iPhone Local ASR Test
Validate the newly implemented Local mode on device:
- Grant microphone and speech recognition permissions when prompted
- Record on iPhone and confirm transcript appears without a Deepgram key
- If Apple Speech quality/latency is not good enough, evaluate FluidAudio/Parakeet iOS/Core ML integration next
- Preserve Deepgram as optional cloud backend

### Other Backlog
- [ ] Enable the Yappatron keyboard on iPhone and test pasteboard insertion in another app
- [ ] Finish normal Xcode platform/runtime setup so asset catalog/icon builds work without CLI override
- [ ] Hot-swap backends without requiring restart
- [ ] Additional cloud providers (Soniox at $0.12/hr)
- [ ] App notarization

## Quick Commands

```bash
# Mac - build & run
cd ~/Workspace/yappatron/packages/app/Yappatron
./scripts/run-dev.sh

# VPS - deploy website
cd ~/code/yappatron/packages/website
npm run build
CLOUDFLARE_API_TOKEN=$(cat ~/.config/cloudflare/pages-token) npx wrangler pages deploy dist --project-name yappatron
```
