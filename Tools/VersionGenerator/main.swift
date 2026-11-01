// SPDX-License-Identifier: MPL-2.0

import Foundation
import Versioning

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  switch arguments.first {
  case "resolve" where arguments.count == 2:
    let environment = ProcessInfo.processInfo.environment
    let tag = environment["AWAKEN_RELEASE_TAG"].flatMap { $0.isEmpty ? nil : $0 }
    print(
      try SourceVersion.resolve(
        directory: arguments[1], releaseTag: tag, snapshot: environment["AWAKEN_SNAPSHOT"] == "1"))
  case "emit" where arguments.count == 6:
    let tag = arguments[3].isEmpty ? nil : arguments[3]
    let version = try SourceVersion.resolve(
      directory: arguments[1], releaseTag: tag, snapshot: arguments[4] == "1")
    let source = "enum BuildVersion { static let current = \"\(version)\" }\n"
    try source.write(toFile: arguments[5], atomically: true, encoding: .utf8)
  default: throw ToolError("invalid version-generator arguments")
  }
} catch {
  FileHandle.standardError.write(Data("version: \(error)\n".utf8))
  exit(1)
}
