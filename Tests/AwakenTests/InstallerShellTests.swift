// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import XCTest

@testable import Awaken

final class InstallerShellTests: XCTestCase {
  private func evaluate(_ script: String, shell: String = "/bin/sh", prelude: String = "") throws
    -> (
      status: Int32, output: String
    )
  {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-c", prelude + "\neval \"$1\"", "awaken-test", script]
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    output.fileHandleForWriting.closeFile()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, text)
  }

  func testSetupFunctionQuotesArgumentsAndPropagatesFailureInSupportedShells() throws {
    let executable =
      "/Users/O'Brien/a b/$(printf injected)/`printf injected`/\nAWAKEN_SUDOERS\nawaken"
    let script = try Installer.setupScript(executable: executable, user: "test_user")
      .replacingOccurrences(of: "/usr/bin/sudo", with: "awaken_test_sudo")
    let prelude = #"""
      awaken_test_sudo() { printf '%s\0' "$@"; /bin/cat >/dev/null; return 17; }
      """#
    let pattern =
      "awaken|awaken-macos-universal(-SNAPSHOT)?|"
      + NSRegularExpression.escapedPattern(for: URL(fileURLWithPath: executable).lastPathComponent)
    let arguments = ["--", "/bin/sh", "-s", "--", executable, "test_user", pattern]
    for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
      let result = try evaluate(script, shell: shell, prelude: prelude)
      XCTAssertEqual(result.status, 17, result.output)
      XCTAssertEqual(result.output, arguments.joined(separator: "\0") + "\0")
    }
    XCTAssertThrowsError(try Installer.setupScript(executable: executable, user: "bad\nALL"))
  }

  func testSetupFunctionRemainsCallableAfterEvaluation() throws {
    let script = try Installer.setupScript(executable: "/test/awaken", user: "test_user")
      .replacingOccurrences(of: "/usr/bin/sudo", with: "awaken_test_sudo")
    let prelude = #"""
      count=0
      awaken_test_sudo() { /bin/cat >/dev/null; count=$((count + 1)); }
      """#
    for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
      let result = try evaluate(
        script + "\nawaken_sudoers\nprintf '%s' \"$count\"", shell: shell, prelude: prelude)
      XCTAssertEqual(result.status, 0, result.output)
      XCTAssertEqual(result.output, "2")
    }
  }

  func testShellInstallsRefreshesAndSecuresFiles() throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }
    for content in ["first worker", "updated worker"] {
      try Data(content.utf8).write(to: fixture.source)
      let result = try evaluate(fixture.script)
      XCTAssertEqual(result.status, 0, result.output)
      XCTAssertEqual(try String(contentsOf: fixture.helper), content)
      XCTAssertEqual(try String(contentsOf: fixture.rule), fixture.contents)
      XCTAssertEqual(try fixture.permissions(fixture.helper), 0o755)
      XCTAssertEqual(try fixture.permissions(fixture.rule), 0o440)
      try fixture.assertNoTemporaryFiles()
    }
  }

  func testShellRefusesActiveSessionsAndUnavailableProcessInspection() throws {
    for active in [true, false] {
      let fixture = try InstallFixture()
      defer { fixture.remove() }
      let command = active ? "/usr/bin/true" : "/bin/sh -c 'exit 2' --"
      let script = fixture.script.replacingOccurrences(of: "/usr/bin/false", with: command)
      let result = try evaluate(script)
      XCTAssertNotEqual(result.status, 0, result.output)
      XCTAssertTrue(
        result.output.contains(active ? "Awaken is in use" : "cannot check"), result.output)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rule.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.helper.path))
      try fixture.assertNoTemporaryFiles()
    }
  }

  func testShellRechecksActivityBeforeReplacingFiles() throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }
    XCTAssertEqual(try evaluate(fixture.script).status, 0)
    try Data("replacement".utf8).write(to: fixture.source)
    let marker = fixture.directory.appendingPathComponent("active").path
    let script = fixture.script
      .replacingOccurrences(
        of: "/usr/bin/false",
        with: "/bin/sh -c 'test -e \"$1\"' -- '\(marker)'"
      )
      .replacingOccurrences(
        of: #"/bin/chmod 755 "$helper_tmp""#,
        with: #"/bin/chmod 755 "$helper_tmp""# + "\n/usr/bin/touch '\(marker)'")
    let result = try evaluate(script)
    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("Awaken is in use"), result.output)
    XCTAssertEqual(try String(contentsOf: fixture.helper), "worker")
    XCTAssertEqual(try String(contentsOf: fixture.rule), fixture.contents)
    try fixture.assertNoTemporaryFiles()
  }

  func testShellRefusesUnrelatedRulesAndUnrecognisedHelpers() throws {
    for state in ["different-rule", "extra-newline", "unrecognised-helper"] {
      let fixture = try InstallFixture()
      defer { fixture.remove() }
      let existingRule = state != "unrecognised-helper"
      let existing = existingRule ? fixture.rule : fixture.helper
      let content = state == "extra-newline" ? fixture.contents + "\n" : "unrelated"
      try FileManager.default.createDirectory(
        at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: existing)
      let result = try evaluate(fixture.script)
      XCTAssertNotEqual(result.status, 0, result.output)
      XCTAssertTrue(result.output.contains("refusing"), result.output)
      XCTAssertEqual(try String(contentsOf: existing), content)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: (existingRule ? fixture.helper : fixture.rule).path))
      try fixture.assertNoTemporaryFiles()
    }
  }

  func testShellRejectsSymlinksInFilesAndAncestorDirectories() throws {
    for target in ["rule", "helper", "ancestor"] {
      let fixture = try InstallFixture()
      defer { fixture.remove() }
      let link =
        target == "rule" ? fixture.rule : target == "helper" ? fixture.helper : fixture.library
      if target == "ancestor" { try FileManager.default.removeItem(at: link) }
      try FileManager.default.createDirectory(
        at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
      let result = try evaluate(fixture.script)
      XCTAssertNotEqual(result.status, 0, result.output)
      XCTAssertTrue(result.output.contains("must not be a symlink"), result.output)
      XCTAssertEqual(try String(contentsOf: fixture.source), "worker")
    }
  }

  func testShellRejectsWritableAncestors() throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777], ofItemAtPath: fixture.library.path)
    let result = try evaluate(fixture.script)
    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("no group/other write access"), result.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rule.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.helper.path))
  }

  func testFailedValidationAndCopyLeaveInstalledFilesIntact() throws {
    for validationFailure in [true, false] {
      let fixture = try InstallFixture()
      defer { fixture.remove() }
      XCTAssertEqual(try evaluate(fixture.script).status, 0)
      try Data("replacement".utf8).write(to: fixture.source)
      let script: String
      if validationFailure {
        script = fixture.script.replacingOccurrences(of: "/usr/sbin/visudo", with: "/usr/bin/false")
      } else {
        try FileManager.default.removeItem(at: fixture.source)
        script = fixture.script
      }
      let result = try evaluate(script)
      XCTAssertNotEqual(result.status, 0, result.output)
      XCTAssertEqual(try String(contentsOf: fixture.helper), "worker")
      XCTAssertEqual(try String(contentsOf: fixture.rule), fixture.contents)
      try fixture.assertNoTemporaryFiles()
    }
  }

  func testFailedRuleRenameRemovesOnlyANewlyInstalledHelper() throws {
    for installed in [false, true] {
      let fixture = try InstallFixture()
      defer { fixture.remove() }
      if installed { XCTAssertEqual(try evaluate(fixture.script).status, 0) }
      let script = fixture.script.replacingOccurrences(
        of: #"/bin/mv -f "$rule_tmp" "$rule""#, with: "/usr/bin/false")
      let result = try evaluate(script)
      XCTAssertNotEqual(result.status, 0, result.output)
      XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.helper.path), installed)
      XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.rule.path), installed)
      if installed {
        XCTAssertEqual(try String(contentsOf: fixture.helper), "worker")
        XCTAssertEqual(try String(contentsOf: fixture.rule), fixture.contents)
      }
      try fixture.assertNoTemporaryFiles()
    }
  }
}

private struct InstallFixture {
  let directory: URL
  let library: URL
  let source: URL
  let rule: URL
  let helper: URL
  let contents: String
  let script: String

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    library = directory.appendingPathComponent("Library")
    source = directory.appendingPathComponent("awaken")
    rule = directory.appendingPathComponent("sudoers.d/awaken")
    helper = library.appendingPathComponent("PrivilegedHelperTools/awaken")
    let user = try XCTUnwrap(getpwuid(getuid()))
    let account = String(cString: user.pointee.pw_name)
    contents = try Installer.rule(user: account).replacingOccurrences(
      of: "/Library", with: library.path)
    // Keep the real shell operations; substitute sudo, root ownership and paths inside this fixture.
    script = try Installer.setupScript(executable: source.path, user: account)
      .replacingOccurrences(of: "/usr/bin/sudo -- /bin/sh", with: "/bin/sh")
      .replacingOccurrences(of: "root_uid=0", with: "root_uid=\(geteuid())")
      .replacingOccurrences(of: "/usr/sbin/chown", with: "/usr/bin/true")
      .replacingOccurrences(of: "/usr/bin/pgrep", with: "/usr/bin/false")
      .replacingOccurrences(of: "/Library", with: library.path)
      .replacingOccurrences(
        of: "/private/etc/sudoers.d", with: rule.deletingLastPathComponent().path
      )
      .replacingOccurrences(of: #"if [ "$1" != / ]"#, with: "if [ \"$1\" != '\(directory.path)' ]")
    guard !script.contains("/usr/bin/sudo") else { throw Failure("fixture must never invoke sudo") }
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: rule.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("worker".utf8).write(to: source)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }

  func permissions(_ file: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
  }

  func assertNoTemporaryFiles() throws {
    let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
    XCTAssertFalse(
      paths.contains { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".awaken-") })
  }
}
