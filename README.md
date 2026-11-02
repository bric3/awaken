# Awaken

Timed sleep prevention for macOS 13+. Supports lid-close sessions on battery and AC power.

> [!IMPORTANT]
> Use at your own risk. Review the [safety notes](#safety) before using lid mode.

## Usage

```sh
awaken                        # Prevent idle sleep for 300 seconds
awaken -t 30m                 # Run for 30 minutes
awaken -t 2h                  # Run for two hours
awaken -t 1d                  # Run for 24 hours
awaken --ignore-lid           # Requires root or passwordless sudo
awaken --prevent-screensaver  # Keep the display awake
awaken --version             # Print the embedded build version
```

| Short | Option                  | Behaviour                                      |
| ----- | ----------------------- | ---------------------------------------------- |
| `-t`  | `--timeout DURATION`    | Whole number; units `s`, `m`, `h`, `d`.        |
| `-l`  | `--ignore-lid`          | Prevent lid-close sleep through a root worker. |
| `-q`  | `--no-countdown`        | Disable live countdown updates.                |
| `-s`  | `--prevent-screensaver` | Prevent automatic screensaver/display sleep.   |
| `-V`  | `--version`             | Print `awaken <version>`.                      |
| `-h`  | `--help`                | Print usage and setup commands.                |

The duration is a positive whole number followed by an optional lowercase `s`, `m`, `h` or `d`. Bare numbers mean seconds. `1d` is 24 hours. The default is `300s`.

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

Ordinary sessions, including `--prevent-screensaver`, require no sudo. `--ignore-lid` starts a separate root worker and requires a readable internal battery and lid sensor.

Before using `--ignore-lid`, install the worker and its passwordless sudo rule:

```sh
awaken sudoers            # Inspect the shell setup function
eval "$(awaken sudoers)"  # Define and run awaken_sudoers
```

`awaken sudoers` prints a POSIX shell function named `awaken_sudoers` followed by its invocation. It refuses while Awaken is running. Evaluating the output authenticates through sudo and performs installation with shell commands, checking again before replacing files. The function remains available in the current shell.

Setup installs `/Library/PrivilegedHelperTools/awaken` and `/private/etc/sudoers.d/awaken`. The rule permits only the root-owned worker command. The function checks ownership, validates the rule with `visudo`, and refuses unrelated files. No background service is installed.

Run lid sessions directly after setup:

```sh
awaken --ignore-lid -t 1h
```

Lid mode fails immediately unless Awaken runs as root or sudo permits the exact worker command without a password. It uses `sudo -n -k`: no prompt and no cached credentials.

Before activation, Awaken checks the worker protocol. Compatible workers from a different build emit a warning and an update command; incompatible workers fail before receiving a session request. Binary comparison also detects different `SNAPSHOT` builds with the same version string. A compatible older worker can retain its older countdown format.

Rerun setup after updating the executable to refresh the worker protocol. Stop active sessions before removal:

```sh
make install-sudoers      # Source-tree alternative
make uninstall-sudoers   # Remove the rule and root worker
```

`make uninstall` removes only the local executable.

## Safety

> [!NOTE]
>
> - Expiry uses a continuous monotonic clock: NTP and manual clock changes neither extend nor shorten sessions. Time asleep counts towards expiry.
> - The worker restores sleep on foreground disconnection, including crashes and `SIGKILL`, and handles SIGINT, SIGTERM and SIGHUP.
> - Lid mode refuses existing sleep prevention and concurrent Awaken lid sessions. It stops at battery charge <=10%, serious/critical thermal state, or unavailable safety readings, including on AC power.
> - Activation and restoration are verified. Partial activation failures trigger cleanup.
> - Ending a lid session restores sleep and requests immediate sleep if the lid is closed.

> [!WARNING]
> Lid mode changes the global, undocumented `SleepDisabled` setting through [`pmset`](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m). Avoid concurrent lid-control tools. Idle-sleep timers and saved screensaver settings remain unchanged.
>
> Killing or suspending the root worker can leave sleep disabled. OS failure and reboot recovery are not guaranteed.
>
> **Keep the Mac ventilated.** Manual recovery:
>
> ```sh
> sudo pmset -a disablesleep 0
> ```

## Manual checks

Run these on the target Mac. Quit other keep-awake tools first.

### Lid-close sleep

Disconnect external displays and docks to avoid macOS closed-display mode. Use a ventilated surface and battery charge above 10%.

1. With Awaken stopped, close the lid for 15 seconds, then reopen it. Confirm a lid-triggered sleep entry in the log below. Record the timestamps for each test.
2. Complete the [worker setup](#privileges), then run `awaken --ignore-lid -t 120`. Wait for the active session message, close the lid for 30 seconds, then reopen it before expiry. No system sleep entry should occur during this interval.
3. Press Ctrl-C. `SleepDisabled` should return to `No`.
4. Run a new 60-second lid session, close the lid and wait 90 seconds before reopening it. The log should show sleep near expiry; `SleepDisabled` should be `No`.
5. Repeat on battery and AC power.

Inspect settings in a second terminal while the lid is open:

```sh
ioreg -r -d 1 -n IOPMrootDomain | rg '"(SleepDisabled|AppleClamshellState)"'
pmset -g log | rg 'Entering Sleep|Wake from|Clamshell' | tail -n 30
```

`SleepDisabled` should be `Yes` only during the lid session. This setting confirms activation; the sleep log confirms physical behaviour. A dark or locked display alone does not prove system sleep. If the baseline does not sleep, resolve that before testing Awaken.

### Automatic screensaver

Record the current System Settings values. Set the idle interval to one minute in [Screen Saver settings](https://support.apple.com/guide/mac-help/mchlp1227/mac), and set display-off time longer than three minutes for the current power source in [Lock Screen settings](https://support.apple.com/guide/mac-help/mh11784/mac).

1. Run `awaken -t 180`. Leave keyboard and mouse untouched for 90 seconds. The automatic screensaver should start. Stop the session after this baseline check.
2. Run `awaken --prevent-screensaver -t 180`. Leave all input untouched for 90 seconds. The screensaver should remain inactive and the display should stay awake.
3. Let the session expire. Automatic screensaver activation should resume once the idle interval is met. Restore the original settings.

`pmset -g assertions` should show Awaken's `PreventUserIdleSystemSleep`, `PreventUserIdleDisplaySleep` and `UserIsActive` assertions during step 2. Assertions confirm requests to macOS; the idle test confirms the visible result. Preview, hot corners and explicit locking do not test automatic activation.

## Build

```sh
make build
make test
```

The tests cover parsing, clocks, terminal output, worker messages, cleanup and native assertions. Global power-setting changes use substitutes.

Physical lid-close operation, privileged installation and actual idle screensaver suppression remain unverified. Verify these on the target Mac before relying on them.

See [RELEASING.md](RELEASING.md) for versioning, draft builds and release publication.

## Licence

Licensed under the [Mozilla Public License 2.0](LICENSE) (`MPL-2.0`).

```sh
make license        # Add missing SPDX headers
make license-check  # Check for missing headers without editing
```

Both targets use the project's SwiftPM `LicenseTool`; no additional toolchain is required. They cover Swift sources, tests, build tools, plugins, workflows, `Package.swift` and `Makefile`. The tool preserves SwiftPM's first-line tools directive and existing notices. A conflicting SPDX licence stops the operation for manual review.
