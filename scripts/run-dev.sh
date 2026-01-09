#!/bin/bash
# Build and run Yappatron as a proper .app bundle
# This ensures permissions stick across rebuilds

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/build/Yappatron.app"
INSTALL_PATH="/Applications/Yappatron.app"

echo "Building Yappatron.app bundle..."
"$SCRIPT_DIR/build-app.sh"

echo ""
echo "Installing to /Applications..."
# Remove old version if exists
if [ -d "$INSTALL_PATH" ]; then
    rm -rf "$INSTALL_PATH"
fi

cp -r "$APP_BUNDLE" "$INSTALL_PATH"

echo "Launching Yappatron..."
open -a "$INSTALL_PATH"

echo ""
echo "✓ Yappatron is now running from /Applications/Yappatron.app"
echo ""
echo "Next steps:"
echo "1. Grant microphone permission when prompted"
echo "2. Grant accessibility permission in System Settings > Privacy & Security > Accessibility"
echo "3. Speak to test transcription!"
