#!/usr/bin/env bash
# Build the iOS companion for the Simulator with swiftc (no Xcode project). Reuses the iOS-SAFE subset of
# MicloudKit (no DriveSource/FSEvents, no engine/ledger — just the status-read path).
set -euo pipefail
cd "$(dirname "$0")"
APP="MicloudPhone.app"
rm -rf "$APP"; mkdir -p "$APP"

mkdir -p kit
KITSRC=../MicloudKit/Sources/MicloudKit
for f in StatusReport Telemetry SyncSource NextcloudWebDAV NextcloudLoginFlow Capacity ImmichClient PhotoTarget; do
  cp "$KITSRC/$f.swift" kit/
done

cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>micloud</string>
  <key>CFBundleDisplayName</key><string>micloud</string>
  <key>CFBundleIdentifier</key><string>com.mineracks.micloud.phone</string>
  <key>CFBundleExecutable</key><string>MicloudPhone</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${MICLOUD_IOS_VERSION:-0.2}</string>
  <key>CFBundleVersion</key><string>${MICLOUD_IOS_BUILD:-2}</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIBackgroundModes</key><array><string>processing</string></array>
  <key>BGTaskSchedulerPermittedIdentifiers</key><array><string>com.mineracks.micloud.phone.healthbackfill</string></array>
  <key>DTPlatformName</key><string>iphonesimulator</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.mineracks.micloud.phone</string><key>CFBundleURLSchemes</key><array><string>micloud</string></array></dict></array>
  <key>NSHealthShareUsageDescription</key><string>micloud backs up your Apple Health data to storage you own.</string>
  <key>NSHealthUpdateUsageDescription</key><string>micloud reads and writes Health data only to back it up to your own storage.</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string><string>es</string><string>pt</string><string>de</string><string>it</string><string>nl</string><string>ru</string><string>ja</string><string>ko</string><string>zh-Hans</string><string>zh-Hant</string><string>tr</string><string>pl</string><string>hi</string><string>ar</string></array>
</dict></plist>
PLIST

cat > MicloudPhone.entitlements <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.developer.healthkit</key><true/>
  <key>com.apple.developer.healthkit.background-delivery</key><true/>
  <key>com.apple.developer.healthkit.access</key><array/>
</dict></plist>
ENT

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
echo "compiling for iOS Simulator (SDK: $(basename "$SDK"))…"
swiftc -O -parse-as-library -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
  -o "$APP/MicloudPhone" MicloudPhoneApp.swift HealthArchive.swift Pairing.swift Loc.swift kit/*.swift \
  -framework SwiftUI -framework HealthKit -framework AuthenticationServices

echo "bundling localizations…"
for d in *.lproj; do
  [ -d "$d" ] || continue
  mkdir -p "$APP/$d"; cp "$d/Localizable.strings" "$APP/$d/"
done
# App icon without an asset catalog: CFBundleIcons names the files, sips makes them from the Mac iconset.
ICONSRC=../micloud/micloud.iconset/icon_512x512@2x.png
if [ -f "$ICONSRC" ]; then
  sips -z 120 120 "$ICONSRC" --out "$APP/AppIcon60x60@2x.png" >/dev/null
  sips -z 180 180 "$ICONSRC" --out "$APP/AppIcon60x60@3x.png" >/dev/null
  plutil -insert CFBundleIcons -xml '<dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array><key>CFBundleIconName</key><string>AppIcon</string></dict></dict>' "$APP/Info.plist"
fi

# Simulator: sign WITHOUT entitlements. Any entitlement blob — HealthKit or a bare get-task-allow — makes
# SpringBoard refuse the launch ("did not return a process handle nor launch error"), and HealthKit does not
# work in the simulator anyway. The entitlements file above is kept for reference only. (PROVISIONING.md, trap 2.)
codesign --force --sign - "$APP"
echo "✅ built $(pwd)/$APP ($(ls -d "$APP"/*.lproj 2>/dev/null | wc -l | tr -d ' ') languages)"
