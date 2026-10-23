#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="NtfyBar"
BUNDLE_ID="com.padina.ntfybar"
VERSION="1.1.0"
BUILD_NUMBER="3"
BUILD_CONFIG="release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
# RELEASE=1: ad hoc signed (no local certificate name ships) and zipped into dist/NtfyBar.zip for
# GitHub Releases and the Homebrew cask. Dev builds use the first local code-signing identity.
RELEASE="${RELEASE:-}"

cd "$ROOT_DIR"

# Universal (Apple Silicon + Intel). -file-prefix-map: no build-machine paths in #file strings.
swift build -c "$BUILD_CONFIG" --arch arm64 --arch x86_64 -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=."
BIN_DIR="$(swift build -c "$BUILD_CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/NtfyBarApp" "$MACOS_DIR/$APP_NAME"
cp Assets/icons/AppIcon.icns Assets/icons/menubar.png Assets/icons/menubar@2x.png "$RESOURCES_DIR/"
cp -R Resources/BundledPlugins "$RESOURCES_DIR/BundledPlugins"
find "$RESOURCES_DIR" -name .DS_Store -delete

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Self-hosted ntfy servers may be plain http on a home network; the user picks the URL. -->
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>NtfyBar connects to ntfy servers on your local network when you add one.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Roy Padina · MIT</string>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/$APP_NAME"
# Drop the debug map (object-file paths from the build machine).
strip -S -x "$MACOS_DIR/$APP_NAME"

if [[ -n "$RELEASE" && -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F '"' '/valid identities found/ { next } /".+"/ { print $2; exit }'
    )"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
else
    echo "warning: no code-signing identity found; falling back to ad hoc signing" >&2
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

if [[ -n "$RELEASE" ]]; then
    ZIP="$DIST_DIR/NtfyBar.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$ZIP"
    shasum -a 256 "$ZIP"
fi

echo "$APP_DIR"
