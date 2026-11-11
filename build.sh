#!/bin/zsh
# Builds "Pin on Top.app" into ./build from Sources/main.swift, as one app for both Apple
# silicon and Intel Macs. Needs only the Xcode Command Line Tools (xcode-select --install).
#
#   ./build.sh                  build only
#   ./build.sh --install        build, copy to /Applications and open it
#   ./build.sh --zip            build, then zip it to build/Pin-on-Top-<version>.zip with its SHA-256
#   ./build.sh --print-version  print the version and stop
#
# Options can be combined, such as ./build.sh --zip --install.
set -euo pipefail
cd "${0:A:h}"

# The version for the app and the release. CHANGELOG.md's newest section and the README's zip
# name must match it.
VERSION="1.1.0"

install_app=false
make_zip=false
for option in "$@"; do
  case "$option" in
    --print-version) echo "$VERSION"; exit 0 ;;
    --install) install_app=true ;;
    --zip) make_zip=true ;;
    *) echo "Unknown option: $option (try --install, --zip or --print-version)" >&2; exit 2 ;;
  esac
done

APP="build/Pin on Top.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
    Sources/main.swift -o "build/PinOnTop-$arch"
done
lipo -create build/PinOnTop-arm64 build/PinOnTop-x86_64 -output "$APP/Contents/MacOS/PinOnTop"
rm build/PinOnTop-arm64 build/PinOnTop-x86_64

# Made by scripts/make_icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pin on Top</string>
  <key>CFBundleDisplayName</key><string>Pin on Top</string>
  <key>CFBundleIdentifier</key><string>io.github.kurrt.pin-on-top</string>
  <key>CFBundleExecutable</key><string>PinOnTop</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Kurrt. MIT licence.</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# A synced folder such as iCloud Drive can add extended attributes, which codesign refuses.
# The ad hoc signature lets macOS remember the Screen Recording and Accessibility grants.
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

if $make_zip; then
  ZIP="Pin-on-Top-$VERSION.zip"
  rm -f "build/$ZIP" "build/$ZIP.sha256"
  # Without extended attributes, which would add ._ files that break the signature for unzip tools
  # that don't know them.
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "build/$ZIP"
  # The file name only, so shasum -a 256 -c works next to the download.
  (cd build && shasum -a 256 "$ZIP" > "$ZIP.sha256")
  echo "Zipped $PWD/build/$ZIP"
fi

if $install_app; then
  pkill -x PinOnTop || true
  rm -rf "/Applications/Pin on Top.app"
  cp -R "$APP" /Applications/
  open "/Applications/Pin on Top.app"
  echo "Installed to /Applications/Pin on Top.app"
fi
