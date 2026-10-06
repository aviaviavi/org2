import AppKit
import Darwin
import Foundation
import Network
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Address resolution

/// Turns what a person types in the Browser address field into a URL:
/// full URLs, `localhost:3000`, bare host names, absolute or corpus-relative
/// file paths, and otherwise a web search.
public enum WorkspaceBrowserAddress {
  public static let searchURLPrefix = "https://duckduckgo.com/?q="

  public static func resolve(_ raw: String, corpusRoot: URL? = nil) -> URL? {
    let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return nil }
    let lower = input.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") {
      return URL(string: input)
    }
    if lower == "about:blank" { return URL(string: "about:blank") }
    // Local paths.
    let expanded = (input as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return FileManager.default.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
    }
    if let corpusRoot, !input.contains(" "), !looksLikeHost(input) {
      let candidate = corpusRoot.appendingPathComponent(input)
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    // Loopback and private development servers default to http.
    if isLocalHost(lower) { return URL(string: "http://\(input)") }
    if looksLikeHost(input) { return URL(string: "https://\(input)") }
    let query = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
    return URL(string: searchURLPrefix + query)
  }

  /// `localhost`, `127.0.0.1`, `[::1]`, `*.localhost`, `*.local`, and private
  /// IPv4 addresses, with an optional port and path.
  public static func isLocalHost(_ lowerInput: String) -> Bool {
    let host = hostPart(lowerInput)
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "[::1]" || host == "0.0.0.0" { return true }
    let octets = host.split(separator: ".").compactMap { UInt8($0) }
    guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
    return octets[0] == 127 || octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 100 && (64...127).contains(octets[1]))
  }

  static func hostPart(_ input: String) -> String {
    var host = input
    if let slash = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { host = String(host[..<slash]) }
    if host.hasPrefix("[") { return host.split(separator: "]").first.map { $0 + "]" } ?? host }
    if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
    return host
  }

  static func looksLikeHost(_ input: String) -> Bool {
    guard !input.contains(" ") else { return false }
    let host = hostPart(input.lowercased())
    if isLocalHost(input.lowercased()) { return true }
    let labels = host.split(separator: ".")
    guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
    return labels.allSatisfy { label in !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
  }

  /// Common development-server ports probed for "Local apps".
  public static let developmentPorts: [UInt16] = [3000, 3001, 4000, 4200, 4321, 5000, 5173, 5174, 8000, 8080, 8081, 8888, 9000]
}

// MARK: - Local static site server

/// Serves one folder over HTTP on the loopback interface so local web apps
/// that need an http origin (fetch, modules, service workers) run in the
/// Browser. Read-only: GET and HEAD only, confined to the folder.
public final class LocalStaticSiteServer: @unchecked Sendable {
  public let root: URL
  public private(set) var port: UInt16 = 0
  private var server: MobileRemoteHTTPServer?

  public init(root: URL) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
  }

  public var url: URL? { port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)/") }

  public func start() async throws -> URL {
    let port = try Self.freeLoopbackPort()
    let root = self.root
    let server = MobileRemoteHTTPServer(handler: { request in
      Self.response(for: request, root: root)
    })
    try server.start(host: "127.0.0.1", port: port)
    self.server = server
    self.port = port
    // Wait until the listener accepts connections.
    for _ in 0..<50 {
      if Self.canConnect(port: port) { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    guard let url else { throw CocoaError(.fileReadUnknown) }
    return url
  }

  public func stop() {
    server?.stop()
    server = nil
  }

  deinit { stop() }

  static func freeLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard named == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
    return UInt16(bigEndian: address.sin_port)
  }

  /// A quick, non-blocking-ish loopback connect probe (used for readiness
  /// and to discover running development servers).
  public static func canConnect(port: UInt16, timeoutMilliseconds: Int32 = 150) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    let flags = fcntl(descriptor, F_GETFL, 0)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if result == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    guard poll(&poller, 1, timeoutMilliseconds) > 0 else { return false }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
    return error == 0
  }

  static let maximumFileBytes = 256 * 1024 * 1024

  static func response(for request: MobileRemoteHTTPRequest, root: URL) -> MobileRemoteHTTPResponse {
    guard request.method == "GET" || request.method == "HEAD" else {
      return MobileRemoteHTTPResponse(statusCode: 405, headers: ["Allow": "GET, HEAD"], body: Data("Method Not Allowed".utf8))
    }
    guard let file = resolve(path: request.path, root: root) else {
      return MobileRemoteHTTPResponse(statusCode: 404, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("Not Found".utf8))
    }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
          let size = attributes[.size] as? Int, size <= maximumFileBytes,
          let data = request.method == "HEAD" ? Data() : try? Data(contentsOf: file)
    else {
      return MobileRemoteHTTPResponse(statusCode: 500, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("Could not read file".utf8))
    }
    return MobileRemoteHTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": mimeType(for: file), "X-Content-Type-Options": "nosniff"],
      body: data
    )
  }

  /// Maps a request path onto a file inside `root`, serving `index.html` for
  /// folders. Paths that escape the folder (including through symlinks) are
  /// rejected.
  static func resolve(path rawPath: String, root: URL) -> URL? {
    var path = rawPath
    if let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<query]) }
    guard let decoded = path.removingPercentEncoding, !decoded.contains("\0") else { return nil }
    let components = decoded.split(separator: "/").map(String.init)
    guard !components.contains("..") else { return nil }
    var candidate = root
    for component in components where !component.isEmpty && component != "." { candidate.appendPathComponent(component) }
    candidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { return nil }
    if isDirectory.boolValue {
      let index = candidate.appendingPathComponent("index.html")
      return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }
    return candidate
  }

  static func mimeType(for file: URL) -> String {
    switch file.pathExtension.lowercased() {
    case "html", "htm": "text/html; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "js", "mjs", "cjs": "text/javascript; charset=utf-8"
    case "json", "map", "webmanifest": "application/json; charset=utf-8"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "ico": "image/x-icon"
    case "wasm": "application/wasm"
    case "txt", "md", "org": "text/plain; charset=utf-8"
    case "xml": "application/xml"
    case "pdf": "application/pdf"
    case "woff": "font/woff"
    case "woff2": "font/woff2"
    case "ttf": "font/ttf"
    case "mp4", "m4v": "video/mp4"
    case "mp3": "audio/mpeg"
    case "wav": "audio/wav"
    default: "application/octet-stream"
    }
  }
}

// MARK: - Browser model

/// State for the Browser surface. The WKWebView itself lives in the view;
/// navigation requests flow through `pendingRequest`.
@MainActor
@Observable
public final class WorkspaceBrowserModel {
  public struct NavigationRequest: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
      case load(URL)
      case back
      case forward
      case reload
      case stop
    }
    public let id: Int
    public let action: Action
  }

  public struct ServedSite: Identifiable, Equatable, Sendable {
    public let root: URL
    public let url: URL
    public var id: String { root.path }
  }

  public var addressText = ""
  public private(set) var currentURL: URL?
  public private(set) var title = ""
  public private(set) var isLoading = false
  public private(set) var progress: Double = 0
  public private(set) var canGoBack = false
  public private(set) var canGoForward = false
  public private(set) var errorMessage: String?
  public private(set) var pendingRequest: NavigationRequest?
  public private(set) var servedSites: [ServedSite] = []
  public private(set) var runningLocalPorts: [UInt16] = []
  @ObservationIgnored private var requestSequence = 0
  @ObservationIgnored private var servers: [String: LocalStaticSiteServer] = [:]

  public init() {}

  private func request(_ action: NavigationRequest.Action) {
    requestSequence += 1
    pendingRequest = NavigationRequest(id: requestSequence, action: action)
  }

  public func load(_ url: URL) {
    errorMessage = nil
    addressText = url.isFileURL ? url.path : url.absoluteString
    request(.load(url))
  }

  /// Loads whatever is in the address field.
  @discardableResult
  public func submitAddress(corpusRoot: URL?) -> Bool {
    guard let url = WorkspaceBrowserAddress.resolve(addressText, corpusRoot: corpusRoot) else {
      errorMessage = "“\(addressText)” is not a URL or an existing file."
      return false
    }
    load(url)
    return true
  }

  public func goBack() { request(.back) }
  public func goForward() { request(.forward) }
  public func reload() { request(.reload) }
  public func stopLoading() { request(.stop) }

  func update(url: URL?, title: String, isLoading: Bool, progress: Double, canGoBack: Bool, canGoForward: Bool) {
    if currentURL != url {
      currentURL = url
      if let url, url.absoluteString != "about:blank" {
        addressText = url.isFileURL ? url.path : url.absoluteString
      }
    }
    if self.title != title { self.title = title }
    if self.isLoading != isLoading { self.isLoading = isLoading }
    if abs(self.progress - progress) > 0.01 { self.progress = progress }
    if self.canGoBack != canGoBack { self.canGoBack = canGoBack }
    if self.canGoForward != canGoForward { self.canGoForward = canGoForward }
  }

  func reportError(_ message: String?) {
    errorMessage = message
  }

  /// Serves `folder` on a loopback port and opens it.
  public func serve(folder: URL, entry: URL? = nil) async {
    let root = folder.standardizedFileURL.resolvingSymlinksInPath()
    do {
      let base: URL
      if let existing = servedSites.first(where: { $0.root == root }) {
        base = existing.url
      } else {
        let server = LocalStaticSiteServer(root: root)
        base = try await server.start()
        servers[root.path] = server
        servedSites.append(ServedSite(root: root, url: base))
      }
      var target = base
      if let entry {
        let resolvedEntry = entry.standardizedFileURL.resolvingSymlinksInPath()
        if resolvedEntry.path.hasPrefix(root.path + "/") {
          let relative = String(resolvedEntry.path.dropFirst(root.path.count + 1))
          target = base.appendingPathComponent(relative)
        }
      }
      load(target)
    } catch {
      errorMessage = "Could not serve \(root.lastPathComponent): \(error.localizedDescription)"
    }
  }

  public func stopServing(_ site: ServedSite) {
    servers.removeValue(forKey: site.root.path)?.stop()
    servedSites.removeAll { $0.id == site.id }
  }

  /// Finds development servers listening on common loopback ports.
  public func refreshRunningLocalPorts() async {
    let ports = WorkspaceBrowserAddress.developmentPorts
    let served = Set(servedSites.compactMap { $0.url.port.map(UInt16.init) })
    let found = await Task.detached(priority: .utility) {
      ports.filter { LocalStaticSiteServer.canConnect(port: $0, timeoutMilliseconds: 80) }
    }.value
    runningLocalPorts = found.filter { !served.contains($0) }
  }
}

// MARK: - Web view

/// A WKWebView that follows a `WorkspaceBrowserModel`'s navigation requests
/// and reports its state back.
struct WorkspaceWebView: NSViewRepresentable {
  let model: WorkspaceBrowserModel
  var fileReadAccessRoot: URL?

  func makeCoordinator() -> Coordinator { Coordinator(model: model, fileReadAccessRoot: fileReadAccessRoot) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.preferences.isElementFullscreenEnabled = true
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true
    webView.allowsMagnification = true
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    context.coordinator.attach(webView)
    if let request = model.pendingRequest { context.coordinator.perform(request, in: webView) }
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.fileReadAccessRoot = fileReadAccessRoot
    if let request = model.pendingRequest { context.coordinator.perform(request, in: webView) }
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let model: WorkspaceBrowserModel
    var fileReadAccessRoot: URL?
    private var lastHandledRequest = 0
    private var observations: [NSKeyValueObservation] = []
    private weak var webView: WKWebView?

    init(model: WorkspaceBrowserModel, fileReadAccessRoot: URL?) {
      self.model = model
      self.fileReadAccessRoot = fileReadAccessRoot
    }

    func attach(_ webView: WKWebView) {
      self.webView = webView
      let publish: (WKWebView) -> Void = { [weak self] webView in
        MainActor.assumeIsolated { self?.publish(webView) }
      }
      observations = [
        webView.observe(\.url, options: [.new]) { webView, _ in publish(webView) },
        webView.observe(\.title, options: [.new]) { webView, _ in publish(webView) },
        webView.observe(\.isLoading, options: [.new]) { webView, _ in publish(webView) },
        webView.observe(\.estimatedProgress, options: [.new]) { webView, _ in publish(webView) },
        webView.observe(\.canGoBack, options: [.new]) { webView, _ in publish(webView) },
        webView.observe(\.canGoForward, options: [.new]) { webView, _ in publish(webView) },
      ]
    }

    func detach() {
      observations.removeAll()
    }

    private func publish(_ webView: WKWebView) {
      model.update(
        url: webView.url,
        title: webView.title ?? "",
        isLoading: webView.isLoading,
        progress: webView.estimatedProgress,
        canGoBack: webView.canGoBack,
        canGoForward: webView.canGoForward
      )
    }

    func perform(_ request: WorkspaceBrowserModel.NavigationRequest, in webView: WKWebView) {
      guard request.id != lastHandledRequest else { return }
      lastHandledRequest = request.id
      switch request.action {
      case .load(let url):
        if url.isFileURL {
          let root = fileReadAccessRoot.flatMap { url.path.hasPrefix($0.path + "/") ? $0 : nil }
            ?? url.deletingLastPathComponent()
          webView.loadFileURL(url, allowingReadAccessTo: root)
        } else {
          webView.load(URLRequest(url: url))
        }
      case .back: webView.goBack()
      case .forward: webView.goForward()
      case .reload: webView.reload()
      case .stop: webView.stopLoading()
      }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      report(error)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      model.reportError(nil)
    }

    private func report(_ error: Error) {
      let nsError = error as NSError
      guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
      model.reportError(error.localizedDescription)
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
        decisionHandler(.allow)
        return
      }
      // Hand mail, phone, and app links to macOS.
      if !["http", "https", "file", "about", "blob", "data"].contains(scheme) {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }

    /// `target=_blank` links open in the same view.
    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
        webView.load(URLRequest(url: url))
      }
      return nil
    }
  }
}

// MARK: - Browser surface

struct WorkspaceBrowserView: View {
  @Environment(WorkspaceStore.self) private var store
  @FocusState private var addressFocused: Bool

  var body: some View {
    let browser = store.browser
    VStack(spacing: 0) {
      toolbar(browser)
      if browser.isLoading {
        ProgressView(value: browser.progress)
          .progressViewStyle(.linear)
          .frame(height: 2)
      } else {
        Divider()
      }
      if let error = browser.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.08))
      }
      ZStack {
        WorkspaceWebView(model: browser, fileReadAccessRoot: store.corpusRoot)
          .opacity(browser.currentURL == nil ? 0 : 1)
        if browser.currentURL == nil {
          startPage(browser)
        }
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
    .task { await browser.refreshRunningLocalPorts() }
  }

  private func toolbar(_ browser: WorkspaceBrowserModel) -> some View {
    @Bindable var browser = browser
    return HStack(spacing: 8) {
      Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
        .disabled(!browser.canGoBack)
        .help("Back")
      Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
        .disabled(!browser.canGoForward)
        .help("Forward")
      Button {
        browser.isLoading ? browser.stopLoading() : browser.reload()
      } label: {
        Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
      }
      .disabled(browser.currentURL == nil)
      .help(browser.isLoading ? "Stop" : "Reload")
      TextField("Enter a URL, localhost:3000, a file path, or search", text: $browser.addressText)
        .textFieldStyle(.roundedBorder)
        .focused($addressFocused)
        .onSubmit { browser.submitAddress(corpusRoot: store.corpusRoot) }
        .accessibilityLabel("Address")
      Menu {
        Button("Serve Folder…") { chooseFolderToServe(browser) }
        if !browser.servedSites.isEmpty {
          Divider()
          ForEach(browser.servedSites) { site in
            Menu(site.root.lastPathComponent) {
              Button("Open \(site.url.absoluteString)") { browser.load(site.url) }
              Button("Stop Serving") { browser.stopServing(site) }
            }
          }
        }
        Divider()
        Button("Find Running Local Apps") { Task { await browser.refreshRunningLocalPorts() } }
        ForEach(browser.runningLocalPorts, id: \.self) { port in
          Button("localhost:\(port)") { browser.load(URL(string: "http://localhost:\(port)")!) }
        }
      } label: {
        Image(systemName: "server.rack")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Serve a folder as a local web app, or open a running development server")
      Button {
        if let url = browser.currentURL { NSWorkspace.shared.open(url) }
      } label: {
        Image(systemName: "safari")
      }
      .disabled(browser.currentURL == nil)
      .help("Open in Default Browser")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func startPage(_ browser: WorkspaceBrowserModel) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Browser")
        .font(.title2.weight(.semibold))
      Text("Visit a website, open a local development server such as localhost:5173, or open an HTML file from the corpus. Use Serve Folder to run a static web app over http on this Mac only.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !browser.runningLocalPorts.isEmpty {
        Text("Running on this Mac")
          .font(.headline)
        HStack(spacing: 8) {
          ForEach(browser.runningLocalPorts, id: \.self) { port in
            Button("localhost:\(port)") { browser.load(URL(string: "http://localhost:\(port)")!) }
              .buttonStyle(.bordered)
          }
        }
      }
      HStack(spacing: 10) {
        Button("Serve Folder…") { chooseFolderToServe(browser) }
        Button("Open HTML File…") { chooseHTMLFile(browser) }
      }
      Spacer()
    }
    .padding(28)
    .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func chooseFolderToServe(_ browser: WorkspaceBrowserModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = store.corpusRoot
    panel.prompt = "Serve"
    panel.message = "Choose a folder containing index.html to serve on this Mac only."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await browser.serve(folder: url) }
  }

  private func chooseHTMLFile(_ browser: WorkspaceBrowserModel) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.html]
    panel.directoryURL = store.corpusRoot
    guard panel.runModal() == .OK, let url = panel.url else { return }
    browser.load(url)
  }
}

// MARK: - HTML files in the detail pane

/// Shows a corpus HTML file as a rendered web page, with relative assets
/// resolved inside the corpus, a switch to its source, and actions to open
/// it in the Browser or serve its folder over http.
struct HTMLFilePreviewPane: View {
  @Environment(WorkspaceStore.self) private var store
  let file: String
  let revision: Int
  @State private var model = WorkspaceBrowserModel()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "globe")
          .foregroundStyle(.secondary)
        Text(model.title.isEmpty ? URL(fileURLWithPath: file).lastPathComponent : model.title)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Spacer()
        Button("Source") { store.showHTMLFileSource(true) }
          .help("Edit this file's HTML source")
        Button("Open in Browser") { store.openInBrowser(URL(fileURLWithPath: file)) }
        Button("Serve Folder") {
          let url = URL(fileURLWithPath: file)
          store.makeSurfacePrimary(.browser)
          Task { await store.browser.serve(folder: url.deletingLastPathComponent(), entry: url) }
        }
        .help("Serve this file's folder over http on this Mac only, for pages that need an http origin")
      }
      .buttonStyle(.link)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      if let error = model.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
      }
      Divider()
      WorkspaceWebView(model: model, fileReadAccessRoot: store.corpusRoot)
    }
    .onAppear { model.load(URL(fileURLWithPath: file)) }
    .onChange(of: revision) { _, _ in model.reload() }
  }
}

// MARK: - Store integration

extension WorkspaceStore {
  nonisolated static let htmlPreviewExtensions: Set<String> = ["html", "htm", "xhtml"]

  nonisolated static func isHTMLFile(_ path: String) -> Bool {
    htmlPreviewExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  public var selectedFileIsHTML: Bool {
    guard let file = selectedLocation?.file else { return false }
    return Self.isHTMLFile(file)
  }

  /// Whether the detail pane shows the selected HTML file as a web page.
  public var showsSelectedHTMLFileAsPage: Bool {
    selectedFileIsHTML && !htmlFileShowsSource && !isEditingEntry
  }

  public func showHTMLFileSource(_ showsSource: Bool) {
    htmlFileShowsSource = showsSource
  }

  /// Opens `url` in the Browser surface.
  public func openInBrowser(_ url: URL) {
    browser.load(url)
    makeSurfacePrimary(.browser)
  }
}
