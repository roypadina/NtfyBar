#!/bin/bash
# Regenerates the NtfyBar demo from scratch: compile the app's real NtfyBarCore module, then kit + scene + the app's real popup view files,
# render frames offscreen (no window is ever shown, nothing is clicked or captured, the installed app is never launched), encode.
# One command: ./render.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$HERE}"; [ -f "$KIT/DemoKit.swift" ] || KIT="$HERE/../kit"          # repo: kit is vendored next to this file
APP="${APP_SRC:-$HERE/../..}"                                                   # repo: docs/demo -> repo root
GIF="${GIF:-$HERE/../demo.gif}"                                                 # repo: docs/demo.gif
BUILD="${BUILD:-${TMPDIR:-/tmp}/ntfybar-demo}"                                  # never inside the repo (hundreds of MB of frames)
mkdir -p "$BUILD"
# NtfyBarCore is a Swift 6 module of its own (all logic: PopupContent, StatusSummary, SafeOpen ...); the app view files import it.
swiftc -swift-version 6 -Onone -parse-as-library -module-name NtfyBarCore -emit-module -emit-module-path "$BUILD/NtfyBarCore.swiftmodule" \
  -emit-library -static -o "$BUILD/libNtfyBarCore.a" $(find "$APP/Sources/NtfyBarCore" -name '*.swift' | sort)
swiftc -swift-version 5 -parse-as-library -O -I "$BUILD" -L "$BUILD" -lNtfyBarCore -licucore -o "$BUILD/demo" \
  "$KIT/DemoKit.swift" "$HERE/scene.swift" \
  "$APP/Sources/NtfyBarApp/PopupPanel.swift" "$APP/Sources/NtfyBarApp/Theme.swift" "$APP/Sources/NtfyBarApp/Components.swift"
rm -rf "$BUILD/frames"
NTFYBAR_ASSETS="$APP/Assets/icons" \
  "$BUILD/demo" "$BUILD/frames" 30 -AppleLocale en_US -AppleLanguages "(en)"
POSTER=${POSTER:-144}  # t = 4.8 s: popup fully in (scene 2, 2.4 s in), bell "1", caption settled, no cursor yet (scene 3 starts 5.4 s)
"$KIT/encode.sh" "$BUILD/frames" "$GIF" "${MP4:-}" "${WEBP:-}" "${POSTER:-}"
rm -rf "$BUILD/frames"                                                            # only after a successful encode (set -e)
