# macos-runner-box

Turns a spare MacBook (in my case an M1 Air with a broken screen) into a headless, always-on host for four GitHub Actions self-hosted runners. The setup script disables sleep so the lid can stay closed, installs a root `caffeinate` daemon as a second line of defense, registers the runners as launchd services, and installs a watchdog that polls GitHub every two minutes with a read-only token and restarts any runner GitHub reports as offline — the state a runner gets stuck in after a long sleep or network outage, where the process is alive but never reconnects. No `gh` CLI and no account sign-in on the machine; the only credentials it holds are the runners' own registration and a fine-grained PAT that can only list runners.

## Setup

1. On the Mac: disable FileVault, enable automatic login for the runner user, and turn on Remote Login (SSH) and Screen Sharing so you can reach it headless later. Install the Xcode Command Line Tools (`xcode-select --install`).
2. Clone this repo onto the Mac and edit the variables at the top of `setup-runner-mac.sh` (`RUNNER_URL`, `SCOPE`, `RUNNER_COUNT`, `RUNNER_PREFIX`, `LABELS`).
3. From another machine, create a fine-grained PAT with only **Self-hosted runners: Read-only** (org runners) or **Administration: Read-only** (repo runners).
4. From another machine, get a runner registration token from *Settings → Actions → Runners → New self-hosted runner*. It's valid for one hour and registers all four runners.
5. On the Mac, run `./setup-runner-mac.sh` and paste the two tokens when prompted (or pass `REG_TOKEN=... WATCHDOG_TOKEN=...`).
6. Verify with `launchctl list | grep -E 'actions.runner|com.ben'` and `tail -f ~/Library/Logs/runner-watchdog.log`, then close the lid.
