# M.A.C.K. for the Mac App Store (sandboxed edition)

This folder holds the **sandboxed edition** of M.A.C.K., prepared for the Mac App Store. It is not on the store yet. The main project in the parent folder (Python server plus a Swift shell) is unchanged and still the easiest way to try M.A.C.K.

## How it differs from the main build

| | Main build | App Store edition |
|---|---|---|
| Stats | `server.py` (Python, command-line tools) | Native Swift (`Sources/Stats.swift`), sandbox-safe system APIs |
| Pages | served by a local web server on `127.0.0.1:8765` | served from inside the app by a custom URL scheme (no server) |
| Live Feed | YouTube iframe in the page | separate overlay web view (YouTube refuses embeds from a custom-scheme page) |
| Sandbox | no | App Sandbox on: only `app-sandbox` and `network.client` entitlements |
| Wording | film-inspired ("Global Thermonuclear War"...) | reworded by `tools/make-store-web.py` ("Global Meltdown"...) |
| Extras | | app icon, privacy manifest, About and Settings windows, main menu |

The web files (`war.html`, `index.html`, `vendor/`, `audio/`) are shared with the main build. `tools/make-store-web.py` creates the store wording from the shared `war.html`, and it stops with an error if any expected text is missing.

## Build it yourself

You need Xcode (the full app, not just the command line tools) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd appstore/MackApp
xcodegen generate            # recreates MACK.xcodeproj from project.yml (the project is also checked in)
xcodebuild -project MACK.xcodeproj -scheme MACK -configuration Release \
  -derivedDataPath build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
open build/Build/Products/Release/MACK.app
```

That builds an ad-hoc signed, sandboxed copy for local testing. Look for the readout in the menu bar. Apple silicon only.

To publish your own build to the App Store you need your own Apple Developer account, bundle ID and team (change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`).

## Self-tests

The app has an automated check mode that runs inside the sandbox and prints what it finds:

```bash
build/Build/Products/Release/MACK.app/Contents/MacOS/MACK --selftest war      # war room loads, live data flows
build/Build/Products/Release/MACK.app/Contents/MacOS/MACK --selftest popover  # menu-bar dashboard
build/Build/Products/Release/MACK.app/Contents/MacOS/MACK --selftest audio    # audio engine and music
build/Build/Products/Release/MACK.app/Contents/MacOS/MACK --selftest feed 1   # live feed overlay, preset 0-2
```

To hide your Mac's real name in screenshots, add `-hostOverride demo-mac` to any command above.

## Layout

```
appstore/
  MackApp/
    project.yml            XcodeGen project description (source of truth)
    MACK.xcodeproj         generated project, checked in for convenience
    Sources/               Stats.swift, Web.swift, main.swift
    Resources/             PrivacyInfo.xcprivacy, Credits.html
    Assets.xcassets/       app icon
    tools/                 icon source (icon.html) and the rendered 1024 px icon
    MackApp.entitlements   sandbox entitlements
    build-app.sh           quick swiftc build (no Xcode project) for experiments
  tools/make-store-web.py  builds the store wording
```

Same MIT license as the rest of the project.
