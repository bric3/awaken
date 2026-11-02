// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest

@testable import Awaken

final class WorkerCompatibilityTests: XCTestCase {
  private func greeting(_ text: String) throws -> String {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    try pipe.fileHandleForWriting.close()
    return try Awaken.waitForWorkerReady(
      pipe.fileHandleForReading.fileDescriptor, cancellation: Cancellation())
  }

  func testCompatibleGreetingPreservesSudoWarnings() throws {
    let text = "sudo warning\n" + Awaken.workerReady
    let actual = try greeting(text)
    var reported = ""
    XCTAssertEqual(actual, text)
    XCTAssertEqual(
      try Awaken.workerResult(
        status: 0, diagnostics: actual, usingSudo: true, report: { reported += $0 }), 0)
    XCTAssertEqual(reported, "sudo warning\n")
  }

  func testIncompatibleGreetingFailsBeforeARequestCanBeSent() throws {
    let actual = try greeting("warning: AWAKEN-WORKER-READY/3\nAWAKEN-WORKER-READY/4\n")
    XCTAssertThrowsError(try Awaken.workerResult(status: 0, diagnostics: actual, usingSudo: true)) {
      XCTAssertTrue(String(describing: $0).contains("incompatible protocol"))
      XCTAssertTrue(String(describing: $0).contains("eval \"$(awaken sudoers)\""))
    }
  }

  func testDeniedWorkerReturnsItsDiagnosticWithoutWaitingForARequest() throws {
    XCTAssertEqual(try greeting("sudo: a password is required\n"), "sudo: a password is required\n")
  }

  func testAWorkerWithoutAGreetingHasABoundedStartup() throws {
    let pipe = Pipe()
    XCTAssertThrowsError(
      try Awaken.waitForWorkerReady(
        pipe.fileHandleForReading.fileDescriptor, cancellation: Cancellation(), timeout: 0)
    ) {
      XCTAssertTrue(String(describing: $0).contains("compatible protocol"))
      XCTAssertTrue(String(describing: $0).contains("eval \"$(awaken sudoers)\""))
    }
  }

  func testStartupDiagnosticsAreBounded() {
    XCTAssertThrowsError(try greeting(String(repeating: "x", count: 4097)))
  }

  func testDifferentSnapshotBuildsWarnButIdenticalCopiesDoNot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = directory.appendingPathComponent("local")
    let worker = directory.appendingPathComponent("worker")
    let binary = Data("0.1.0-SNAPSHOT\nnew build".utf8)
    try binary.write(to: local)
    try binary.write(to: worker)
    XCTAssertNil(Awaken.workerBuildWarning(localExecutable: local.path, worker: worker.path))
    try Data("0.1.0-SNAPSHOT\nold build".utf8).write(to: worker)
    let warning = try XCTUnwrap(
      Awaken.workerBuildWarning(localExecutable: local.path, worker: worker.path))
    XCTAssertTrue(warning.contains("compatible protocol"))
    XCTAssertTrue(warning.contains("eval \"$(awaken sudoers)\""))
  }

  func testSetupIgnoresItsOwnProcessAndRefusesOtherProcesses() throws {
    try Installer.requireIdle(processes: [], currentPID: 10)
    try Installer.requireIdle(processes: [10], currentPID: 10)
    for processes: [Int32] in [[20], [10, 20]] {
      XCTAssertThrowsError(try Installer.requireIdle(processes: processes, currentPID: 10)) {
        XCTAssertTrue(String(describing: $0).contains("Awaken is in use"))
      }
    }
  }
}
