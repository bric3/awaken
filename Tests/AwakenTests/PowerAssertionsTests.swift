import Foundation
import IOKit.pwr_mgt
import XCTest

@testable import Awaken

final class PowerAssertionsTests: XCTestCase {
  func testOrdinaryModeOnlyHoldsIdleSleepAssertion() throws {
    let fake = FakeAssertions()
    let assertions = fake.assertions()
    try assertions.acquire(preventScreensaver: false)
    try assertions.release()
    XCTAssertEqual(fake.types, [kIOPMAssertPreventUserIdleSystemSleep as String])
    XCTAssertEqual(fake.activityInputs, [])
    XCTAssertEqual(fake.released, [1])
  }

  func testScreensaverModeHoldsDisplayAndUserActivityAssertions() throws {
    let fake = FakeAssertions()
    let assertions = fake.assertions()
    try assertions.acquire(preventScreensaver: true)
    try assertions.refreshActivity()
    try assertions.release()
    try assertions.release()
    XCTAssertEqual(
      fake.types,
      [
        kIOPMAssertPreventUserIdleSystemSleep as String,
        kIOPMAssertPreventUserIdleDisplaySleep as String,
      ])
    XCTAssertEqual(fake.activityInputs, [0, 3])
    XCTAssertEqual(fake.released, [3, 1, 2])
  }

  func testRenewalTracksAReplacementAssertionID() throws {
    let fake = FakeAssertions()
    let assertions = fake.assertions()
    try assertions.acquire(preventScreensaver: true)
    fake.activityID = 4
    try assertions.refreshActivity()
    try assertions.release()
    XCTAssertEqual(fake.released, [4, 1, 2])
  }

  func testPartialAcquisitionFailuresReleaseEveryAcquiredAssertion() {
    for failActivity in [false, true] {
      let fake = FakeAssertions()
      fake.failDisplay = !failActivity
      fake.failActivity = failActivity
      let assertions = fake.assertions()
      XCTAssertThrowsError(try assertions.acquire(preventScreensaver: true))
      XCTAssertEqual(fake.released, failActivity ? [1, 2] : [1])
    }
  }

  func testReleaseFailureStillAttemptsAllAssertions() throws {
    let fake = FakeAssertions()
    let assertions = fake.assertions()
    try assertions.acquire(preventScreensaver: true)
    fake.failRelease = true
    XCTAssertThrowsError(try assertions.release())
    XCTAssertEqual(fake.released, [3, 1, 2])
  }
}

private final class FakeAssertions {
  var types: [String] = []
  var activityInputs: [IOPMAssertionID] = []
  var released: [IOPMAssertionID] = []
  var activityID: IOPMAssertionID = 3
  var failDisplay = false
  var failActivity = false
  var failRelease = false

  func assertions() -> PowerAssertions {
    PowerAssertions(
      create: { type, id in
        self.types.append(type as String)
        if self.failDisplay, self.types.count == 2 { return kIOReturnError }
        id = IOPMAssertionID(self.types.count)
        return kIOReturnSuccess
      },
      declareActivity: { id in
        self.activityInputs.append(id)
        if self.failActivity { return kIOReturnError }
        id = self.activityID
        return kIOReturnSuccess
      },
      release: { id in
        self.released.append(id)
        return self.failRelease ? kIOReturnError : kIOReturnSuccess
      }
    )
  }
}
