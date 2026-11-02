// SPDX-License-Identifier: MPL-2.0

import XCTest

@testable import ReleaseTool

final class ReleaseTests: XCTestCase {
  func testReleaseTagAndPrereleaseCheckboxMustMatch() throws {
    try ReleaseTool.validate(tag: "v0.1.0-rc.1", prerelease: "true")
    try ReleaseTool.validate(tag: "v0.1.0", prerelease: "false")
    XCTAssertThrowsError(try ReleaseTool.validate(tag: "v0.1.0", prerelease: "true"))
    XCTAssertThrowsError(try ReleaseTool.validate(tag: "v0.1.0-rc.1", prerelease: "false"))
  }

  func testInvalidReleaseInputsAreRejected() {
    for tag in ["untagged-placeholder", "0.1.0", "v0.1.0-SNAPSHOT", "v01.1.0", "v0.1.0\n"] {
      XCTAssertThrowsError(try ReleaseTool.validate(tag: tag, prerelease: "false"))
    }
    XCTAssertThrowsError(try ReleaseTool.validate(tag: "v0.1.0", prerelease: "yes"))
  }
}
