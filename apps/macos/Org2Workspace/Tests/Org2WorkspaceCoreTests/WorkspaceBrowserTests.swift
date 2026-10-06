import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceBrowserTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("browser-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("site/assets"), withIntermediateDirectories: true)
    try Data("<!doctype html><title>Demo</title><link rel=stylesheet href=assets/app.css>".utf8)
      .write(to: root.appendingPathComponent("site/index.html"))
    try Data("body{color:red}".utf8).write(to: root.appendingPathComponent("site/assets/app.css"))
    try Data("secret".utf8).write(to: root.appendingPathComponent("outside.txt"))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testAddressResolution() {
    XCTAssertEqual(WorkspaceBrowserAddress.resolve("https://example.com/a")?.absoluteString, "https://example.com/a")
    XCTAssertEqual(WorkspaceBrowserAddress.resolve("localhost:5173")?.absoluteString, "http://localhost:5173")
    XCTAssertEqual(WorkspaceBrowserAddress.resolve("127.0.0.1:8000/docs")?.absoluteString, "http://127.0.0.1:8000/docs")
    XCTAssertEqual(WorkspaceBrowserAddress.resolve("app.localhost:3000")?.absoluteString, "http://app.localhost:3000")
    XCTAssertEqual(WorkspaceBrowserAddress.resolve("192.168.1.20:8080")?.absoluteString, "http://192.168.1.20:8080")
    XCTAssertEqual(WorkspaceBrowserAddress.resolve("example.com")?.absoluteString, "https://example.com")
    XCTAssertEqual(WorkspaceBrowserAddress.resolve("github.com/aviaviavi/org2")?.absoluteString, "https://github.com/aviaviavi/org2")
    XCTAssertEqual(WorkspaceBrowserAddress.resolve("site/index.html", corpusRoot: root)?.path, root.appendingPathComponent("site/index.html").path)
    XCTAssertEqual(WorkspaceBrowserAddress.resolve(root.appendingPathComponent("site/index.html").path)?.isFileURL, true)
    XCTAssertTrue(WorkspaceBrowserAddress.resolve("how do I use org2")?.absoluteString.hasPrefix(WorkspaceBrowserAddress.searchURLPrefix) == true)
    XCTAssertNil(WorkspaceBrowserAddress.resolve("   "))
    XCTAssertNil(WorkspaceBrowserAddress.resolve("/definitely/missing/file.html"))
  }

  func testStaticServerResolvesInsideTheFolderOnly() {
    let site = root.appendingPathComponent("site").standardizedFileURL.resolvingSymlinksInPath()
    XCTAssertEqual(LocalStaticSiteServer.resolve(path: "/", root: site)?.lastPathComponent, "index.html")
    XCTAssertEqual(LocalStaticSiteServer.resolve(path: "/assets/app.css?v=2", root: site)?.lastPathComponent, "app.css")
    XCTAssertNil(LocalStaticSiteServer.resolve(path: "/../outside.txt", root: site))
    XCTAssertNil(LocalStaticSiteServer.resolve(path: "/%2e%2e/outside.txt", root: site))
    XCTAssertNil(LocalStaticSiteServer.resolve(path: "/missing.js", root: site))
    XCTAssertEqual(LocalStaticSiteServer.mimeType(for: URL(fileURLWithPath: "/a.mjs")), "text/javascript; charset=utf-8")
    let post = LocalStaticSiteServer.response(for: MobileRemoteHTTPRequest(method: "POST", path: "/"), root: site)
    XCTAssertEqual(post.statusCode, 405)
  }

  func testStaticServerServesAFolderOverLoopback() async throws {
    let server = LocalStaticSiteServer(root: root.appendingPathComponent("site"))
    let base = try await server.start()
    defer { server.stop() }
    XCTAssertEqual(base.host, "127.0.0.1")
    let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("assets/app.css"))
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/css; charset=utf-8")
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "body{color:red}")
    let (_, missing) = try await URLSession.shared.data(from: base.appendingPathComponent("nope.html"))
    XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
  }

  @MainActor
  func testBrowserModelAndHTMLFilePresentation() async throws {
    let model = WorkspaceBrowserModel()
    model.addressText = "localhost:4321"
    XCTAssertTrue(model.submitAddress(corpusRoot: nil))
    guard case .load(let url) = model.pendingRequest?.action else { return XCTFail("expected a load request") }
    XCTAssertEqual(url.absoluteString, "http://localhost:4321")
    model.addressText = "/missing/page.html"
    XCTAssertFalse(model.submitAddress(corpusRoot: nil))
    XCTAssertNotNil(model.errorMessage)

    await model.serve(folder: root.appendingPathComponent("site"), entry: root.appendingPathComponent("site/assets/app.css"))
    XCTAssertEqual(model.servedSites.count, 1)
    guard case .load(let served) = model.pendingRequest?.action else { return XCTFail("expected a served load") }
    XCTAssertEqual(served.path, "/assets/app.css")
    model.stopServing(model.servedSites[0])
    XCTAssertTrue(model.servedSites.isEmpty)

    XCTAssertTrue(WorkspaceStore.isHTMLFile("/a/index.HTML"))
    XCTAssertFalse(WorkspaceStore.isHTMLFile("/a/index.org"))
    XCTAssertEqual(WorkspaceSurface.browser.title, "Browser")
    XCTAssertTrue(WorkspaceSurface.sidebarCases.contains(.browser))
  }
}
