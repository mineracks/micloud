#!/usr/bin/env bash
# Build PhotosApp: main.swift + MicloudKit sources (./kit/) → one sandboxed, ad-hoc-signed .app.
# NSPhotoLibraryUsageDescription is REQUIRED in Info.plist or the app crashes on Photos access.
set -euo pipefail
cd "$(dirname "$0")"
APP="PhotosApp.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PhotosApp</string>
  <key>CFBundleDisplayName</key><string>micloud PhotosApp</string>
  <key>CFBundleIdentifier</key><string>com.mineracks.micloud.photosapp</string>
  <key>CFBundleExecutable</key><string>PhotosApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPhotoLibraryUsageDescription</key><string>micloud mirrors your photos to storage you own.</string>
</dict></plist>
PLIST

echo "compiling (main.swift + kit/*.swift)…"
swiftc -O -o "$APP/Contents/MacOS/PhotosApp" main.swift kit/*.swift -framework AppKit -framework Photos -framework CoreServices

echo "signing (ad-hoc, sandbox + photos-library + network.client)…"
codesign --force --sign - --entitlements PhotosApp.entitlements "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -iE "sandbox|photos|network" || echo "  (entitlements not shown)"
echo
echo "✅ built: $(pwd)/$APP"
echo "   launch via run.sh; grant Photos access when prompted"
echo "   log: ~/Library/Containers/com.mineracks.micloud.photosapp/Data/micloud-photosapp.log"
