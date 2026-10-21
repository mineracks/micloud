# micloud for iPhone (companion + Health archive)

The iPhone app does two things: it pairs with the Mac relay and shows the mirror's status, and it
archives Apple Health to the same Nextcloud folder. Health is the one source that never reaches a
Mac, so the phone has to send it itself. It walks the full history once (one month at a time, in
the background, usually overnight on charge) and then sends new samples as they appear.

There is no App Store build yet, so you build it yourself.

## Simulator build (status UI only)

HealthKit is unavailable in the Simulator, so this build is for the pairing and status screens.

```bash
cd app/ios
./build-ios.sh        # swiftc, no Xcode project
./run-ios.sh          # boots a simulator and installs it
```

## Device build (needed for Health)

You need a paid Apple Developer account, because HealthKit requires an explicit App ID with the
HealthKit capability, a development certificate, and a development provisioning profile that
lists your iPhone.

1. In App Store Connect or the developer portal, create an explicit App ID for your bundle id
   (the scripts default to `com.mineracks.micloud.phone`; change `BUNDLE` in the scripts or set
   `MICLOUD_IOS_BUNDLE` where supported, and use your own reverse-DNS name) with the HealthKit
   capability enabled.
2. Create an Apple Development certificate and import it into a keychain on the build Mac.
3. Create an iOS App Development profile for that App ID, certificate and your device UDID.
   Save it as `~/micloud-ios-dev.mobileprovision`.
4. Build and install over USB (`devicectl` needs Xcode):

```bash
cd app/ios
MICLOUD_IOS_TEAM=YOUR_TEAM_ID \
MICLOUD_IOS_KEYCHAIN=~/Library/Keychains/login.keychain-db \
MICLOUD_IOS_PROFILE=~/micloud-ios-dev.mobileprovision \
./build-ios-device.sh --install
```

The script embeds the profile, signs with the first Apple Development identity in that keychain,
and the entitlements it writes must be a subset of what your profile allows.

On first launch, pair the phone with the Mac relay from the dashboard's pairing sheet, then turn
on the Health archive. It asks for read access to every Health type once. Keep the phone on
charge overnight for the first full walk.

## TestFlight

`build-ios-store.sh` is the App Store Connect upload path. It expects an App Store Connect API key
in an env file (`APPLE_API_KEY`, `APPLE_API_ISSUER`, `APPLE_API_KEY_PATH`) and a distribution
certificate and profile for your team.
