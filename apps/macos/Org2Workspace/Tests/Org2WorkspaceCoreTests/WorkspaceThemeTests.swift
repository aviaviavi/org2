import AppKit
import WebKit
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

  func testRenderedDocumentStylesheetFollowsImportedThemesOnly() {
    let paper = WorkspaceThemeCatalog.theme(id: nil, for: .light)
    let night = WorkspaceThemeCatalog.theme(id: nil, for: .dark)
    let dracula = WorkspaceThemeCatalog.theme(id: "dracula", for: .dark)
    let solarized = WorkspaceThemeCatalog.theme(id: "solarized-light", for: .light)

    XCTAssertEqual(WorkspaceThemeDocumentStyle.stylesheet(light: paper, dark: night), "")

    let darkOnly = WorkspaceThemeDocumentStyle.stylesheet(light: paper, dark: dracula)
    XCTAssertTrue(darkOnly.hasPrefix("@media (prefers-color-scheme: dark)"), "light half keeps the export palette")
    XCTAssertTrue(darkOnly.contains("--org2-surface: #282a36;"))
    XCTAssertTrue(darkOnly.contains(":root h1 { color: #ff79c6; }"))

    let both = WorkspaceThemeDocumentStyle.stylesheet(light: solarized, dark: dracula)
    XCTAssertTrue(both.contains("--org2-text: #586e75;"))
    XCTAssertTrue(both.contains(":root .org2-todo { color: #dc322f;"))
  }

  func testThemeStylesheetIsInjectedAfterExportStylesAndReplaceable() {
    let html = "<html><head><style>h1{}</style></head><body></body></html>"
    let injected = WorkspaceThemeDocumentStyle.injecting(":root{}", into: html)
    XCTAssertTrue(injected.contains("<style>h1{}</style><style id=\"org2-workspace-theme\">"))
    XCTAssertEqual(WorkspaceThemeDocumentStyle.injecting("", into: html), html)

    let custom = "<head><style>h1{}</style><style id=\"org2-app-user-style\">h1{color:red}</style></head>"
    let beforeUser = WorkspaceThemeDocumentStyle.injecting(":root{}", into: custom)
    XCTAssertTrue(beforeUser.contains("</style><style id=\"org2-app-user-style\">"))
    XCTAssertLessThan(
      beforeUser.range(of: "org2-workspace-theme")!.lowerBound,
      beforeUser.range(of: "org2-app-user-style")!.lowerBound
    )

    let script = WorkspaceThemeDocumentStyle.replacementScript("a { color: \"x\" }\n</style>")
    XCTAssertTrue(script.contains("org2-workspace-theme"))
    XCTAssertTrue(script.contains(#"["a { color: \"x\" }\n<\/style>"]"#) || script.contains(#"["a { color: \"x\" }\n</style>"]"#))
  }

  @MainActor
  func testThemeStylesheetRecolorsARenderedDarkPageAndSwapsLive() async throws {
    // Mirrors the shared export: palette variables on :root with a dark override.
    let exportHTML = """
    <!doctype html><html><head><style id="org2-app-document-style">
    :root { color-scheme: light dark; --org2-text: #18201e; }
    @media (prefers-color-scheme: dark) { :root { --org2-text: #dce3de; } }
    html, body { background: transparent; } body { color: var(--org2-text); }
    h1 { color: var(--org2-text); } .org2-todo { color: #86a3ff; }
    </style></head><body><h1><span class="org2-todo">TODO</span> Groceries</h1></body></html>
    """
    let paper = WorkspaceThemeCatalog.theme(id: nil, for: .light)
    let spacemacs = WorkspaceThemeCatalog.theme(id: "spacemacs-dark", for: .dark)
    let nord = WorkspaceThemeCatalog.theme(id: "nord", for: .dark)

    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    webView.appearance = NSAppearance(named: .darkAqua)
    let loader = ThemeTestNavigationWaiter()
    webView.navigationDelegate = loader
    webView.loadHTMLString(
      WorkspaceThemeDocumentStyle.injecting(
        WorkspaceThemeDocumentStyle.stylesheet(light: paper, dark: spacemacs),
        into: exportHTML
      ),
      baseURL: nil
    )
    await loader.waitForLoad()

    let styles = "JSON.stringify([getComputedStyle(document.body).backgroundColor, getComputedStyle(document.body).color, getComputedStyle(document.querySelector('h1')).color, getComputedStyle(document.querySelector('.org2-todo')).color])"
    var computed = try await webView.evaluateJavaScript(styles) as? String
    XCTAssertEqual(computed, #"["rgb(41, 43, 46)","rgb(178, 178, 178)","rgb(79, 151, 215)","rgb(220, 117, 47)"]"#)

    _ = try await webView.evaluateJavaScript(
      WorkspaceThemeDocumentStyle.replacementScript(WorkspaceThemeDocumentStyle.stylesheet(light: paper, dark: nord))
    )
    computed = try await webView.evaluateJavaScript(styles) as? String
    XCTAssertEqual(computed?.hasPrefix(#"["rgb(46, 52, 64)","rgb(216, 222, 233)""#), true, computed ?? "")

    _ = try await webView.evaluateJavaScript(WorkspaceThemeDocumentStyle.replacementScript(""))
    computed = try await webView.evaluateJavaScript(styles) as? String
    XCTAssertEqual(computed?.hasPrefix(#"["rgba(0, 0, 0, 0)","rgb(220, 227, 222)""#), true, computed ?? "")
  }

  func testChatStylesheetAddsTranscriptRulesOnlyForImportedThemes() {
    let paper = WorkspaceThemeCatalog.theme(id: nil, for: .light)
    let night = WorkspaceThemeCatalog.theme(id: nil, for: .dark)
    let spacemacs = WorkspaceThemeCatalog.theme(id: "spacemacs-light", for: .light)
    XCTAssertEqual(WorkspaceThemeDocumentStyle.chatStylesheet(light: paper, dark: night), "")
    let css = WorkspaceThemeDocumentStyle.chatStylesheet(light: spacemacs, dark: night)
    XCTAssertTrue(css.contains(":root .message-card { background: #fbf8ef; border-color: #e0dad6; }"))
    XCTAssertFalse(css.contains("@media"), "the default dark half keeps the built-in chat colors")
  }

  @MainActor
  func testChatThemeRecolorsTranscriptCardsInARealWebView() async throws {
    let page = """
    <!doctype html><html><head><style>\(AIChatTranscriptHTML.style)</style></head>
    <body><article class="assistant"><div class="message-card"><div class="message-header"><strong>Codex</strong></div><main>Hi</main></div></article></body></html>
    """
    let spacemacs = WorkspaceThemeCatalog.theme(id: "spacemacs-dark", for: .dark)
    let paper = WorkspaceThemeCatalog.theme(id: nil, for: .light)
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    webView.appearance = NSAppearance(named: .darkAqua)
    let loader = ThemeTestNavigationWaiter()
    webView.navigationDelegate = loader
    webView.loadHTMLString(page, baseURL: nil)
    await loader.waitForLoad()
    _ = try await webView.evaluateJavaScript(WorkspaceThemeDocumentStyle.replacementScript(
      WorkspaceThemeDocumentStyle.chatStylesheet(light: paper, dark: spacemacs)
    ))
    let computed = try await webView.evaluateJavaScript("""
    JSON.stringify([getComputedStyle(document.body).backgroundColor, getComputedStyle(document.body).color,
      getComputedStyle(document.querySelector('.message-card')).backgroundColor,
      getComputedStyle(document.querySelector('.message-header')).color])
    """) as? String
    XCTAssertEqual(computed, #"["rgba(0, 0, 0, 0)","rgb(178, 178, 178)","rgb(41, 43, 46)","rgb(147, 147, 147)"]"#)
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

@MainActor
private final class ThemeTestNavigationWaiter: NSObject, WKNavigationDelegate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var finished = false

  func waitForLoad() async {
    if finished { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finished = true
    continuation?.resume()
    continuation = nil
  }
}
