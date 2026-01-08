# Session: Website Deploy & Memory Bank

**Date:** 2026-01-08
**Location:** VPS (tiny-bat)

## What Happened

1. Cloned repo from GitHub to VPS
2. Explored architecture — discovered Python code is dormant, Swift is production
3. Created CF Pages project `yappatron`
4. Deployed website to yappatron.pages.dev
5. Added sakura-inspired styling (pink palette, floating petals, dark mode)
6. Documented licensing (all permissive, no GPL)
7. Set up proper memory-bank structure

## Key Discoveries

- **Ghost text diffing** is implemented in Swift (`InputSimulator.applyTextUpdate`) but rarely fires because Parakeet model doesn't often revise mid-stream
- **FluidAudio** uses Apache 2.0, models are MIT/Apache — clean licensing
- **FluidAudioTTS** (not used) has GPL dependency — avoid

## Files Changed

- `packages/website/` — Astro config, wrangler.toml, sakura CSS
- `MEMBANK.md` — Updated with licensing, cleaner structure
- `memory-bank/` — Created proper structure

## Tasks Created

```
yap-821c  done     Website deployment
yap-e049  P0       Race condition crash
yap-ac58  P2       Custom vocabulary (Swift)
yap-a4df  P2       App notarization
```
