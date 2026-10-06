#!/bin/bash
# setup-runner-mac.sh  (no gh, no account sign-in on this machine)
# One-time setup for a headless MacBook (lid closed, no display) as a
# dedicated GitHub Actions runner box.
#
# Run as the user that will own the runners; it sudos for the power settings
# and the caffeinate daemon. Safe to re-run — configured runners are skipped.
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
# Pass WATCHDOG_TOKEN=... to skip the prompt. Skipped if the file already exists.
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

echo "== Runners =="
# Remove the runners with a number above RUNNER_COUNT.
extras=()
for dir in "$HOME"/actions-runner-*; do
  [ -d "$dir" ] || continue
  i=${dir##*/actions-runner-}
  case "$i" in ''|*[!0-9]*) continue ;; esac
  [ "$i" -gt "$RUNNER_COUNT" ] && extras+=("$i")
done

# Runner.Worker only exists while a runner executes a job.
stop_if_busy() {
  if pgrep -u "$(id -u)" -f "$HOME/actions-runner-$1/bin/Runner.Worker" >/dev/null; then
    echo "$RUNNER_PREFIX$1 is busy with a job. Wait for it to finish, then run this script again." >&2
    exit 1
  fi
}

# Check all the extra runners before the script changes anything.
need_remove_token=0
for i in ${extras[@]+"${extras[@]}"}; do
  dir="$HOME/actions-runner-$i"
  stop_if_busy "$i"
  [ -f "$dir/.runner" ] && need_remove_token=1
done
if [ "$need_remove_token" = 1 ] && [ -z "${REMOVE_TOKEN:-}" ]; then
  read -rsp "Removal token for $RUNNER_URL: " REMOVE_TOKEN; echo
fi

for i in ${extras[@]+"${extras[@]}"}; do
  name="$RUNNER_PREFIX$i"
  dir="$HOME/actions-runner-$i"
  # Check again. The runner can accept a job while the script waits for the token.
  stop_if_busy "$i"
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
    if [ -f .runner ]; then
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
if [ ! -f "$TARBALL" ]; then
  curl -fsSL -o "$TARBALL" \
    "https://github.com/actions/runner/releases/download/v$VER/actions-runner-$ARCH-$VER.tar.gz"
fi

need_token=0
for i in $(seq 1 "$RUNNER_COUNT"); do
  [ -f "$HOME/actions-runner-$i/.runner" ] || need_token=1
done
if [ "$need_token" = 1 ] && [ -z "${REG_TOKEN:-}" ]; then
  read -rsp "Registration token for $RUNNER_URL: " REG_TOKEN; echo
fi

for i in $(seq 1 "$RUNNER_COUNT"); do
  name="$RUNNER_PREFIX$i"
  dir="$HOME/actions-runner-$i"
  # svc.sh install writes .service. A runner with .runner but no .service is
  # registered but has no LaunchAgent, because an earlier run failed after config.sh.
  if [ -f "$dir/.runner" ] && [ -f "$dir/.service" ]; then
    echo "$name already configured in $dir — skipping"
    continue
  fi
  if [ -f "$dir/.runner" ]; then
    echo "$name is registered but has no service — installing the service"
  else
    mkdir -p "$dir"
    tar xzf "$TARBALL" -C "$dir"
  fi
  (
    cd "$dir"
    if [ ! -f .runner ]; then
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

TOKEN_DIR="$HOME/.runner-watchdog"
mkdir -p "$TOKEN_DIR"; chmod 700 "$TOKEN_DIR"
if [ ! -s "$TOKEN_DIR/token" ]; then
  if [ -z "${WATCHDOG_TOKEN:-}" ]; then
    read -rsp "Watchdog PAT (read-only self-hosted runners): " WATCHDOG_TOKEN; echo
  fi
  printf '%s\n' "$WATCHDOG_TOKEN" > "$TOKEN_DIR/token"
fi
chmod 600 "$TOKEN_DIR/token"

# Sanity-check the token/scope before wiring up the agent.
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $(cat "$TOKEN_DIR/token")" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/$SCOPE/actions/runners?per_page=1")
if [ "$code" != "200" ]; then
  echo "Token check failed: HTTP $code for $SCOPE/actions/runners (401/403 = bad token, 404 = wrong SCOPE or missing permission)"
  exit 1
fi

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
