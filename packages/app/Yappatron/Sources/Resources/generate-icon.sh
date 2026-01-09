#!/bin/bash
# Generate a simple 'y' icon for Yappatron

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICONSET="$SCRIPT_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"

# Generate SVG with centered 'y'
cat > "$SCRIPT_DIR/icon.svg" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg">
  <rect width="1024" height="1024" fill="white"/>
  <text
    x="512"
    y="700"
    font-family="system-ui, -apple-system, sans-serif"
    font-size="700"
    font-weight="300"
    text-anchor="middle"
    fill="black">y</text>
</svg>
EOF

# Convert SVG to PNG at different sizes using sips (built into macOS)
# First, convert to a large PNG using qlmanage (quick look)
qlmanage -t -s 1024 -o "$SCRIPT_DIR" "$SCRIPT_DIR/icon.svg" > /dev/null 2>&1
mv "$SCRIPT_DIR/icon.svg.png" "$SCRIPT_DIR/icon-1024.png"

# Generate all required icon sizes
sips -z 16 16 "$SCRIPT_DIR/icon-1024.png" --out "$ICONSET/icon_16x16.png" > /dev/null
sips -z 32 32 "$SCRIPT_DIR/icon-1024.png" --out "$ICONSET/icon_16x16@2x.png" > /dev/null
sips -z 32 32 "$SCRIPT_DIR/icon-1024.png" --out "$ICONSET/icon_32x32.png" > /dev/null
sips -z 64 64 "$SCRIPT_DIR/icon-1024.png" --out "$ICONSET/icon_32x32@2x.png" > /dev/null
sips -z 128 128 "$SCRIPT_DIR/icon-1024.png" --out "$ICONSET/icon_128x128.png" > /dev/null
sips -z 256 256 "$SCRIPT_DIR/icon-1024.png" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
sips -z 256 256 "$SCRIPT_DIR/icon-1024.png" --out "$ICONSET/icon_256x256.png" > /dev/null
sips -z 512 512 "$SCRIPT_DIR/icon-1024.png" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
sips -z 512 512 "$SCRIPT_DIR/icon-1024.png" --out "$ICONSET/icon_512x512.png" > /dev/null
cp "$SCRIPT_DIR/icon-1024.png" "$ICONSET/icon_512x512@2x.png"

# Convert iconset to icns
iconutil -c icns "$ICONSET" -o "$SCRIPT_DIR/AppIcon.icns"

# Clean up temporary files
rm -rf "$ICONSET"
rm "$SCRIPT_DIR/icon.svg"
rm "$SCRIPT_DIR/icon-1024.png"

echo "Generated AppIcon.icns"
