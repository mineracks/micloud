#!/usr/bin/env bash
# Build an AD-HOC signed .ipa + OTA manifest so the iPhone can install updates over the air,
# from anywhere, with no cable, no TestFlight and no Apple review.
#
# How OTA install works: Safari opens an itms-services:// URL pointing at a manifest plist; iOS
# itself then fetches the manifest and the .ipa. Two consequences that bite people:
#   - BOTH URLs must be HTTPS with a publicly trusted cert (iOS does the fetching, not Safari).
#   - Any auth in front of them (CF Access, basic auth) BREAKS it — iOS carries no cookies. Hence
#     the unguessable path rather than a login.
#
# Ad-hoc differs from the development build in two ways that matter:
#   - signed with "Apple Distribution", not "Apple Development"
#   - NO get-task-allow entitlement (distribution profiles reject it)
# The device must be in the ad-hoc profile's device list, so adding a phone means regenerating the
# profile (profiles snapshot the device list at creation) and rebuilding.
#
#   ./build-ios-ota.sh            # build + package, print the paths
#   ./build-ios-ota.sh --deploy   # …and publish to vps-au, printing the install URL
set -euo pipefail
cd "$(dirname "$0")"

APP="MicloudPhone-adhoc.app"
TEAM="${MICLOUD_IOS_TEAM:-NB859QPG78}"
BUNDLE=com.mineracks.micloud.phone
# Signing material: the mini keeps its certs in the shared mineracks-build keychain (the Studio-era
# micloud-ios keychain is honoured if it exists).
KC="${MICLOUD_IOS_KEYCHAIN:-$([ -f "$HOME/Library/Keychains/micloud-ios.keychain-db" ] && echo "$HOME/Library/Keychains/micloud-ios.keychain-db" || echo "$HOME/Library/Keychains/mineracks-build.keychain-db")}"
IDENTITY="${MICLOUD_IOS_DIST_IDENTITY:-Apple Distribution: mineracks pty ltd (NB859QPG78)}"
PROFILE="${MICLOUD_IOS_ADHOC_PROFILE:-$HOME/micloud-adhoc.mobileprovision}"
VERSION="${MICLOUD_IOS_VERSION:-0.2}"
BUILDNO="${MICLOUD_IOS_BUILD:-2}"
# Stable unguessable directory — keep it constant so the install URL doesn't change between builds.
OTA_TOKEN="${MICLOUD_OTA_TOKEN:-$(cat "$HOME/.micloud-ota-token" 2>/dev/null)}"
OTA_HOST="${MICLOUD_OTA_HOST:-getmicloud.com}"

[ -f "$PROFILE" ] || { echo "FATAL: no ad-hoc profile at $PROFILE"; exit 1; }
[ -n "$OTA_TOKEN" ] || { echo "FATAL: no OTA token (set MICLOUD_OTA_TOKEN or ~/.micloud-ota-token)"; exit 1; }

rm -rf "$APP" Payload MicloudPhone.ipa
mkdir -p "$APP" kit
KITSRC=../MicloudKit/Sources/MicloudKit
for f in StatusReport Telemetry SyncSource NextcloudWebDAV NextcloudLoginFlow Capacity ImmichClient PhotoTarget; do
  cp "$KITSRC/$f.swift" kit/
done

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>micloud</string>
  <key>CFBundleDisplayName</key><string>micloud</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE</string>
  <key>CFBundleExecutable</key><string>MicloudPhone</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILDNO</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
  <key>UISupportedInterfaceOrientations~ipad</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIBackgroundModes</key><array><string>processing</string></array>
  <key>BGTaskSchedulerPermittedIdentifiers</key><array><string>com.mineracks.micloud.phone.healthbackfill</string></array>
  <key>DTPlatformName</key><string>iphoneos</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.mineracks.micloud.phone</string><key>CFBundleURLSchemes</key><array><string>micloud</string></array></dict></array>
  <key>NSHealthShareUsageDescription</key><string>micloud backs up your Apple Health data to storage you own.</string>
  <key>NSHealthUpdateUsageDescription</key><string>micloud reads and writes Health data only to back it up to your own storage.</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string><string>es</string><string>pt</string><string>de</string><string>it</string><string>nl</string><string>ru</string><string>ja</string><string>ko</string><string>zh-Hans</string><string>zh-Hant</string><string>tr</string><string>pl</string><string>hi</string><string>ar</string></array>
</dict></plist>
PLIST

# NOTE: no get-task-allow — a distribution profile refuses it.
cat > MicloudPhone-adhoc.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>com.apple.developer.healthkit</key><true/>
  <key>com.apple.developer.healthkit.background-delivery</key><true/>
</dict></plist>
ENT

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "compiling $VERSION ($BUILDNO) for iOS device…"
swiftc -O -parse-as-library -sdk "$SDK" -target arm64-apple-ios17.0 \
  -o "$APP/MicloudPhone" MicloudPhoneApp.swift HealthArchive.swift Pairing.swift Loc.swift kit/*.swift \
  -framework SwiftUI -framework HealthKit -framework AuthenticationServices

for d in *.lproj; do
  [ -d "$d" ] || continue
  mkdir -p "$APP/$d"; cp "$d/Localizable.strings" "$APP/$d/"
done
# App icon without an asset catalog: CFBundleIcons names the files, sips makes them from the Mac iconset.
ICONSRC=../micloud/micloud.iconset/icon_512x512@2x.png
[ -f "$ICONSRC" ] || (cd ../micloud && swift gen-icon.swift >/dev/null)   # gitignored; a fresh clone has none → no icon on the phone
if [ -f "$ICONSRC" ]; then
  sips -z 120 120 "$ICONSRC" --out "$APP/AppIcon60x60@2x.png" >/dev/null
  sips -z 180 180 "$ICONSRC" --out "$APP/AppIcon60x60@3x.png" >/dev/null
  sips -z 152 152 "$ICONSRC" --out "$APP/AppIcon76x76@2x.png" >/dev/null        # iPad home screen
  sips -z 167 167 "$ICONSRC" --out "$APP/AppIcon83.5x83.5@2x.png" >/dev/null    # iPad Pro
  plutil -insert CFBundleIcons -xml '<dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array><key>CFBundleIconName</key><string>AppIcon</string></dict></dict>' "$APP/Info.plist"
  plutil -insert 'CFBundleIcons~ipad' -xml '<dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key><array><string>AppIcon60x60</string><string>AppIcon76x76</string><string>AppIcon83.5x83.5</string></array><key>CFBundleIconName</key><string>AppIcon</string></dict></dict>' "$APP/Info.plist"
fi

cp "$PROFILE" "$APP/embedded.mobileprovision"

KCPASS="${MICLOUD_IOS_KEYCHAIN_PASS:-$(cat "$HOME/.micloud-ios-keychain-pass" 2>/dev/null || cat "$HOME/.mineracks-build-keychain-pass" 2>/dev/null)}"
[ -n "$KCPASS" ] || { echo "FATAL: no keychain password"; exit 1; }
security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
codesign --force --sign "$IDENTITY" --keychain "$KC" \
  --entitlements MicloudPhone-adhoc.entitlements --generate-entitlement-der "$APP"
codesign --verify --verbose=1 "$APP"

mkdir -p Payload && cp -R "$APP" "Payload/MicloudPhone.app"
zip -qry MicloudPhone.ipa Payload && rm -rf Payload
echo "✅ $(pwd)/MicloudPhone.ipa ($(du -h MicloudPhone.ipa | cut -f1))"

BASE="https://$OTA_HOST/_ota/$OTA_TOKEN"
cat > manifest.plist <<MAN
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array><dict>
    <key>kind</key><string>software-package</string>
    <key>url</key><string>$BASE/MicloudPhone.ipa</string>
  </dict></array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>$BUNDLE</string>
    <key>bundle-version</key><string>$VERSION</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>micloud</string>
  </dict>
</dict></array></dict></plist>
MAN

cat > index.html <<HTML
<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Install micloud</title>
<style>body{font:17px -apple-system,sans-serif;background:#131A2A;color:#EEF1F6;display:grid;place-items:center;height:100vh;margin:0;text-align:center}
a{display:inline-block;background:#F7931A;color:#fff;text-decoration:none;font-weight:650;padding:15px 30px;border-radius:12px;margin-top:22px}
small{color:#939CAF;display:block;margin-top:20px}</style>
<div><h1>mi<span style="color:#F7931A">cloud</span></h1>
<p>Version $VERSION (build $BUILDNO)</p>
<a href="itms-services://?action=download-manifest&url=$BASE/manifest.plist">Install on this iPhone</a>
<small>Open this page in Safari on the iPhone.</small></div>
HTML

echo "✅ manifest + install page written"
echo "   install URL: $BASE/"

if [ "${1:-}" = "--deploy" ]; then
  DEST="${MICLOUD_OTA_DEST:-mineracks-ext-vps-au}"
  echo "publishing to $DEST…"
  ssh "${MICLOUD_OTA_SSH:-vps-au}" "sudo mkdir -p /var/www/getmicloud/_ota/$OTA_TOKEN && sudo chown \$(whoami) /var/www/getmicloud/_ota/$OTA_TOKEN"
  scp -q MicloudPhone.ipa manifest.plist index.html "${MICLOUD_OTA_SSH:-vps-au}:/var/www/getmicloud/_ota/$OTA_TOKEN/"
  echo "✅ deployed — open $BASE/ in Safari on the iPhone"
fi
