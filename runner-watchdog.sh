#!/bin/bash
# runner-watchdog.sh  (scoped read-only PAT, no gh)
#
# Asks GitHub which of our self-hosted runners are "offline" and restarts their
# launchd services. This catches the stuck state where Runner.Listener is alive
# locally but has lost its session with GitHub.
#
# Token: a fine-grained PAT stored in ~/.runner-watchdog/token (mode 600).
#   Org runners:  Organization permissions -> "Self-hosted runners: Read-only"
#   Repo runners: Repository permissions   -> "Administration: Read-only"
# Nothing else. The token can list runners and that's all.
#
# Runs as a LaunchAgent every 2 minutes (see setup-runner-mac.sh).
# Needs python3 (present once Xcode Command Line Tools are installed).

set -u

SCOPE="orgs/YOUR_ORG"      # or "repos/OWNER/REPO" — overwritten by setup script
PREFIX="air-m1-"           # only touch runners whose name starts with this
STRIKES=2                  # consecutive offline checks before restarting

STATE="$HOME/.runner-watchdog"
TOKEN_FILE="$STATE/token"
LOG="$HOME/Library/Logs/runner-watchdog.log"
mkdir -p "$STATE" "$(dirname "$LOG")"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

[ -r "$TOKEN_FILE" ] || { log "no token at $TOKEN_FILE"; exit 1; }
TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")

# One page of 100 is plenty for a handful of runners.
resp=$(curl -sS --max-time 20 -w '\n%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/$SCOPE/actions/runners?per_page=100" 2>/dev/null) \
  || { log "GitHub API unreachable; skipping this check"; exit 0; }

code=${resp##*$'\n'}
body=${resp%$'\n'*}
if [ "$code" != "200" ]; then
  # 401/403 = bad or expired token; 404 = wrong SCOPE or token lacks permission.
  log "GitHub API returned HTTP $code; skipping (check token/SCOPE)"
  exit 0
fi

uid=$(id -u)

while read -r name status busy; do
  [ -n "$name" ] || continue

  plist=$(ls "$HOME"/Library/LaunchAgents/actions.runner.*."$name".plist 2>/dev/null | head -1)
  if [ -z "$plist" ]; then
    log "$name: no LaunchAgent found, skipping"
    continue
  fi
  label=$(basename "$plist" .plist)
  strikes_file="$STATE/$name.strikes"

  if [ "$status" = "online" ] || [ "$busy" = "true" ]; then
    rm -f "$strikes_file"
    continue
  fi

  n=$(( $(cat "$strikes_file" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$strikes_file"
  if [ "$n" -lt "$STRIKES" ]; then
    log "$name: offline (strike $n/$STRIKES)"
    continue
  fi

  log "$name: offline for $n consecutive checks, restarting $label"
  if launchctl kickstart -k "gui/$uid/$label"; then
    rm -f "$strikes_file"
  else
    log "$name: kickstart failed (rc=$?) — is the service bootstrapped?"
  fi
done < <(printf '%s' "$body" | python3 -c '
import json, sys
prefix = sys.argv[1]
for r in json.load(sys.stdin).get("runners", []):
    if r["name"].startswith(prefix):
        print(r["name"], r["status"], str(r["busy"]).lower())
' "$PREFIX")
