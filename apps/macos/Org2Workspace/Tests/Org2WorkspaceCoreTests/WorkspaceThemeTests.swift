import AppKit
import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceThemeTests: XCTestCase {
  func testCatalogOffersDefaultsAndImportedThemesForBothAppearances() {
    let ids = WorkspaceThemeCatalog.all.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "theme IDs must be unique")

    let light = WorkspaceThemeCatalog.themes(for: .light)
    let dark = WorkspaceThemeCatalog.themes(for: .dark)
    XCTAssertEqual(light.first?.id, WorkspaceThemeCatalog.defaultLightID)
    XCTAssertEqual(dark.first?.id, WorkspaceThemeCatalog.defaultDarkID)
    XCTAssertGreaterThanOrEqual(light.count + dark.count - 2, 12, "expected at least a dozen imported themes")
    XCTAssertTrue(light.allSatisfy { $0.appearance == .light })
    XCTAssertTrue(dark.allSatisfy { $0.appearance == .dark })
  }

  func testPersistedIDsFallBackToTheDefaultForTheirAppearance() {
    XCTAssertEqual(WorkspaceThemeCatalog.theme(id: "dracula", for: .dark).id, "dracula")
    XCTAssertEqual(WorkspaceThemeCatalog.theme(id: "dracula", for: .light).id, WorkspaceThemeCatalog.defaultLightID)
    XCTAssertEqual(WorkspaceThemeCatalog.theme(id: "missing", for: .dark).id, WorkspaceThemeCatalog.defaultDarkID)
    XCTAssertEqual(WorkspaceThemeCatalog.theme(id: nil, for: .light).id, WorkspaceThemeCatalog.defaultLightID)
  }

  func testImportedThemesKeepReadableBodyTextContrast() {
    for theme in WorkspaceThemeCatalog.all {
      let text = theme.resolvedColor(.text)
      let document = theme.resolvedColor(.document)
      XCTAssertGreaterThanOrEqual(
        Self.contrast(text, document), 4.5,
        "\(theme.name) body text must stay readable"
      )
      let isDarkBackground = Self.luminance(document) < 0.2
      XCTAssertEqual(isDarkBackground, theme.appearance == .dark, "\(theme.name) appearance must match its background")
    }
  }

  func testLiveColorsFollowTheSelectedPairPerAppearance() throws {
    let center = WorkspaceThemeCenter()
    center.select(lightThemeID: "solarized-light", darkThemeID: "nord")
    XCTAssertEqual(center.lightThemeID, "solarized-light")
    XCTAssertEqual(center.darkThemeID, "nord")

    let document = center.liveColor(.document)
    XCTAssertEqual(try Self.hex(document, in: .aqua), 0xfdf6e3)
    XCTAssertEqual(try Self.hex(document, in: .darkAqua), 0x2e3440)

    center.select(lightThemeID: "nord", darkThemeID: "unknown")
    XCTAssertEqual(center.lightThemeID, WorkspaceThemeCatalog.defaultLightID)
    XCTAssertEqual(center.darkThemeID, WorkspaceThemeCatalog.defaultDarkID)
    XCTAssertTrue(center.liveColor(.document) === document, "AppKit colors stay stable across theme changes")
    XCTAssertEqual(try Self.hex(document, in: .darkAqua), 0x1b211f)
  }

  func testDefaultPairKeepsSystemTintAndBodyText() {
    let center = WorkspaceThemeCenter()
    XCTAssertNil(center.trackedAccent())
    XCTAssertFalse(center.trackedOverridesBodyText())
    center.select(lightThemeID: nil, darkThemeID: "dracula")
    XCTAssertNotNil(center.trackedAccent())
    XCTAssertTrue(center.trackedOverridesBodyText())
  }

  private static func hex(_ color: NSColor, in name: NSAppearance.Name) throws -> UInt32 {
    let appearance = try XCTUnwrap(NSAppearance(named: name))
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB)
    }
    let rgb = try XCTUnwrap(resolved)
    let r = UInt32((rgb.redComponent * 255).rounded())
    let g = UInt32((rgb.greenComponent * 255).rounded())
    let b = UInt32((rgb.blueComponent * 255).rounded())
    return (r << 16) | (g << 8) | b
  }

  private static func luminance(_ color: NSColor) -> Double {
    func channel(_ value: CGFloat) -> Double {
      let v = Double(value)
      return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    let rgb = color.usingColorSpace(.sRGB) ?? color
    return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
  }

  private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let la = luminance(a)
    let lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
}
