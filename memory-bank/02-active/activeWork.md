# Active Work

**Last Updated:** 2026-01-09 15:45 UTC

## Current Focus

System is stable and working well. Ready to add configurability and explore further accuracy improvements.

### What's Done
- ✅ Swift rewrite with FluidAudio streaming
- ✅ 320ms chunk size upgrade for improved accuracy (tested, confirmed working)
- ✅ Ghost text with diff-based corrections
- ✅ Website deployed to yappatron.pages.dev
- ✅ Editorial redesign: Newsreader serif, breathing animation, light/dark mode
- ✅ Content loaded from JSON at build time
- ✅ Theme picker: mist, lotus, ember, moss, depth
- ✅ Added `scripts/run-dev.sh` for ad-hoc signing
- ✅ Permission issue resolved with proper .app bundle
- ✅ Race condition fixed with actor-based buffer queue
- ✅ System tested and passes quality bar for accuracy/speed balance

### In Progress
- Nothing currently blocking

### Next
- [ ] Add chunk size configurability (user settings: 160ms/320ms)
- [ ] Clean up excessive logging
- [ ] Explore even slower/larger models for accuracy
- [ ] Custom vocabulary (Swift port)
- [ ] App notarization
- [ ] Performance metrics collection

## Quick Commands

```bash
# Mac - build & run
cd ~/Workspace/yappatron/packages/app/Yappatron
swift build
.build/debug/Yappatron

# VPS - deploy website
cd ~/code/yappatron/packages/website
npm run build
CLOUDFLARE_API_TOKEN=$(cat ~/.config/cloudflare/pages-token) npx wrangler pages deploy dist --project-name yappatron

# Tasks
td list
```
