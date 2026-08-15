#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="PowerMeter.app"
BIN="$APP/Contents/MacOS/PowerMeter"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Info.plist — LSUIElement makes it a menu-bar-only agent (no Dock icon)
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>PowerMeter</string>
    <key>CFBundleDisplayName</key>     <string>전력 모니터</string>
    <key>CFBundleIdentifier</key>      <string>local.powermeter</string>
    <key>CFBundleVersion</key>         <string>1.5</string>
    <key>CFBundleShortVersionString</key><string>1.5</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>PowerMeter</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# bundle the app icon if present
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "Compiling…"
swiftc -O Sources/main.swift -o "$BIN" \
    -target arm64-apple-macos13.0 \
    -framework Cocoa -framework IOKit -framework ServiceManagement

# ad-hoc code signature so Gatekeeper/TCC treat it as a stable identity
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
