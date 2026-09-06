// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Org2Workspace",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "OpenOrgServer", targets: ["OpenOrgServer"]),
    .executable(name: "Org2Workspace", targets: ["Org2Workspace"]),
    .executable(name: "Org2WorkspaceDiagnostics", targets: ["Org2WorkspaceDiagnostics"]),
    .executable(name: "Org2WorkspaceScreenshotRenderer", targets: ["Org2WorkspaceScreenshotRenderer"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
  ],
  targets: [
    .executableTarget(name: "OpenOrgServer", dependencies: ["Org2WorkspaceCore"]),
    .executableTarget(
      name: "Org2Workspace",
      dependencies: [
        "Org2WorkspaceCore",
        "Org2WorkspaceDiagnosticsCore",
        .product(name: "Sparkle", package: "Sparkle")
      ],
      resources: [
        .process("Resources")
      ],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]
    ),
    .target(
      name: "Org2WorkspaceCore",
      resources: [
        .process("Resources")
      ]
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
