// SPDX-License-Identifier: MPL-2.0

import Foundation
import Versioning

@main
enum ReleaseTool {
  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.first == "validate", arguments.count == 3 else {
        throw ToolError("expected validate TAG PRERELEASE")
      }
      try validate(tag: arguments[1], prerelease: arguments[2])
    } catch {
      FileHandle.standardError.write(Data("release: \(error)\n".utf8))
      exit(1)
    }
  }

  static func validate(tag: String, prerelease: String) throws {
    guard ["true", "false"].contains(prerelease) else {
      throw ToolError("invalid prerelease flag")
    }
    let version = try Version.tag(tag)
    guard !version.prerelease.isEmpty == (prerelease == "true") else {
      throw ToolError("prerelease checkbox does not match the tag suffix")
    }
  }
}
