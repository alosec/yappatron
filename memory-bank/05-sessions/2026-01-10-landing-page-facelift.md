# Session: Landing Page Facelift (2026-01-10)

**Status:** ✅ COMPLETE - Milestone reached

## Summary

Major visual overhaul of the yappatron landing page. The app is now ready to share publicly.

## What We Shipped

### Visual Design
- **RGB breathing orb** - Replaced subtle single-color orb with vibrant red/green/blue multicolor gradient that rotates and pulses
- **Light/dark mode toggle** - Sun/moon button in header, respects system preference, saves to localStorage
- **Removed theme picker** - Eliminated the mist/lotus/ember/moss/depth color dots in favor of unified RGB look
- **Improved readability** - Bumped text colors from dim grays to primary text with opacity for all sections

### Content Updates
- **Features rewritten** for vibe coding focus:
  1. Streaming text - characters flow in real-time
  2. Built for vibe coding - talk to Claude, auto-enters on pause
  3. Faster than Apple - 320ms beats native dictation
  4. Fully local - no cloud, no API calls
- **Install section** - Now references `./scripts/run-dev.sh` with permissions troubleshooting guide
- **Latency updated** - 160ms → 320ms throughout
- **Requirements** - Added M4 to Apple Silicon list

### Video Demo
- Added video player component with play/pause controls
- Trimmed first third of demo video
- Progress bar and hover-to-pause UX

## Files Changed
- `packages/website/src/pages/index.astro` - Complete visual overhaul
- `packages/website/src/content.json` - Features, steps, latency updates
- `packages/website/public/demo.mp4` - Trimmed video
- `memory-bank/00-core/techStack.md` - Deployment docs

## Deployment
- Project: `yappatron` (NOT `yappa` from wrangler.toml)
- URL: https://yappatron.pages.dev
- Command: `CLOUDFLARE_API_TOKEN=$(cat ~/.config/cloudflare/pages-token) npx wrangler pages deploy dist --project-name yappatron`

## What's Next (Future, Not Urgent)
- iPhone app (local models = no subscriptions, unlike Whisper Flow's $15/month ripoff)
- Live on-the-fly editing (streaming LLM corrections instead of backspacing)
- Apple Developer Program when ready to notarize/ship iPhone app
