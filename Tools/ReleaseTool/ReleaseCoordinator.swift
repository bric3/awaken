// SPDX-License-Identifier: MPL-2.0

import Foundation
import Versioning

struct Release: Decodable {
  let id: Int
  let tagName: String
  let draft: Bool
  let prerelease: Bool
  let body: String?
  let assets: [Asset]
  enum CodingKeys: String, CodingKey {
    case id, draft, prerelease, body, assets
    case tagName = "tag_name"
  }
  struct Asset: Decodable {
    let id: Int
    let name: String
  }
}

enum DraftNotes {
  static let start = "<!-- awaken:development -->"
  static let end = "<!-- /awaken:development -->"

  static func update(_ body: String?, version: String, sha: String) throws -> String {
    let summary = "\(start)\nDevelopment build: `\(version)` (`\(sha)`).\n\(end)"
    guard let body else { return summary }
    if !body.contains(start), !body.contains(end) {
      return body.isEmpty ? summary : body + "\n\n" + summary
    }
    guard let first = body.range(of: start), let last = body.range(of: end),
      first.upperBound <= last.lowerBound
    else {
      throw ToolError("draft notes have incomplete Awaken markers")
    }
    return body.replacingCharacters(in: first.lowerBound..<last.upperBound, with: summary)
  }
}

struct ReleaseCoordinator {
  let repository: String
  var request: (_ method: String, _ path: String, _ fields: [String: Any]?) throws -> Data
  var upload: (_ id: Int, _ path: String) throws -> Void
  var report: (String) -> Void = { print($0) }

  private func get<T: Decodable>(_ path: String, as: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: request("GET", "repos/\(repository)/\(path)", nil))
  }

  private func release(_ id: Int) throws -> Release { try get("releases/\(id)", as: Release.self) }

  private func uploadAssets(_ id: Int, paths: [String]) throws {
    let assets = try release(id).assets
    for path in paths {
      let name = URL(fileURLWithPath: path).lastPathComponent
      for asset in assets where asset.name == name {
        _ = try request("DELETE", "repos/\(repository)/releases/assets/\(asset.id)", nil)
      }
      // A draft can have a pending tag without a Git ref; upload directly to its release ID.
      try upload(id, path)
    }
  }

  private func isCurrent(_ sha: String) throws -> Bool {
    struct Branch: Decodable {
      struct Commit: Decodable { let sha: String }
      let commit: Commit
    }
    return try get("branches/master", as: Branch.self).commit.sha == sha
  }

  func updateDraft(version: String, sha: String, directory: String) throws {
    guard version.hasSuffix("-SNAPSHOT") else {
      throw ToolError("draft builds require a SNAPSHOT version")
    }
    let tag = "v" + version.dropLast("-SNAPSHOT".count)
    _ = try Version.tag(tag)
    guard try isCurrent(sha) else {
      report("Skipped stale master build.")
      return
    }
    var releases: [Release] = []
    var page = 1
    while true {
      let batch = try get("releases?per_page=100&page=\(page)", as: [Release].self)
      releases += batch
      if batch.count < 100 { break }
      page += 1
    }
    let drafts = releases.filter {
      $0.draft
        && (($0.body ?? "").contains(DraftNotes.start)
          || $0.assets.contains(where: { $0.name == "awaken-macos-universal-SNAPSHOT" }))
    }
    guard drafts.count <= 1 else {
      throw ToolError("multiple managed drafts; keep one Awaken development draft")
    }
    let draft: Release
    if let existing = drafts.first {
      draft = try release(existing.id)
      guard draft.draft else {
        report("Draft was published; skipped update.")
        return
      }
    } else {
      guard !releases.contains(where: { $0.tagName == tag }) else {
        report("Release tag is already in use; waiting for the next master build.")
        return
      }
      let fields: [String: Any] = [
        "tag_name": tag, "target_commitish": sha, "name": "Next release",
        "draft": true, "body": try DraftNotes.update(nil, version: version, sha: sha),
      ]
      draft = try JSONDecoder().decode(
        Release.self, from: request("POST", "repos/\(repository)/releases", fields))
    }
    // Existing tags cannot be retargeted by editing a draft's target_commitish.
    struct Ref: Decodable { let ref: String }
    let selectedTag = draft.tagName.hasPrefix("untagged-") ? tag : draft.tagName
    _ = try Version.tag(selectedTag)
    let refs = try get("git/matching-refs/tags/\(selectedTag)", as: [Ref].self)
    guard !refs.contains(where: { $0.ref == "refs/tags/\(selectedTag)" }) else {
      report("Draft uses an existing Git tag; skipped update to preserve its commit.")
      return
    }
    let latest = try release(draft.id)
    guard try isCurrent(sha), latest.draft, latest.tagName == draft.tagName else {
      report("Draft changed; skipped update.")
      return
    }
    _ = try request(
      "PATCH", "repos/\(repository)/releases/\(draft.id)",
      [
        "tag_name": selectedTag,
        "target_commitish": sha,
        "body": try DraftNotes.update(latest.body, version: version, sha: sha),
      ])
    guard try isCurrent(sha), try release(draft.id).draft else {
      report("Draft changed; skipped upload.")
      return
    }
    // Snapshot assets have distinct names so a concurrent UI publication cannot replace release binaries.
    try uploadAssets(
      draft.id,
      paths: [
        directory + "/awaken-macos-universal-SNAPSHOT",
        directory + "/awaken-macos-universal-SNAPSHOT.sha256",
      ])
  }

  static func validateRelease(tag: String, prerelease: Bool, version: String) throws {
    let parsed = try Version.tag(tag)
    guard !parsed.prerelease.isEmpty == prerelease else {
      throw ToolError("prerelease checkbox does not match the tag suffix")
    }
    guard parsed.description == version else {
      throw ToolError("binary version does not match the release tag")
    }
  }

  func publish(id: Int, tag: String, prerelease: Bool, version: String, directory: String) throws {
    try Self.validateRelease(tag: tag, prerelease: prerelease, version: version)
    let current = try release(id)
    guard !current.draft, current.tagName == tag, current.prerelease == prerelease else {
      throw ToolError("release state changed; rerun from the intended release event")
    }
    try uploadAssets(
      id,
      paths: [directory + "/awaken-macos-universal", directory + "/awaken-macos-universal.sha256"])
    for asset in try release(id).assets
    where ["awaken-macos-universal-SNAPSHOT", "awaken-macos-universal-SNAPSHOT.sha256"].contains(
      asset.name)
    {
      _ = try request("DELETE", "repos/\(repository)/releases/assets/\(asset.id)", nil)
    }
  }
}
