#!/bin/bash
# Builds MacMon.app (the menu-bar app + war-room window) next to this script.
# Needs the Xcode Command Line Tools (for swiftc and python3):  xcode-select --install
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. It ships with the Xcode Command Line Tools:  xcode-select --install" >&2
  exit 1
fi

APP=MacMon.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O MacMon.swift -o $APP/Contents/MacOS/MacMon
cp server.py index.html war.html $APP/Contents/Resources/
cp -R vendor $APP/Contents/Resources/vendor
cp -R audio $APP/Contents/Resources/audio
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MacMon</string>
<key>CFBundleIdentifier</key><string>io.github.mack.macmon</string>
<key>CFBundleExecutable</key><string>MacMon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
P
# ad-hoc signature so macOS will launch a locally built app
codesign --force --sign - $APP >/dev/null 2>&1 || true
echo "Built $APP  ->  open it with:  open $APP"
