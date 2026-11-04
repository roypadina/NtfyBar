#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="NtfyBar"
BUNDLE_ID="com.padina.ntfybar"
VERSION="1.6.1"
BUILD_NUMBER="11"
BUILD_CONFIG="release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SIGNING_IDENTITY="${NTFYBAR_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
# RELEASE=1: signed with the maintainer's stable identity when it is in the keychain (so macOS
# permissions survive updates), else ad hoc; zipped into dist/NtfyBar.zip for GitHub Releases and
# the Homebrew cask. Dev builds use that identity too, else the first local code-signing identity.
RELEASE="${RELEASE:-}"

cd "$ROOT_DIR"

# Universal (Apple Silicon + Intel). -file-prefix-map: no build-machine paths in #file strings.
swift build -c "$BUILD_CONFIG" --arch arm64 --arch x86_64 -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=."
BIN_DIR="$(swift build -c "$BUILD_CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/NtfyBarApp" "$MACOS_DIR/$APP_NAME"
# Sparkle (in-app updates): the framework SwiftPM puts next to the binary; ditto keeps its symlinks.
mkdir -p "$CONTENTS_DIR/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
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
    <!-- Sparkle updates: the feed is the appcast.xml asset of the latest GitHub release. No
         SUEnableAutomaticChecks on purpose: Sparkle asks once, since NtfyBar contacts no one unasked. -->
    <key>SUFeedURL</key>
    <string>https://github.com/roypadina/NtfyBar/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>qq4oZAVmJanKJ1bTAzGSO94WWX6cx+/5kCjBZxJXEm0=</string>
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

STABLE_ID="KeyLayoutSwitcher Dev"
if [[ -z "$SIGNING_IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$STABLE_ID\""; then
    SIGNING_IDENTITY="$STABLE_ID"
fi

if [[ -n "$RELEASE" && -z "$SIGNING_IDENTITY" ]]; then
    echo "warning: stable signing identity missing; ad hoc release build" >&2
    SIGNING_IDENTITY="-"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F '"' '/valid identities found/ { next } /".+"/ { print $2; exit }'
    )"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "warning: no code-signing identity found; falling back to ad hoc signing" >&2
    SIGNING_IDENTITY="-"
fi
# Inside-out, not --deep: --deep --identifier would stamp the app's identifier on Sparkle's helpers.
find "$CONTENTS_DIR" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \
    -o \( -name Autoupdate -type f \) \) | while read -r nested; do
    codesign --force --preserve-metadata=identifier,entitlements,flags --sign "$SIGNING_IDENTITY" "$nested"
done
codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

if [[ -n "$RELEASE" ]]; then
    ZIP="$DIST_DIR/NtfyBar.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$ZIP"
    shasum -a 256 "$ZIP"

    # Sparkle feed for this release only (uploaded next to the zip; the app reads the latest release's
    # appcast.xml). Only with the key whose public half the app ships; any other key makes a feed every
    # copy refuses.
    SPARKLE=.build/artifacts/sparkle/Sparkle/bin
    if [[ "$("$SPARKLE/generate_keys" -p 2>/dev/null || true)" == "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$CONTENTS_DIR/Info.plist")" ]]; then
        FEED_DIR=$(mktemp -d)
        cp "$ZIP" "$FEED_DIR/"
        # This version's CHANGELOG section becomes the update prompt's release notes.
        awk -v v="## [$VERSION]" 'index($0, v) == 1 {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md > "$FEED_DIR/$APP_NAME.md"
        rm -f "$DIST_DIR/appcast.xml"  # generate_appcast merges into an existing file
        "$SPARKLE/generate_appcast" --embed-release-notes \
            --download-url-prefix "https://github.com/roypadina/NtfyBar/releases/download/v$VERSION/" \
            -o "$DIST_DIR/appcast.xml" "$FEED_DIR"
        rm -rf "$FEED_DIR"
        echo "$DIST_DIR/appcast.xml"
    else
        echo "Sparkle signing key (matching SUPublicEDKey) not in the keychain: no appcast.xml"
    fi
fi

echo "$APP_DIR"
