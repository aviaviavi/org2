import AppKit
import XCTest
@testable import Org2WorkspaceCore

final class ConnectorBrandLogoTests: XCTestCase {
  @MainActor
  func testSlackAndNotionUseBundledBrandLogos() throws {
    for type in ["slack", "notion", "Slack"] {
      let image = try XCTUnwrap(ConnectorBrandLogo.image(for: type), "missing logo for \(type)")
      XCTAssertGreaterThan(image.size.width, 0)
      XCTAssertGreaterThan(image.size.height, 0)
    }
  }

  @MainActor
  func testUnknownConnectorFallsBackToSymbol() {
    XCTAssertNil(ConnectorBrandLogo.resourceName(for: "gmail"))
    XCTAssertNil(ConnectorBrandLogo.image(for: "gmail"))
  }
}
