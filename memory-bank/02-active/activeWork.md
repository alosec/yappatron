# Active Work

**Last Updated:** 2026-01-08 11:05 UTC

## Current Focus

Website redesigned with editorial aesthetic. Core app works but has race condition crash.

### What's Done
- ✅ Swift rewrite with FluidAudio streaming
- ✅ 160ms real-time transcription
- ✅ Ghost text with diff-based corrections
- ✅ Website deployed to yappatron.pages.dev
- ✅ Editorial redesign: Newsreader serif, breathing animation, light/dark mode
- ✅ Content loaded from JSON at build time
- ✅ Theme picker: mist, lotus, ember, moss, depth

### In Progress
- 🔄 Race condition crash (P0) — see [blockers](blockers.md)
- 🔄 Website polish (awaiting feedback)

### Next
- [ ] Fix race condition (actor isolation or upstream)
- [ ] Custom vocabulary (Swift port)
- [ ] App notarization

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
