# Active Work

**Last Updated:** 2026-01-10 05:00 UTC (2026-01-09 late night local)

## Current Focus

System is stable with dual-pass refinement now available as optional toggle. Testing enabled mode for punctuation quality.

### What's Done
- ✅ Swift rewrite with FluidAudio streaming
- ✅ 320ms chunk size upgrade for improved accuracy (tested, confirmed working)
- ✅ Ghost text with diff-based corrections
- ✅ **Orb animations:** Voronoi Cells (default) + Concentric Rings with RGB palette
- ✅ **Dual-pass refinement:** Optional toggle for punctuation/capitalization (disabled by default)
- ✅ Website deployed to yappatron.pages.dev
- ✅ Editorial redesign: Newsreader serif, breathing animation, light/dark mode
- ✅ Content loaded from JSON at build time
- ✅ Theme picker: mist, lotus, ember, moss, depth
- ✅ Added `scripts/run-dev.sh` for ad-hoc signing
- ✅ Permission issue resolved with proper .app bundle
- ✅ Race condition fixed with actor-based buffer queue
- ✅ System tested and passes quality bar for accuracy/speed balance

### In Progress
- 🧪 Testing dual-pass refinement in real usage (user is actively testing)

### Next
- [ ] Evaluate dual-pass refinement quality and performance
- [ ] Consider visual feedback for when refinement is processing
- [ ] Add chunk size configurability (user settings: 160ms/320ms)
- [ ] Clean up excessive logging
- [ ] Explore larger batch models (1.1B) if CoreML conversion becomes available
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
