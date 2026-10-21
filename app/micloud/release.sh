#!/usr/bin/env bash
# Build the downloadable micloud release: the full "relay" build (every lane, Developer ID signed, hardened
# runtime), notarized + stapled by notarize.sh, zipped with ditto so Gatekeeper accepts it on any Mac.
#
#   MICLOUD_MAC_VERSION=0.2.0 MICLOUD_MAC_BUILD=5 ./release.sh [--bundle-exporter] [--env ASC_ENV_FILE]
#
# Needs a "Developer ID Application" identity in an unlocked keychain and an App Store Connect API key for
# notarytool (see notarize.sh). The Messages lane's helper, imessage-exporter, is GPL-3.0; the release does
# NOT bundle it unless --bundle-exporter is given — the app also looks for it in /opt/homebrew/bin and
# /usr/local/bin, so `brew install imessage-exporter` on the target Mac is enough.
set -euo pipefail
cd "$(dirname "$0")"
: "${MICLOUD_MAC_VERSION:?set MICLOUD_MAC_VERSION (e.g. 0.2.0)}" "${MICLOUD_MAC_BUILD:?set MICLOUD_MAC_BUILD (integer)}"
BUNDLE=0; ENVARGS=()
while [ $# -gt 0 ]; do case "$1" in
  --bundle-exporter) BUNDLE=1; shift;; --env) ENVARGS=(--env "$2"); shift 2;; *) echo "unknown arg $1" >&2; exit 2;; esac; done
export MICLOUD_RELAY=1
[ "$BUNDLE" = 1 ] || export IMESSAGE_EXPORTER=/nonexistent/imessage-exporter
./build.sh
# Capture first, then grep: `codesign … | grep -q` lets grep close the pipe early, codesign dies with SIGPIPE and
# under pipefail a correctly signed app reads as unsigned (the trap notarize.sh documents).
SIGINFO="$(codesign -dvv micloud.app 2>&1 || true)"
printf '%s\n' "$SIGINFO" | grep -q 'Authority=Developer ID Application' || { echo "release.sh: not Developer-ID signed — no identity in the keychain?" >&2; exit 1; }
./notarize.sh --app micloud.app ${ENVARGS[@]+"${ENVARGS[@]}"}   # bash 3.2 + set -u: an empty array is "unbound"
OUT="micloud-${MICLOUD_MAC_VERSION}.zip"; rm -f "$OUT"
ditto -c -k --keepParent micloud.app "$OUT"
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "✅ release artefact: $(pwd)/$OUT  (version $MICLOUD_MAC_VERSION build $MICLOUD_MAC_BUILD, exporter bundled: $BUNDLE)"
