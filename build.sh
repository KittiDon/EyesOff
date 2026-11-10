#!/bin/bash
# Builds EyesOff.app into ~/Applications.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/EyesOff.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>EyesOff</string>
    <key>CFBundleDisplayName</key>     <string>EyesOff</string>
    <key>CFBundleExecutable</key>      <string>EyesOff</string>
    <key>CFBundleIdentifier</key>      <string>com.kirtan.eyesoff</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

swiftc -O \
    -target x86_64-apple-macosx13.0 \
    -framework Cocoa -framework ServiceManagement -framework IOKit \
    -o "$APP/Contents/MacOS/EyesOff" \
    "$SRC_DIR/Sources/main.swift"

codesign --force --deep --sign - "$APP"

echo "Built: $APP"
