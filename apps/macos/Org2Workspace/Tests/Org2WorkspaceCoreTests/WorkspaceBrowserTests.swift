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
    XCTAssertFalse(WorkspaceSurface.allCases.map(\.rawValue).contains("browser"), "web pages open from links, not a Browser surface")
  }

  func testWebLinksRouteToAnInAppPageRegardlessOfFileType() throws {
    for raw in ["https://example.com", "http://localhost:5173/app", "https://example.com/report.pdf", "HTTPS://Example.com/a.png?x=1"] {
      let url = try XCTUnwrap(URL(string: raw))
      XCTAssertEqual(WorkspaceWebLinkRouting.destination(for: url), .webPage(url), raw)
    }
    for raw in ["mailto:a@example.com", "zoommtg://join?x=1", "file:///tmp/a.html", "https:///no-host"] {
      let url = try XCTUnwrap(URL(string: raw))
      XCTAssertEqual(WorkspaceWebLinkRouting.destination(for: url), .external(url), raw)
    }
  }

  @MainActor
  func testWebLinkOpensInDetailPaneWithBackAndForward() throws {
    let suiteName = "org2-web-page-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    let file = root.appendingPathComponent("note.org").path
    try Data("* Note\nSee https://example.com/docs\n".utf8).write(to: URL(fileURLWithPath: file))

    store.selectedSurface = .aiChat
    store.openChatFileReference(AIChatFileReference(path: file, line: nil))
    XCTAssertEqual(store.selectedLocation?.file, file)

    let page = try XCTUnwrap(URL(string: "https://example.com/docs"))
    let recorder = WebLinkRecorder()
    let action = OpenWorkspaceWebLinkAction { url, inNewTab in recorder.opened.append((url, inNewTab)) }
    action(page, inNewTab: true)
    XCTAssertEqual(recorder.opened.map(\.0), [page])
    XCTAssertEqual(recorder.opened.map(\.1), [true])

    store.openWebPage(page)
    XCTAssertEqual(store.presentedWebPageURL, page)
    XCTAssertNil(store.selectedLocation, "the web page replaces the document in the detail pane")
    XCTAssertTrue(store.hasWorkspaceDetailContent)
    XCTAssertEqual(store.selectedSurface, .aiChat, "opening a link keeps the current surface")
    guard case .load(let requested) = store.browser.pendingRequest?.action else { return XCTFail("expected a load") }
    XCTAssertEqual(requested, page)

    store.navigateBack()
    XCTAssertNil(store.presentedWebPageURL)
    XCTAssertEqual(store.selectedLocation?.file, file)

    store.navigateForward()
    XCTAssertEqual(store.presentedWebPageURL, page)
    XCTAssertNil(store.selectedLocation)

    store.openChatFileReference(AIChatFileReference(path: file, line: nil))
    XCTAssertNil(store.presentedWebPageURL, "opening a document clears the web page")
    XCTAssertEqual(store.selectedLocation?.file, file)

    let tabCount = store.workspaceTabs.count
    store.openWebPageInNewTab(page)
    XCTAssertEqual(store.workspaceTabs.count, tabCount + 1)
    XCTAssertEqual(store.presentedWebPageURL, page)
  }
}

@MainActor
private final class WebLinkRecorder {
  var opened: [(URL, Bool)] = []
}
