// swift-tools-version: 5.9
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
    .testTarget(name: "AwakenTests", dependencies: ["Awaken"]),
    .testTarget(name: "ReleaseTests", dependencies: ["Versioning", "ReleaseTool"]),
  ]
)
