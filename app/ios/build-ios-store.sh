#!/usr/bin/env bash
# Build an App Store / TestFlight signed .ipa and (optionally) upload it to App Store Connect.
#
# Differences from the ad-hoc build that App Store validation enforces:
#   - signed with "Apple Distribution" + an IOS_APP_STORE profile (no device list, no get-task-allow)
#   - the app icon must come from a compiled asset catalog (Assets.car) with the 1024×1024 marketing icon —
#     CFBundleIconFiles alone is rejected ("The large app icon must be in an asset catalog")
#   - ITSAppUsesNonExemptEncryption=false so TestFlight does not stop on the export-compliance question
#     (HTTPS only; no custom crypto)
#
# Needs an App Store Connect APP RECORD for the bundle id (App Store Connect → Apps → + → platforms iOS + macOS,
# name "micloud", bundle com.mineracks.micloud, SKU micloud). The API cannot create one; it is a one-time UI step.
# The same bundle id is what the Mac App Store build (../micloud/build-mac-store.sh) uses, so TestFlight shows
# one app with an iOS and a macOS build.
#
#   ./build-ios-store.sh            # build + package
#   ./build-ios-store.sh --upload   # …and upload with altool (API key from asc.env)
set -euo pipefail
cd "$(dirname "$0")"

APP="MicloudPhone-store.app"
TEAM="${MICLOUD_IOS_TEAM:-NB859QPG78}"
BUNDLE="${MICLOUD_IOS_BUNDLE:-com.mineracks.micloud}"
KC="${MICLOUD_IOS_KEYCHAIN:-$HOME/Library/Keychains/mineracks-build.keychain-db}"
IDENTITY="${MICLOUD_IOS_DIST_IDENTITY:-Apple Distribution: mineracks pty ltd (NB859QPG78)}"
PROFILE="${MICLOUD_IOS_STORE_PROFILE:-$HOME/micloud-appstore.mobileprovision}"
VERSION="${MICLOUD_IOS_VERSION:-0.2}"
BUILDNO="${MICLOUD_IOS_BUILD:-11}"
[ -f "$PROFILE" ] || { echo "FATAL: no App Store profile at $PROFILE"; exit 1; }

rm -rf "$APP" Payload MicloudPhone-store.ipa xcassets-build
mkdir -p "$APP" kit
KITSRC=../MicloudKit/Sources/MicloudKit
for f in StatusReport Telemetry SyncSource NextcloudWebDAV NextcloudLoginFlow Capacity ImmichClient PhotoTarget; do
  cp "$KITSRC/$f.swift" kit/
done

# ── asset catalog: AppIcon from the Mac iconset's 1024 px master ──
ICONSRC=../micloud/icon-ios-1024.png   # opaque full-bleed square: the squircle master has alpha → ITMS-90717
[ -f "$ICONSRC" ] || (cd ../micloud && swift gen-icon.swift ios >/dev/null)   # gitignored; a fresh clone has none → no icon on the phone
mkdir -p xcassets-build/Assets.xcassets/AppIcon.appiconset
cp "$ICONSRC" xcassets-build/Assets.xcassets/AppIcon.appiconset/icon-1024.png
cat > xcassets-build/Assets.xcassets/AppIcon.appiconset/Contents.json <<'JSON'
{ "images": [ { "filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ],
  "info": { "author": "xcode", "version": 1 } }
JSON
cat > xcassets-build/Assets.xcassets/Contents.json <<'JSON'
{ "info": { "author": "xcode", "version": 1 } }
JSON
xcrun actool xcassets-build/Assets.xcassets --compile "$APP" --platform iphoneos --minimum-deployment-target 17.0 \
  --app-icon AppIcon --output-partial-info-plist xcassets-build/partial.plist >/dev/null

# SDK / Xcode stamps: without these altool refuses the ipa with 90534 "Unsupported SDK or Xcode version"
# (build 7, 2026-10-14) — a hand-written Info.plist has none, so Apple cannot tell which SDK built it.
SDK_BUILD=$(xcrun --sdk iphoneos --show-sdk-build-version)
SDK_VER=$(xcrun --sdk iphoneos --show-sdk-platform-version)
XC_VER=$(xcodebuild -version | awk '/Xcode/{print $2}')
XC_BUILD=$(xcodebuild -version | awk '/Build version/{print $3}')
XC_DT=$(printf '%02d%d%d' "${XC_VER%%.*}" "$(echo "$XC_VER" | cut -d. -f2)" "$(echo "$XC_VER" | cut -d. -f3 | sed 's/^$/0/')")
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
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIBackgroundModes</key><array><string>processing</string></array>
  <key>BGTaskSchedulerPermittedIdentifiers</key><array><string>com.mineracks.micloud.phone.healthbackfill</string></array>
  <key>DTPlatformName</key><string>iphoneos</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.mineracks.micloud.phone</string><key>CFBundleURLSchemes</key><array><string>micloud</string></array></dict></array>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSHealthShareUsageDescription</key><string>micloud backs up your Apple Health data to storage you own.</string>
  <key>NSHealthUpdateUsageDescription</key><string>micloud reads and writes Health data only to back it up to your own storage.</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>DTPlatformBuild</key><string>$SDK_BUILD</string>
  <key>DTPlatformVersion</key><string>$SDK_VER</string>
  <key>DTSDKBuild</key><string>$SDK_BUILD</string>
  <key>DTSDKName</key><string>iphoneos$SDK_VER</string>
  <key>DTXcode</key><string>$XC_DT</string>
  <key>DTXcodeBuild</key><string>$XC_BUILD</string>
  <key>BuildMachineOSBuild</key><string>$(sw_vers -buildVersion)</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string><string>es</string><string>pt</string><string>de</string><string>it</string><string>nl</string><string>ru</string><string>ja</string><string>ko</string><string>zh-Hans</string><string>zh-Hant</string><string>tr</string><string>pl</string><string>hi</string><string>ar</string></array>
</dict></plist>
PLIST
# merge actool's icon keys (CFBundleIcons / CFBundleIconName)
plutil -convert xml1 xcassets-build/partial.plist -o xcassets-build/partial.xml
python3 - "$APP/Info.plist" xcassets-build/partial.xml <<'PY'
import plistlib, sys
info = plistlib.load(open(sys.argv[1], 'rb')); part = plistlib.load(open(sys.argv[2], 'rb'))
info.update(part); plistlib.dump(info, open(sys.argv[1], 'wb'))
PY

cat > MicloudPhone-store.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>com.apple.developer.healthkit</key><true/>
  <key>com.apple.developer.healthkit.background-delivery</key><true/>
  <key>beta-reports-active</key><true/>
</dict></plist>
ENT

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "compiling $VERSION ($BUILDNO) for the App Store…"
swiftc -O -parse-as-library -sdk "$SDK" -target arm64-apple-ios17.0 \
  -o "$APP/MicloudPhone" MicloudPhoneApp.swift HealthArchive.swift Pairing.swift Loc.swift kit/*.swift \
  -framework SwiftUI -framework HealthKit -framework AuthenticationServices

for d in *.lproj; do
  [ -d "$d" ] || continue
  mkdir -p "$APP/$d"; cp "$d/Localizable.strings" "$APP/$d/"
done
cp "$PROFILE" "$APP/embedded.mobileprovision"

KCPASS="${MICLOUD_IOS_KEYCHAIN_PASS:-$(cat "$HOME/.micloud-ios-keychain-pass" 2>/dev/null || cat "$HOME/.mineracks-build-keychain-pass" 2>/dev/null)}"
[ -n "$KCPASS" ] || { echo "FATAL: no keychain password"; exit 1; }
security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
codesign --force --sign "$IDENTITY" --keychain "$KC" \
  --entitlements MicloudPhone-store.entitlements --generate-entitlement-der "$APP"
codesign --verify --verbose=1 "$APP"

mkdir -p Payload && cp -R "$APP" "Payload/MicloudPhone.app"
zip -qry MicloudPhone-store.ipa Payload && rm -rf Payload
echo "✅ $(pwd)/MicloudPhone-store.ipa ($(du -h MicloudPhone-store.ipa | cut -f1))"

if [ "${1:-}" = "--upload" ]; then
  # altool reads the .p8 from ~/.appstoreconnect/private_keys/AuthKey_<id>.p8; asc.env names the key.
  set -a; . "$HOME/.mineracks-release/asc.env"; set +a
  mkdir -p "$HOME/.appstoreconnect/private_keys"
  [ -f "$HOME/.appstoreconnect/private_keys/AuthKey_$APPLE_API_KEY.p8" ] || cp "${APPLE_API_KEY_PATH/#\~/$HOME}" "$HOME/.appstoreconnect/private_keys/AuthKey_$APPLE_API_KEY.p8"
  echo "validating…"
  xcrun altool --validate-app -t ios -f MicloudPhone-store.ipa --apiKey "$APPLE_API_KEY" --apiIssuer "$APPLE_API_ISSUER" 2>&1 | tail -5
  echo "uploading…"
  xcrun altool --upload-app -t ios -f MicloudPhone-store.ipa --apiKey "$APPLE_API_KEY" --apiIssuer "$APPLE_API_ISSUER" 2>&1 | tail -5
  echo "✅ uploaded — processing takes ~5–15 min, then it appears under TestFlight in App Store Connect"
fi
