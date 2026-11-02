// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

@main
enum Awaken {
  static let helperPath = "/Library/PrivilegedHelperTools/awaken"
  static let workerReady = "AWAKEN-WORKER-READY/3\n"
  static let help = """
    Awaken \(BuildVersion.current)

    Usage: awaken [-l] [-q] [-s] [-t SECONDS]
           awaken sudoers

      -l, --ignore-lid           Prevent lid-close sleep; requires root or passwordless sudo.
      -t, --timeout SECONDS      Session duration; default: 300 seconds.
      -q, --no-countdown         Disable countdown updates.
      -s, --prevent-screensaver  Prevent automatic screensaver and display sleep.
      -V, --version             Print the embedded build version.
      -h, --help                Print help.

    Ctrl-C ends the session. Countdown updates require a terminal.
    Lid sessions stop at <=10% battery or serious/critical thermal state.

    Setup:
      make install               Install into XDG_BIN_HOME or ~/.local/bin.
      awaken sudoers             Print the sudoers setup function.
      eval "$(awaken sudoers)"    Define and run the setup function.
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
          try Installer.setupScript(
            executable: executable, user: String(cString: user.pointee.pw_name)))
        return
      } else if arguments == ["--privileged-worker"] {
        guard geteuid() == 0 else { throw Failure("worker requires root") }
        try worker(cancellation)
      } else if arguments.count == 2, arguments[0] == "--uninstall-sudoers" {
        try Installer.uninstall(user: arguments[1])
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
    try FileHandle.standardError.write(contentsOf: Data(workerReady.utf8))
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

  static func workerCommand(executable: String, isRoot: Bool) -> (path: String, arguments: [String])
  {
    if isRoot { return (executable, ["--privileged-worker"]) }
    return ("/usr/bin/sudo", ["-n", "-k", "--", executable, "--privileged-worker"])
  }

  static func workerResult(
    status: Int32, diagnostics: String, usingSudo: Bool,
    report: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
  ) throws -> Int32 {
    guard let ready = diagnostics.range(of: workerReady) else {
      let requirement =
        usingSudo
        ? "--ignore-lid requires root or passwordless sudo; the privileged worker did not start."
        : "the privileged worker did not start; refresh an older installed worker."
      throw Failure(
        "\(requirement)\n\(diagnostics)Run: sudo \"$(command -v awaken)\" --ignore-lid -t SECONDS\nOr set up the worker: eval \"$(awaken sudoers)\""
      )
    }
    let message = diagnostics.replacingCharacters(in: ready, with: "")
    if !message.isEmpty { report(message) }
    return status
  }

  static func launchWorker(request: WorkerRequest, cancellation: Cancellation) throws -> Int32 {
    let process = Process()
    let control = Pipe()
    let diagnostics = Pipe()
    let isRoot = geteuid() == 0
    let installed = FileManager.default.fileExists(atPath: helperPath)
    guard let localExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
      throw Failure("cannot locate the awaken executable")
    }
    let executable = installed ? helperPath : localExecutable
    if installed { try Installer.checkTrustedFile(helperPath) }
    let command = workerCommand(executable: executable, isRoot: isRoot)
    process.executableURL = URL(fileURLWithPath: command.path)
    process.arguments = command.arguments
    process.standardInput = control
    process.standardOutput = FileHandle.standardOutput
    process.standardError = diagnostics
    try process.run()
    control.fileHandleForReading.closeFile()
    diagnostics.fileHandleForWriting.closeFile()
    defer { try? control.fileHandleForWriting.close() }
    var requestError: Error?
    do {
      try control.fileHandleForWriting.write(contentsOf: Data(request.message.utf8))
    } catch {
      // sudo can reject the command before its input pipe is written; keep its diagnostic.
      requestError = error
      try? control.fileHandleForWriting.close()
    }
    var closed = requestError != nil
    while process.isRunning {
      if cancellation.signalNumber != 0, !closed {
        try control.fileHandleForWriting.close()
        closed = true
        // Forward cancellation to sudo or the directly launched root worker.
        process.terminate()
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    let message = String(
      decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if process.terminationReason == .uncaughtSignal { return 128 + process.terminationStatus }
    if cancellation.signalNumber != 0 { return 128 + cancellation.signalNumber }
    let status = try workerResult(
      status: process.terminationStatus, diagnostics: message, usingSudo: !isRoot)
    if let requestError {
      throw Failure("cannot send the session to the privileged worker: \(requestError)")
    }
    if status != 0 { return status }
    return cancellation.signalNumber == 0 ? 0 : 128 + cancellation.signalNumber
  }
}
