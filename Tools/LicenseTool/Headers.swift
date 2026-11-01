// SPDX-License-Identifier: MPL-2.0

import Foundation

struct HeaderError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

enum Headers {
  static func applying(to text: String, filename: String) throws -> String {
    let prefix = filename.hasSuffix(".swift") ? "//" : "#"
    let notice = prefix + " SPDX-License-Identifier: MPL-2.0"
    let comments = text.components(separatedBy: .newlines).prefix(20)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix(prefix) }
    guard !comments.contains(where: { $0.contains("SPDX-License-Identifier:") && $0 != notice })
    else {
      throw HeaderError("conflicting SPDX licence in \(filename)")
    }
    if comments.contains(notice) { return text }
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    if filename == "Package.swift", text.hasPrefix("// swift-tools-version:") {
      guard let end = text.range(of: newline) else { return text + newline + notice + newline }
      return String(text[..<end.upperBound]) + notice + newline + newline
        + String(text[end.upperBound...])
    }
    return notice + newline + newline + text
  }

  static func files(in root: URL) throws -> [URL] {
    var files = [
      root.appendingPathComponent("Package.swift"), root.appendingPathComponent("Makefile"),
    ]
    for directory in ["Sources", "Tests", "Tools", "Plugins", ".github"] {
      guard
        let entries = FileManager.default.enumerator(
          at: root.appendingPathComponent(directory),
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles])
      else { throw HeaderError("cannot read \(directory)") }
      for case let file as URL in entries
      where ["swift", "yml", "yaml"].contains(file.pathExtension) {
        files.append(file)
      }
    }
    return try files.filter {
      let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      return values.isRegularFile == true && values.isSymbolicLink != true
    }.sorted { $0.path < $1.path }
  }

  static func run(in root: URL, check: Bool) throws -> [String] {
    // Validate all files before writing, so a conflicting licence leaves the tree unchanged.
    var changes: [(URL, String)] = []
    for file in try files(in: root) {
      let original = try String(contentsOf: file, encoding: .utf8)
      let updated = try applying(to: original, filename: file.lastPathComponent)
      if original != updated { changes.append((file, updated)) }
    }
    if !check {
      for (file, text) in changes { try text.write(to: file, atomically: true, encoding: .utf8) }
    }
    return changes.map { $0.0.path }
  }
}
