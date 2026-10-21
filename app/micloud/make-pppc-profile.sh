#!/usr/bin/env bash
# Generate an MDM PPPC (Privacy Preferences Policy Control) profile that pre-grants micloud the
# Calendar / Reminders / Contacts / Photos TCC services with NO prompt at all.
#
# ⚠ REQUIRES MDM. A PPPC profile only takes effect for these user-privacy services when it is delivered by
# an MDM server the Mac is enrolled in (User-Approved MDM or supervised). A manually double-clicked
# .mobileconfig installs but is SILENTLY IGNORED for Calendar/Contacts/Reminders/Photos. Until the demo
# Mac is MDM-enrolled this profile is a future artifact — day-to-day, stable signing
# (make-signing-identity.sh) + a single one-time grant is what keeps grants across rebuilds.
#
# The profile is keyed on the app's *stable* designated requirement, so it only matches builds signed with
# the persistent identity (run make-signing-identity.sh + build.sh first).
set -euo pipefail
APP="${1:-$HOME/Applications/micloud.app}"
OUT="${2:-micloud-pppc.mobileconfig}"

BID="$(defaults read "$APP/Contents/Info" CFBundleIdentifier)"
REQ="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
[ -n "$REQ" ] || { echo "ERROR: no designated requirement — is $APP signed?"; exit 1; }
case "$REQ" in
  *cdhash*) echo "⚠ requirement pins cdhash (ad-hoc) — this profile would break on every rebuild."
            echo "  Run make-signing-identity.sh + build.sh for a stable cert-based requirement first." ;;
esac

# Deterministic UUIDs from the bundle id, so regenerating doesn't churn the profile's identity in MDM.
uuid() { printf '%s-%s' "$1" "$BID" | shasum | cut -c1-32 \
  | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/' | tr 'a-z' 'A-Z'; }
TUUID=$(uuid top); PUUID=$(uuid pay)

svc() { cat <<EOF
          <key>$1</key>
          <array>
            <dict>
              <key>Identifier</key><string>$BID</string>
              <key>IdentifierType</key><string>bundleID</string>
              <key>CodeRequirement</key><string>$REQ</string>
              <key>Authorization</key><string>Allow</string>
            </dict>
          </array>
EOF
}

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadIdentifier</key><string>com.mineracks.micloud.pppc</string>
  <key>PayloadUUID</key><string>$TUUID</string>
  <key>PayloadDisplayName</key><string>micloud — Privacy (PPPC)</string>
  <key>PayloadDescription</key><string>Pre-grants micloud access to Calendars, Reminders, Contacts and Photos. Requires MDM enrolment to take effect.</string>
  <key>PayloadOrganization</key><string>Mineracks</string>
  <key>PayloadScope</key><string>System</string>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.apple.TCC.configuration-profile-policy</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadIdentifier</key><string>com.mineracks.micloud.pppc.payload</string>
      <key>PayloadUUID</key><string>$PUUID</string>
      <key>PayloadDisplayName</key><string>micloud PPPC</string>
      <key>Services</key>
      <dict>
$(svc Calendar)
$(svc Reminders)
$(svc AddressBook)
$(svc Photos)
      </dict>
    </dict>
  </array>
</dict></plist>
EOF
echo "wrote $OUT"
echo "  bundle:      $BID"
echo "  requirement: $REQ"
