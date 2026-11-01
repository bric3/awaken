import Darwin
import Foundation

enum Installer {
  static let rulePath = "/private/etc/sudoers.d/awaken"

  static func setupCommand(executable: String, user: String) throws -> String {
    _ = try rule(user: user)
    let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    return "/usr/bin/sudo -- \(quote(executable)) --install-sudoers \(quote(user))"
  }

  static func rule(user: String) throws -> String {
    guard user != "ALL",
      user.range(of: "\\A[A-Za-z_][A-Za-z0-9_.-]*\\z", options: .regularExpression) != nil
    else {
      throw Failure("unsupported account name for sudoers")
    }
    return
      "# Managed by awaken.\n\(user) ALL=(root) NOPASSWD: \(Awaken.helperPath) --privileged-worker\n"
  }

  static func checkTrustedFile(_ path: String, directory: Bool = false) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
      info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG)
    else {
      throw Failure("\(path) must be root-owned, with no group/other write access or symlink")
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    if path != "/" { try checkTrustedFile(parent, directory: true) }
  }

  static func run(user: String, uninstall: Bool) throws {
    guard geteuid() == 0 else { throw Failure("sudoers installation requires sudo") }
    guard getpwnam(user) != nil else { throw Failure("account does not exist: \(user)") }
    let contents = try rule(user: user)
    let manager = FileManager.default
    let helperDirectory = URL(fileURLWithPath: Awaken.helperPath).deletingLastPathComponent().path
    try checkTrustedFile("/private/etc/sudoers.d", directory: true)
    try checkTrustedFile("/Library", directory: true)
    if manager.fileExists(atPath: helperDirectory) {
      try checkTrustedFile(helperDirectory, directory: true)
    } else if !uninstall {
      guard mkdir(helperDirectory, 0o755) == 0 else {
        throw Failure("cannot create helper directory")
      }
    }

    // Refuse files belonging to another installation or user, including dangling symlinks.
    var info = stat()
    let ruleExists = lstat(rulePath, &info) == 0
    if ruleExists {
      try checkTrustedFile(rulePath)
      guard try String(contentsOfFile: rulePath, encoding: .utf8) == contents else {
        throw Failure("refusing to overwrite or remove unrelated \(rulePath)")
      }
    }
    let helperExists = lstat(Awaken.helperPath, &info) == 0
    if helperExists {
      try checkTrustedFile(Awaken.helperPath)
      guard ruleExists else {
        throw Failure("refusing to replace or remove an unrecognised helper")
      }
    }

    if uninstall {
      if ruleExists { try manager.removeItem(atPath: rulePath) }
      if helperExists { try manager.removeItem(atPath: Awaken.helperPath) }
      print("Removed sudoers rule and root worker.")
      return
    }

    let ruleTemporary = "/private/etc/sudoers.d/.awaken-\(UUID().uuidString)"
    let helperTemporary = helperDirectory + "/.awaken-\(UUID().uuidString)"
    defer {
      try? manager.removeItem(atPath: ruleTemporary)
      try? manager.removeItem(atPath: helperTemporary)
    }
    try Data(contents.utf8).write(
      to: URL(fileURLWithPath: ruleTemporary), options: .withoutOverwriting)
    guard chmod(ruleTemporary, 0o440) == 0, chown(ruleTemporary, 0, 0) == 0 else {
      throw Failure("cannot secure sudoers fragment")
    }
    try runCommand("/usr/sbin/visudo", ["-c", "-f", ruleTemporary])

    guard let source = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
      throw Failure("cannot locate the awaken executable")
    }
    try manager.copyItem(at: source, to: URL(fileURLWithPath: helperTemporary))
    guard chmod(helperTemporary, 0o755) == 0, chown(helperTemporary, 0, 0) == 0 else {
      throw Failure("cannot secure privileged worker")
    }
    guard rename(helperTemporary, Awaken.helperPath) == 0 else {
      throw Failure("cannot install privileged worker")
    }
    guard rename(ruleTemporary, rulePath) == 0 else {
      if !helperExists { try? manager.removeItem(atPath: Awaken.helperPath) }
      throw Failure("cannot install sudoers fragment")
    }
    print("Installed sudoers rule and root worker for \(user).")
  }
}
