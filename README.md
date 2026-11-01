# Awaken

Timed sleep prevention for macOS 13+. Supports lid-close sessions on battery and AC power.

## Usage

```sh
awaken                        # Prevent idle sleep for 300 seconds
awaken -t 1800                # Run for 30 minutes
awaken --ignore-lid           # Prevent lid-close sleep; requires sudo
awaken --prevent-screensaver  # Keep the display awake
awaken --version             # Print the embedded build version
```

| Short | Option                  | Behaviour                                      |
| ----- | ----------------------- | ---------------------------------------------- |
| `-t`  | `--timeout SECONDS`     | Positive whole seconds; default `300`.         |
| `-l`  | `--ignore-lid`          | Prevent lid-close sleep through a root worker. |
| `-q`  | `--no-countdown`        | Disable live countdown updates.                |
| `-s`  | `--prevent-screensaver` | Prevent automatic screensaver/display sleep.   |
| `-V`  | `--version`             | Print `awaken <version>`.                      |
| `-h`  | `--help`                | Print usage and setup commands.                |

Ctrl-C ends the session. The countdown updates one terminal line per second; redirected output uses ordinary status lines. Paused terminal output does not block expiry. The display can sleep unless `-s` is enabled; `-s` can wake an idle display and does not override an explicit lock.

## Install

Download `awaken-macos-universal` and its `.sha256` file from the same GitHub release:

```sh
shasum -a 256 -c awaken-macos-universal.sha256
mkdir -p "${XDG_BIN_HOME:-$HOME/.local/bin}"
install -m 755 awaken-macos-universal "${XDG_BIN_HOME:-$HOME/.local/bin}/awaken"
```

The universal binary supports Apple Silicon and Intel. It is ad-hoc signed and not notarised by Apple. Add the installation directory to `PATH`.

Build from source with Swift 5.9+ and Xcode command-line tools:

```sh
make install
make install BINDIR=/your/bin
make uninstall
```

`BINDIR` defaults to `${XDG_BIN_HOME:-$HOME/.local/bin}`. Use the same override when uninstalling.

## Privileges

Ordinary sessions require no sudo. `--ignore-lid` starts a separate root worker and requires a readable internal battery and lid sensor.

Optional passwordless setup:

```sh
awaken sudoers            # Inspect the quoted setup command
eval "$(awaken sudoers)"  # Authenticate and install
```

Setup installs `/Library/PrivilegedHelperTools/awaken` and `/private/etc/sudoers.d/awaken`. The rule permits only the root-owned worker command. The installer checks ownership, validates the rule with `visudo`, and refuses unrelated files. No background service is installed.

Rerun setup after updating the executable. Stop active sessions before removal:

```sh
make install-sudoers      # Source-tree alternative
make uninstall-sudoers   # Remove the rule and root worker
```

`make uninstall` removes only the local executable.

## Safety

- Expiry uses a continuous monotonic clock: NTP, manual clock changes and time asleep do not extend sessions.
- The worker restores sleep on foreground disconnection, including crashes and `SIGKILL`, and handles SIGINT, SIGTERM and SIGHUP.
- Lid mode refuses existing sleep prevention and concurrent Awaken lid sessions. It stops at battery charge <=10%, serious/critical thermal state, or unavailable safety readings, including on AC power.
- Activation and restoration are verified. Partial activation failures trigger cleanup.
- Ending a lid session restores sleep and requests immediate sleep if the lid is closed.

Lid mode changes the global, undocumented `SleepDisabled` setting through [`pmset`](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m). Avoid concurrent lid-control tools. Idle-sleep timers and saved screensaver settings remain unchanged.

Killing or suspending the root worker can leave sleep disabled. OS failure and reboot recovery are not guaranteed. Keep the Mac ventilated. Manual recovery:

```sh
sudo pmset -a disablesleep 0
```

## Build and versions

```sh
make build
make test
```

SwiftPM generates an embedded version; the installed tool needs neither Git nor a version file. Local builds use reachable Git tags:

| Source state                     | Embedded version  |
| -------------------------------- | ----------------- |
| No release tags or Git metadata  | `0.1.0-SNAPSHOT`  |
| Clean checkout at `v0.1.0-rc.1`  | `0.1.0-rc.1`      |
| Clean checkout at `v0.1.0`       | `0.1.0`           |
| Development after either tag     | `0.1.1-SNAPSHOT`  |

Development uses the highest reachable release version, removes its prerelease suffix, increments the patch, and appends `-SNAPSHOT`. Dirty builds use the development version. Master CI forces snapshot mode even when HEAD has a release tag.

The tests cover parsing, clocks, terminal output, worker messages, cleanup, native assertions, Git version transitions and release coordination. Global power-setting changes and GitHub API writes use substitutes.

Physical lid-close operation, privileged installation and actual idle screensaver suppression remain unverified. Verify these on the target Mac before relying on them.

## GitHub releases

The [workflow](.github/workflows/release.yml) uses GitHub's built-in token with `contents: write`. Keep release immutability disabled: assets are uploaded after publication. Runs are serialised; stale master builds skip draft updates.

**Development:** each successful `master` build creates or updates one managed draft. It suggests the next final tag and targets the built commit without creating a Git tag. Snapshot assets have a `-SNAPSHOT` filename suffix. The managed body block records the version and commit; user notes, title and tag selection are preserved. Existing Git tags are never moved. Failed builds leave the previous draft intact.

**Publish:** open the draft or create a release in GitHub. Choose a new tag and its target commit:

| Tag            | Prerelease checkbox | Embedded version |
| -------------- | ------------------- | ---------------- |
| `v0.1.0-rc.1`  | Checked             | `0.1.0-rc.1`     |
| `v0.1.0`       | Unchecked           | `0.1.0`          |

Click **Publish release**. [The published event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#release) tests and rebuilds the exact tag, verifies its version, signs both architectures, and uploads the binary and checksum. Snapshot assets are removed after a successful upload. Draft saves do not trigger release builds. Reruns replace the workflow's assets and preserve release notes.

To finalise a candidate, create a new final tag and release. Changing the prerelease checkbox does not rename an `-rc.N` version. Assets appear after the build succeeds; monitor the Actions run for failures.
