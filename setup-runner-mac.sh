#!/bin/bash
# setup-runner-mac.sh  (no gh, no account sign-in on this machine)
# One-time setup for a headless MacBook (lid closed, no display) as a
# dedicated GitHub Actions runner box.
#
# Run as the user that will own the runners; it sudos for the power settings
# and the caffeinate daemon. Safe to re-run — configured runners are skipped.
# A runner that GitHub deleted (after a long time offline) is registered again.
#
# Usage: ./setup-runner-mac.sh [runner-count]
# A re-run reconciles the host to the runner count: it adds the missing
# runners and removes the runners with a number above the count. The argument
# overrides RUNNER_COUNT below for one run; it is not saved.
#
# Registration tokens: generate them on your own machine, not here.
#   Org:  https://github.com/organizations/ORG/settings/actions/runners/new
#   Repo: https://github.com/OWNER/REPO/settings/actions/runners/new
#   (or: gh api -X POST orgs/ORG/actions/runners/registration-token --jq .token)
# They expire after 1 hour, and one token can register all the runners in
# that window. The script prompts for it; pass REG_TOKEN=... to skip the prompt.
#
# Removal tokens: only needed when the script removes runners. This is not the
# registration token. Get it from the "Remove" dialog of a runner on GitHub
#   (or: gh api -X POST orgs/ORG/actions/runners/remove-token --jq .token)
# It expires after 1 hour, and one token can remove all the extra runners in
# that window. The script prompts for it; pass REMOVE_TOKEN=... to skip the prompt.
#
# Watchdog token: a fine-grained PAT with ONLY
#   org runners:  Organization permissions -> Self-hosted runners: Read-only
#   repo runners: Repository permissions   -> Administration: Read-only
# The script prompts for it and stores it in ~/.runner-watchdog/token (mode 600).
# Pass WATCHDOG_TOKEN=... to skip the prompt; it replaces a stored token. If the
# file exists, the script uses it, and asks for a new token if GitHub rejects it.
# The script also uses this token to find the runners that GitHub deleted.
#
# Put runner-watchdog.sh next to this script.

set -euo pipefail

# ---- edit these -------------------------------------------------------------
RUNNER_URL="https://github.com/YOUR_ORG"   # org URL, or https://github.com/OWNER/REPO
SCOPE="orgs/YOUR_ORG"                      # API path matching RUNNER_URL: orgs/ORG or repos/OWNER/REPO
RUNNER_COUNT=4
RUNNER_PREFIX="air-m1-"
LABELS="self-hosted,macOS,ARM64,air-m1"
# -----------------------------------------------------------------------------

RUNNER_COUNT="${1:-$RUNNER_COUNT}"
case "$RUNNER_COUNT" in
  ''|*[!0-9]*) RUNNER_COUNT=0 ;;
esac
# Read the count as a decimal number. This rejects "00" and removes leading
# zeros, so "seq 1 00" cannot count down to 0.
RUNNER_COUNT=$((10#$RUNNER_COUNT))
if [ "$RUNNER_COUNT" -lt 1 ]; then
  echo "Usage: $0 [runner-count]  (a whole number, 1 or more)" >&2
  exit 2
fi

BIN_DIR="$HOME/bin"
AGENTS="$HOME/Library/LaunchAgents"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== Power: never sleep, even with the lid closed =="
# disablesleep 1 is what lets a laptop stay awake with the lid closed and no
# external display. Everything else is belt-and-suspenders.
sudo pmset -a sleep 0 disksleep 0 displaysleep 2 disablesleep 1 \
  standby 0 autopoweroff 0 hibernatemode 0 powernap 0 womp 1 tcpkeepalive 1
pmset -g | grep -E 'sleep|disablesleep|standby' || true

echo "== caffeinate LaunchDaemon (runs as root, before any login) =="
sudo tee /Library/LaunchDaemons/com.ben.caffeinate.plist >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.ben.caffeinate</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-s</string>
    <string>-i</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
sudo chown root:wheel /Library/LaunchDaemons/com.ben.caffeinate.plist
sudo chmod 644 /Library/LaunchDaemons/com.ben.caffeinate.plist
sudo launchctl bootout system/com.ben.caffeinate 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.ben.caffeinate.plist

echo "== Watchdog token =="
TOKEN_DIR="$HOME/.runner-watchdog"
mkdir -p "$TOKEN_DIR"; chmod 700 "$TOKEN_DIR"
# WATCHDOG_TOKEN replaces a stored token, so a new token needs no prompt.
if [ -n "${WATCHDOG_TOKEN:-}" ]; then
  printf '%s\n' "$WATCHDOG_TOKEN" > "$TOKEN_DIR/token"
elif [ ! -s "$TOKEN_DIR/token" ]; then
  read -rsp "Watchdog PAT (read-only self-hosted runners): " WATCHDOG_TOKEN; echo
  printf '%s\n' "$WATCHDOG_TOKEN" > "$TOKEN_DIR/token"
fi
chmod 600 "$TOKEN_DIR/token"

# Set GITHUB_IDS to the IDs of all the runners in SCOPE, one per line, and
# API_CODE to the HTTP status of the last request. Return 1 if a request fails.
fetch_runner_ids() {
  local page=1 resp out total
  GITHUB_IDS=""
  while :; do
    resp=$(curl -sS --max-time 20 -w '\n%{http_code}' \
      -H "Authorization: Bearer $(tr -d '[:space:]' < "$TOKEN_DIR/token")" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/$SCOPE/actions/runners?per_page=100&page=$page" 2>/dev/null) \
      || { API_CODE=000; return 1; }
    API_CODE=${resp##*$'\n'}
    [ "$API_CODE" = 200 ] || return 1
    # The first line is total_count. The other lines are the runner IDs.
    out=$(printf '%s' "${resp%$'\n'*}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("total_count", 0))
for r in d.get("runners", []):
    print(r["id"])
') || { API_CODE=parse; return 1; }
    total=$(printf '%s\n' "$out" | head -1)
    GITHUB_IDS+="$(printf '%s\n' "$out" | tail -n +2)"$'\n'
    [ $((page * 100)) -ge "$total" ] && return 0
    page=$((page + 1))
  done
}

# A fine-grained PAT expires. If GitHub rejects the stored token, ask for a new one.
if ! fetch_runner_ids && { [ "$API_CODE" = 401 ] || [ "$API_CODE" = 403 ]; }; then
  echo "GitHub rejected the watchdog token (HTTP $API_CODE). It may have expired."
  read -rsp "New watchdog PAT (read-only self-hosted runners): " WATCHDOG_TOKEN; echo
  printf '%s\n' "$WATCHDOG_TOKEN" > "$TOKEN_DIR/token"
  fetch_runner_ids || true
fi
if [ "$API_CODE" != "200" ]; then
  echo "Token check failed: HTTP $API_CODE for $SCOPE/actions/runners (000 = GitHub unreachable, 401/403 = bad token, 404 = wrong SCOPE or missing permission)"
  exit 1
fi

# Newer runners also write .runner_migrated. config.sh refuses to configure a
# runner while .runner or .runner_migrated exists, so check both.
# Print the config file of runner $1, or return 1 if the runner has none.
runner_config() {
  local f
  for f in .runner .runner_migrated; do
    if [ -f "$HOME/actions-runner-$1/$f" ]; then
      echo "$HOME/actions-runner-$1/$f"
      return 0
    fi
  done
  return 1
}
is_configured() { runner_config "$1" >/dev/null; }

# GitHub deletes a runner that stays offline for too long. The runner
# directory still holds the old registration, so the script cannot skip it.
# Return 0 if runner $1 is configured here but GitHub has no runner with its ID.
is_deleted_on_github() {
  local runner_file id
  runner_file=$(runner_config "$1") || return 1
  # The runner writes .runner with a UTF-8 BOM. If the file is unreadable,
  # keep the runner: a false "deleted" would clear a good registration.
  id=$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8-sig"))["agentId"])
' "$runner_file" 2>/dev/null) || return 1
  # A here-string, not a pipe: with pipefail, an early grep -q exit can make
  # the pipe fail and mark a live runner as deleted.
  ! grep -qx "$id" <<< "$GITHUB_IDS"
}

echo "== Runners =="
# Remove the runners with a number above RUNNER_COUNT.
extras=()
for dir in "$HOME"/actions-runner-*; do
  [ -d "$dir" ] || continue
  i=${dir##*/actions-runner-}
  case "$i" in ''|*[!0-9]*) continue ;; esac
  [ "$i" -gt "$RUNNER_COUNT" ] && extras+=("$i")
done

# Runner.Worker only exists while a runner executes a job. The pattern has no
# $HOME prefix, because the process path differs from $HOME if $HOME holds a symlink.
stop_if_busy() {
  if pgrep -u "$(id -u)" -f "/actions-runner-$1/bin/Runner\.Worker" >/dev/null; then
    echo "$RUNNER_PREFIX$1 is busy with a job. Wait for it to finish, then run this script again." >&2
    exit 1
  fi
}

if [ "${#extras[@]}" -gt 0 ]; then
  echo "Runners above the count of $RUNNER_COUNT, to remove: ${extras[*]/#/$RUNNER_PREFIX}"
fi

# Check all the extra runners before the script removes a runner.
need_remove_token=0
for i in ${extras[@]+"${extras[@]}"}; do
  dir="$HOME/actions-runner-$i"
  stop_if_busy "$i"
  # A runner that GitHub deleted needs no removal on GitHub.
  if is_configured "$i" && ! is_deleted_on_github "$i"; then
    need_remove_token=1
  fi
done
if [ "$need_remove_token" = 1 ] && [ -z "${REMOVE_TOKEN:-}" ]; then
  read -rsp "Removal token for $RUNNER_URL: " REMOVE_TOKEN; echo
fi

for i in ${extras[@]+"${extras[@]}"}; do
  name="$RUNNER_PREFIX$i"
  dir="$HOME/actions-runner-$i"
  # Check again. The runner can accept a job while the script waits for the token.
  stop_if_busy "$i"
  remove=0
  if is_configured "$i" && ! is_deleted_on_github "$i"; then remove=1; fi
  (
    cd "$dir"
    # svc.sh install writes .service, so the file shows that the LaunchAgent exists.
    if [ -f .service ]; then
      # Undo runners-stop.sh --persist. A disabled label blocks a later runner
      # with the same name.
      launchctl enable "gui/$(id -u)/$(basename "$(cat .service)" .plist)" || true
      ./svc.sh stop || true
      ./svc.sh uninstall
    fi
    if [ "$remove" = 1 ]; then
      ./config.sh remove --token "$REMOVE_TOKEN"
    fi
  )
  rm -rf "$dir"
  rm -f "$HOME/.runner-watchdog/$name.strikes"
  echo "removed $name"
done

ARCH=osx-arm64
# Latest version from the unauthenticated releases redirect (no API, no token).
VER=$(curl -fsSI https://github.com/actions/runner/releases/latest \
  | awk -F'/tag/v' 'tolower($0) ~ /^location:/ {print $2}' | tr -d '\r\n')
[ -n "$VER" ] || { echo "Could not determine runner version"; exit 1; }
TARBALL="/tmp/actions-runner-$ARCH-$VER.tar.gz"
# A download cut off by an earlier run leaves a truncated cache; discard it.
if [ -f "$TARBALL" ] && ! gzip -t "$TARBALL" 2>/dev/null; then
  echo "Cached $TARBALL is corrupt — downloading again"
  rm -f "$TARBALL"
fi
if [ ! -f "$TARBALL" ]; then
  # Download to a temporary name so an interrupted transfer never becomes the cache.
  curl -fsSL -o "$TARBALL.part" \
    "https://github.com/actions/runner/releases/download/v$VER/actions-runner-$ARCH-$VER.tar.gz"
  gzip -t "$TARBALL.part" || { echo "Downloaded runner tarball is corrupt"; rm -f "$TARBALL.part"; exit 1; }
  mv "$TARBALL.part" "$TARBALL"
fi

# Clear the local registration of each runner that GitHub deleted. The loop
# below then registers it again under the same name and keeps its files.
for i in $(seq 1 "$RUNNER_COUNT"); do
  is_deleted_on_github "$i" || continue
  name="$RUNNER_PREFIX$i"
  echo "$name is configured here, but GitHub deleted it — clearing the local registration"
  stop_if_busy "$i"
  (
    cd "$HOME/actions-runner-$i"
    # svc.sh install fails while the old plist exists, so remove the service too.
    if [ -f .service ]; then
      launchctl enable "gui/$(id -u)/$(basename "$(cat .service)" .plist)" || true
      ./svc.sh stop || true
      ./svc.sh uninstall
    fi
    rm -f .runner .runner_migrated .credentials .credentials_migrated \
      .credentials_rsaparams .service
  )
  rm -f "$HOME/.runner-watchdog/$name.strikes"
done

need_token=0
for i in $(seq 1 "$RUNNER_COUNT"); do
  is_configured "$i" || need_token=1
done
if [ "$need_token" = 1 ] && [ -z "${REG_TOKEN:-}" ]; then
  read -rsp "Registration token for $RUNNER_URL: " REG_TOKEN; echo
fi

for i in $(seq 1 "$RUNNER_COUNT"); do
  name="$RUNNER_PREFIX$i"
  dir="$HOME/actions-runner-$i"
  # svc.sh install writes .service. A configured runner with no .service is
  # registered but has no LaunchAgent, because an earlier run failed after config.sh.
  configured=0
  if is_configured "$i"; then configured=1; fi
  if [ "$configured" = 1 ] && [ -f "$dir/.service" ]; then
    echo "$name already configured in $dir — skipping"
    continue
  fi
  if [ "$configured" = 1 ]; then
    echo "$name is registered but has no service — installing the service"
  else
    mkdir -p "$dir"
    tar xzf "$TARBALL" -C "$dir"
  fi
  (
    cd "$dir"
    if [ "$configured" = 0 ]; then
      ./config.sh --url "$RUNNER_URL" --token "$REG_TOKEN" --name "$name" \
        --labels "$LABELS" --unattended --replace
    fi
    ./svc.sh install    # creates ~/Library/LaunchAgents/actions.runner.<scope>.<name>.plist with KeepAlive
    ./svc.sh start
  )
done

echo "== Watchdog LaunchAgent (every 2 minutes) =="
mkdir -p "$BIN_DIR" "$AGENTS" "$HOME/Library/Logs"
cp "$HERE/runner-watchdog.sh" "$BIN_DIR/runner-watchdog.sh"
chmod +x "$BIN_DIR/runner-watchdog.sh"
sed -i '' \
  -e "s|^SCOPE=.*|SCOPE=\"$SCOPE\"|" \
  -e "s|^PREFIX=.*|PREFIX=\"$RUNNER_PREFIX\"|" \
  "$BIN_DIR/runner-watchdog.sh"

cat > "$AGENTS/com.ben.runner-watchdog.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.ben.runner-watchdog</string>
  <key>ProgramArguments</key>
  <array><string>$BIN_DIR/runner-watchdog.sh</string></array>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/runner-watchdog.out</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/runner-watchdog.err</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/com.ben.runner-watchdog" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTS/com.ben.runner-watchdog.plist"

echo
echo "Done. Check:"
echo "  launchctl list | grep -E 'actions.runner|com.ben'"
echo "  tail -f ~/Library/Logs/runner-watchdog.log"
