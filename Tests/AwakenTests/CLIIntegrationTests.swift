// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import IOKit.pwr_mgt
import XCTest

@testable import Awaken

final class CLIIntegrationTests: XCTestCase {
  private var executable: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/awaken")
  }

  private func launch(_ arguments: [String]) throws -> (Process, Pipe) {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    output.fileHandleForWriting.closeFile()
    return (process, output)
  }

  private func launchTerminal(_ arguments: [String], suspendOutput: Bool = false) throws -> (
    Process, FileHandle, FileHandle
  ) {
    var master: Int32 = -1
    var slave: Int32 = -1
    guard openpty(&master, &slave, nil, nil, nil) == 0 else {
      throw Failure("cannot open test terminal")
    }
    let terminal = FileHandle(fileDescriptor: master, closeOnDealloc: true)
    let output = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
    if suspendOutput, tcflow(slave, TCOOFF) != 0 {
      throw Failure("cannot suspend test terminal output")
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    try process.run()
    // Keep the slave open until output is read; macOS can discard queued data on its last close.
    return (process, terminal, output)
  }

  private func readTerminal(_ terminal: FileHandle) -> String {
    var bytes = [UInt8](repeating: 0, count: 4096)
    var output = Data()
    while true {
      var event = pollfd(fd: terminal.fileDescriptor, events: Int16(POLLIN), revents: 0)
      guard poll(&event, 1, 100) > 0 else { break }
      let count = read(terminal.fileDescriptor, &bytes, bytes.count)
      if count > 0 {
        output.append(contentsOf: bytes.prefix(count))
      } else if count == 0 || errno == EIO {
        break
      } else if errno != EINTR {
        XCTFail("terminal read failed")
        break
      }
    }
    return String(decoding: output, as: UTF8.self)
  }

  private func waitForActivation(_ output: Pipe) throws {
    let deadline = Deadline(seconds: 5, now: continuousNanoseconds())
    var line = ""
    while !deadline.expired(at: continuousNanoseconds()) {
      if let byte = try ControlPipe.readByte(output.fileHandleForReading.fileDescriptor, wait: 100)
      {
        if byte == 10 {
          XCTAssertTrue(line.hasPrefix("Awake for up to "), line)
          return
        }
        line.append(Character(UnicodeScalar(byte)))
      }
    }
    XCTFail("CLI did not activate within 5 seconds")
    throw Failure("activation timed out")
  }

  private func waitForExit(_ process: Process) {
    let deadline = Deadline(seconds: 5, now: continuousNanoseconds())
    while process.isRunning, !deadline.expired(at: continuousNanoseconds()) {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      XCTFail("CLI did not exit within 5 seconds")
    }
  }

  private func stopIfRunning(_ process: Process) {
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
  }

  func testOrdinarySessionExpires() throws {
    let (process, output) = try launch(["--timeout", "1"])
    defer { stopIfRunning(process) }
    try waitForActivation(output)
    waitForExit(process)
    XCTAssertEqual(process.terminationStatus, 0)
  }

  func testVersionOptionsPrintTheEmbeddedVersion() throws {
    for option in ["-V", "--version"] {
      let (process, output) = try launch([option])
      defer { stopIfRunning(process) }
      waitForExit(process)
      let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      XCTAssertEqual(text, "awaken \(BuildVersion.current)\n")
      XCTAssertEqual(process.terminationStatus, 0)
    }
  }

  func testTerminalCountdownRedrawsOneLine() throws {
    let (process, terminal, slave) = try launchTerminal(["-t", "2"])
    defer {
      stopIfRunning(process)
      slave.closeFile()
    }
    waitForExit(process)
    let output = readTerminal(terminal)
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertTrue(output.contains("\rAwake: 00:00:02"), output)
    XCTAssertTrue(output.contains("\rAwake: 00:00:01"), output)
    XCTAssertTrue(output.contains("\rAwake: 00:00:00"), output)
    XCTAssertTrue(output.hasSuffix("\r\n"), output)
    XCTAssertEqual(output.utf8.filter { $0 == 10 }.count, 1)
  }

  func testFlowControlledTerminalDoesNotDelayExpiry() throws {
    let (process, terminal, slave) = try launchTerminal(["-t", "1"], suspendOutput: true)
    defer {
      tcflow(slave.fileDescriptor, TCOON)
      stopIfRunning(process)
      slave.closeFile()
      terminal.closeFile()
    }
    waitForExit(process)
    XCTAssertEqual(process.terminationStatus, 0)
  }

  func testTerminalCountdownCancellationEndsTheLine() throws {
    let (process, terminal, slave) = try launchTerminal(["-t", "30"])
    defer {
      stopIfRunning(process)
      slave.closeFile()
    }
    var output = ""
    let deadline = Deadline(seconds: 5, now: continuousNanoseconds())
    while !output.contains("Ctrl-C to stop."), !deadline.expired(at: continuousNanoseconds()) {
      if let byte = try ControlPipe.readByte(terminal.fileDescriptor, wait: 100) {
        output.append(Character(UnicodeScalar(byte)))
      }
    }
    XCTAssertTrue(output.contains("Ctrl-C to stop."))
    kill(process.processIdentifier, SIGTERM)
    waitForExit(process)
    output += readTerminal(terminal)
    XCTAssertTrue(output.hasSuffix("\r\n"), output)
    XCTAssertFalse(output.contains("00:00:00"), output)
    XCTAssertEqual(process.terminationStatus, 128 + SIGTERM)
  }

  func testTerminalCountdownCanBeDisabled() throws {
    for option in ["-q", "--no-countdown"] {
      let (process, terminal, slave) = try launchTerminal([option, "-t", "1"])
      defer {
        stopIfRunning(process)
        slave.closeFile()
      }
      waitForExit(process)
      let output = readTerminal(terminal)
      XCTAssertTrue(output.hasPrefix("Awake for up to "), output)
      XCTAssertFalse(output.contains("remaining."), output)
      XCTAssertEqual(process.terminationStatus, 0)
    }
  }

  func testRedirectedOutputHasNoCountdownUpdates() throws {
    let (process, output) = try launch(["-t", "1"])
    defer { stopIfRunning(process) }
    waitForExit(process)
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertTrue(text.hasPrefix("Awake for up to "))
    XCTAssertFalse(text.contains("\r"))
    XCTAssertFalse(text.contains("remaining."))
  }

  private func assertions(for pid: Int32) throws -> [String] {
    var result: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess,
      let byPID = result?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
    else {
      throw Failure("cannot read assertions by process")
    }
    return (byPID[NSNumber(value: pid)] ?? []).compactMap {
      $0[kIOPMAssertionTypeKey as String] as? String
    }
  }

  func testScreensaverModeCreatesAndReleasesNativeAssertions() throws {
    let (process, output) = try launch(["--prevent-screensaver", "--no-countdown", "-t", "30"])
    defer { stopIfRunning(process) }
    try waitForActivation(output)
    let active = try assertions(for: process.processIdentifier)
    XCTAssertTrue(active.contains(kIOPMAssertPreventUserIdleSystemSleep as String), "\(active)")
    XCTAssertTrue(active.contains(kIOPMAssertPreventUserIdleDisplaySleep as String), "\(active)")
    XCTAssertTrue(active.contains("UserIsActive"), "\(active)")
    kill(process.processIdentifier, SIGTERM)
    waitForExit(process)
    XCTAssertEqual(process.terminationStatus, 128 + SIGTERM)
    XCTAssertTrue(try assertions(for: process.processIdentifier).isEmpty)
  }

  func testOrdinarySessionHandlesCancellationSignals() throws {
    for number in [SIGINT, SIGTERM, SIGHUP] {
      let (process, output) = try launch(["-t", "30"])
      defer { stopIfRunning(process) }
      try waitForActivation(output)
      XCTAssertEqual(kill(process.processIdentifier, number), 0)
      waitForExit(process)
      XCTAssertEqual(process.terminationReason, .exit)
      XCTAssertEqual(process.terminationStatus, 128 + number)
    }
  }

  func testCliRejectsWorkerExtraArgumentsAndInvalidTimeouts() throws {
    for arguments in [
      ["--privileged-worker", "extra"], ["-t", "0"], ["--lid"], ["sudoers", "extra"],
    ] {
      let (process, _) = try launch(arguments)
      defer { stopIfRunning(process) }
      waitForExit(process)
      XCTAssertEqual(process.terminationStatus, 1)
    }
  }

  func testWorkerRejectsNonRootBeforeReportingReady() throws {
    guard geteuid() != 0 else { throw XCTSkip("requires an unprivileged test process") }
    let (process, output) = try launch(["--privileged-worker"])
    defer { stopIfRunning(process) }
    waitForExit(process)
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 1)
    XCTAssertEqual(text, "awaken: worker requires root\n")
  }

  func testSudoersSubcommandPrintsOnlyTheSetupCommand() throws {
    let (process, output) = try launch(["sudoers"])
    defer { stopIfRunning(process) }
    waitForExit(process)
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let user = try XCTUnwrap(getpwuid(getuid()))
    let expected = try Installer.setupCommand(
      executable: executable.resolvingSymlinksInPath().path,
      user: String(cString: user.pointee.pw_name)
    )
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(text, expected + "\n")
  }

  func testCommandTimeoutIsBounded() {
    XCTAssertThrowsError(try runCommand("/bin/sleep", ["30"], timeout: 1)) {
      XCTAssertTrue(String(describing: $0).contains("timed out"))
    }
  }
}
