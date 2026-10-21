#!/usr/bin/env bash
# Build + sign the iOS companion for a REAL iPhone, and optionally install it.
#
# Why this exists alongside build-ios.sh: HealthKit does NOT work in the iOS Simulator
# (HKHealthStore.isHealthDataAvailable() is false there), so the Health capture lane can only ever be
# exercised on device. The simulator build stays useful for the sync-status UI; this one is the only
# way to test Health.
#
# Device builds need real provisioning, all of which now exists under team NB859QPG78:
#   - explicit App ID  com.mineracks.micloud.phone  with the HealthKit capability (wildcards are
#     refused for HealthKit)
#   - an Apple Development certificate, in the `micloud-ios` keychain on the Studio
#   - an IOS_APP_DEVELOPMENT profile naming that App ID + cert + at least one registered device
#     (Apple rejects a development profile with an empty devices relationship)
#
# The profile is embedded as embedded.mobileprovision; the entitlements below must be a SUBSET of
# what the profile authorises or the install is rejected.
#
#   ./build-ios-device.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP="MicloudPhone-device.app"
TEAM="${MICLOUD_IOS_TEAM:-NB859QPG78}"
BUNDLE=com.mineracks.micloud.phone
# Signing material: the mini keeps its certs in the shared mineracks-build keychain (the Studio-era
# micloud-ios keychain is honoured if it exists).
KC="${MICLOUD_IOS_KEYCHAIN:-$([ -f "$HOME/Library/Keychains/micloud-ios.keychain-db" ] && echo "$HOME/Library/Keychains/micloud-ios.keychain-db" || echo "$HOME/Library/Keychains/mineracks-build.keychain-db")}"
PROFILE="${MICLOUD_IOS_PROFILE:-$([ -f "$HOME/micloud-ios-dev.mobileprovision" ] && echo "$HOME/micloud-ios-dev.mobileprovision" || echo "$HOME/micloud-ios.mobileprovision")}"

[ -f "$PROFILE" ] || { echo "FATAL: no provisioning profile at $PROFILE"; exit 1; }

rm -rf "$APP"; mkdir -p "$APP"
mkdir -p kit
KITSRC=../MicloudKit/Sources/MicloudKit
for f in StatusReport Telemetry SyncSource NextcloudWebDAV NextcloudLoginFlow Capacity ImmichClient PhotoTarget; do
  cp "$KITSRC/$f.swift" kit/
done

# Info.plist mirrors build-ios.sh but declares the DEVICE platform.
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>micloud</string>
  <key>CFBundleDisplayName</key><string>micloud</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE</string>
  <key>CFBundleExecutable</key><string>MicloudPhone</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${MICLOUD_IOS_VERSION:-0.2}</string>
  <key>CFBundleVersion</key><string>${MICLOUD_IOS_BUILD:-2}</string>
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

# Must stay a subset of what the profile grants.
cat > MicloudPhone-device.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><true/>
  <key>com.apple.developer.healthkit</key><true/>
  <key>com.apple.developer.healthkit.background-delivery</key><true/>
</dict></plist>
ENT

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "compiling for iOS device (SDK: $(basename "$SDK"))…"
swiftc -O -parse-as-library -sdk "$SDK" -target arm64-apple-ios17.0 \
  -o "$APP/MicloudPhone" MicloudPhoneApp.swift HealthArchive.swift Pairing.swift Loc.swift kit/*.swift \
  -framework SwiftUI -framework HealthKit -framework AuthenticationServices

echo "bundling localizations…"
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

# Keychain password: env override, else a 0600 file created during setup. Never a literal in git —
# the keychain is a local throwaway holding only a revocable development cert, but the rule stands.
KCPASS="${MICLOUD_IOS_KEYCHAIN_PASS:-$(cat "$HOME/.micloud-ios-keychain-pass" 2>/dev/null || cat "$HOME/.mineracks-build-keychain-pass" 2>/dev/null)}"
[ -n "$KCPASS" ] || { echo "FATAL: no keychain password (set MICLOUD_IOS_KEYCHAIN_PASS or ~/.micloud-ios-keychain-pass)"; exit 1; }
security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
IDENTITY="${MICLOUD_IOS_IDENTITY:-$(security find-identity -v -p codesigning "$KC" | awk -F'"' '/Apple Development/ {print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "FATAL: no Apple Development identity in $KC"; exit 1; }
codesign --force --sign "$IDENTITY" --keychain "$KC" \
  --entitlements MicloudPhone-device.entitlements --generate-entitlement-der "$APP"
codesign --verify --verbose=1 "$APP"
echo "✅ built + signed $(pwd)/$APP"

if [ "${1:-}" = "--install" ]; then
  DEV=$(xcrun devicectl list devices 2>/dev/null | awk '/connected|available/ {print $(NF-1); exit}')
  [ -n "$DEV" ] || { echo "no device found — connect the iPhone over USB and tap Trust"; exit 1; }
  echo "installing onto $DEV…"
  xcrun devicectl device install app --device "$DEV" "$APP"
  echo "✅ installed — launch it on the phone and tap the Health tile"
fi
