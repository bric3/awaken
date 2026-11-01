// SPDX-License-Identifier: MPL-2.0

import XCTest

@testable import Awaken

final class WorkerAuthorizationTests: XCTestCase {
  func testRootStartsWorkerDirectly() {
    let command = Awaken.workerCommand(executable: "/trusted/awaken", isRoot: true)
    XCTAssertEqual(command.path, "/trusted/awaken")
    XCTAssertEqual(command.arguments, ["--privileged-worker"])
  }

  func testNonRootCannotPromptOrUseCachedCredentials() {
    let command = Awaken.workerCommand(executable: "/trusted/awaken", isRoot: false)
    XCTAssertEqual(command.path, "/usr/bin/sudo")
    XCTAssertEqual(command.arguments, ["-n", "-k", "--", "/trusted/awaken", "--privileged-worker"])
  }

  func testDeniedStartReportsPermissionAndSetupInstructions() {
    XCTAssertThrowsError(
      try Awaken.workerResult(
        status: 1, diagnostics: "sudo: a password is required\n", usingSudo: true)
    ) {
      let message = String(describing: $0)
      XCTAssertTrue(message.contains("requires root or passwordless sudo"))
      XCTAssertTrue(message.contains("sudo: a password is required"))
      XCTAssertTrue(message.contains("sudo \"$(command -v awaken)\""))
      XCTAssertTrue(message.contains("eval \"$(awaken sudoers)\""))
    }
  }

  func testWorkerFailuresPreserveTheActualCause() throws {
    var output = ""
    let diagnostics = Awaken.workerReady + "awaken: battery charge is at or below 10%\n"
    XCTAssertEqual(
      try Awaken.workerResult(
        status: 1, diagnostics: diagnostics, usingSudo: true, report: { output += $0 }), 1)
    XCTAssertEqual(output, "awaken: battery charge is at or below 10%\n")
    XCTAssertFalse(output.contains("sudoers"))
  }

  func testWarningsBeforeWorkerReadyArePreserved() throws {
    var output = ""
    XCTAssertEqual(
      try Awaken.workerResult(
        status: 0, diagnostics: "warning\n" + Awaken.workerReady, usingSudo: false,
        report: { output += $0 }), 0)
    XCTAssertEqual(output, "warning\n")
  }

  func testOlderRootWorkerReportsRefreshInstructions() {
    XCTAssertThrowsError(
      try Awaken.workerResult(status: 1, diagnostics: "invalid worker request\n", usingSudo: false)
    ) {
      XCTAssertTrue(String(describing: $0).contains("refresh an older installed worker"))
    }
  }

  func testSuccessfulExitWithoutWorkerReadyIsRejected() {
    XCTAssertThrowsError(try Awaken.workerResult(status: 0, diagnostics: "", usingSudo: true))
  }
}
