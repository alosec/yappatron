#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/packages/ios/YappatronIOS/YappatronIOS.xcodeproj"
DERIVED_DATA="${IOS_DERIVED_DATA:-/tmp/yappatron-ios-device-build}"
TEAM_ID="${DEVELOPMENT_TEAM:-Z3RF5257M2}"
DEVICE_ID="${IOS_DEVICE_ID:-}"
LOG_FILE="${TMPDIR:-/tmp}/yappatron-ios-device-build.log"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required. Install Xcode, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

if ! xcrun devicectl list devices >/dev/null 2>&1; then
  echo "Could not query iOS devices with devicectl."
  echo "Plug in the iPhone, unlock it, enable Developer Mode, and trust this Mac."
  exit 1
fi

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(
    xcodebuild -project "$PROJECT" -scheme YappatronIOS -showdestinations 2>/dev/null \
      | sed -nE 's/.*platform:iOS, arch:arm64, id:([^,]+), name:.*/\1/p' \
      | head -1
  )"
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "No connected iPhone destination was found."
  echo "Run this to inspect what Xcode sees:"
  echo "  xcodebuild -project packages/ios/YappatronIOS/YappatronIOS.xcodeproj -scheme YappatronIOS -showdestinations"
  exit 1
fi

if ! security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | grep -q "OU=$TEAM_ID"; then
  echo "No Apple Development certificate for team $TEAM_ID was found in the keychain."
  echo "Open Xcode > Settings > Accounts and refresh the Apple account for this team."
  exit 1
fi

echo "Building YappatronIOS for device $DEVICE_ID with team $TEAM_ID..."
rm -rf "$DERIVED_DATA"
rm -f "$LOG_FILE"

if ! xcodebuild \
  -project "$PROJECT" \
  -scheme YappatronIOS \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  build 2>&1 | tee "$LOG_FILE"; then
  echo
  echo "iOS device build failed."
  if grep -q "No Account for Team\\|No profiles for" "$LOG_FILE"; then
    echo "Xcode could not create or refresh the provisioning profiles."
    echo "Open Xcode > Settings > Accounts, sign in or refresh the Apple account, then rerun this script."
  fi
  exit 1
fi

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/Yappatron.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Build succeeded, but app bundle was not found at:"
  echo "  $APP_PATH"
  exit 1
fi

echo "Installing $APP_PATH..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

if [[ "${LAUNCH:-0}" == "1" ]]; then
  xcrun devicectl device process launch --device "$DEVICE_ID" com.yappatron.ios
fi

echo "Installed Yappatron on device $DEVICE_ID."
