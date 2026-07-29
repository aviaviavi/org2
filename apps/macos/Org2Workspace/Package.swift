// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Org2Workspace",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Org2Workspace", targets: ["Org2Workspace"]),
    .executable(name: "Org2WorkspaceDiagnostics", targets: ["Org2WorkspaceDiagnostics"]),
    .executable(name: "Org2WorkspaceScreenshotRenderer", targets: ["Org2WorkspaceScreenshotRenderer"])
  ],
  targets: [
    .executableTarget(
      name: "Org2Workspace",
      dependencies: ["Org2WorkspaceCore", "Org2WorkspaceDiagnosticsCore"],
      resources: [
        .process("Resources")
      ]
    ),
    .target(
      name: "Org2WorkspaceCore"
    ),
    .target(
      name: "Org2WorkspaceDiagnosticsCore"
    ),
    .executableTarget(
      name: "Org2WorkspaceDiagnostics",
      dependencies: ["Org2WorkspaceDiagnosticsCore"]
    ),
    .executableTarget(
      name: "Org2WorkspaceScreenshotRenderer",
      dependencies: ["Org2WorkspaceCore"]
    ),
    .testTarget(
      name: "Org2WorkspaceCoreTests",
      dependencies: ["Org2WorkspaceCore"]
    ),
    .testTarget(
      name: "Org2WorkspaceDiagnosticsTests",
      dependencies: ["Org2WorkspaceDiagnosticsCore"]
    )
  ]
)
