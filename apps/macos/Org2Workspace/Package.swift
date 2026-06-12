// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Org2Workspace",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Org2Workspace", targets: ["Org2Workspace"])
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
    .testTarget(
      name: "Org2WorkspaceCoreTests",
      dependencies: ["Org2WorkspaceCore"]
    )
  ]
)
