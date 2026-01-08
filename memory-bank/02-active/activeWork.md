# Active Work

**Last Updated:** 2026-01-08 10:15 UTC

## Current Focus

Website deployed. Core app works but has race condition crash.

### What's Done
- ✅ Swift rewrite with FluidAudio streaming
- ✅ 160ms real-time transcription
- ✅ Ghost text with diff-based corrections
- ✅ Website deployed to yappatron.pages.dev
- ✅ Sakura styling

### In Progress
- 🔄 Race condition crash (P0) — see [blockers](blockers.md)

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
