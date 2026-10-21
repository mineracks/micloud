#!/usr/bin/env bash
# Build the Mac App Store / TestFlight package of the dashboard (monitor) app and optionally upload it.
#
#   ./build-mac-store.sh            # build.sh (non-relay) → re-sign for the Mac App Store → micloud-store.pkg
#   ./build-mac-store.sh --upload   # …and upload with altool (API key from asc.env)
#
# What the Mac App Store needs that the Developer ID build does not:
#   - signed with "Apple Distribution" + a MAC_APP_STORE profile at Contents/embedded.provisionprofile
#   - application-identifier / team-identifier entitlements on top of the sandbox ones
#   - an installer package signed with "3rd Party Mac Developer Installer" (productbuild)
#   - bundle id com.mineracks.micloud — the SAME as the iPhone app, so one App Store Connect record carries both
#     platforms and TestFlight on the Mac lists it. The relay keeps com.mineracks.micloud.dashboard (Developer ID).
#   - LSApplicationCategoryType, ITSAppUsesNonExemptEncryption=false
#   - the app icon in a COMPILED ASSET CATALOG (Assets.car + CFBundleIconName), not only an .icns:
#     build 1 was rejected after upload with ITMS-90546 "Missing asset catalog" (2026-10-14)
set -euo pipefail
cd "$(dirname "$0")"

TEAM="${MICLOUD_TEAM:-NB859QPG78}"
BUNDLE="${MICLOUD_MAC_BUNDLE:-com.mineracks.micloud}"
KC="${MICLOUD_KEYCHAIN:-$HOME/Library/Keychains/mineracks-build.keychain-db}"
APP_IDENTITY="${MICLOUD_MAC_DIST_IDENTITY:-Apple Distribution: mineracks pty ltd ($TEAM)}"
PKG_IDENTITY="${MICLOUD_MAC_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer: mineracks pty ltd ($TEAM)}"
PROFILE="${MICLOUD_MAC_STORE_PROFILE:-$HOME/micloud-macappstore.provisionprofile}"
VERSION="${MICLOUD_MAC_VERSION:-0.2}"
BUILDNO="${MICLOUD_MAC_BUILD:-4}"
[ -f "$PROFILE" ] || { echo "FATAL: no Mac App Store profile at $PROFILE"; exit 1; }

KCPASS="${MICLOUD_KEYCHAIN_PASS:-$(cat "$HOME/.mineracks-build-keychain-pass" 2>/dev/null)}"
[ -n "$KCPASS" ] || { echo "FATAL: no keychain password"; exit 1; }
security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true

# icon: the generated iconset (gitignored) → .icns
[ -f micloud.iconset/icon_512x512@2x.png ] || swift gen-icon.swift >/dev/null
[ -f micloud.icns ] || iconutil -c icns micloud.iconset -o micloud.icns

# 1 · the ordinary (non-relay) build: compiles, bundles resources, signs with whatever is at hand — re-signed below
MICLOUD_RELAY=0 ./build.sh >/dev/null
APP="micloud-store.app"
rm -rf "$APP" micloud-store.pkg && ditto micloud.app "$APP"

# 1b · asset catalog: the iconset → Assets.car + AppIcon.icns (ITMS-90546 without it)
rm -rf xcassets-build && mkdir -p xcassets-build/Assets.xcassets/AppIcon.appiconset
python3 - micloud.iconset xcassets-build/Assets.xcassets/AppIcon.appiconset <<'EOP'
import json, shutil, sys, os
src, dst = sys.argv[1], sys.argv[2]
images = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        shutil.copy(os.path.join(src, name), os.path.join(dst, name))
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(os.path.join(dst, "Contents.json"), "w"), indent=1)
EOP
echo '{ "info": { "author": "xcode", "version": 1 } }' > xcassets-build/Assets.xcassets/Contents.json
xcrun actool xcassets-build/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 13.0 \
  --app-icon AppIcon --output-partial-info-plist xcassets-build/partial.plist >/dev/null
[ -f "$APP/Contents/Resources/Assets.car" ] || { echo "FATAL: actool produced no Assets.car"; exit 1; }

# 2 · Info.plist for the store
PL="$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE" "$PL"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PL"
plutil -replace CFBundleVersion -string "$BUILDNO" "$PL"
plutil -replace LSMinimumSystemVersion -string "13.0" "$PL"
plutil -replace LSApplicationCategoryType -string "public.app-category.utilities" "$PL"
plutil -replace ITSAppUsesNonExemptEncryption -bool false "$PL"
plutil -replace CFBundleSupportedPlatforms -xml '<array><string>MacOSX</string></array>' "$PL"
plutil -convert xml1 xcassets-build/partial.plist -o xcassets-build/partial.xml
python3 - "$PL" xcassets-build/partial.xml <<'EOP'
import plistlib, sys
info = plistlib.load(open(sys.argv[1], 'rb')); part = plistlib.load(open(sys.argv[2], 'rb'))
info.update(part); plistlib.dump(info, open(sys.argv[1], 'wb'))   # CFBundleIconName/CFBundleIconFile -> AppIcon
EOP
plutil -lint "$PL" >/dev/null
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# 3 · entitlements: the sandbox set + the identifiers the store checks against the profile
python3 - micloud.entitlements micloud-store.entitlements "$TEAM" "$BUNDLE" <<'EOP'
import plistlib, sys
e = plistlib.load(open(sys.argv[1], 'rb'))
e['com.apple.application-identifier'] = f"{sys.argv[3]}.{sys.argv[4]}"
e['com.apple.developer.team-identifier'] = sys.argv[3]
plistlib.dump(e, open(sys.argv[2], 'wb'))
EOP

echo "signing for the Mac App Store ($BUNDLE $VERSION ($BUILDNO))…"
codesign --force --sign "$APP_IDENTITY" --keychain "$KC" --entitlements micloud-store.entitlements \
  --identifier "$BUNDLE" --generate-entitlement-der "$APP"
codesign --verify --deep --verbose=1 "$APP"

echo "packaging…"
productbuild --component "$APP" /Applications --sign "$PKG_IDENTITY" --keychain "$KC" micloud-store.pkg >/dev/null
echo "✅ $(pwd)/micloud-store.pkg ($(du -h micloud-store.pkg | cut -f1))"

if [ "${1:-}" = "--upload" ]; then
  set -a; . "$HOME/.mineracks-release/asc.env"; set +a
  mkdir -p "$HOME/.appstoreconnect/private_keys"
  [ -f "$HOME/.appstoreconnect/private_keys/AuthKey_$APPLE_API_KEY.p8" ] || cp "${APPLE_API_KEY_PATH/#\~/$HOME}" "$HOME/.appstoreconnect/private_keys/AuthKey_$APPLE_API_KEY.p8"
  echo "validating…"
  xcrun altool --validate-app -t macos -f micloud-store.pkg --apiKey "$APPLE_API_KEY" --apiIssuer "$APPLE_API_ISSUER" 2>&1 | tail -5
  echo "uploading…"
  xcrun altool --upload-app -t macos -f micloud-store.pkg --apiKey "$APPLE_API_KEY" --apiIssuer "$APPLE_API_ISSUER" 2>&1 | tail -5
  echo "✅ uploaded — processing takes ~5–15 min, then it appears under TestFlight (macOS) in App Store Connect"
fi
