# Visual Effects Research: Siri-like Orb Animation

**Created:** 2026-01-09
**Status:** Ready for Implementation
**Epic:** yap-dec5

## Chosen Approach: metasidd/Orb

**GitHub:** [metasidd/Orb](https://github.com/metasidd/Orb)
**License:** MIT
**Platform:** macOS 14+, iOS 17+

### Why This Library

- Pure SwiftUI (no Metal complexity to start)
- 10 configuration parameters for customization
- Beautiful out-of-the-box Siri-like effect
- Layered approach: gradients + wavy blobs + particles + glow
- Easy audio reactivity integration

### Architecture

**Components:**
1. Gradient backgrounds (animated color arrays)
2. Wavy blob shapes (organic morphing)
3. Particle system (floating particles)
4. Layered glow effects
5. Shadow rendering

**Configuration:**
```swift
OrbConfiguration(
    backgroundColors: [.purple, .blue, .pink],
    glowColor: .white,
    coreGlowIntensity: 1.2,
    speed: 60,
    showBackground: true,
    showWavyBlobs: true,
    showParticles: true,
    showGlowEffects: true,
    showShadow: true
)
```

## Implementation Plan

### Phase 1: Basic Integration (yap-dec5.3.1)
- Add metasidd/Orb via Swift Package Manager
- Replace current Circle in OverlayView with OrbView
- Configure psychedelic color palette

### Phase 2: Audio Reactivity (yap-dec5.3.2)
- Extract audio amplitude from TranscriptionEngine
- Pass to OverlayViewModel
- Modulate orb scale, glow intensity, speed based on amplitude

### Phase 3: State Animations (yap-dec5.5)
- Idle: Subtle breathing
- Speaking: Active morphing with audio reactivity
- Finalization: Burst effect when Enter pressed

## Future Enhancements

If we want more advanced effects later:

**Add Vortex for particles:**
- GitHub: [twostraws/Vortex](https://github.com/twostraws/Vortex)
- Burst particles on finalization

**Add Metal shaders:**
- GitHub: [twostraws/Inferno](https://github.com/twostraws/Inferno)
- Circle wave shader for extra morphing
- Bubble shader for iridescent effect

**Add real-time waveform:**
- GitHub: [dmrschmidt/DSWaveformImage](https://github.com/dmrschmidt/DSWaveformImage)
- Live audio waveform visualization

## Color Palette Ideas

**Psychedelic Option 1:**
- Purple (#8B5CF6)
- Blue (#3B82F6)
- Pink (#EC4899)
- Teal (#14B8A6)

**Psychedelic Option 2:**
- Deep Purple (#7C3AED)
- Cyan (#06B6D4)
- Magenta (#D946EF)
- Orange (#F97316)

**Siri-inspired:**
- Purple-Blue gradient
- White/cyan glow
- Subtle pink accents

## Technical Notes

**Performance:**
- Pure SwiftUI means 60fps on modern Macs
- Can upgrade to Metal later for 120fps if needed
- Current OverlayWindow already supports smooth animations

**Integration Points:**
- OverlayViewModel tracks `isSpeaking` (already connected)
- Can add `audioAmplitude: Double` property
- TranscriptionEngine can expose amplitude via callback

**No Refactoring Needed:**
- Current SwiftUI-based overlay is perfect foundation
- Just swap Circle for OrbView
- Existing animation infrastructure works as-is

## References

- [metasidd/Orb GitHub](https://github.com/metasidd/Orb)
- [Siri Animation Clone Gist](https://gist.github.com/amosgyamfi/b611c216604fd40a5aad2673fc5cf0b4)
- Research agent: aa34b6e (full visual effects research)
