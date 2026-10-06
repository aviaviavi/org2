import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceSurfaceThemeTests: XCTestCase {
  func testAgendaSurfaceAndCollectionUseSpacemacsDocumentColorAcrossThemeChanges() async throws {
    let suite = "WorkspaceSurfaceThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let center = WorkspaceThemeCenter.shared
    let originalLight = center.lightThemeID
    let originalDark = center.darkThemeID
    defer {
      defaults.removePersistentDomain(forName: suite)
      center.select(lightThemeID: originalLight, darkThemeID: originalDark)
    }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    let views = [
      AnyView(WorkspaceSurfaceView(surface: .agenda).environment(store)),
      AnyView(WorkspaceLazyCollection {
        Section {
          Text("A row").frame(height: 28)
        } header: {
          WorkspaceLazySectionHeader { Text("Section") }
        }
      })
    ]
    for view in views {
      let host = NSHostingView(rootView: view)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
        styleMask: [.titled], backing: .buffered, defer: false
      )
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFrontRegardless()
      // Compare rendered pixels to a reference swatch through the same display
      // color conversion, rather than comparing display RGB to raw palette RGB.
      let referenceHost = NSHostingView(rootView: Color.clear)
      let referenceWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false
      )
      referenceWindow.isReleasedWhenClosed = false
      referenceWindow.contentView = referenceHost
      referenceWindow.orderFrontRegardless()
      defer {
        window.contentView = nil; window.close()
        referenceWindow.contentView = nil; referenceWindow.close()
      }
      // Keep the same mounted host while switching both palette and appearance.
      for (light, dark, appearance) in [
        ("spacemacs-light", "spacemacs-dark", NSAppearance.Name.aqua),
        ("spacemacs-light", "spacemacs-dark", NSAppearance.Name.darkAqua),
        ("solarized-light", "nord", NSAppearance.Name.aqua)
      ] {
        center.select(lightThemeID: light, darkThemeID: dark)
        window.appearance = NSAppearance(named: appearance)
        referenceWindow.appearance = window.appearance
        referenceHost.rootView = Color(nsColor: center.theme(for: appearance == .darkAqua ? .dark : .light)
          .resolvedColor(.document))
        for _ in 0..<4 {
          await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
          }
          host.layoutSubtreeIfNeeded()
          referenceHost.layoutSubtreeIfNeeded()
          window.displayIfNeeded()
          referenceWindow.displayIfNeeded()
          CATransaction.flush()
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let actual = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 40, y: rep.pixelsHigh - 40)?.usingColorSpace(.sRGB))
        let referenceRep = try XCTUnwrap(referenceHost.bitmapImageRepForCachingDisplay(in: referenceHost.bounds))
        referenceHost.cacheDisplay(in: referenceHost.bounds, to: referenceRep)
        let expected = try XCTUnwrap(referenceRep.colorAt(x: 50, y: 50)?.usingColorSpace(.sRGB))
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.015, "surface red: \(appearance)")
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.015, "surface green: \(appearance)")
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.015, "surface blue: \(appearance)")
      }
    }
  }
}
