#!/bin/zsh
# Builds TokenCapsule.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/TokenCapsule.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework ServiceManagement \
  Sources/Logs.swift Sources/UI.swift Sources/main.swift -o "$APP/Contents/MacOS/TokenCapsule"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TokenCapsule</string>
  <key>CFBundleDisplayName</key><string>TokenCapsule</string>
  <key>CFBundleIdentifier</key><string>io.github.kritikal619.tokencapsule</string>
  <key>CFBundleExecutable</key><string>TokenCapsule</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
mkdir -p ~/Applications
ditto "$APP" ~/Applications/TokenCapsule.app
echo "Installed ~/Applications/TokenCapsule.app"
