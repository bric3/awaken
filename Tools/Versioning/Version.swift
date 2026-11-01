import Foundation

public struct ToolError: Error, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}

public struct Version: Equatable, Comparable, CustomStringConvertible {
  public let major: UInt64
  public let minor: UInt64
  public let patch: UInt64
  public let prerelease: [String]
  public let description: String

  public init(_ text: String) throws {
    let pattern =
      #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z"#
    guard text.range(of: pattern, options: .regularExpression) != nil else {
      throw ToolError("invalid version: \(text); expected X.Y.Z or X.Y.Z-prerelease")
    }
    let parts = text.split(separator: "-", maxSplits: 1)
    let numbers = parts[0].split(separator: ".").compactMap { UInt64($0) }
    guard numbers.count == 3 else { throw ToolError("version number overflow: \(text)") }
    major = numbers[0]
    minor = numbers[1]
    patch = numbers[2]
    prerelease = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
    for part in prerelease where part.utf8.allSatisfy({ (48...57).contains($0) }) {
      guard part.count == 1 || !part.hasPrefix("0") else {
        throw ToolError("leading zero in prerelease: \(text)")
      }
    }
    guard !prerelease.contains("SNAPSHOT") else {
      throw ToolError("SNAPSHOT is reserved for development builds")
    }
    description = text
  }

  public static func tag(_ tag: String) throws -> Version {
    guard tag.hasPrefix("v") else { throw ToolError("release tag must start with v") }
    return try Version(String(tag.dropFirst()))
  }

  public var nextSnapshot: String {
    get throws {
      guard patch < UInt64.max else { throw ToolError("patch number overflow") }
      return "\(major).\(minor).\(patch + 1)-SNAPSHOT"
    }
  }

  public static func < (lhs: Version, rhs: Version) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
    if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
      return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
    }
    for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
      let numericA = a.utf8.allSatisfy { (48...57).contains($0) }
      let numericB = b.utf8.allSatisfy { (48...57).contains($0) }
      if numericA != numericB { return numericA }
      if numericA, a.count != b.count { return a.count < b.count }
      return a < b
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }
}

public enum Command {
  public static func run(
    _ executable: String, _ arguments: [String], directory: String? = nil, input: Data? = nil
  ) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    let stdin = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    try process.run()
    output.fileHandleForWriting.closeFile()
    if let input {
      try stdin.fileHandleForWriting.write(contentsOf: input)
      try stdin.fileHandleForWriting.close()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ToolError("\(executable) \(arguments.joined(separator: " ")) failed")
    }
    return data
  }
}

public enum SourceVersion {
  public static func resolve(directory: String, releaseTag: String? = nil, snapshot: Bool = false)
    throws -> String
  {
    func git(_ arguments: [String]) throws -> String {
      String(
        decoding: try Command.run("/usr/bin/git", ["-C", directory] + arguments), as: UTF8.self
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let repository = FileManager.default.fileExists(atPath: directory + "/.git")
    guard repository else {
      if releaseTag != nil { throw ToolError("release builds require a Git checkout") }
      return "0.1.0-SNAPSHOT"
    }
    let dirty = try !git(["status", "--porcelain", "--untracked-files=normal"]).isEmpty
    if let releaseTag, !releaseTag.isEmpty {
      let version = try Version.tag(releaseTag)
      guard !dirty else { throw ToolError("release builds require a clean checkout") }
      guard
        try git(["rev-parse", "HEAD"]) == git(["rev-parse", "refs/tags/\(releaseTag)^{commit}"])
      else {
        throw ToolError("release tag does not identify HEAD")
      }
      return version.description
    }
    guard (try? git(["rev-parse", "--verify", "--quiet", "HEAD"])) != nil else {
      return "0.1.0-SNAPSHOT"
    }
    let tags = try git(["tag", "--merged", "HEAD"]).split(separator: "\n").compactMap {
      try? Version.tag(String($0))
    }
    if !dirty, !snapshot {
      let exact = try git(["tag", "--points-at", "HEAD"]).split(separator: "\n").compactMap {
        try? Version.tag(String($0))
      }
      if let version = exact.max() { return version.description }
    }
    return try tags.max()?.nextSnapshot ?? "0.1.0-SNAPSHOT"
  }
}
