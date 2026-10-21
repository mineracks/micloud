#!/usr/bin/env bash
# Build the micloud dashboard app: SwiftUI app.swift + PhotosSource + Dashboard + MicloudKit (./kit/)
# → one sandboxed, ad-hoc-signed .app. SwiftUI @main needs -parse-as-library. Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"
APP="micloud.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>micloud</string>
  <key>CFBundleDisplayName</key><string>micloud</string>
  <key>CFBundleIdentifier</key><string>com.mineracks.micloud.dashboard</string>
  <key>CFBundleExecutable</key><string>micloud</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>micloud</string>
  <key>CFBundleIconName</key><string>micloud</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPhotoLibraryUsageDescription</key><string>micloud mirrors your photos to storage you own (Immich + Nextcloud).</string>
  <key>NSCalendarsUsageDescription</key><string>micloud backs up your calendars to storage you own.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>micloud backs up your calendars to storage you own.</string>
  <key>NSRemindersUsageDescription</key><string>micloud backs up your reminders to storage you own.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>micloud backs up your reminders to storage you own.</string>
  <!-- Telemetry goes to a self-hosted Loki the person configures, usually plain http on their own LAN /
       tailnet. ATS would otherwise refuse it silently ("requires the use of a secure connection"). -->
  <key>NSAppTransportSecurity</key><dict>
    ATS_POLICY
  </dict>
  <key>NSLocalNetworkUsageDescription</key><string>micloud reports its sync health to monitoring on your own network (optional).</string>
  <key>NSContactsUsageDescription</key><string>micloud backs up your contacts to storage you own.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.mineracks.micloud.oauth</string>
    <key>CFBundleURLSchemes</key><array><string>micloud</string><string>app.immich</string></array>
  </dict></array>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string><string>es</string><string>pt</string><string>de</string><string>it</string><string>nl</string><string>ru</string><string>ja</string><string>ko</string><string>zh-Hans</string><string>zh-Hant</string><string>tr</string><string>pl</string><string>hi</string><string>ar</string></array>
</dict></plist>
PLIST

# kit/ is a gitignored working copy of the MicloudKit module sources. Regenerate it from the tracked
# source so a fresh clone (e.g. the Mac Studio signing host) builds without needing the local copy.
# Relay/fleet build: the Loki endpoint is a tailnet IP, which ATS does not class as "local" — allow it.
# The App Store build keeps the stricter default (local networking only).
# NOTE (Apple): NSAllowsArbitraryLoads is IGNORED whenever NSAllowsLocalNetworking is also present —
# so the two must never be combined, or a tailnet/VPN Loki address is still refused.
if [ "${MICLOUD_RELAY:-0}" = "1" ]; then
  sed -i '' 's|ATS_POLICY|<key>NSAllowsArbitraryLoads</key><true/>|' "$APP/Contents/Info.plist"
else
  sed -i '' 's|ATS_POLICY|<key>NSAllowsLocalNetworking</key><true/>|' "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

mkdir -p kit && cp ../MicloudKit/Sources/MicloudKit/*.swift kit/ 2>/dev/null || true

echo "compiling (SwiftUI @main, -parse-as-library + kit/*.swift)…"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/micloud" \
  MicloudApp.swift Production.swift RelayCommon.swift SafariBookmarksSource.swift AppleNotesSource.swift MessagesSource.swift MailSource.swift PhotosSource.swift PhotosBackfillSource.swift PhotosFolderBridgeSource.swift NotesBridgeSource.swift BookmarksBridgeSource.swift MailBridgeSource.swift BackfillModel.swift RemoteFeed.swift Dashboard.swift DriveGrant.swift Permissions.swift \
  Onboarding.swift Localizer.swift ICS.swift EventKitBackfillSource.swift ContactsBackfillSource.swift kit/*.swift \
  -framework SwiftUI -framework AppKit -framework Photos -framework CoreServices -framework EventKit -framework Contacts -framework Network

echo "bundling resources (icon + localizations)…"
mkdir -p "$APP/Contents/Resources"
[ -f micloud.icns ] && cp micloud.icns "$APP/Contents/Resources/micloud.icns"
for d in *.lproj; do
  mkdir -p "$APP/Contents/Resources/$d"
  cp "$d/Localizable.strings" "$APP/Contents/Resources/$d/"
done

# Relay / "pro edition" build (MICLOUD_RELAY=1): sandbox exceptions for Safari/Notes/Messages stores + the
# bundled imessage-exporter (Homebrew) the Messages lane runs. Not for the App Store build.
ENTITLEMENTS="micloud.entitlements"
if [ "${MICLOUD_RELAY:-0}" = "1" ]; then
  ENTITLEMENTS="micloud-relay.entitlements"
  EXP="${IMESSAGE_EXPORTER:-$(command -v imessage-exporter || echo /opt/homebrew/bin/imessage-exporter)}"
  if [ -x "$EXP" ]; then cp "$EXP" "$APP/Contents/MacOS/imessage-exporter"; echo "  bundled imessage-exporter ($EXP)"
  else echo "  ⚠ imessage-exporter not found — Messages lane will report it missing"; fi
fi
echo "signing… (entitlements: $ENTITLEMENTS)"
# Prefer the Developer ID Application identity over ad-hoc. Ad-hoc's designated requirement pins the cdhash,
# which changes every build → macOS TCC treats each rebuild as a new app and WIPES all Privacy grants
# (Calendar/Reminders/Contacts/Photos), forcing a full re-grant. A Developer ID signature gives a stable,
# TEAM-based requirement (identifier + anchor apple generic + leaf OU = TeamID) that is identical across
# rebuilds, so tccd recognises a rebuild as the same app and KEEPS the grants. It also enables notarization
# (see packaging/macos-sign/). `--options runtime` = hardened runtime (required for notarization).
# Falls back to ad-hoc so a machine without the cert still builds (with the wipe-on-rebuild behaviour, warned).
# Override the identity with MICLOUD_SIGNING_IDENTITY; auto-detects any "Developer ID Application" otherwise.
# `|| true` so a no-match grep (no cert on this host) doesn't trip `set -o pipefail` and abort the build.
SIGN_ID="${MICLOUD_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o 'Developer ID Application: [^"]*' | head -1 || true)}"
if [ -n "$SIGN_ID" ]; then
  echo "  Developer ID: $SIGN_ID  (+ hardened runtime → stable requirement, TCC grants survive rebuilds)"
  [ -f "$APP/Contents/MacOS/imessage-exporter" ] && codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/imessage-exporter"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" --identifier com.mineracks.micloud.dashboard \
    --entitlements "$ENTITLEMENTS" "$APP"
else
  echo "  ⚠ no 'Developer ID Application' identity in keychain → ad-hoc sign (TCC grants WILL be wiped on rebuild;"
  echo "     not notarizable). Sign+notarize on a host with the cert: packaging/macos-sign/sign-notarize-deploy.sh"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
fi
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -iE "sandbox|photos|network|user-selected|calendars|addressbook" || true
echo "designated requirement (must be identical across rebuilds to keep grants):"
codesign -d -r- "$APP" 2>&1 | sed 's/^/  /'
echo
echo "✅ built: $(pwd)/$APP  — launch via run.sh"
