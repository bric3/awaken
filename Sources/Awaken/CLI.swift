// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

@main
enum Awaken {
  static let helperPath = "/Library/PrivilegedHelperTools/awaken"
  static let help = """
    Awaken \(BuildVersion.current)

    Usage: awaken [-l] [-q] [-s] [-t SECONDS]
           awaken sudoers

      -l, --ignore-lid           Prevent lid-close sleep; requires sudo.
      -t, --timeout SECONDS      Session duration; default: 300 seconds.
      -q, --no-countdown         Disable countdown updates.
      -s, --prevent-screensaver  Prevent automatic screensaver and display sleep.
      -V, --version             Print the embedded build version.
      -h, --help                Print help.

    Ctrl-C ends the session. Countdown updates require a terminal.
    Lid sessions stop at <=10% battery or serious/critical thermal state.

    Setup:
      make install               Install into XDG_BIN_HOME or ~/.local/bin.
      awaken sudoers             Print the passwordless setup command.
      eval "$(awaken sudoers)"    Install the root worker and sudoers rule.
      make uninstall-sudoers     Remove the worker and rule from source.

    Rerun sudoers setup after updates. No background service is installed.

    Recovery: sudo pmset -a disablesleep 0
    Killing or suspending the worker can leave sleep disabled. Keep the Mac ventilated.
    """

  static func main() {
    let cancellation = Cancellation()
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments == ["sudoers"] {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
          let user = getpwuid(getuid())
        else {
          throw Failure("cannot locate the executable or current account")
        }
        print(
          try Installer.setupCommand(
            executable: executable, user: String(cString: user.pointee.pw_name)))
        return
      } else if arguments == ["--privileged-worker"] {
        guard geteuid() == 0 else { throw Failure("worker requires root") }
        try worker(cancellation)
      } else if arguments.count == 2,
        arguments[0] == "--install-sudoers" || arguments[0] == "--uninstall-sudoers"
      {
        try Installer.run(user: arguments[1], uninstall: arguments[0] == "--uninstall-sudoers")
      } else {
        let options = try Options.parse(arguments)
        if options.version {
          print("awaken \(BuildVersion.current)")
          return
        }
        if options.help {
          print(help)
          return
        }
        let showCountdown = !options.noCountdown && isatty(STDOUT_FILENO) == 1
        if options.ignoreLid {
          let request = WorkerRequest(
            seconds: options.seconds, showCountdown: showCountdown,
            preventScreensaver: options.preventScreensaver
          )
          let status = try launchWorker(request: request, cancellation: cancellation)
          exit(status)
        }
        let power = try MacPower()
        try power.session(
          preventScreensaver: options.preventScreensaver,
          cancelled: { cancellation.signalNumber != 0 }
        )
        .run(seconds: options.seconds, ignoreLid: false, showCountdown: showCountdown)
      }
      if cancellation.signalNumber != 0 { exit(128 + cancellation.signalNumber) }
    } catch {
      FileHandle.standardError.write(Data("awaken: \(error)\n".utf8))
      exit(1)
    }
  }

  static func worker(_ cancellation: Cancellation) throws {
    let sessionLock = try SessionLock()
    try withExtendedLifetime(sessionLock) {
      let request = try ControlPipe.request(STDIN_FILENO, cancellation: cancellation)
      let power = try MacPower()
      try power.session(
        preventScreensaver: request.preventScreensaver,
        cancelled: {
          if cancellation.signalNumber != 0 { return true }
          return try ControlPipe.disconnected(STDIN_FILENO)
        }
      ).run(seconds: request.seconds, ignoreLid: true, showCountdown: request.showCountdown)
    }
  }

  static func launchWorker(request: WorkerRequest, cancellation: Cancellation) throws -> Int32 {
    let process = Process()
    let control = Pipe()
    let installed = FileManager.default.fileExists(atPath: helperPath)
    guard let localExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
      throw Failure("cannot locate the awaken executable")
    }
    let executable = installed ? helperPath : localExecutable
    if installed { try Installer.checkTrustedFile(helperPath) }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["--", executable, "--privileged-worker"]
    process.standardInput = control
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    control.fileHandleForReading.closeFile()
    defer { try? control.fileHandleForWriting.close() }
    try control.fileHandleForWriting.write(contentsOf: Data(request.message.utf8))
    var closed = false
    while process.isRunning {
      if cancellation.signalNumber != 0, !closed {
        try control.fileHandleForWriting.close()
        closed = true
        // Also cancel sudo while it is still waiting for authentication.
        process.terminate()
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    if process.terminationReason == .uncaughtSignal { return 128 + process.terminationStatus }
    if process.terminationStatus != 0 {
      if installed {
        FileHandle.standardError.write(
          Data("After an update, refresh the worker: eval \"$(awaken sudoers)\"\n".utf8))
      }
      return process.terminationStatus
    }
    return cancellation.signalNumber == 0 ? 0 : 128 + cancellation.signalNumber
  }
}
