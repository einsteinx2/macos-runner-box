#!/bin/bash
# runners-stop.sh
# Temporarily stop the runners and the watchdog without shutting down the Mac.
#
# The watchdog is stopped first. Otherwise it sees the runners go offline on
# GitHub and kickstarts them again within about 4 minutes.
#
# Usage: ./runners-stop.sh [--force] [--persist]
#   --force    stop even if a runner is in the middle of a job (the job fails)
#   --persist  also disable the services, so they stay off after a reboot
#
# Undo with ./runners-start.sh.

set -euo pipefail

WATCHDOG_LABEL="com.ben.runner-watchdog"

force=0
persist=0
for arg in "$@"; do
  case "$arg" in
    --force)   force=1 ;;
    --persist) persist=1 ;;
    *) echo "Usage: $0 [--force] [--persist]" >&2; exit 2 ;;
  esac
done

uid=$(id -u)

# Runner.Worker only exists while a runner executes a job. Check only the
# processes of this user, because this script stops only this user's runners.
if [ "$force" = 0 ] && pgrep -u "$uid" -f Runner.Worker >/dev/null; then
  echo "A runner is busy with a job. Wait for it to finish, or pass --force." >&2
  exit 1
fi

labels=("$WATCHDOG_LABEL")
for p in "$HOME"/Library/LaunchAgents/actions.runner.*.plist; do
  [ -e "$p" ] && labels+=("$(basename "$p" .plist)")
done

for label in "${labels[@]}"; do
  if [ "$persist" = 1 ]; then
    launchctl disable "gui/$uid/$label"
  fi
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    launchctl bootout "gui/$uid/$label"
    echo "stopped   $label"
  else
    echo "not loaded $label"
  fi
done

if [ "$persist" = 1 ]; then
  echo "Services disabled; they stay off after a reboot until runners-start.sh."
else
  echo "Services stay off until runners-start.sh or the next login."
fi
