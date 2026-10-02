import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatDocumentMediaTests: XCTestCase {
  func testChatAttachmentsUseRevisionedResourceURLsOnlyForImages() throws {
    let image = AIChatAttachment(
      fileName: "Screenshot.png",
      mimeType: "image/png",
      data: Data([1, 2, 3])
    )
    let text = AIChatAttachment(
      fileName: "notes.txt",
      mimeType: "text/plain",
      data: Data("notes".utf8)
    )

    let imageURL = try XCTUnwrap(
      OrgHTMLLocalResourceSchemeHandler.chatAttachmentResourceURL(for: image)
    )
    XCTAssertEqual(imageURL.scheme, OrgHTMLLocalResourceSchemeHandler.scheme)
    XCTAssertEqual(imageURL.host, "attachment")
    XCTAssertTrue(imageURL.absoluteString.contains("revision="))
    XCTAssertNil(OrgHTMLLocalResourceSchemeHandler.chatAttachmentResourceURL(for: text))
  }

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

  func testDocumentViewsShowUserLinkedImagesOutsideTheCorpusButChatDoesNot() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let corpus = base.appendingPathComponent("corpus")
    let daily = corpus.appendingPathComponent("daily")
    let attachments = corpus.appendingPathComponent("attachments")
    let outside = base.appendingPathComponent("Documents")
    for directory in [daily, attachments, outside] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: base) }
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let screenshot = outside.appendingPathComponent("Screenshot 9.28.55\u{202F}AM.png")
    try png.write(to: screenshot)
    try png.write(to: attachments.appendingPathComponent("capture.png"))
    let source = EntrySource(file: "daily/2026-10-02.org", startLine: 1, endLineExclusive: 1, text: "", isSubtree: false)

    func loadedWidth(_ html: String, allowsOutside: Bool) async throws -> Int {
      let resources = OrgHTMLLocalResourceSchemeHandler()
      resources.configure(source: source, corpusRoot: corpus, allowsAbsoluteImagesOutsideCorpus: allowsOutside)
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.setURLSchemeHandler(resources, forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme)
      let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 300), configuration: configuration)
      view.loadHTMLString(OrgHTMLLocalResourceSchemeHandler.rewritingLocalImageSources(in: html), baseURL: daily)
      var width = 0
      var complete = false
      for _ in 0..<150 {
        let state = try? await view.evaluateJavaScript(
          "(()=>{const i=document.querySelector('img');return i?[i.complete,i.naturalWidth]:[false,0]})()"
        ) as? [Any]
        complete = state?.first as? Bool ?? false
        width = state?.last as? Int ?? 0
        if width > 0 || complete { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      return width
    }

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let absolute = try await cli.renderAppHTML(
      "- [ ] weird rendering [[\(screenshot.path)]]",
      sourcePath: corpus.appendingPathComponent(source.file).path
    )
    let documentWidth = try await loadedWidth(absolute, allowsOutside: true)
    let chatWidth = try await loadedWidth(absolute, allowsOutside: false)
    XCTAssertEqual(documentWidth, 8)
    XCTAssertEqual(chatWidth, 0)

    let captured = try await cli.renderAppHTML(
      "[[file:attachments/capture.png]]",
      sourcePath: corpus.appendingPathComponent(source.file).path
    )
    let capturedWidth = try await loadedWidth(captured, allowsOutside: false)
    XCTAssertEqual(capturedWidth, 8)
  }
}
