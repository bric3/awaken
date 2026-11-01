// SPDX-License-Identifier: MPL-2.0

import Foundation
import PackagePlugin

@main
struct BuildVersionPlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let generator = try context.tool(named: "VersionGenerator").path
    let directory = context.package.directory.string
    var fingerprint = "no-git"
    if FileManager.default.fileExists(atPath: directory + "/.git") {
      let status = try git(directory, ["status", "--porcelain", "--untracked-files=normal"])
      let head = try git(
        directory, ["rev-parse", "--verify", "--quiet", "HEAD"], allowMissing: true)
      let tags = head.isEmpty ? "" : try git(directory, ["tag", "--merged", "HEAD"])
      fingerprint = head + "\n" + tags + "\n" + status
    }
    let environment = ProcessInfo.processInfo.environment
    let file = context.pluginWorkDirectory.appending("BuildVersion.swift")
    // Git state is a command argument so tag-only changes invalidate generated source.
    return [
      .buildCommand(
        displayName: "Embed Awaken version", executable: generator,
        arguments: [
          "emit", directory, fingerprint, environment["AWAKEN_RELEASE_TAG"] ?? "",
          environment["AWAKEN_SNAPSHOT"] ?? "", file.string,
        ], outputFiles: [file])
    ]
  }

  private func git(_ directory: String, _ arguments: [String], allowMissing: Bool = false) throws
    -> String
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    output.fileHandleForWriting.closeFile()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 || allowMissing else { throw VersionError() }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct VersionError: Error {}
