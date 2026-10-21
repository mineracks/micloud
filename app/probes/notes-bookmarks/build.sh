#!/usr/bin/env bash
# Build the UNSANDBOXED power-build probe (Notes + Bookmarks). No app-sandbox entitlement — so with the
# user's Full Disk Access + Automation consent it can read Safari bookmarks + drive Notes.app.
set -euo pipefail
cd "$(dirname "$0")"
APP="NotesBookmarks.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NotesBookmarks</string>
  <key>CFBundleDisplayName</key><string>micloud — Notes + Bookmarks</string>
  <key>CFBundleIdentifier</key><string>com.mineracks.micloud.notesbookmarks</string>
  <key>CFBundleExecutable</key><string>NotesBookmarks</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSAppleEventsUsageDescription</key><string>micloud backs up your Notes to storage you own.</string>
</dict></plist>
PLIST

echo "compiling (unsandboxed; main.swift + kit/*.swift)…"
swiftc -O -o "$APP/Contents/MacOS/NotesBookmarks" main.swift kit/*.swift -framework AppKit -framework CoreServices

echo "signing (ad-hoc, NO sandbox — this is the power build)…"
codesign --force --sign - "$APP"
echo
echo "✅ built: $(pwd)/$APP"
echo "   1) Grant Full Disk Access: System Settings › Privacy & Security › Full Disk Access → add this .app"
echo "   2) Launch via run.sh; grant Automation for Notes when prompted"
echo "   log: ~/micloud-notesbookmarks.log"
