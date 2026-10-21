#!/bin/bash
# Build -> Developer-ID sign -> notarize -> staple -> deploy micloud.app to the demo Mac.
#
# Runs entirely on ONE trusted host (the Mac Studio, or any Mac with the Swift toolchain + Xcode CLT).
# The signing materials come from the Ansible vault and are imported into a THROWAWAY keychain that is
# destroyed on exit, so the host holds no standing cert. Mirrors the wifi2qr signing posture. No secrets
# are printed. This is the "no MacBook needed" path — the whole pipeline is self-contained here.
#
# Requirements on the host:
#   - this micloud repo checked out (the script builds app/micloud from it)
#   - ~/mineracks-infrastructure with a CURRENT vault.yml + ansible/vault-password.txt (git pull to refresh)
#   - swiftc, xcrun notarytool (Xcode CLT), sshpass, rsync, ansible-vault
#   - network to Apple (notarization) + reachability to the demo Mac
#
# Env overrides: MICLOUD_INFRA, DEMO_HOST/DEMO_USER/DEMO_PW, MICLOUD_APP_DEST, NOTARY_TIMEOUT.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APPDIR="$REPO/app/micloud"
BID="com.mineracks.micloud.dashboard"

INFRA="${MICLOUD_INFRA:-$HOME/mineracks-infrastructure}"
VAULT="$INFRA/ansible/inventory/group_vars/all/vault.yml"
VPW="$INFRA/ansible/vault-password.txt"
DEMO_HOST="${DEMO_HOST:-LAN_HOST}"; DEMO_USER="${DEMO_USER:-admin}"; DEMO_PW="${DEMO_PW:-admin}"
APP_DEST="${MICLOUD_APP_DEST:-/Users/admin/Applications/micloud.app}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-25m}"

# Single top-level vault var (single-line scalar). System python may lack pyyaml, so grep/sed. The trailing
# colon disambiguates prefix-sharing names; values keep internal colons.
vget(){ ansible-vault view --vault-password-file "$VPW" "$VAULT" | grep "^$1:" | head -1 | sed -E "s/^$1:[[:space:]]*//; s/^\"//; s/\"$//" | tr -d '\n'; }
step(){ echo; echo "=== $* ==="; }

for t in swiftc sshpass rsync ansible-vault; do command -v "$t" >/dev/null || { echo "FATAL: missing $t"; exit 1; }; done
xcrun notarytool --version >/dev/null 2>&1 || { echo "FATAL: notarytool not found (install Xcode CLT)"; exit 1; }
[ -f "$VPW" ] && [ -f "$VAULT" ] || { echo "FATAL: vault not found under $INFRA (git pull it?)"; exit 1; }

SIGN_TMP="$(mktemp -d)"
KC="$SIGN_TMP/micloud-signing.keychain-db"; KCPASS="$(openssl rand -hex 20)"
ORIG=$(security list-keychains -d user | tr -d '"' | xargs)
CM="$HOME/.ssh/cm-micloud-deploy"
SO=(-o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o IdentitiesOnly=yes -o NumberOfPasswordPrompts=1 -o ConnectTimeout=12 -o ControlMaster=auto -o "ControlPath=$CM" -o ControlPersist=120)
cleanup(){ security delete-keychain "$KC" 2>/dev/null || true
           [ -n "$ORIG" ] && security list-keychains -d user -s $ORIG 2>/dev/null || true
           sshpass -p "$DEMO_PW" ssh "${SO[@]}" -O exit "$DEMO_USER@$DEMO_HOST" 2>/dev/null || true
           rm -rf "$SIGN_TMP"; }
trap cleanup EXIT
dm(){ sshpass -p "$DEMO_PW" ssh "${SO[@]}" "$DEMO_USER@$DEMO_HOST" "$@"; }

step "1/6 build the app (swiftc) from $APPDIR"
( cd "$APPDIR" && ./build.sh ) >/dev/null
APP="$APPDIR/micloud.app"; [ -d "$APP" ] || { echo "FATAL: build produced no app"; exit 1; }

step "2/6 throwaway keychain from the vaulted Developer ID p12 (+ Apple intermediate)"
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
vget vault_wifi2qr_developer_id_p12_b64 | base64 -d > "$SIGN_TMP/cert.p12"
P12PASS="$(vget vault_wifi2qr_developer_id_p12_password)"
security import "$SIGN_TMP/cert.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign
# The p12 holds only the leaf+key; import the Apple "Developer ID CA - G2" intermediate so codesign can
# build the chain to the (system-trusted) Apple root. Without it a fresh keychain shows "0 valid identities".
security import "$HERE/DeveloperIDG2CA.cer" -k "$KC" 2>/dev/null || true
security list-keychains -d user -s "$KC" $ORIG
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
SIGN_ID="$(vget vault_wifi2qr_signing_identity)"
security find-identity -v -p codesigning "$KC" | grep -q "Developer ID Application" \
  || { echo "FATAL: no valid Developer ID identity (chain incomplete?)"; exit 1; }

step "3/6 Developer ID sign (hardened runtime + sandbox entitlements + secure timestamp)"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" --identifier "$BID" \
  --entitlements "$APPDIR/micloud.entitlements" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | grep -i designated

step "4/6 notarize"
vget vault_wifi2qr_notary_key_p8_b64 | base64 -d > "$SIGN_TMP/notary.p8"
NKID="$(vget vault_wifi2qr_notary_key_id)"; NISS="$(vget vault_wifi2qr_notary_issuer)"
ditto -c -k --keepParent "$APP" "$SIGN_TMP/micloud.zip"
xcrun notarytool submit "$SIGN_TMP/micloud.zip" --key "$SIGN_TMP/notary.p8" --key-id "$NKID" --issuer "$NISS" \
  --wait --timeout "$NOTARY_TIMEOUT"

step "5/6 staple + verify"
xcrun stapler staple "$APP"; xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP" 2>&1 | grep -iE "accepted|source|notarized" || true

step "6/6 deploy signed+stapled app to the demo Mac ($DEMO_USER@$DEMO_HOST)"
DEST_DIR="$(dirname "$APP_DEST")"; DEST_BASE="$(basename "$APP_DEST")"
sshpass -p "$DEMO_PW" rsync -a --delete -e "ssh ${SO[*]}" "$APP/" "$DEMO_USER@$DEMO_HOST:$DEST_DIR/$DEST_BASE.new/"
dm "launchctl bootout gui/\$(id -u)/com.mineracks.micloud 2>/dev/null; sleep 1
    rm -rf '$APP_DEST' && mv '$DEST_DIR/$DEST_BASE.new' '$APP_DEST'
    launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.mineracks.micloud.plist 2>/dev/null \
      || launchctl kickstart -k gui/\$(id -u)/com.mineracks.micloud
    echo DEPLOYED"
dm "codesign -dv --verbose=4 '$APP_DEST' 2>&1 | grep -iE 'Authority=|TeamIdentifier=|flags='; xcrun stapler validate '$APP_DEST' 2>&1 | tail -1"
echo
echo "✅ micloud is Developer-ID-signed + notarized + stapled + deployed. Stable team-based requirement =>"
echo "   future rebuilds keep their TCC grants (one re-grant is needed only the first time you switch from ad-hoc)."
