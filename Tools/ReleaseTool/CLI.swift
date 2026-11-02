// SPDX-License-Identifier: MPL-2.0

import Foundation
import Versioning

@main
enum ReleaseTool {
  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      let environment = ProcessInfo.processInfo.environment
      if arguments.first == "validate", arguments.count == 3 {
        guard ["true", "false"].contains(arguments[2]) else {
          throw ToolError("invalid prerelease flag")
        }
        let version = try Version.tag(arguments[1]).description
        try ReleaseCoordinator.validateRelease(
          tag: arguments[1], prerelease: arguments[2] == "true", version: version)
        return
      }
      guard arguments.count == 2, let repository = environment["GH_REPO"],
        repository.range(of: #"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z"#, options: .regularExpression)
          != nil
      else {
        throw ToolError("expected draft|publish ASSET_DIRECTORY and GH_REPO=owner/repository")
      }
      let coordinator = ReleaseCoordinator(
        repository: repository,
        request: { method, path, fields in
          var args = ["gh", "api", "--method", method, path]
          if fields != nil { args += ["--input", "-"] }
          return try Command.run(
            "/usr/bin/env", args,
            input: fields.map { try JSONSerialization.data(withJSONObject: $0) })
        },
        upload: { id, path in
          let file = URL(fileURLWithPath: path)
          guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw ToolError("cannot read release asset size: \(path)")
          }
          var url = URLComponents(
            string: "https://uploads.github.com/repos/\(repository)/releases/\(id)/assets")
          url?.queryItems = [
            URLQueryItem(name: "name", value: file.lastPathComponent)
          ]
          guard let endpoint = url?.url?.absoluteString else {
            throw ToolError("invalid release upload URL")
          }
          _ = try Command.run(
            "/usr/bin/env",
            [
              "gh", "api", "--method", "POST", endpoint, "--input", path,
              "--header", "Content-Type: application/octet-stream",
              "--header", "Content-Length: \(size)",
            ])
        })
      let binary = arguments[1] + "/awaken-macos-universal"
      let result = try Command.run(binary, ["--version"])
      let text = String(decoding: result, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard text.hasPrefix("awaken ") else { throw ToolError("invalid binary version output") }
      let version = String(text.dropFirst("awaken ".count))
      switch arguments[0] {
      case "draft":
        guard let sha = environment["GITHUB_SHA"] else { throw ToolError("missing GITHUB_SHA") }
        try coordinator.updateDraft(version: version, sha: sha, directory: arguments[1])
      case "publish":
        guard let event = environment["GITHUB_EVENT_PATH"] else {
          throw ToolError("missing GITHUB_EVENT_PATH")
        }
        struct Event: Decodable { let release: Release }
        let release = try JSONDecoder().decode(
          Event.self, from: Data(contentsOf: URL(fileURLWithPath: event))
        ).release
        try coordinator.publish(
          id: release.id, tag: release.tagName, prerelease: release.prerelease, version: version,
          directory: arguments[1])
      default: throw ToolError("unknown release operation")
      }
    } catch {
      FileHandle.standardError.write(Data("release: \(error)\n".utf8))
      exit(1)
    }
  }
}
