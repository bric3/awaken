import Foundation
import XCTest

@testable import Versioning

final class VersionTests: XCTestCase {
  func testSemverOrderingAndValidation() throws {
    let ordered = try ["0.1.0-alpha.1", "0.1.0-rc.2", "0.1.0-rc.10", "0.1.0", "0.1.1", "1.0.0"].map(
      Version.init)
    XCTAssertEqual(ordered.sorted(), ordered)
    XCTAssertEqual(try Version.tag("v0.1.0-rc.1").nextSnapshot, "0.1.1-SNAPSHOT")
    for invalid in ["0.1", "01.1.0", "0.1.0-01", "0.1.0-SNAPSHOT", "0.1.0\n", "-1.0.0"] {
      XCTAssertThrowsError(try Version(invalid))
    }
  }

  func testSourceVersionsAcrossTagsCommitsAndDirtyFiles() throws {
    let repo = try GitFixture()
    defer { repo.remove() }
    XCTAssertEqual(try repo.version(), "0.1.0-SNAPSHOT")
    try repo.commit()
    try repo.git(["tag", "v0.1.0-rc.1"])
    XCTAssertEqual(try repo.version(), "0.1.0-rc.1")
    XCTAssertEqual(try repo.version(snapshot: true), "0.1.1-SNAPSHOT")
    try repo.git(["tag", "v0.1.0"])
    XCTAssertEqual(try repo.version(), "0.1.0")
    XCTAssertEqual(try repo.version(tag: "v0.1.0-rc.1"), "0.1.0-rc.1")
    try "dirty".write(toFile: repo.path + "/untracked", atomically: true, encoding: .utf8)
    XCTAssertEqual(try repo.version(), "0.1.1-SNAPSHOT")
    XCTAssertThrowsError(try repo.version(tag: "v0.1.0"))
    try repo.git(["add", "untracked"])
    try repo.commit()
    XCTAssertEqual(try repo.version(), "0.1.1-SNAPSHOT")
    XCTAssertThrowsError(try repo.version(tag: "v0.1.0"))
  }

  func testVersionWithoutGitAndUnreachableTags() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .path
    XCTAssertEqual(try SourceVersion.resolve(directory: directory), "0.1.0-SNAPSHOT")
    XCTAssertThrowsError(try SourceVersion.resolve(directory: directory, releaseTag: "v0.1.0"))
    let repo = try GitFixture()
    defer { repo.remove() }
    try repo.commit()
    try repo.git(["tag", "v0.1.0"])
    try repo.git(["checkout", "-b", "other"])
    try repo.commit()
    try repo.git(["tag", "v9.0.0"])
    try repo.git(["checkout", "master"])
    XCTAssertEqual(try repo.version(snapshot: true), "0.1.1-SNAPSHOT")
  }
}

final class GitFixture {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  init() throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try git(["init", "-b", "master"])
    try git(["config", "user.name", "Awaken tests"])
    try git(["config", "user.email", "tests@example.invalid"])
    try git(["config", "commit.gpgsign", "false"])
    try git(["config", "tag.gpgsign", "false"])
    try git(["config", "core.hooksPath", "/dev/null"])
  }
  func git(_ arguments: [String]) throws {
    _ = try Command.run("/usr/bin/git", ["-C", path] + arguments)
  }
  func commit() throws { try git(["commit", "--allow-empty", "-m", "test: version fixture"]) }
  func version(tag: String? = nil, snapshot: Bool = false) throws -> String {
    try SourceVersion.resolve(directory: path, releaseTag: tag, snapshot: snapshot)
  }
  func remove() { try? FileManager.default.removeItem(atPath: path) }
}
