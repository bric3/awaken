// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

enum Installer {
  static let rulePath = "/private/etc/sudoers.d/awaken"

  private static func processPattern(executable: String) -> String {
    let name = NSRegularExpression.escapedPattern(
      for: URL(fileURLWithPath: executable).lastPathComponent)
    return "awaken|awaken-macos-universal(-SNAPSHOT)?|\(name)"
  }

  static func checkNotInUse(executable: String) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-a", "-x", processPattern(executable: executable)]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    output.fileHandleForWriting.closeFile()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
      throw Failure("cannot check whether Awaken is in use")
    }
    let processes = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
      Int32($0)
    }
    guard process.terminationStatus == 1 || !processes.isEmpty else {
      throw Failure("cannot check whether Awaken is in use")
    }
    try requireIdle(processes: processes, currentPID: getpid())
  }

  static func requireIdle(processes: [Int32], currentPID: Int32) throws {
    guard processes.allSatisfy({ $0 == currentPID }) else {
      throw Failure("Awaken is in use; stop all sessions before updating sudoers")
    }
  }

  static func setupScript(executable: String, user: String) throws -> String {
    let contents = try rule(user: user)
    let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    return #"""
      awaken_sudoers() {
        /usr/bin/sudo -- /bin/sh -s -- \#(quote(executable)) \#(quote(user)) \#(quote(processPattern(executable: executable))) <<'AWAKEN_SUDOERS'
      set -eu
      umask 077
      root_uid=0
      process_pattern=$3

      fail() { printf 'awaken: %s\n' "$*" >&2; exit 1; }
      idle() {
        if /usr/bin/pgrep -a -x "$process_pattern" >/dev/null; then
          fail 'Awaken is in use; stop all sessions before updating sudoers'
        else
          [ "$?" -eq 1 ] || fail 'cannot check whether Awaken is in use'
        fi
      }
      trusted() {
        [ ! -L "$1" ] || fail "$1 must not be a symlink"
        if [ "$2" = directory ]; then
          [ -d "$1" ] || fail "$1 must be a directory"
        else
          [ -f "$1" ] || fail "$1 must be a regular file"
        fi
        owner=$(/usr/bin/stat -f '%u' "$1")
        mode=$(/usr/bin/stat -f '%Lp' "$1")
        [ "$owner" -eq "$root_uid" ] && [ "$((0$mode & 022))" -eq 0 ] ||
          fail "$1 must be root-owned, with no group/other write access"
        if [ "$1" != / ]; then trusted "$(/usr/bin/dirname "$1")" directory; fi
      }

      [ "$(/usr/bin/id -u)" -eq "$root_uid" ] || fail 'sudoers installation requires sudo'
      idle
      source=$1
      user=$2
      /usr/bin/id -u "$user" >/dev/null || fail "account does not exist: $user"
      helper=\#(quote(Awaken.helperPath))
      rule=\#(quote(rulePath))
      helper_dir=${helper%/*}
      trusted "${rule%/*}" directory
      trusted /Library directory
      if [ -e "$helper_dir" ] || [ -L "$helper_dir" ]; then
        trusted "$helper_dir" directory
      else
        /bin/mkdir -m 755 "$helper_dir"
      fi

      rule_tmp=
      helper_tmp=
      cleanup() {
        [ -z "$rule_tmp" ] || /bin/rm -f "$rule_tmp"
        [ -z "$helper_tmp" ] || /bin/rm -f "$helper_tmp"
      }
      trap cleanup 0
      trap 'exit 1' HUP INT TERM
      rule_tmp=$(/usr/bin/mktemp "${rule%/*}/.awaken-XXXXXXXX")
      /bin/cat >"$rule_tmp" <<'AWAKEN_RULE'
      \#(contents.dropLast())
      AWAKEN_RULE

      rule_exists=false
      if [ -e "$rule" ] || [ -L "$rule" ]; then
        trusted "$rule" file
        /usr/bin/cmp -s "$rule" "$rule_tmp" || fail "refusing to overwrite unrelated $rule"
        rule_exists=true
      fi
      helper_exists=false
      if [ -e "$helper" ] || [ -L "$helper" ]; then
        trusted "$helper" file
        [ "$rule_exists" = true ] || fail 'refusing to replace an unrecognised helper'
        helper_exists=true
      fi

      /usr/sbin/chown 0:0 "$rule_tmp"
      /bin/chmod 440 "$rule_tmp"
      /usr/sbin/visudo -c -f "$rule_tmp"
      helper_tmp=$(/usr/bin/mktemp "$helper_dir/.awaken-XXXXXXXX")
      /bin/cp "$source" "$helper_tmp"
      /usr/sbin/chown 0:0 "$helper_tmp"
      /bin/chmod 755 "$helper_tmp"
      idle
      /bin/mv -f "$helper_tmp" "$helper"
      if ! /bin/mv -f "$rule_tmp" "$rule"; then
        [ "$helper_exists" = true ] || /bin/rm -f "$helper"
        fail 'cannot install sudoers fragment'
      fi
      printf 'Installed sudoers rule and root worker for %s.\n' "$user"
      AWAKEN_SUDOERS
      }
      awaken_sudoers
      """#
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

  static func uninstall(user: String) throws {
    guard geteuid() == 0 else { throw Failure("sudoers removal requires sudo") }
    guard getpwnam(user) != nil else { throw Failure("account does not exist: \(user)") }
    let contents = try rule(user: user)
    let manager = FileManager.default
    let helperDirectory = URL(fileURLWithPath: Awaken.helperPath).deletingLastPathComponent().path
    try checkTrustedFile("/private/etc/sudoers.d", directory: true)
    try checkTrustedFile("/Library", directory: true)
    if manager.fileExists(atPath: helperDirectory) {
      try checkTrustedFile(helperDirectory, directory: true)
    }

    // Refuse files belonging to another installation or user, including dangling symlinks.
    var info = stat()
    let ruleExists = lstat(rulePath, &info) == 0
    if ruleExists {
      try checkTrustedFile(rulePath)
      guard try String(contentsOfFile: rulePath, encoding: .utf8) == contents else {
        throw Failure("refusing to remove unrelated \(rulePath)")
      }
    }
    let helperExists = lstat(Awaken.helperPath, &info) == 0
    if helperExists {
      try checkTrustedFile(Awaken.helperPath)
      guard ruleExists else {
        throw Failure("refusing to remove an unrecognised helper")
      }
    }

    if ruleExists { try manager.removeItem(atPath: rulePath) }
    if helperExists { try manager.removeItem(atPath: Awaken.helperPath) }
    print("Removed sudoers rule and root worker.")
  }
}
