# Active Work

**Last Updated:** 2026-01-10
**Status:** MILESTONE REACHED - stepping back for now

## Current State

Yappatron is ready to share. The app works well, the landing page looks great. Taking a break to focus on other projects.

### What's Done
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
- ✅ Removed theme color picker (single unified look)
- ✅ Video demo player with play/pause
- ✅ Improved readability across all sections
- ✅ Updated features: streaming text, built for vibe coding, faster than apple, fully local
- ✅ Install instructions with run-dev.sh and permissions troubleshooting
- ✅ Deployed to yappatron.pages.dev

## Future Ideas (not urgent)

### iPhone App
Strong motivation here. Local models mean no subscription fees. Whisper Flow charges $15/month for something we built in hours with better UX. Would need Apple Developer Program ($99/year) anyway for notarization.

### Live On-the-Fly Editing
Instead of backspacing whole utterance, make edits as text streams in. Have a rough mental model for structuring LLM API calls for text-based corrections, but not ready to implement yet. Worth exploring with Claude when the time comes.

### Go Legit
Apple Developer license for notarization. Makes sense to do when building iPhone app anyway. No rush.

### Other Backlog
- [ ] **Listening toggle** (yap-c2dd) - Button/hotkey to enable/disable always-listening mode. Not push-to-talk, but a toggle. When off, no streaming or auto-enter happens.
- [ ] Chunk size configurability (160ms/320ms toggle)
- [ ] Custom vocabulary (Swift port)
- [ ] Performance metrics collection
- [ ] Visual feedback when refinement is processing

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
