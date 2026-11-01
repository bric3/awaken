import Foundation
import IOKit.pwr_mgt

final class PowerAssertions {
  private let create: (CFString, inout IOPMAssertionID) -> IOReturn
  private let declareActivity: (inout IOPMAssertionID) -> IOReturn
  private let releaseAssertion: (IOPMAssertionID) -> IOReturn
  private var assertions: [IOPMAssertionID] = []
  private var activity: IOPMAssertionID = 0

  init(
    create: @escaping (CFString, inout IOPMAssertionID) -> IOReturn = {
      IOPMAssertionCreateWithName(
        $0, IOPMAssertionLevel(kIOPMAssertionLevelOn), "awaken" as CFString, &$1)
    },
    declareActivity: @escaping (inout IOPMAssertionID) -> IOReturn = {
      IOPMAssertionDeclareUserActivity("awaken" as CFString, kIOPMUserActiveLocal, &$0)
    },
    release: @escaping (IOPMAssertionID) -> IOReturn = IOPMAssertionRelease
  ) {
    self.create = create
    self.declareActivity = declareActivity
    self.releaseAssertion = release
  }

  func acquire(preventScreensaver: Bool) throws {
    do {
      var types = [kIOPMAssertPreventUserIdleSystemSleep as CFString]
      if preventScreensaver { types.append(kIOPMAssertPreventUserIdleDisplaySleep as CFString) }
      for type in types {
        var assertion: IOPMAssertionID = 0
        guard create(type, &assertion) == kIOReturnSuccess else {
          throw Failure("cannot create \(type) assertion")
        }
        assertions.append(assertion)
      }
      if preventScreensaver { try refreshActivity() }
    } catch {
      do { try release() } catch let cleanup {
        throw Failure("assertion acquisition failed: \(error); cleanup failed: \(cleanup)")
      }
      throw error
    }
  }

  func refreshActivity() throws {
    // Reuse the returned ID: IOKit may replace an expired user-activity assertion.
    guard declareActivity(&activity) == kIOReturnSuccess else {
      throw Failure("cannot declare user activity for screensaver prevention")
    }
  }

  func release() throws {
    var failed = false
    if activity != 0 {
      failed = releaseAssertion(activity) != kIOReturnSuccess
      activity = 0
    }
    for assertion in assertions {
      if releaseAssertion(assertion) != kIOReturnSuccess { failed = true }
    }
    assertions.removeAll()
    if failed { throw Failure("cannot release power assertions") }
  }
}
