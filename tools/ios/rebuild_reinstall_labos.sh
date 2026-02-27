#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="$ROOT_DIR/LabOS.xcodeproj"
SCHEME="LabOSApp"
BUNDLE_ID="labos.LabOSApp"
DERIVED_ACTIVE="$ROOT_DIR/.build/labos-ios-active"
APP_PATH="$DERIVED_ACTIVE/Build/Products/Debug-iphonesimulator/LabOSApp.app"
APP_BIN="$APP_PATH/LabOSApp"
DERIVED_DATA_BASE="$HOME/Library/Developer/Xcode/DerivedData"

UDID="$(xcrun simctl list devices | awk -F '[()]' '/\(Booted\)/{print $2; exit}')"
if [[ -z "${UDID:-}" ]]; then
  echo "No booted iOS simulator found."
  exit 1
fi

echo "Using simulator: $UDID"
echo "Root: $ROOT_DIR"

echo "Terminating and uninstalling existing app..."
xcrun simctl terminate "$UDID" "$BUNDLE_ID" || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" || true

echo "Building with fixed DerivedData path: $DERIVED_ACTIVE"
rm -rf "$DERIVED_ACTIVE"
mkdir -p "$DERIVED_ACTIVE"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_ACTIVE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce app bundle at: $APP_PATH"
  exit 1
fi

echo "Removing old LabOS DerivedData directories..."
if compgen -G "$DERIVED_DATA_BASE/LabOS-*" > /dev/null; then
  rm -rf "$DERIVED_DATA_BASE"/LabOS-*
fi

echo "Installing from fixed app path..."
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" || true
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

INSTALLED_APP_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app)"
INSTALLED_BIN="$INSTALLED_APP_DIR/LabOSApp"

SRC_SHA="$(shasum -a 256 "$APP_BIN" | awk '{print $1}')"
INST_SHA="$(shasum -a 256 "$INSTALLED_BIN" | awk '{print $1}')"

echo "Source SHA256:   $SRC_SHA"
echo "Installed SHA256:$INST_SHA"

if [[ "$SRC_SHA" != "$INST_SHA" ]]; then
  echo "ERROR: installed app hash does not match built artifact hash."
  exit 2
fi

echo "Done. Installed app matches the latest fixed-path build."
