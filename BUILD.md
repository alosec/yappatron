# Building Yappatron

## Quick Start

```bash
# Build and install
./scripts/run-dev.sh
```

This will:
1. Build the Swift package in release mode
2. Create a proper .app bundle at `build/Yappatron.app`
3. Install it to `/Applications/Yappatron.app`
4. Launch the app

## What Changed: The "Going Legit" Approach (Without Paying Apple)

### The Problem
Running a bare Swift executable from `.build/debug/` meant:
- Permissions didn't stick across rebuilds (binary hash changed)
- macOS couldn't track the app properly
- No stable bundle identifier for the permission system

### The Solution
Create a proper .app bundle with:
- Stable bundle identifier: `com.yappatron.app`
- Proper Info.plist with all permission descriptions
- Ad-hoc code signing (FREE, no Developer Program needed)
- Install to `/Applications/` for stable location

### What You Get
✓ Double-clickable .app in Applications folder
✓ Permissions persist across rebuilds
✓ Proper macOS integration (Dock, Spotlight, etc.)
✓ **Costs $0** - ad-hoc signing only
✗ Can't distribute to others (they'll get security warnings)

## Manual Build

```bash
# Just build (doesn't install)
./scripts/build-app.sh

# Output: build/Yappatron.app
```

## Permissions Setup

When you first launch Yappatron.app, you'll need to:

1. **Microphone**: App will prompt automatically - click "Allow"
2. **Accessibility**:
   - Open System Settings > Privacy & Security > Accessibility
   - Find "Yappatron" in the list
   - Toggle it ON

Permissions will now persist even after rebuilding the app!

## Rebuilding

```bash
# After making code changes
./scripts/run-dev.sh
```

This rebuilds, reinstalls, and relaunches. Your permissions will carry over because the bundle ID stays the same.

## Icon

The app includes a simple lowercase "y" icon on white background. To regenerate it:

```bash
cd packages/app/Yappatron/Sources/Resources
./generate-icon.sh
```

## Technical Details

**Bundle Structure:**
```
Yappatron.app/
├── Contents/
│   ├── Info.plist          # Bundle metadata & permissions
│   ├── MacOS/
│   │   └── Yappatron       # The executable
│   ├── Resources/
│   │   └── AppIcon.icns    # App icon
│   └── _CodeSignature/     # Ad-hoc signature
```

**Key Info.plist Settings:**
- `CFBundleIdentifier`: `com.yappatron.app` (stable identity)
- `LSUIElement`: `true` (menu bar app, no Dock icon)
- `NSMicrophoneUsageDescription`: Permission prompt text
- `NSAppleEventsUsageDescription`: Accessibility permission note

**Code Signing:**
- Ad-hoc signing: `codesign --force --deep --sign - Yappatron.app`
- No Developer ID certificate needed
- Works perfectly for personal use
- Free forever
