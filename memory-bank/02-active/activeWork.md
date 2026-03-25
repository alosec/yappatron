# Active Work

**Last Updated:** 2026-03-24

## Current State

Deepgram Nova-3 cloud STT backend added and working excellently. System has pluggable STT backends (cloud + local).

### Key UX Features
- **☁️ Deepgram Nova-3 cloud STT**: Sub-300ms latency, punctuation, smart formatting — user's preferred backend
- **🏠 Local Parakeet STT**: Fully offline fallback option
- **🔀 Swappable backends**: Switch via menu bar → STT Backend submenu
- **Psychedelic orb visualization**: Voronoi Cells animation during speech
- **Auto-send with Enter**: Optional hands-free mode for Claude Code etc.
- **Dual-pass refinement**: Optional punctuation for local mode (auto-skipped for cloud)

### What's Done
- ✅ **Cloud STT (Deepgram Nova-3)** — WebSocket streaming, punctuation, smart formatting (2026-03-24)
- ✅ **Pluggable STTProvider protocol** — Swappable backends without touching audio pipeline
- ✅ **API key management** — Secure storage in app preferences, menu bar UI for key entry
- ✅ Swift rewrite with FluidAudio streaming
- ✅ 320ms chunk size for improved accuracy
- ✅ Ghost text with diff-based corrections
- ✅ Orb animations: Voronoi Cells (default) + Concentric Rings with RGB palette
- ✅ Dual-pass refinement: Optional toggle for punctuation/capitalization
- ✅ `scripts/run-dev.sh` for ad-hoc signing
- ✅ Permission handling documented

### Landing Page (2026-01-10 major facelift)
- ✅ RGB multicolor breathing orb (red/green/blue gradient)
- ✅ Light/dark mode toggle
- ✅ Video demo player with play/pause
- ✅ Deployed to yappatron.pages.dev

## Future Ideas (not urgent)

### iPhone App
Strong motivation here. Local models mean no subscription fees. Whisper Flow charges $15/month for something we built in hours with better UX.

### Live On-the-Fly Editing
Instead of backspacing whole utterance, make edits as text streams in.

### Other Backlog
- [ ] Hot-swap backends without requiring restart
- [ ] Additional cloud providers (Soniox at $0.12/hr)
- [ ] **Listening toggle** (yap-c2dd)
- [ ] Custom vocabulary (Swift port)
- [ ] Visual feedback when refinement is processing
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
