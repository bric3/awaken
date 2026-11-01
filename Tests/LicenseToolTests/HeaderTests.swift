// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest

@testable import LicenseTool

final class HeaderTests: XCTestCase {
  func testSwiftAndWorkflowNoticesAreIdempotent() throws {
    for (file, prefix) in [("App.swift", "//"), ("release.yml", "#"), ("Makefile", "#")] {
      let original = "// Copyright somebody\nlet name = \"é\"\n"
      let result = try Headers.applying(to: original, filename: file)
      XCTAssertEqual(result, prefix + " SPDX-License-Identifier: MPL-2.0\n\n" + original)
      XCTAssertEqual(try Headers.applying(to: result, filename: file), result)
    }
  }

  func testManifestDirectiveStaysFirst() throws {
    let original = "// swift-tools-version: 5.9\nimport PackageDescription\n"
    let result = try Headers.applying(to: original, filename: "Package.swift")
    XCTAssertEqual(
      result,
      "// swift-tools-version: 5.9\n// SPDX-License-Identifier: MPL-2.0\n\nimport PackageDescription\n"
    )
    XCTAssertEqual(try Headers.applying(to: result, filename: "Package.swift"), result)
    let crlf = original.replacingOccurrences(of: "\n", with: "\r\n")
    XCTAssertEqual(
      try Headers.applying(to: crlf, filename: "Package.swift"),
      result.replacingOccurrences(of: "\n", with: "\r\n"))
  }

  func testConflictingNoticeIsPreserved() {
    XCTAssertThrowsError(
      try Headers.applying(to: "// SPDX-License-Identifier: MIT\n", filename: "App.swift"))
    XCTAssertThrowsError(
      try Headers.applying(
        to: "// SPDX-License-Identifier: MPL-2.0\n// SPDX-License-Identifier: MIT\n",
        filename: "App.swift"))
  }

  func testCheckDoesNotWriteAndApplySkipsArtifactsAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let manager = FileManager.default
    defer { try? manager.removeItem(at: root) }
    for path in ["Sources", "Tests", "Tools", "Plugins", ".github/workflows", ".build", "dist"] {
      try manager.createDirectory(
        at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    for file in [
      "Package.swift", "Makefile", "Sources/App.swift", ".github/workflows/ci.yml",
      ".build/Generated.swift", "dist/Generated.swift",
    ] {
      try "original\n".write(
        to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
    try manager.createSymbolicLink(
      at: root.appendingPathComponent("Sources/Link.swift"),
      withDestinationURL: root.appendingPathComponent("dist/Generated.swift"))
    XCTAssertEqual(try Headers.run(in: root, check: true).count, 4)
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("Sources/App.swift")), "original\n")
    let conflicting = root.appendingPathComponent("Tools/Other.swift")
    try "// SPDX-License-Identifier: MIT\n".write(
      to: conflicting, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try Headers.run(in: root, check: false))
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("Sources/App.swift")), "original\n")
    try manager.removeItem(at: conflicting)
    XCTAssertEqual(try Headers.run(in: root, check: false).count, 4)
    XCTAssertTrue(try Headers.run(in: root, check: true).isEmpty)
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("dist/Generated.swift")), "original\n")
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent(".build/Generated.swift")), "original\n")
  }
}
