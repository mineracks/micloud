#!/usr/bin/env bash
# Build DriveApp: compiles main.swift + the MicloudKit sources (expected in ./kit/) into one sandboxed,
# ad-hoc-signed .app. Deploy step drops the MicloudKit *.swift into ./kit/ so relative paths work off-repo.
set -euo pipefail
cd "$(dirname "$0")"
APP="DriveApp.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DriveApp</string>
  <key>CFBundleDisplayName</key><string>micloud DriveApp</string>
  <key>CFBundleIdentifier</key><string>com.mineracks.micloud.driveapp</string>
  <key>CFBundleExecutable</key><string>DriveApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST

echo "compiling (main.swift + kit/*.swift)…"
swiftc -O -o "$APP/Contents/MacOS/DriveApp" main.swift kit/*.swift -framework AppKit -framework CoreServices

echo "signing (ad-hoc, sandbox + user-selected + network.client)…"
codesign --force --sign - --entitlements DriveApp.entitlements "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -iE "sandbox|user-selected|network" || echo "  (entitlements not shown)"
echo
echo "✅ built: $(pwd)/$APP"
echo "   launch via run.sh (sets NEXTCLOUD_* from env, execs the app so the picker + upload work)"
echo "   log: ~/Library/Containers/com.mineracks.micloud.driveapp/Data/micloud-driveapp.log"
