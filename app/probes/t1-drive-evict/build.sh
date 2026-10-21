#!/usr/bin/env bash
# Build the T1 probe as a sandboxed .app, ad-hoc signed (no Apple Developer account needed
# for local run — user-selected file access + app-sandbox are honoured with any signature).
# Requires: full Xcode OR command-line swiftc + codesign. Run on the Mac that will run the probe.
set -euo pipefail
cd "$(dirname "$0")"
APP="T1Probe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>T1Probe</string>
  <key>CFBundleDisplayName</key><string>micloud T1 probe</string>
  <key>CFBundleIdentifier</key><string>com.mineracks.micloud.t1probe</string>
  <key>CFBundleExecutable</key><string>T1Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST

echo "compiling…"
swiftc -O -o "$APP/Contents/MacOS/T1Probe" main.swift -framework AppKit

echo "signing (ad-hoc, with sandbox entitlements)…"
codesign --force --sign - --entitlements T1Probe.entitlements "$APP"

echo "entitlements embedded:"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -iE "sandbox|user-selected" || echo "  (none shown — check codesign)"
echo
echo "✅ built: $(pwd)/$APP"
echo "   run it (in the GUI session):   open $APP"
echo "   result log:  ~/Library/Containers/com.mineracks.micloud.t1probe/Data/micloud-t1-result.txt"
