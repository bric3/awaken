import Foundation
import XCTest

@testable import ReleaseTool

final class ReleaseTests: XCTestCase {
  func testReleaseTagCheckboxAndBinaryMustMatch() throws {
    try ReleaseCoordinator.validateRelease(
      tag: "v0.1.0-rc.1", prerelease: true, version: "0.1.0-rc.1")
    try ReleaseCoordinator.validateRelease(tag: "v0.1.0", prerelease: false, version: "0.1.0")
    XCTAssertThrowsError(
      try ReleaseCoordinator.validateRelease(tag: "v0.1.0", prerelease: true, version: "0.1.0"))
    XCTAssertThrowsError(
      try ReleaseCoordinator.validateRelease(
        tag: "v0.1.0-rc.1", prerelease: false, version: "0.1.0-rc.1"))
    XCTAssertThrowsError(
      try ReleaseCoordinator.validateRelease(
        tag: "v0.1.0", prerelease: false, version: "0.1.1-SNAPSHOT"))
  }

  func testDraftCreationAndUserNotesPreservedOnUpdate() throws {
    let github = FakeGitHub()
    try github.updateDraft()
    XCTAssertEqual(github.releases.count, 1)
    XCTAssertEqual(github.releases[0]["tag_name"] as? String, "v0.1.0")
    XCTAssertEqual(github.patches[0]["target_commitish"] as? String, "current")
    XCTAssertEqual(
      github.uploads[0].1,
      ["/dist/awaken-macos-universal-SNAPSHOT", "/dist/awaken-macos-universal-SNAPSHOT.sha256"])
    github.patches = []
    github.releases[0]["tag_name"] = "v0.2.0-rc.1"
    github.releases[0]["body"] =
      "User notes\n" + (github.releases[0]["body"] as! String) + "\nMore notes"
    try github.updateDraft()
    let body = try XCTUnwrap(github.patches[0]["body"] as? String)
    XCTAssertTrue(body.hasPrefix("User notes\n"))
    XCTAssertTrue(body.hasSuffix("\nMore notes"))
    XCTAssertNil(github.patches[0]["tag_name"])
    XCTAssertNil(github.patches[0]["name"])
    XCTAssertEqual(github.uploads.last?.0, "v0.2.0-rc.1")
  }

  func testUnrelatedDraftIsPreserved() throws {
    let github = FakeGitHub()
    github.releases = [github.release(tag: "v2.0.0", body: "Manual notes")]
    try github.updateDraft()
    XCTAssertEqual(github.releases.count, 2)
    XCTAssertEqual(github.releases[0]["body"] as? String, "Manual notes")
  }

  func testStaleBuildAndPublishedDraftDoNotWrite() throws {
    let github = FakeGitHub()
    try github.coordinator().updateDraft(version: "0.1.0-SNAPSHOT", sha: "old", directory: "/dist")
    XCTAssertTrue(github.releases.isEmpty)
    github.releases = [
      github.release(body: try DraftNotes.update(nil, version: "0.1.0-SNAPSHOT", sha: "old"))
    ]
    github.publishedDuringRead = true
    try github.updateDraft()
    XCTAssertTrue(github.patches.isEmpty)
    XCTAssertTrue(github.uploads.isEmpty)
  }

  func testExistingTagCannotBeRetargeted() throws {
    let github = FakeGitHub()
    github.existingTag = true
    github.releases = [
      github.release(body: try DraftNotes.update(nil, version: "0.1.0-SNAPSHOT", sha: "old"))
    ]
    try github.updateDraft()
    XCTAssertTrue(github.patches.isEmpty)
    XCTAssertTrue(github.uploads.isEmpty)
  }

  func testFailedDraftUploadLeavesDraftAvailable() throws {
    let github = FakeGitHub()
    github.failUpload = true
    XCTAssertThrowsError(try github.updateDraft())
    XCTAssertEqual(github.releases[0]["draft"] as? Bool, true)
  }

  func testFinalUploadCleansSnapshotAssetsOnlyAfterSuccess() throws {
    let github = FakeGitHub()
    var release = github.release(body: "Release notes", draft: false)
    release["assets"] = [
      ["id": 10, "name": "awaken-macos-universal-SNAPSHOT"], ["id": 11, "name": "user-file"],
    ]
    github.releases = [release]
    try github.coordinator().publish(
      id: 1, tag: "v0.1.0", prerelease: false, version: "0.1.0", directory: "/dist")
    XCTAssertEqual(
      github.uploads[0].1, ["/dist/awaken-macos-universal", "/dist/awaken-macos-universal.sha256"])
    XCTAssertEqual(github.deleted, ["repos/test/repo/releases/assets/10"])
    XCTAssertTrue(github.patches.isEmpty)
    github.deleted = []
    github.failUpload = true
    XCTAssertThrowsError(
      try github.coordinator().publish(
        id: 1, tag: "v0.1.0", prerelease: false, version: "0.1.0", directory: "/dist"))
    XCTAssertTrue(github.deleted.isEmpty)
  }

  func testMalformedAndAmbiguousDraftMarkersFail() throws {
    XCTAssertThrowsError(try DraftNotes.update(DraftNotes.start, version: "x", sha: "y"))
    let github = FakeGitHub()
    let notes = try DraftNotes.update(nil, version: "0.1.0-SNAPSHOT", sha: "old")
    github.releases = [github.release(body: notes), github.release(tag: "v0.2.0", body: notes)]
    XCTAssertThrowsError(try github.updateDraft())
    XCTAssertTrue(github.uploads.isEmpty)
  }
}

private final class FakeGitHub {
  var releases: [[String: Any]] = []
  var patches: [[String: Any]] = []
  var uploads: [(String, [String])] = []
  var deleted: [String] = []
  var publishedDuringRead = false
  var existingTag = false
  var failUpload = false

  func release(tag: String = "v0.1.0", body: String, draft: Bool = true) -> [String: Any] {
    ["id": 1, "tag_name": tag, "draft": draft, "prerelease": false, "body": body, "assets": []]
  }

  func updateDraft() throws {
    try coordinator().updateDraft(version: "0.1.0-SNAPSHOT", sha: "current", directory: "/dist")
  }

  func coordinator() -> ReleaseCoordinator {
    ReleaseCoordinator(
      repository: "test/repo",
      request: { method, path, fields in
        var result: Any = [:]
        if path.hasSuffix("branches/master") {
          result = ["commit": ["sha": "current"]]
        } else if path.contains("matching-refs") {
          result = self.existingTag ? [["ref": "refs/tags/v0.1.0"]] : []
        } else if method == "POST" {
          var release = fields!
          release["id"] = self.releases.count + 1
          release["assets"] = []
          release["prerelease"] = false
          self.releases.append(release)
          result = release
        } else if method == "PATCH" {
          self.patches.append(fields!)
          result = self.releases.last!
        } else if method == "DELETE" {
          self.deleted.append(path)
        } else if path.contains("?per_page") {
          result = self.releases
        } else {
          var release = self.releases.last!
          if self.publishedDuringRead { release["draft"] = false }
          result = release
        }
        return try JSONSerialization.data(withJSONObject: result)
      },
      upload: { tag, paths in
        if self.failUpload { throw NSError(domain: "test", code: 1) }
        self.uploads.append((tag, paths))
      }, report: { _ in })
  }
}
