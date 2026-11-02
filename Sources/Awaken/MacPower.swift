// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

func continuousNanoseconds() -> UInt64 {
  // Darwin's raw monotonic clock includes sleep and ignores wall-clock adjustments.
  clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}

func writeTerminalStatus(_ text: String) {
  guard let path = ttyname(STDOUT_FILENO) else { return }
  // A separate descriptor keeps terminal flow control from delaying expiry or changing stdout's flags.
  let descriptor = open(path, O_WRONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { return }
  defer { close(descriptor) }
  text.utf8CString.withUnsafeBufferPointer {
    _ = write(descriptor, $0.baseAddress, $0.count - 1)
  }
}

final class Cancellation {
  private let lock = NSLock()
  private var received: Int32 = 0
  private var sources: [DispatchSourceSignal] = []

  init() {
    for number in [SIGINT, SIGTERM, SIGHUP] {
      // exec resets caught handlers, so sudo can still handle and forward signals.
      signal(number) { _ in }
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { [weak self] in
        guard let self else { return }
        self.lock.lock()
        self.received = number
        self.lock.unlock()
      }
      source.resume()
      sources.append(source)
    }
    signal(SIGPIPE, SIG_IGN)
  }

  var signalNumber: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  deinit {
    for source in sources { source.cancel() }
  }
}

func runCommand(_ path: String, _ arguments: [String], timeout: UInt64 = 5) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  let deadline = Deadline(seconds: timeout, now: continuousNanoseconds())
  while process.isRunning, !deadline.expired(at: continuousNanoseconds()) {
    Thread.sleep(forTimeInterval: 0.02)
  }
  if process.isRunning {
    // Do not leave a timed-out pmset able to apply its change after cleanup.
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
    throw Failure("\(path) \(arguments.joined(separator: " ")) timed out")
  }
  guard process.terminationStatus == 0 else {
    throw Failure(
      "\(path) \(arguments.joined(separator: " ")) failed (status \(process.terminationStatus))")
  }
}

final class MacPower {
  private let assertions = PowerAssertions()
  private let root: io_registry_entry_t

  init() throws {
    root = IORegistryEntryFromPath(kIOMainPortDefault, "IOPower:/IOPowerConnection/IOPMrootDomain")
    guard root != 0 else { throw Failure("cannot access IOPMrootDomain") }
  }

  deinit { IOObjectRelease(root) }

  func property(_ key: String) throws -> Bool {
    guard
      let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue(),
      CFGetTypeID(value) == CFBooleanGetTypeID(), let result = value as? Bool
    else {
      throw Failure("cannot read power setting \(key)")
    }
    return result
  }

  func checkSafety() throws {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else {
      throw Failure("battery information is unavailable")
    }
    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
          as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
      else { continue }
      guard let current = description[kIOPSCurrentCapacityKey] as? Double,
        let maximum = description[kIOPSMaxCapacityKey] as? Double,
        maximum > 0
      else { throw Failure("battery capacity is unavailable") }
      try Safety(
        batteryPercent: current / maximum * 100, thermal: ProcessInfo.processInfo.thermalState
      ).check()
      return
    }
    throw Failure("ignore-lid mode requires a Mac with a readable internal battery")
  }

  func session(preventScreensaver: Bool = false, cancelled: @escaping () throws -> Bool) -> Session
  {
    Session(
      cancelled: cancelled,
      acquire: { try self.assertions.acquire(preventScreensaver: preventScreensaver) },
      release: assertions.release,
      refreshActivity: { if preventScreensaver { try self.assertions.refreshActivity() } },
      sleepDisabled: { try self.property("SleepDisabled") },
      setSleepDisabled: {
        try runCommand("/usr/bin/pmset", ["-a", "disablesleep", $0 ? "1" : "0"])
      },
      checkSafety: checkSafety,
      lidClosed: { try self.property("AppleClamshellState") },
      sleepNow: { try runCommand("/usr/bin/pmset", ["sleepnow"]) }
    )
  }
}

final class SessionLock {
  private let descriptor: Int32

  init(path: String = "/private/var/run/awaken.lock", owner: uid_t = 0) throws {
    descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw Failure("cannot open session lock") }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == owner,
      info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
      info.st_nlink == 1
    else {
      close(descriptor)
      throw Failure("session lock has unsafe ownership or permissions")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw Failure("another ignore-lid session is running")
    }
  }

  // Keep the file: unlinking it allows a second process to lock a different inode.
  deinit { close(descriptor) }
}

enum ControlPipe {
  enum Disconnected: Error { case foreground }

  static func readByte(_ descriptor: Int32, wait: Int32) throws -> UInt8? {
    var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
    let result = poll(&event, 1, wait)
    if result < 0, errno == EINTR { return nil }
    guard result >= 0, event.revents & Int16(POLLERR | POLLNVAL) == 0 else {
      throw Failure("control pipe failed")
    }
    if result == 0 { return nil }
    var byte: UInt8 = 0
    let count = read(descriptor, &byte, 1)
    if count < 0, errno == EINTR { return nil }
    if count == 0 { throw Disconnected.foreground }
    guard count == 1 else { throw Failure("cannot read control pipe") }
    return byte
  }

  static func request(_ descriptor: Int32, cancellation: Cancellation) throws -> WorkerRequest {
    var bytes: [UInt8] = []
    let deadline = Deadline(seconds: 10, now: continuousNanoseconds())
    while !deadline.expired(at: continuousNanoseconds()), cancellation.signalNumber == 0 {
      guard let byte = try readByte(descriptor, wait: 100) else { continue }
      if byte == 10 {
        return try WorkerRequest.parse(String(decoding: bytes, as: UTF8.self))
      }
      guard bytes.count < 64, (32...126).contains(byte) else {
        throw Failure("invalid worker request")
      }
      bytes.append(byte)
    }
    throw Failure("worker input timed out or was cancelled")
  }

  static func disconnected(_ descriptor: Int32) throws -> Bool {
    do {
      if try readByte(descriptor, wait: 0) != nil {
        throw Failure("unexpected worker input")
      }
      return false
    } catch Disconnected.foreground {
      return true
    }
  }
}

struct WorkerRequest: Equatable {
  // Bump this when requests or startup handshakes become incompatible.
  static let protocolVersion = 3
  let seconds: UInt64
  let showCountdown: Bool
  let preventScreensaver: Bool

  var message: String {
    "AWAKEN/\(Self.protocolVersion) \(seconds) \(showCountdown ? 1 : 0) \(preventScreensaver ? 1 : 0)\n"
  }

  static func parse(_ line: String) throws -> WorkerRequest {
    let fields = line.split(separator: " ", omittingEmptySubsequences: false)
    guard fields.first == "AWAKEN/\(Self.protocolVersion)" else {
      throw Failure("incompatible worker; refresh with eval \"$(awaken sudoers)\"")
    }
    guard fields.count == 4, ["0", "1"].contains(fields[2]), ["0", "1"].contains(fields[3]) else {
      throw Failure("invalid worker request")
    }
    return WorkerRequest(
      seconds: try Options.duration(String(fields[1])),
      showCountdown: fields[2] == "1", preventScreensaver: fields[3] == "1"
    )
  }
}
