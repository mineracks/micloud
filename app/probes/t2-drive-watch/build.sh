#!/usr/bin/env bash
# Build the T2 probe as a sandboxed .app, ad-hoc signed. Run on the Mac that will run the probe.
set -euo pipefail
cd "$(dirname "$0")"
APP="T2Probe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>T2Probe</string>
  <key>CFBundleDisplayName</key><string>micloud T2 probe</string>
  <key>CFBundleIdentifier</key><string>com.mineracks.micloud.t2probe</string>
  <key>CFBundleExecutable</key><string>T2Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST

echo "compiling…"
swiftc -O -o "$APP/Contents/MacOS/T2Probe" main.swift -framework AppKit -framework CoreServices

echo "signing (ad-hoc, with sandbox entitlements)…"
codesign --force --sign - --entitlements T2Probe.entitlements "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -iE "sandbox|user-selected" || echo "  (none shown)"
echo
echo "✅ built: $(pwd)/$APP"
echo "   run it (GUI):  open $APP   — then pick the folder to watch and leave it running"
echo "   result log:    ~/Library/Containers/com.mineracks.micloud.t2probe/Data/micloud-t2-result.txt"
