// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Org2Workspace",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Org2Workspace", targets: ["Org2Workspace"]),
    .executable(name: "Org2WorkspaceScreenshotRenderer", targets: ["Org2WorkspaceScreenshotRenderer"])
  ],
  targets: [
    .executableTarget(
      name: "Org2Workspace",
      dependencies: ["Org2WorkspaceCore"],
      resources: [
        .process("Resources")
      ]
    ),
    .target(
      name: "Org2WorkspaceCore"
    ),
    .executableTarget(
      name: "Org2WorkspaceScreenshotRenderer",
      dependencies: ["Org2WorkspaceCore"]
    ),
    .testTarget(
      name: "Org2WorkspaceCoreTests",
      dependencies: ["Org2WorkspaceCore"]
    )
  ]
)
