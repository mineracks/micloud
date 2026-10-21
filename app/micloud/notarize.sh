#!/usr/bin/env bash
# Notarize + staple a Developer-ID-signed micloud.app so Gatekeeper accepts it on ANY Mac, not only the
# one it was built on (an unstapled Developer ID app is "rejected: Unnotarized Developer ID" the moment it
# is downloaded or copied with a quarantine flag). Run after build.sh. Stapling does not touch the code
# signature, so TCC grants keyed on the designated requirement survive.
#
# Needs an App Store Connect API key with the Developer role. Reads APPLE_API_KEY (key id),
# APPLE_API_ISSUER and APPLE_API_KEY_PATH (the .p8) from --env FILE; default is the first of
# ~/.mineracks-release/asc.env, ~/.mineracks-release/asc.env, else the MacBook's WiFi2QR key folder.
# Nothing is echoed. Unlike the previous version of this script it does NOT re-sign: build.sh already
# signed with the right entitlements (re-signing here with micloud.entitlements silently stripped the
# relay build's sandbox exceptions).
#
#   ./notarize.sh [--app micloud.app] [--env FILE]
set -euo pipefail
cd "$(dirname "$0")"
APP="micloud.app"; ENVF=""
while [ $# -gt 0 ]; do case "$1" in
  --app) APP="$2"; shift 2;; --env) ENVF="$2"; shift 2;; *) echo "unknown arg $1" >&2; exit 2;; esac; done
if [ -z "$ENVF" ]; then
  for c in "$HOME/.mineracks-release/asc.env" "$HOME/.mineracks-release/asc.env"; do [ -f "$c" ] && { ENVF="$c"; break; }; done
fi
if [ -n "$ENVF" ] && [ -f "$ENVF" ]; then
  set -a; . "$ENVF"; set +a
else
  # MacBook fallback: the WiFi2QR signing folder (what the previous notarize.sh hard-coded).
  WK="${MICLOUD_NOTARY_KEY:-$HOME/Desktop/Apple Signing/AuthKey_YOUR_KEY_ID.p8}"
  [ -f "$WK" ] || { echo "no ASC env file (APPLE_API_KEY / APPLE_API_ISSUER / APPLE_API_KEY_PATH) — pass --env" >&2; exit 2; }
  APPLE_API_KEY_PATH="$WK"; APPLE_API_KEY="${MICLOUD_NOTARY_KEYID:-YOUR_KEY_ID}"
  APPLE_API_ISSUER="${MICLOUD_NOTARY_ISSUER:-YOUR_ISSUER_ID}"
fi
: "${APPLE_API_KEY:?}" "${APPLE_API_ISSUER:?}" "${APPLE_API_KEY_PATH:?}"
[ -d "$APP" ] || { echo "$APP not found — run build.sh first" >&2; exit 1; }
# Capture first, then grep: `codesign … | grep -q` lets grep close the pipe after the first match, codesign
# dies with SIGPIPE, and under `pipefail` a correctly signed app reads as "not signed".
SIGINFO="$(codesign -dvv "$APP" 2>&1 || true)"
printf '%s\n' "$SIGINFO" | grep -q 'Authority=Developer ID Application' \
  || { echo "$APP is not Developer-ID signed (ad-hoc builds cannot be notarized) — build with the cert in the keychain" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ditto -c -k --keepParent "$APP" "$TMP/micloud.zip"
echo "submitting $APP to the Apple notary service (usually 1–5 min)…"
xcrun notarytool submit "$TMP/micloud.zip" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" \
  --issuer "$APPLE_API_ISSUER" --wait --timeout 30m | tee "$TMP/notary.log"
if ! grep -q 'status: Accepted' "$TMP/notary.log"; then
  ID="$(sed -n 's/^ *id: //p' "$TMP/notary.log" | head -1)"
  echo "✗ not accepted. Reasons: xcrun notarytool log $ID --key \$APPLE_API_KEY_PATH --key-id \$APPLE_API_KEY --issuer \$APPLE_API_ISSUER" >&2
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP" 2>&1 | tail -2
echo "✅ $APP notarized + stapled"
