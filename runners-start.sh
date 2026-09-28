#!/bin/bash
# runners-start.sh
# Start the runners and the watchdog again after runners-stop.sh.
#
# The runners start before the watchdog, so the watchdog never tries to
# kickstart a service that is not loaded yet. Old strike counts are cleared,
# so the watchdog does not restart a runner that is still connecting.
#
# Usage: ./runners-start.sh

set -euo pipefail

AGENTS="$HOME/Library/LaunchAgents"
WATCHDOG_PLIST="$AGENTS/com.ben.runner-watchdog.plist"

uid=$(id -u)

rm -f "$HOME"/.runner-watchdog/*.strikes

plists=()
for p in "$AGENTS"/actions.runner.*.plist; do
  [ -e "$p" ] && plists+=("$p")
done
plists+=("$WATCHDOG_PLIST")

for p in "${plists[@]}"; do
  label=$(basename "$p" .plist)
  # Undo runners-stop.sh --persist. This is a no-op if the service is enabled.
  launchctl enable "gui/$uid/$label"
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    echo "running   $label"
  else
    launchctl bootstrap "gui/$uid" "$p"
    echo "started   $label"
  fi
done
