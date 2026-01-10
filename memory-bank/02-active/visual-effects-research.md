# Visual Effects Research: Siri-like Orb Animation

**Created:** 2026-01-09
**Updated:** 2026-01-09
**Status:** Blocked - Need macOS-Native Approach
**Epic:** yap-dec5

## ❌ BLOCKER: metasidd/Orb (iOS-Only)

**GitHub:** [metasidd/Orb](https://github.com/metasidd/Orb)
**License:** MIT
**Platform:** ~~macOS 14+~~, iOS 17+ ONLY

### Why This Library DOESN'T Work

**CRITICAL:** Despite README claiming macOS 14+ support, the library uses UIKit APIs that don't exist on macOS:
- `UIColor` (iOS-only, use `NSColor` on macOS)
- `UIGraphicsImageRenderer` (iOS-only)
- `UIBezierPath` (iOS-only, use `NSBezierPath` on macOS)

**Build Errors:**
- Cannot find type 'UIColor' in scope
- Cannot find 'UIGraphicsImageRenderer' in scope
- Cannot find 'UIBezierPath' in scope

**Attempted:** 2026-01-09 - Integration failed, library incompatible with macOS
**Commit:** ab2b6a8 - Documented blocker and reverted

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

## macOS-Native Approaches to Explore

### Option 1: Pure SwiftUI Animation (Recommended Start)
Based on [Siri Animation Gist](https://gist.github.com/amosgyamfi/b611c216604fd40a5aad2673fc5cf0b4):
- Layered circles with rotation3DEffect
- Continuous rotation animations (12s easing loop)
- Hue rotation for color morphing
- Blend modes (.hardLight, .difference)
- Timeline animation with autoreverses: false

**Pros:**
- Pure SwiftUI, fully macOS compatible
- No external dependencies
- 60fps smooth on modern Macs

**Cons:**
- More manual implementation needed
- No wavy blob morphing (static shapes rotating)

### Option 2: Metal Shaders (Advanced)
Use [twostraws/Inferno](https://github.com/twostraws/Inferno) for Metal shaders:
- Circle wave shader for morphing
- Bubble shader for iridescent effect
- Full GPU acceleration (120fps capable)

**Pros:**
- Most performant
- Most visually stunning
- Full control over effects

**Cons:**
- More complex to implement
- Metal shader knowledge required

### Option 3: Custom Path Animation
- Use SwiftUI Path and GeometryEffect
- Animate control points for organic morphing
- Layer multiple paths with different animations

**Pros:**
- True morphing (not just rotation)
- SwiftUI-native
- Full customization

**Cons:**
- Complex path calculations
- Need to implement morphing algorithm

## Next Steps

1. **Revert Orb integration** - Remove dependency, restore previous implementation
2. **Implement Option 1 (Pure SwiftUI)** - Start with rotating layered circles approach
3. **Test and iterate** - Get basic animation working first
4. **Consider Option 2/3** - If more organic feel needed later

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
