# Active Work

**Last Updated:** 2026-03-24

## Current State

Deepgram Nova-3 cloud STT is live and working well. Text streams in as clean sentence-level chunks during speech (is_final segments only — no backspacing). Orb animates from interims. Current UX is strong but we want to improve to real-time character-level streaming in a future session.

### Key UX Features
- **☁️ Deepgram Nova-3 cloud STT**: Punctuation, smart formatting, sentence-level streaming
- **🏠 Local Parakeet STT**: Fully offline fallback option
- **🔀 Swappable backends**: Switch via menu bar → STT Backend submenu
- **Forward-only typing**: Only is_final segments get typed — zero backspacing
- **Orb animation**: Fires on interims for immediate speech feedback
- **EOU tuning**: Deepgram endpointing 1500ms, local fallback timer 2500ms, speech_final disabled
- **Auto-send with Enter**: Optional hands-free mode for Claude Code etc.

### What's Done
- ✅ **Cloud STT (Deepgram Nova-3)** — WebSocket streaming, punctuation, smart formatting
- ✅ **Forward-only chunk streaming** — is_final segments typed as they arrive, no backspacing
- ✅ **Decoupled orb from typing** — interims trigger orb, only finals trigger typing
- ✅ **EOU timing tuned** — speech_final disabled, endpointing 1500ms, local timer 2500ms
- ✅ **Pluggable STTProvider protocol** — Swappable backends
- ✅ **API key management** — UserDefaults storage, menu bar UI
- ✅ Orb animations: Voronoi Cells (default) + Concentric Rings
- ✅ Dual-pass refinement: Optional toggle for local mode

### Landing Page (2026-01-10)
- ✅ Deployed to yappatron.pages.dev

## Next Priority

### Real-time character-level streaming (future session)
Currently text appears in sentence-level chunks from is_final segments. The goal is character-by-character streaming while speaking. Backspacing approach was tried extensively and doesn't work well with Deepgram's interim revisions. Future ideas:
- Trust interim words that match previous interim (stable prefix)
- Check if Deepgram has a "high confidence" signal per word
- Hybrid: type stable prefix of interims, correct on is_final

### Other Backlog
- [ ] Hot-swap backends without requiring restart
- [ ] Additional cloud providers (Soniox at $0.12/hr)
- [ ] iPhone app
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
