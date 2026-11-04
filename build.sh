#!/bin/bash
# Builds USBPhotoPull.app with the Xcode command-line tools (no Xcode project needed).
#   ./build.sh            → build for this Mac's architecture
#   ./build.sh universal  → Apple Silicon + Intel
#   ./build.sh install    → build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

NAME="USBPhotoPull"
APP="build/$NAME.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MODE="${1:-}"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

compile() {
  xcrun swiftc -O -parse-as-library \
    -sdk "$SDK" -target "$1-apple-macos13.0" \
    -framework AVKit -framework AVFoundation -framework ImageCaptureCore -framework UserNotifications \
    Sources/*.swift -o "$2"
}

if [[ "$MODE" == "universal" ]]; then
  compile arm64  "build/$NAME-arm64"
  compile x86_64 "build/$NAME-x86_64"
  lipo -create "build/$NAME-arm64" "build/$NAME-x86_64" -output "$APP/Contents/MacOS/$NAME"
  rm "build/$NAME-arm64" "build/$NAME-x86_64"
else
  compile "$(uname -m)" "$APP/Contents/MacOS/$NAME"
fi

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "$MODE" == "install" ]]; then
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/$NAME.app"
  if [[ -d /Applications/PhotoPull.app ]]; then
    echo "Note: the old /Applications/PhotoPull.app is still there — delete it when you're ready."
  fi
fi
