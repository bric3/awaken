// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import XCTest

@testable import Awaken

final class AwakenTests: XCTestCase {
  func testOptions() throws {
    XCTAssertEqual(try Options.parse([]), Options())
    XCTAssertEqual(try Options.parse(["-l", "-t", "12"]), Options(ignoreLid: true, seconds: 12))
    XCTAssertEqual(
      try Options.parse(["--ignore-lid", "--timeout", "12"]), Options(ignoreLid: true, seconds: 12))
    XCTAssertTrue(try Options.parse(["--help"]).help)
    XCTAssertFalse(try Options.parse([]).noCountdown)
    XCTAssertFalse(try Options.parse([]).preventScreensaver)
    XCTAssertEqual(
      try Options.parse(["-s", "-q", "-l", "-t", "12"]),
      Options(ignoreLid: true, seconds: 12, noCountdown: true, preventScreensaver: true)
    )
    XCTAssertEqual(
      try Options.parse(["--prevent-screensaver", "--no-countdown"]),
      Options(noCountdown: true, preventScreensaver: true)
    )
    for arguments in [["--lid"], ["--privileged-worker", "extra"], ["--timeout"], ["-x"]] {
      XCTAssertThrowsError(try Options.parse(arguments))
    }
  }

  func testDurationUnitsForShortAndLongOptions() throws {
    for (text, expected): (String, UInt64) in [
      ("15", 15), ("15s", 15), ("30m", 1_800), ("2h", 7_200), ("2d", 172_800), ("0001h", 3_600),
    ] {
      XCTAssertEqual(try Options.parse(["-t", text]).seconds, expected, text)
      XCTAssertEqual(try Options.parse(["--timeout", text]).seconds, expected, text)
    }
  }

  func testInvalidDurationsAndOverflow() throws {
    for text in [
      "", "0", "0s", "0m", "0h", "0d", "-1", "-1h", "+1", "1.5", "1.5h", "0.5s", "1000ms",
      "1w", "1y", "1H", "s", "m", "h", "d", "1h30m", "1h 30m", "1 s", " 1", "1 ", "1\n", "1s\n",
      "１", "18446744073709551615", "18446744073709551615d", "18446744074",
    ] {
      XCTAssertThrowsError(try Options.duration(text), text)
    }
    for (suffix, multiplier): (String, UInt64) in [
      ("", 1), ("s", 1), ("m", 60), ("h", 3_600), ("d", 86_400),
    ] {
      let limit = 18_446_744_073 / multiplier
      XCTAssertEqual(try Options.duration("\(limit)\(suffix)"), limit * multiplier)
      XCTAssertThrowsError(try Options.duration("\(limit + 1)\(suffix)"))
    }
  }

  func testDeadlineUsesOnlyElapsedContinuousTime() {
    let deadline = Deadline(seconds: 5, now: 100)
    XCTAssertFalse(deadline.expired(at: 4_000_000_100))
    XCTAssertTrue(deadline.expired(at: 5_000_000_100))
    // A wake after a long sleep expires immediately, with no wall-clock input.
    XCTAssertTrue(deadline.expired(at: 86_400_000_000_100))
  }

  func testDeadlineHandlesClockCounterWrap() {
    let deadline = Deadline(seconds: 1, now: UInt64.max - 500_000_000)
    XCTAssertFalse(deadline.expired(at: 0))
    XCTAssertTrue(deadline.expired(at: 500_000_000))
  }

  func testSafetyThresholds() throws {
    try Safety(batteryPercent: 10.01, thermal: .fair).check()
    for percentage in [10.0, 0, -1, 101, .nan, .infinity] {
      XCTAssertThrowsError(try Safety(batteryPercent: percentage, thermal: .nominal).check())
    }
    for thermal in [ProcessInfo.ThermalState.serious, .critical] {
      XCTAssertThrowsError(try Safety(batteryPercent: 90, thermal: thermal).check())
    }
  }

  func testOrdinarySessionLeavesLidSettingAlone() throws {
    let fake = FakePower()
    try fake.session().run(seconds: 1, ignoreLid: false)
    XCTAssertEqual(fake.operations, ["acquire", "release"])
    XCTAssertEqual(fake.time, 1_000_000_000)
  }

  func testLidSessionRestoresBeforeSleeping() throws {
    let fake = FakePower()
    fake.closed = true
    try fake.session().run(seconds: 1, ignoreLid: true)
    XCTAssertEqual(fake.operations, ["acquire", "disable", "restore", "release", "sleep"])
    XCTAssertFalse(fake.disabled)
  }

  func testOpenLidDoesNotForceSleep() throws {
    let fake = FakePower()
    try fake.session().run(seconds: 1, ignoreLid: true)
    XCTAssertFalse(fake.operations.contains("sleep"))
  }

  func testPreexistingSettingAndUnsafeBatteryPreventActivation() {
    let fake = FakePower()
    fake.disabled = true
    XCTAssertThrowsError(try fake.session().run(seconds: 1, ignoreLid: true))
    XCTAssertTrue(fake.operations.isEmpty)
    fake.disabled = false
    fake.safetyFailure = true
    XCTAssertThrowsError(try fake.session().run(seconds: 1, ignoreLid: true))
    XCTAssertTrue(fake.operations.isEmpty)
  }

  func testFailedActivationStillRestores() {
    let fake = FakePower()
    fake.activationFailure = true
    XCTAssertThrowsError(try fake.session().run(seconds: 1, ignoreLid: true))
    XCTAssertEqual(fake.operations, ["acquire", "disable", "restore", "release"])
    XCTAssertFalse(fake.disabled)
  }

  func testFailedActivationVerificationStillRestores() {
    let fake = FakePower()
    fake.ignoreActivation = true
    XCTAssertThrowsError(try fake.session().run(seconds: 1, ignoreLid: true))
    XCTAssertEqual(fake.operations, ["acquire", "disable", "restore", "release"])
  }

  func testRestorationFailureReportsRecoveryAndDoesNotForceSleep() {
    let fake = FakePower()
    fake.closed = true
    fake.restorationFailure = true
    XCTAssertThrowsError(try fake.session().run(seconds: 1, ignoreLid: true)) {
      XCTAssertTrue(String(describing: $0).contains("sudo pmset -a disablesleep 0"))
    }
    XCTAssertTrue(fake.operations.contains("release"))
    XCTAssertFalse(fake.operations.contains("sleep"))
  }

  func testBatteryOrThermalFailureDuringSessionRestores() {
    let fake = FakePower()
    fake.onPause = { fake.safetyFailure = true }
    XCTAssertThrowsError(try fake.session().run(seconds: 10, ignoreLid: true))
    XCTAssertEqual(fake.operations, ["acquire", "disable", "restore", "release"])
  }

  func testCancellationBeforeActivationDoesNothing() throws {
    let fake = FakePower()
    fake.cancelled = true
    try fake.session().run(seconds: 10, ignoreLid: true)
    XCTAssertTrue(fake.operations.isEmpty)
  }

  func testCancellationAndWakeAfterExpiryRestore() throws {
    let cancelled = FakePower()
    cancelled.onPause = { cancelled.cancelled = true }
    try cancelled.session().run(seconds: 10, ignoreLid: true)
    XCTAssertFalse(cancelled.disabled)
    let resumed = FakePower()
    resumed.onPause = { resumed.time += 86_400_000_000_000 }
    try resumed.session().run(seconds: 10, ignoreLid: true)
    XCTAssertFalse(resumed.disabled)
    XCTAssertEqual(resumed.operations, ["acquire", "disable", "restore", "release"])
  }

  func testControlPipeRequestAndForegroundDeath() throws {
    let pipe = Pipe()
    let cancellation = Cancellation()
    let options = try Options.parse(["--timeout", "2h"])
    let request = WorkerRequest(
      seconds: options.seconds, showCountdown: true, preventScreensaver: true)
    XCTAssertEqual(request.message, "AWAKEN/3 7200 1 1\n")
    try pipe.fileHandleForWriting.write(contentsOf: Data(request.message.utf8))
    XCTAssertEqual(
      try ControlPipe.request(
        pipe.fileHandleForReading.fileDescriptor, cancellation: cancellation), request)
    XCTAssertFalse(try ControlPipe.disconnected(pipe.fileHandleForReading.fileDescriptor))
    try pipe.fileHandleForWriting.close()
    XCTAssertTrue(try ControlPipe.disconnected(pipe.fileHandleForReading.fileDescriptor))
  }

  func testWorkerRejectsInvalidAndExtraInput() throws {
    for input in [
      "123\n", "AWAKEN/1 123 0 0\n", "AWAKEN/2 123 0 0\n", "AWAKEN/3 0 0 0\n", "AWAKEN/3 -1 0 0\n",
      "AWAKEN/3 18446744073709551615 0 0\n", "AWAKEN/3 300 /bin/sh 0\n",
      "AWAKEN/3 300 0 2\n", "AWAKEN/3 300 0 0 extra\n", "AWAKEN/3  300 0 0\n",
      String(repeating: "X", count: 65) + "\n", "AWAKEN/3 300\t0 0\n",
    ] {
      let pipe = Pipe()
      try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
      XCTAssertThrowsError(
        try ControlPipe.request(
          pipe.fileHandleForReading.fileDescriptor, cancellation: Cancellation()))
    }
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: Data("AWAKEN/3 1 0 0\nextra".utf8))
    _ = try ControlPipe.request(
      pipe.fileHandleForReading.fileDescriptor, cancellation: Cancellation())
    XCTAssertThrowsError(try ControlPipe.disconnected(pipe.fileHandleForReading.fileDescriptor))
  }

  func testCountdownRoundingAndFormatting() {
    let deadline = Deadline(seconds: 2, now: 100)
    XCTAssertEqual(deadline.remainingSeconds(at: 100), 2)
    XCTAssertEqual(deadline.remainingSeconds(at: 999_999_999), 2)
    XCTAssertEqual(deadline.remainingSeconds(at: 1_000_000_100), 1)
    XCTAssertEqual(deadline.remainingSeconds(at: 2_000_000_100), 0)
    XCTAssertEqual(deadline.remainingSeconds(at: 86_400_000_000_100), 0)
    var output: [String] = []
    var countdown = Countdown(write: { output.append($0) })
    countdown.update(seconds: 100 * 3600)
    countdown.update(seconds: 100 * 3600)
    countdown.update(seconds: 99 * 3600)
    countdown.finish()
    XCTAssertEqual(output.count, 3)
    XCTAssertEqual(output[0], "\r100:00:00 remaining. Ctrl-C to stop.")
    XCTAssertEqual(output[1], "\r99:00:00 remaining. Ctrl-C to stop. ")
    XCTAssertEqual(output[2], "\n")
  }

  func testCountdownEndsBeforeCleanupAndDoesNotChangeSafetyChecks() throws {
    let fake = FakePower()
    var output = ""
    var session = fake.session()
    session.writeStatus = { output += $0 }
    session.report = { output += $0 + "\n" }
    try session.run(seconds: 2, ignoreLid: true, showCountdown: true)
    XCTAssertTrue(output.hasPrefix("\r00:00:02"))
    XCTAssertTrue(output.contains("\r00:00:01"))
    XCTAssertTrue(
      output.hasSuffix("\r00:00:00 remaining. Ctrl-C to stop.\nNormal sleep restored.\n"))
    XCTAssertEqual(fake.operations, ["acquire", "disable", "restore", "release"])
    XCTAssertEqual(fake.safetyChecks, 2)
  }

  func testCancelledOrFailedCountdownEndsWithoutShowingZero() throws {
    for fail in [false, true] {
      let fake = FakePower()
      var output = ""
      var session = fake.session()
      session.writeStatus = { output += $0 }
      fake.onPause = {
        if fail { fake.safetyFailure = true } else { fake.cancelled = true }
      }
      if fail {
        XCTAssertThrowsError(try session.run(seconds: 10, ignoreLid: true, showCountdown: true))
      } else {
        try session.run(seconds: 10, ignoreLid: true, showCountdown: true)
      }
      XCTAssertTrue(output.hasSuffix("\n"))
      XCTAssertFalse(output.contains("00:00:00"))
      XCTAssertFalse(fake.disabled)
    }
  }

  func testCountdownDisabledDoesNotDisableActivityRenewal() throws {
    let fake = FakePower()
    var session = fake.session()
    var renewals = 0
    session.refreshActivity = { renewals += 1 }
    session.writeStatus = { _ in XCTFail("countdown should be disabled") }
    try session.run(seconds: 3, ignoreLid: false)
    XCTAssertEqual(renewals, 2)
  }

  func testActivityRenewalFailureRestoresSleep() {
    let fake = FakePower()
    var session = fake.session()
    session.refreshActivity = { throw Failure("activity renewal failed") }
    XCTAssertThrowsError(try session.run(seconds: 10, ignoreLid: true))
    XCTAssertFalse(fake.disabled)
    XCTAssertEqual(fake.operations, ["acquire", "disable", "restore", "release"])
  }

  func testConcurrentLidSessionsAndSymlinksAreRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("lock").path
    let first = try SessionLock(path: path, owner: getuid())
    try withExtendedLifetime(first) {
      XCTAssertThrowsError(try SessionLock(path: path, owner: getuid()))
    }
    let symlink = directory.appendingPathComponent("symlink").path
    XCTAssertEqual(Darwin.symlink(path, symlink), 0)
    XCTAssertThrowsError(try SessionLock(path: symlink, owner: getuid()))
  }

  func testSudoersIsRestrictedAndValidatedByVisudo() throws {
    let rule = try Installer.rule(user: "test_user")
    XCTAssertEqual(
      rule,
      "# Managed by awaken.\ntest_user ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/awaken --privileged-worker\n"
    )
    for user in ["", "ALL", "bad\nALL", "user\n", "a b", "a*", "a:root", "a\\b"] {
      XCTAssertThrowsError(try Installer.rule(user: user))
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(rule.utf8).write(to: file)
    try runCommand("/usr/sbin/visudo", ["-c", "-f", file.path])
  }

}

private final class FakePower {
  var time: UInt64 = 0
  var disabled = false
  var closed = false
  var cancelled = false
  var activationFailure = false
  var ignoreActivation = false
  var restorationFailure = false
  var safetyFailure = false
  var safetyChecks = 0
  var operations: [String] = []
  var onPause: (() -> Void)?

  func session() -> Session {
    Session(
      now: { self.time },
      cancelled: { self.cancelled },
      pause: {
        self.time += 100_000_000
        self.onPause?()
      },
      acquire: { self.operations.append("acquire") },
      release: { self.operations.append("release") },
      sleepDisabled: { self.disabled },
      setSleepDisabled: { disabled in
        self.operations.append(disabled ? "disable" : "restore")
        if disabled {
          self.disabled = !self.ignoreActivation
          if self.activationFailure { throw Failure("activation failed") }
        } else {
          if self.restorationFailure { throw Failure("restore failed") }
          self.disabled = false
        }
      },
      checkSafety: {
        self.safetyChecks += 1
        if self.safetyFailure { throw Failure("unsafe") }
      },
      lidClosed: { self.closed },
      sleepNow: { self.operations.append("sleep") },
      report: { _ in }
    )
  }
}
