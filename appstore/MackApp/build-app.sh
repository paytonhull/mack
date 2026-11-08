#!/bin/bash
# Builds a sandboxed M.A.C.K. app bundle for local testing (Phase 2). Phase 3 replaces this with an Xcode project.
#   ./build-app.sh            build MACK.app, ad-hoc signed WITH the App Sandbox
#   ./build-app.sh run-test war|popover|feed   build, then run the automated self-test inside the sandbox
set -e
cd "$(dirname "$0")"
SRC=../..            # the shared web files live one level above appstore/
APP=MACK.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources/web
swiftc -O -swift-version 5 Sources/*.swift -o $APP/Contents/MacOS/MACK
python3 ../tools/make-store-web.py >/dev/null
cp ../web/index.html ../web/war.html $APP/Contents/Resources/web/
cp -R $SRC/vendor $APP/Contents/Resources/web/vendor
mkdir -p $APP/Contents/Resources/web/audio
cp $SRC/audio/*.mp3 $APP/Contents/Resources/web/audio/
cp -R $SRC/audio/fx $APP/Contents/Resources/web/audio/fx
xattr -cr $APP/Contents/Resources || true   # no quarantine attributes (the App Store rejects them)
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>M.A.C.K.</string>
<key>CFBundleDisplayName</key><string>M.A.C.K.</string>
<key>CFBundleIdentifier</key><string>io.github.paytonhull.mack</string>
<key>CFBundleExecutable</key><string>MACK</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
codesign --force --sign - --entitlements MackApp.entitlements $APP
echo "Built $APP (sandboxed)"
if [ "$1" = "run-test" ]; then
  echo "--- self-test: ${2:-war}"
  $APP/Contents/MacOS/MACK --selftest "${2:-war}"
fi
