# macos-runner-box

Turns a spare MacBook (in my case an M1 Air with a broken screen) into a headless, always-on host for four GitHub Actions self-hosted runners. The setup script disables sleep so the lid can stay closed, installs a root `caffeinate` daemon as a second line of defense, registers the runners as launchd services, and installs a watchdog that polls GitHub every two minutes with a read-only token and restarts any runner GitHub reports as offline — the state a runner gets stuck in after a long sleep or network outage, where the process is alive but never reconnects. No `gh` CLI and no account sign-in on the machine; the only credentials it holds are the runners' own registration and a fine-grained PAT that can only list runners.

## Setup

1. On the Mac: disable FileVault, enable automatic login for the runner user, and turn on Remote Login (SSH) and Screen Sharing so you can reach it headless later. Install the Xcode Command Line Tools (`xcode-select --install`).
2. Clone this repo onto the Mac and edit the variables at the top of `setup-runner-mac.sh` (`RUNNER_URL`, `SCOPE`, `RUNNER_COUNT`, `RUNNER_PREFIX`, `LABELS`).
3. From another machine, create a fine-grained PAT with only **Self-hosted runners: Read-only** (org runners) or **Administration: Read-only** (repo runners).
4. From another machine, get a runner registration token from *Settings → Actions → Runners → New self-hosted runner*. It's valid for one hour and registers all the runners.
5. On the Mac, run `./setup-runner-mac.sh` and paste the two tokens when prompted (or pass `REG_TOKEN=... WATCHDOG_TOKEN=...`).
6. Verify with `launchctl list | grep -E 'actions.runner|com.ben'` and `tail -f ~/Library/Logs/runner-watchdog.log`, then close the lid.

## Changing the number of runners

Run `./setup-runner-mac.sh <count>` on the Mac, or edit `RUNNER_COUNT` in the script and run it again. The script keeps runners 1 to `<count>`, adds the missing runners, and removes the runners with a higher number.

- To add runners, the script asks for a registration token (or pass `REG_TOKEN=...`).
- To remove runners, the script asks for a removal token (or pass `REMOVE_TOKEN=...`). This is not the registration token. Get it from the *Remove* dialog of a runner on GitHub. It's valid for one hour and removes all the extra runners.
- The script refuses to remove a runner that is in the middle of a job. Wait for the job to finish, then run the script again.

The argument is not saved. A later run without the argument uses `RUNNER_COUNT` from the script, so edit the script to make the count permanent.

## Pausing the runners

To take the runners offline without shutting down the Mac, run `./runners-stop.sh`. It stops the watchdog first, because the watchdog otherwise restarts runners that GitHub reports as offline. The script refuses to stop while a runner is in the middle of a job; pass `--force` to stop anyway (that job fails). The services come back at the next login unless you also pass `--persist`, which disables them until you start them again.

Run `./runners-start.sh` to bring everything back. It starts the runners before the watchdog and clears the watchdog's old strike counts. The power settings and the `caffeinate` daemon are not touched, so the Mac stays awake and reachable over SSH while the runners are stopped.
