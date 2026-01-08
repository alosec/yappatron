# Session: Website Redesign

**Date:** 2026-01-08
**Duration:** ~1 hour
**Focus:** Landing page overhaul

## Summary

Complete redesign of yappatron.pages.dev from generic dark tech template to distinctive editorial aesthetic.

## Changes Made

### Iteration 1: Dark container layout
- Added container card with border
- Theme picker with 5 colors (sakura, wisteria, peach, matcha, frost)
- Fixed mobile padding issues

### Iteration 2: TNG-inspired (rejected)
- Tried Star Trek TNG clean aesthetic
- Grid background, accent bars, Outfit font
- Alex: "does not really bang... it's a copy cat"

### Iteration 3: Editorial/Literary (shipped)
- **Concept:** Voice becoming text invisibly. Presence. Stillness.
- **Typography:** Newsreader serif (literary) + DM Mono (technical)
- **Breathing animation:** Subtle pulsing glow in center - represents "listening"
- **Light/dark mode:** Respects system preference
- **Content from JSON:** All text loaded at build time
- **Minimal chrome:** Dot theme picker, tiny pills, single-dot dividers
- **No container box:** Content breathes on the page
- **Themes:** mist (default), lotus, ember, moss, depth
- **Branding:** 🪷 lotus, lowercase "yappatron", MIT emphasized

## Key Files
- `packages/website/src/content.json` - all page content
- `packages/website/src/pages/index.astro` - single-file page with styles

## Design Principles Discovered
- The design should feel like the product (quiet, present)
- Editorial/literary aesthetic fits voice-to-text better than sci-fi
- Breathing animation adds soul without being distracting
- System light/dark preference is table stakes

## Commits
- `81b1817` - Website: dark container layout, cleaner design
- `fb21303` - Website: theme picker (sakura, wisteria, peach, matcha, frost)
- `183cc0e` - Website: editorial redesign, content.json, breathing animation, light/dark mode
