// SPDX-License-Identifier: MPL-2.0

import Foundation

struct Failure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

struct Options: Equatable {
  var ignoreLid = false
  var seconds: UInt64 = 300
  var help = false
  var noCountdown = false
  var preventScreensaver = false
  var version = false

  static func duration(_ text: String) throws -> UInt64 {
    let (number, multiplier): (Substring, UInt64) =
      switch text.last {
      case "s": (text.dropLast(), 1)
      case "m": (text.dropLast(), 60)
      case "h": (text.dropLast(), 3_600)
      case "d": (text.dropLast(), 86_400)
      default: (text[...], 1)
      }
    guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }),
      let amount = UInt64(number), amount > 0,
      amount <= UInt64.max / 1_000_000_000 / multiplier
    else {
      throw Failure(
        "timeout must be a positive whole number with optional s, m, h or d (maximum 18446744073s)")
    }
    return amount * multiplier
  }

  static func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "-l", "--ignore-lid": options.ignoreLid = true
      case "-h", "--help": options.help = true
      case "-V", "--version": options.version = true
      case "-q", "--no-countdown": options.noCountdown = true
      case "-s", "--prevent-screensaver": options.preventScreensaver = true
      case "-t", "--timeout":
        index += 1
        guard index < arguments.count else { throw Failure("missing timeout duration") }
        options.seconds = try duration(arguments[index])
      default: throw Failure("unknown option: \(arguments[index]); see awaken --help")
      }
      index += 1
    }
    return options
  }
}

struct Deadline {
  let start: UInt64
  let nanoseconds: UInt64

  init(seconds: UInt64, now: UInt64) {
    start = now
    nanoseconds = seconds * 1_000_000_000
  }

  func expired(at now: UInt64) -> Bool {
    now &- start >= nanoseconds
  }

  func remainingSeconds(at now: UInt64) -> UInt64 {
    let elapsed = now &- start
    guard elapsed < nanoseconds else { return 0 }
    let remaining = nanoseconds - elapsed
    return remaining / 1_000_000_000 + (remaining % 1_000_000_000 == 0 ? 0 : 1)
  }
}

struct Countdown {
  var write: (String) -> Void
  private var previousSeconds: UInt64?
  private var width = 0

  init(write: @escaping (String) -> Void) {
    self.write = write
  }

  mutating func update(seconds: UInt64) {
    guard seconds != previousSeconds else { return }
    let hours = String(seconds / 3600)
    let minutes = String(format: "%02d", Int(seconds / 60 % 60))
    let remainder = String(format: "%02d", Int(seconds % 60))
    let line =
      "Awake: \(hours.count < 2 ? "0" : "")\(hours):\(minutes):\(remainder) remaining. Ctrl-C to stop."
    write("\r" + line + String(repeating: " ", count: max(0, width - line.count)))
    width = line.count
    previousSeconds = seconds
  }

  func finish() {
    if previousSeconds != nil { write("\n") }
  }
}

struct Safety {
  let batteryPercent: Double
  let thermal: ProcessInfo.ThermalState

  func check() throws {
    guard batteryPercent.isFinite, (0...100).contains(batteryPercent) else {
      throw Failure("battery reading is unavailable")
    }
    guard batteryPercent > 10 else { throw Failure("battery charge is at or below 10%") }
    switch thermal {
    case .nominal, .fair: break
    default: throw Failure("thermal state is serious, critical or unavailable")
    }
  }
}

// Closures keep the safety and cleanup paths testable without changing this Mac's settings.
struct Session {
  var now: () -> UInt64 = continuousNanoseconds
  var cancelled: () throws -> Bool
  var pause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
  var acquire: () throws -> Void
  var release: () throws -> Void
  var refreshActivity: () throws -> Void = {}
  var sleepDisabled: () throws -> Bool
  var setSleepDisabled: (Bool) throws -> Void
  var checkSafety: () throws -> Void
  var lidClosed: () throws -> Bool
  var sleepNow: () throws -> Void
  var report: (String) -> Void = {
    print($0)
    fflush(stdout)
  }
  var writeStatus: (String) -> Void = writeTerminalStatus

  func run(seconds: UInt64, ignoreLid: Bool, showCountdown: Bool = false) throws {
    let deadline = Deadline(seconds: seconds, now: now())
    if try cancelled() { return }
    if ignoreLid {
      guard try !sleepDisabled() else {
        throw Failure("sleep is already disabled; another tool may own the setting")
      }
      _ = try lidClosed()
      try checkSafety()
    }

    try acquire()
    var mustRestore = false
    var failure: Error?
    var countdown = showCountdown ? Countdown(write: writeStatus) : nil
    do {
      if ignoreLid {
        // pmset may change the setting even when its exit status or verification fails.
        mustRestore = true
        try setSleepDisabled(true)
        guard try sleepDisabled() else { throw Failure("could not verify sleep prevention") }
      }
      if !showCountdown {
        report(
          "Awake for up to \(seconds)s\(ignoreLid ? " (lid-close sleep disabled)" : ""). Press Ctrl-C to stop."
        )
      }
      var lastCheck = now()
      countdown?.update(seconds: deadline.remainingSeconds(at: lastCheck))
      while !deadline.expired(at: now()), try !cancelled() {
        let current = now()
        countdown?.update(seconds: deadline.remainingSeconds(at: current))
        if current &- lastCheck >= 1_000_000_000 {
          if ignoreLid {
            try checkSafety()
            guard try sleepDisabled() else {
              throw Failure("sleep prevention was changed by another tool")
            }
          }
          try refreshActivity()
          lastCheck = current
        }
        pause()
      }
    } catch {
      failure = error
    }
    if failure == nil, deadline.expired(at: now()) { countdown?.update(seconds: 0) }
    countdown?.finish()

    var cleanupFailure: Error?
    if mustRestore {
      do {
        try setSleepDisabled(false)
        guard try !sleepDisabled() else { throw Failure("sleep is still disabled") }
      } catch { cleanupFailure = error }
    }
    do { try release() } catch { cleanupFailure = cleanupFailure ?? error }

    if mustRestore, cleanupFailure == nil {
      report("Normal sleep restored.")
      do {
        if try lidClosed() { try sleepNow() }
      } catch { cleanupFailure = error }
    }
    if let error = cleanupFailure {
      throw Failure(
        "cleanup failed: \(error). Run: sudo pmset -a disablesleep 0\(failure.map { "; session error: \($0)" } ?? "")"
      )
    }
    if let error = failure { throw error }
  }
}
