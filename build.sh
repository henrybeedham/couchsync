#!/bin/zsh
# Builds CouchSync.app (Apple silicon) into ./build.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/CouchSync.app"

# The iroh bridge (invite-code parties) is Rust, in net/. Install Rust with
# https://rustup.rs if cargo isn't found.
[[ -x "$(command -v cargo)" ]] || source "$HOME/.cargo/env" 2>/dev/null || true
if ! command -v cargo >/dev/null; then
  echo "Rust is needed to build CouchSync. Install it from https://rustup.rs" >&2
  exit 1
fi
rustup target add aarch64-apple-darwin >/dev/null 2>&1 || true
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --locked --target aarch64-apple-darwin \
  --manifest-path net/Cargo.toml

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN/CouchSync" "$APP/Contents/MacOS/CouchSync"

# macOS uses the SDK version recorded in the app to decide whether it gets the
# current design (Liquid Glass on macOS 26 and later). The Command Line Tools
# record the deployment target there instead, so write the real SDK version.
SDK_VERSION="$(xcrun --show-sdk-version)"
vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/CouchSync" "$APP/Contents/MacOS/CouchSync"
echo "Built against the macOS $SDK_VERSION SDK"

# Icon
ICONSET="build/CouchSync.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" build/icon-1024.png

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CouchSync</string>
  <key>CFBundleDisplayName</key><string>CouchSync</string>
  <key>CFBundleIdentifier</key><string>local.couchsync.app</string>
  <key>CFBundleExecutable</key><string>CouchSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>CouchSync connects to other Macs to keep playback in step.</string>
</dict>
</plist>
PLIST

# Version: from $VERSION (release.sh sets it), else 1.0.
plutil -replace CFBundleShortVersionString -string "${VERSION:-1.0}" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"

# GIPHY key for the GIF browser: from $GIPHY_API_KEY or a giphy-key.txt file
# next to this script. Without one, the app asks for a key the first time.
GIPHY_KEY="${GIPHY_API_KEY:-$(cat giphy-key.txt 2>/dev/null || true)}"
if [[ -n "$GIPHY_KEY" ]]; then
  plutil -insert GiphyAPIKey -string "$GIPHY_KEY" "$APP/Contents/Info.plist"
  echo "Included GIPHY key"
fi

codesign --force --sign - "$APP"
echo "Built $APP"
