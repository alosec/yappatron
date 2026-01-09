#!/bin/bash
# Build Yappatron.app bundle from Swift Package Manager build

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_PKG="$PROJECT_ROOT/packages/app/Yappatron"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/Yappatron.app"

echo "Building Yappatron Swift package..."
cd "$SWIFT_PKG"
swift build -c release

echo "Creating .app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "Copying binary..."
cp "$SWIFT_PKG/.build/release/Yappatron" "$APP_BUNDLE/Contents/MacOS/Yappatron"

echo "Copying Info.plist..."
cp "$SWIFT_PKG/Sources/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "Copying icon..."
if [ -f "$SWIFT_PKG/Sources/Resources/AppIcon.icns" ]; then
    cp "$SWIFT_PKG/Sources/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "Ad-hoc signing the bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "✓ Yappatron.app built successfully at: $APP_BUNDLE"
echo ""
echo "To install: cp -r '$APP_BUNDLE' /Applications/"
echo "To run: open -a '$APP_BUNDLE'"
