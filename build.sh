#!/bin/zsh
# Builds "Pin on Top.app" into ./build from Sources/main.swift.
# Needs only the Xcode Command Line Tools (xcode-select --install).
#
#   ./build.sh            build only
#   ./build.sh --install  build, copy to /Applications and open it
set -euo pipefail
cd "${0:A:h}"

APP="build/Pin on Top.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  Sources/main.swift -o "$APP/Contents/MacOS/PinOnTop"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pin on Top</string>
  <key>CFBundleDisplayName</key><string>Pin on Top</string>
  <key>CFBundleIdentifier</key><string>io.github.kurrt.pin-on-top</string>
  <key>CFBundleExecutable</key><string>PinOnTop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS can remember the Screen Recording and Accessibility grants.
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x PinOnTop || true
  rm -rf "/Applications/Pin on Top.app"
  cp -R "$APP" /Applications/
  open "/Applications/Pin on Top.app"
  echo "Installed to /Applications/Pin on Top.app"
fi
