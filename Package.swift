// swift-tools-version: 5.9
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

let package = Package(
  name: "awaken",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "awaken", targets: ["Awaken"])],
  targets: [
    .executableTarget(name: "Awaken", plugins: [.plugin(name: "BuildVersion")]),
    .target(name: "Versioning", path: "Tools/Versioning"),
    .executableTarget(
      name: "VersionGenerator", dependencies: ["Versioning"], path: "Tools/VersionGenerator"),
    .plugin(name: "BuildVersion", capability: .buildTool(), dependencies: ["VersionGenerator"]),
    .executableTarget(name: "ReleaseTool", dependencies: ["Versioning"], path: "Tools/ReleaseTool"),
    .executableTarget(name: "LicenseTool", path: "Tools/LicenseTool"),
    .testTarget(name: "AwakenTests", dependencies: ["Awaken"]),
    .testTarget(name: "ReleaseTests", dependencies: ["Versioning", "ReleaseTool"]),
    .testTarget(name: "LicenseToolTests", dependencies: ["LicenseTool"]),
  ]
)
