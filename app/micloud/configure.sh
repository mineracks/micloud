#!/usr/bin/env bash
# Headless install of the micloud relay on a Mac: writes install.json (DIY backend + endpoints), stores
# the Nextcloud app-password and Immich API key in the app's secret store (0600 files, same place the
# app's Keychain fallback uses), installs the launch agent, and (re)starts the app. Secrets are read
# from stdin prompts — never from argv, never echoed.
#
#   ./configure.sh --agent-only     # PREFERRED: just install + start the launch agent; the app's own
#                                   # onboarding (Sign in with Nextcloud / Link Immich) does the rest on screen
#   ./configure.sh --nextcloud https://nextcloud.example.com --user alice --immich https://immich.example.com
#                                   # headless alternative: type the app password + API key at the prompts
#   ./configure.sh --status         # what is configured + is the agent running
#
# After the first launch the dashboard's permissions card walks through the remaining grants (Photos,
# Files folder, Full Disk Access) — Screen Sharing is enough. Everything else is unattended.
set -euo pipefail
# The app is sandboxed: its state lives in the CONTAINER, not in ~/Library/Application Support.
AS="$HOME/Library/Containers/com.mineracks.micloud.dashboard/Data/Library/Application Support/micloud"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/com.mineracks.micloud.plist"
PLIST="$HOME/Library/LaunchAgents/com.mineracks.micloud.plist"
NC=""; USER_=""; IM=""; STATUS=0; AGENT_ONLY=0
while [ $# -gt 0 ]; do case "$1" in
  --nextcloud) NC="$2"; shift 2;; --user) USER_="$2"; shift 2;; --immich) IM="$2"; shift 2;;
  --status) STATUS=1; shift;; --agent-only) AGENT_ONLY=1; shift;; *) echo "unknown arg $1" >&2; exit 2;; esac; done
install_agent() {
  mkdir -p "$HOME/Library/LaunchAgents"; cp "$PLIST_SRC" "$PLIST"
  launchctl bootout "gui/$(id -u)/com.mineracks.micloud" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  sleep 2; launchctl print "gui/$(id -u)/com.mineracks.micloud" | grep -E "state =|pid =" | head -2
}
if [ "$STATUS" = 1 ]; then
  echo "install.json:"; cat "$AS/install.json" 2>/dev/null || echo "  (none)"; echo
  echo "secrets:"; ls -la "$AS/secrets" 2>/dev/null | awk 'NR>1{print "  "$1, $5, $9}'
  echo "agent:"; launchctl print "gui/$(id -u)/com.mineracks.micloud" 2>/dev/null | grep -E "state =|pid =" | head -2 || echo "  not loaded"
  pgrep -fl "micloud.app/Contents/MacOS/micloud" >/dev/null && echo "  process: running" || echo "  process: not running"
  exit 0
fi
if [ "$AGENT_ONLY" = 1 ]; then
  install_agent
  echo "micloud launched in production mode — finish onboarding + the permissions card on screen (Screen Sharing)."
  exit 0
fi
[ -n "$NC" ] && [ -n "$USER_" ] || { echo "--nextcloud and --user are required (or use --agent-only)" >&2; exit 2; }
umask 077; mkdir -p "$AS/secrets"; chmod 700 "$AS" "$AS/secrets"
read -r -s -p "Nextcloud app password for $USER_: " NCP; echo
printf %s "$NCP" > "$AS/secrets/nextcloud:$USER_"; unset NCP
if [ -n "$IM" ]; then
  HOST=$(python3 -c "import sys,urllib.parse;print(urllib.parse.urlparse(sys.argv[1]).hostname)" "$IM")
  read -r -s -p "Immich API key for $HOST: " IMK; echo
  printf %s "$IMK" > "$AS/secrets/immich:$HOST"; unset IMK
fi
python3 - "$AS/install.json" "$NC" "$USER_" "$IM" <<'PY'
import json,sys,os
p,nc,u,im=sys.argv[1:]
d={}
if os.path.exists(p):
    try: d=json.load(open(p))
    except Exception: d={}
d.update({"onboarded":True,"backend":"diy","nextcloudURL":nc,"nextcloudUser":u,"recoveryBackedUp":True})
if im: d["immichURL"]=im
json.dump(d,open(p,"w"),indent=2); print("wrote",p)
PY
chmod 600 "$AS/install.json"
install_agent
echo "micloud launched in production mode — the permissions card on the dashboard lists what still needs a click."
