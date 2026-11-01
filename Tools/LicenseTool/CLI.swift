// SPDX-License-Identifier: MPL-2.0

import Foundation

@main
enum LicenseTool {
  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.isEmpty || arguments == ["--check"] else {
        throw HeaderError("usage: LicenseTool [--check]")
      }
      let check = arguments == ["--check"]
      let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let files = try Headers.run(in: root, check: check)
      if check, !files.isEmpty {
        throw HeaderError("missing MPL-2.0 headers:\n" + files.joined(separator: "\n"))
      }
      print(check ? "MPL-2.0 headers verified." : "Added \(files.count) MPL-2.0 headers.")
    } catch {
      FileHandle.standardError.write(Data("licence: \(error)\n".utf8))
      exit(1)
    }
  }
}
