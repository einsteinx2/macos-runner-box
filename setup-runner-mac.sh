#!/bin/bash
# setup-runner-mac.sh  (no gh, no account sign-in on this machine)
# One-time setup for a headless MacBook (lid closed, no display) as a
# dedicated GitHub Actions runner box.
#
# Run as the user that will own the runners; it sudos for the power settings
# and the caffeinate daemon. Safe to re-run — configured runners are skipped.
#
# Registration tokens: generate them on your own machine, not here.
#   Org:  https://github.com/organizations/ORG/settings/actions/runners/new
#   Repo: https://github.com/OWNER/REPO/settings/actions/runners/new
#   (or: gh api -X POST orgs/ORG/actions/runners/registration-token --jq .token)
# They expire after 1 hour, and one token can register all four runners in
# that window. The script prompts for it; pass REG_TOKEN=... to skip the prompt.
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
  if [ -f "$dir/.runner" ]; then
    echo "$name already configured in $dir — skipping"
    continue
  fi
  mkdir -p "$dir"
  tar xzf "$TARBALL" -C "$dir"
  (
    cd "$dir"
    ./config.sh --url "$RUNNER_URL" --token "$REG_TOKEN" --name "$name" \
      --labels "$LABELS" --unattended --replace
    ./svc.sh install     # creates ~/Library/LaunchAgents/actions.runner.<scope>.<name>.plist with KeepAlive
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
