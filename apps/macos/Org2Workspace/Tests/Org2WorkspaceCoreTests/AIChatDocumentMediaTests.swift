import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatDocumentMediaTests: XCTestCase {
  func testLocalImagesLoadThroughTheDocumentResourceHandler() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let image = directory.appendingPathComponent("test image.png")
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
    let source = directory.appendingPathComponent("message.org").path
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    for target in ["file:test image.png", "file:" + image.path] {
      let html = try await cli.renderAppHTML("[[\(target)][Image]]", sourcePath: source)
      let resources = OrgHTMLLocalResourceSchemeHandler()
      resources.configure(source: EntrySource(file: source, startLine: 1, endLineExclusive: 1, text: "", isSubtree: false), corpusRoot: directory)
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.setURLSchemeHandler(resources, forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme)
      let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 300), configuration: configuration)
      view.loadHTMLString(OrgHTMLLocalResourceSchemeHandler.rewritingLocalImageSources(in: html), baseURL: directory)
      var width = 0
      for _ in 0..<150 {
        width = (try? await view.evaluateJavaScript("document.querySelector('img')?.naturalWidth || 0")) as? Int ?? 0
        if width > 0 { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertEqual(width, 8, target)
    }
  }
}
