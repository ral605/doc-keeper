#!/bin/zsh
# Builds DockKeeper.app and installs it to ~/Applications.
# Note: each rebuild changes the code signature, so macOS will ask for
# Accessibility permission again (remove the old entry, add the new one).
set -e
cd "$(dirname "$0")"
APP=build/DockKeeper.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
# Apple Silicon build
swiftc -O -swift-version 5 -target arm64-apple-macos13 main.swift -o "$APP/Contents/MacOS/DockKeeper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.solvx.dockkeeper</string>
  <key>CFBundleName</key><string>DockKeeper</string>
  <key>CFBundleExecutable</key><string>DockKeeper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/DockKeeper.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/DockKeeper.app"
