import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

public enum RenderedDocumentWidth: String, CaseIterable, Identifiable, Sendable {
  case readable
  case comfortable
  case wide
  case full

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .readable: "Readable"
    case .comfortable: "Comfortable"
    case .wide: "Wide"
    case .full: "Full Width"
    }
  }

  var cssValue: String {
    switch self {
    case .readable: "760px"
    case .comfortable: "960px"
    case .wide: "1200px"
    case .full: "100%"
    }
  }
}

public enum RenderedDocumentMargin: String, CaseIterable, Identifiable, Sendable {
  case compact
  case standard
  case roomy

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .compact: "Compact"
    case .standard: "Standard"
    case .roomy: "Roomy"
    }
  }

  var cssValue: String {
    switch self {
    case .compact: "16px"
    case .standard: "28px"
    case .roomy: "44px"
    }
  }
}

public enum SourceEditorPresentation: String, CaseIterable, Identifiable, Sendable {
  case source
  case split

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .source: "Source"
    case .split: "Split"
    }
  }

  public var systemImage: String {
    switch self {
    case .source: "doc.plaintext"
    case .split: "rectangle.split.2x1"
    }
  }
}

public enum OrgDocumentPreviewKind: String, CaseIterable, Identifiable, Sendable {
  case document
  case slides

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .document: "Document"
    case .slides: "Slides"
    }
  }

  public var systemImage: String {
    switch self {
    case .document: "doc.richtext"
    case .slides: "rectangle.on.rectangle"
    }
  }
}

public enum OrgDocumentPreviewPreference: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case document
  case slides

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .automatic: "Automatic"
    case .document: "Document"
    case .slides: "Slides"
    }
  }

  public var systemImage: String {
    switch self {
    case .automatic: "wand.and.stars"
    case .document: OrgDocumentPreviewKind.document.systemImage
    case .slides: OrgDocumentPreviewKind.slides.systemImage
    }
  }
}

struct OrgHTMLDocumentLayout: Equatable {
  let width: RenderedDocumentWidth
  let margin: RenderedDocumentMargin
}

struct OrgHTMLTableViewSnapshot: Equatable, Sendable {
  let startLine: Int
  let endLine: Int
  let visibleBodyRowIndices: [Int]
  let totalBodyRowCount: Int
  let filterActive: Bool
  let sortActive: Bool

  init?(_ messageBody: Any) {
    guard let body = messageBody as? [String: Any],
          let startLine = (body["startLine"] as? NSNumber)?.intValue,
          let endLine = (body["endLine"] as? NSNumber)?.intValue,
          let indices = body["visibleBodyRowIndices"] as? [NSNumber],
          let totalBodyRowCount = (body["totalBodyRowCount"] as? NSNumber)?.intValue,
          startLine > 0,
          endLine >= startLine,
          totalBodyRowCount > 0
    else {
      return nil
    }
    let visibleBodyRowIndices = indices.map(\.intValue)
    guard !visibleBodyRowIndices.isEmpty,
          Set(visibleBodyRowIndices).count == visibleBodyRowIndices.count,
          visibleBodyRowIndices.allSatisfy({ $0 >= 0 && $0 < totalBodyRowCount })
    else {
      return nil
    }
    self.startLine = startLine
    self.endLine = endLine
    self.visibleBodyRowIndices = visibleBodyRowIndices
    self.totalBodyRowCount = totalBodyRowCount
    self.filterActive = (body["filterActive"] as? NSNumber)?.boolValue ?? false
    self.sortActive = (body["sortActive"] as? NSNumber)?.boolValue ?? false
  }

  init(
    startLine: Int,
    endLine: Int,
    visibleBodyRowIndices: [Int],
    totalBodyRowCount: Int,
    filterActive: Bool,
    sortActive: Bool
  ) {
    self.startLine = startLine
    self.endLine = endLine
    self.visibleBodyRowIndices = visibleBodyRowIndices
    self.totalBodyRowCount = totalBodyRowCount
    self.filterActive = filterActive
    self.sortActive = sortActive
  }
}

final class OrgHTMLLocalResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
  nonisolated static let scheme = "org2-resource"

  private let lock = NSLock()
  private var sourceDirectory: URL?
  private var corpusRoot: URL?

  func configure(source: EntrySource, corpusRoot: URL?) {
    let sourceURL = OrgHTMLDocumentView.sourceFileURL(source, corpusRoot: corpusRoot)
    lock.withLock {
      sourceDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
      self.corpusRoot = corpusRoot?.standardizedFileURL
    }
  }

  nonisolated static func rewritingLocalImageSources(in html: String) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: #"(<img\b[^>]*\bsrc\s*=\s*")([^"]+)(")"#,
      options: [.caseInsensitive]
    ) else { return html }

    let source = html as NSString
    let matches = expression.matches(
      in: html,
      range: NSRange(location: 0, length: source.length)
    )
    guard !matches.isEmpty else { return html }

    let rewritten = NSMutableString(string: html)
    for match in matches.reversed() {
      guard match.numberOfRanges == 4 else { continue }
      let rawTarget = source.substring(with: match.range(at: 2))
      let target = decodeHTMLAttribute(rawTarget)
      guard isLocalResourceTarget(target),
            let resourceURL = resourceURL(for: target)
      else { continue }
      rewritten.replaceCharacters(in: match.range(at: 2), with: resourceURL.absoluteString)
    }
    return rewritten as String
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let requestURL = urlSchemeTask.request.url,
          let fileURL = fileURL(for: requestURL),
          let contentType = UTType(filenameExtension: fileURL.pathExtension),
          contentType.conforms(to: .image),
          let mimeType = contentType.preferredMIMEType
    else {
      urlSchemeTask.didFailWithError(resourceError(.fileReadNoPermission))
      return
    }

    do {
      let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      let response = URLResponse(
        url: requestURL,
        mimeType: mimeType,
        expectedContentLength: data.count,
        textEncodingName: nil
      )
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    } catch {
      urlSchemeTask.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

  private func fileURL(for requestURL: URL) -> URL? {
    guard requestURL.scheme?.lowercased() == Self.scheme,
          requestURL.host == "local",
          let target = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "target" })?
            .value,
          !target.isEmpty
    else { return nil }

    let roots = lock.withLock { (sourceDirectory, corpusRoot) }
    guard let sourceDirectory = roots.0 else { return nil }
    let expandedTarget = NSString(string: target).expandingTildeInPath
    let candidate: URL
    if let explicitURL = URL(string: expandedTarget), explicitURL.isFileURL {
      candidate = explicitURL
    } else if NSString(string: expandedTarget).isAbsolutePath {
      candidate = URL(fileURLWithPath: expandedTarget)
    } else {
      candidate = sourceDirectory.appendingPathComponent(expandedTarget)
    }

    let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
    let allowedRoots = [roots.1, roots.0]
      .compactMap { $0?.standardizedFileURL.resolvingSymlinksInPath() }
    guard allowedRoots.contains(where: { Self.contains(resolved, within: $0) }) else {
      return nil
    }
    return resolved
  }

  private nonisolated static func contains(_ file: URL, within root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return file.path == root.path || file.path.hasPrefix(rootPath)
  }

  private nonisolated static func isLocalResourceTarget(_ target: String) -> Bool {
    if target.hasPrefix("//") { return false }
    guard let scheme = URL(string: target)?.scheme?.lowercased() else { return true }
    return scheme == "file"
  }

  private nonisolated static func resourceURL(for target: String) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = "local"
    components.queryItems = [URLQueryItem(name: "target", value: target)]
    return components.url
  }

  private nonisolated static func decodeHTMLAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  private func resourceError(_ code: CocoaError.Code) -> Error {
    CocoaError(code, userInfo: [NSLocalizedDescriptionKey: "The local Org2 image could not be loaded."])
  }
}

struct OrgHTMLDocumentView: NSViewRepresentable {
  @Environment(\.openOrgFileReference) private var openOrgFileReference
  @Environment(\.orgRoamLinkResolver) private var linkResolver

  let html: String
  var renderIdentity: String? = nil
  let source: EntrySource
  let corpusRoot: URL?
  let searchQuery: String?
  let searchOccurrenceIndex: Int?
  let searchOccurrenceCount: Int
  let scrollRequest: DetailScrollRequest?
  var restorationSourceLine: Int? = nil
  let layout: OrgHTMLDocumentLayout
  let askAIAboutHeading: @MainActor (Int) -> Void
  let reportStatus: @MainActor (String) -> Void
  var allowsTablePersistence = false
  var saveTableView: @MainActor (OrgHTMLTableViewSnapshot) -> Void = { _ in }
  var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.viewportMessageHandlerName
    )
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.tableViewMessageHandlerName
    )
    configuration.setURLSchemeHandler(
      context.coordinator.localResourceHandler,
      forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme
    )

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.underPageBackgroundColor = .clear
    webView.allowsMagnification = true
    webView.setAccessibilityLabel("Rendered Org2 document")
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.openOrgFileReference = openOrgFileReference
    coordinator.linkResolver = linkResolver
    coordinator.source = source
    coordinator.corpusRoot = corpusRoot
    coordinator.localResourceHandler.configure(source: source, corpusRoot: corpusRoot)
    coordinator.askAIAboutHeading = askAIAboutHeading
    coordinator.reportStatus = reportStatus
    let tablePersistenceChanged = coordinator.allowsTablePersistence != allowsTablePersistence
    coordinator.allowsTablePersistence = allowsTablePersistence
    coordinator.saveTableView = saveTableView
    coordinator.reportViewportSourceLine = reportViewportSourceLine
    coordinator.restorationSourceLine = restorationSourceLine
    let layoutChanged = coordinator.layout != layout
    coordinator.layout = layout

    let renderID = renderIdentity ?? "\(source.id)|\(html.utf8.count)|\(html.hashValue)"
    if coordinator.renderID != renderID {
      coordinator.renderID = renderID
      coordinator.searchQuery = searchQuery
      coordinator.searchOccurrenceIndex = searchOccurrenceIndex
      webView.loadHTMLString(
        OrgHTMLLocalResourceSchemeHandler.rewritingLocalImageSources(in: html),
        baseURL: Self.sourceFileURL(source, corpusRoot: corpusRoot).deletingLastPathComponent()
      )
    } else if layoutChanged {
      coordinator.applyLayout(to: webView)
    } else if tablePersistenceChanged {
      coordinator.applyTablePersistence(to: webView)
    } else if coordinator.searchQuery != searchQuery {
      coordinator.searchQuery = searchQuery
      coordinator.searchOccurrenceIndex = searchOccurrenceIndex
      coordinator.applySearch(to: webView, backwards: false)
    } else if coordinator.searchOccurrenceIndex != searchOccurrenceIndex {
      let previousIndex = coordinator.searchOccurrenceIndex
      coordinator.searchOccurrenceIndex = searchOccurrenceIndex
      let movesBackward = Self.movesSearchBackward(
        from: previousIndex,
        to: searchOccurrenceIndex,
        count: searchOccurrenceCount
      )
      coordinator.applySearch(to: webView, backwards: movesBackward)
    }

    if coordinator.scrollRequestID != scrollRequest?.id {
      coordinator.scrollRequestID = scrollRequest?.id
      coordinator.applyScrollRequest(scrollRequest, to: webView)
    }
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.viewportMessageHandlerName
    )
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.tableViewMessageHandlerName
    )
  }

  private static func movesSearchBackward(from previous: Int?, to next: Int?, count: Int) -> Bool {
    guard let previous, let next, count > 1 else { return false }
    if previous == 0 && next == count - 1 { return true }
    if previous == count - 1 && next == 0 { return false }
    return next < previous
  }

  nonisolated static func sourceFileURL(_ source: EntrySource, corpusRoot: URL?) -> URL {
    let expandedPath = NSString(string: source.file).expandingTildeInPath
    if NSString(string: expandedPath).isAbsolutePath {
      return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }
    if let corpusRoot {
      return corpusRoot.appendingPathComponent(expandedPath).standardizedFileURL
    }
    return URL(fileURLWithPath: expandedPath).standardizedFileURL
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    nonisolated static let viewportMessageHandlerName = "org2ViewportSourceLine"
    nonisolated static let tableViewMessageHandlerName = "org2TableView"
    var renderID: String?
    var searchQuery: String?
    var searchOccurrenceIndex: Int?
    var scrollRequestID: Int?
    var scrollRequest: DetailScrollRequest?
    var restorationSourceLine: Int?
    var layout = OrgHTMLDocumentLayout(width: .comfortable, margin: .standard)
    var openOrgFileReference: @MainActor (OpenClawFileReference) -> Void = { _ in }
    var linkResolver = OrgRoamLinkResolver.empty
    var source: EntrySource?
    var corpusRoot: URL?
    var askAIAboutHeading: @MainActor (Int) -> Void = { _ in }
    var reportStatus: @MainActor (String) -> Void = { _ in }
    var allowsTablePersistence = false
    var saveTableView: @MainActor (OrgHTMLTableViewSnapshot) -> Void = { _ in }
    var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }
    let localResourceHandler = OrgHTMLLocalResourceSchemeHandler()

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
      applyLayout(to: webView)
      applyTablePersistence(to: webView)
      installRichCopyHandler(in: webView)
      installViewportSourceLineReporter(in: webView)
      applySearch(to: webView, backwards: false)
      if let scrollRequest {
        applyScrollRequest(scrollRequest, to: webView)
      } else if let restorationSourceLine {
        applySourceLineScroll(restorationSourceLine, to: webView)
      }
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      switch message.name {
      case Self.viewportMessageHandlerName:
        let line = (message.body as? NSNumber)?.intValue
        reportViewportSourceLine(line.flatMap { $0 > 0 ? $0 : nil })
      case Self.tableViewMessageHandlerName:
        guard allowsTablePersistence,
              let snapshot = OrgHTMLTableViewSnapshot(message.body)
        else { return }
        saveTableView(snapshot)
      default:
        return
      }
    }

    func installViewportSourceLineReporter(in webView: WKWebView) {
      let script = """
      (() => {
        if (window.__org2ViewportSourceLineInstalled) {
          window.__org2ReportViewportSourceLine?.();
          return;
        }
        window.__org2ViewportSourceLineInstalled = true;
        let pending = null;
        const sourceLine = () => {
          const viewportHeight = Math.max(1, window.innerHeight || 1);
          const anchorY = Math.min(Math.max(viewportHeight * 0.32, 48), viewportHeight - 1);
          const entries = Array.from(document.querySelectorAll('[data-org2-start-line]'))
            .map((element) => {
              const start = Number(element.dataset.org2StartLine || 0);
              const end = Number(element.dataset.org2EndLine || start);
              return { start, end, rect: element.getBoundingClientRect() };
            })
            .filter((entry) =>
              entry.start > 0 &&
              entry.rect.bottom >= 0 &&
              entry.rect.top <= viewportHeight
            );
          if (entries.length === 0) return null;
          const containing = entries.filter((entry) =>
            entry.rect.top <= anchorY && entry.rect.bottom >= anchorY
          );
          const candidates = containing.length > 0 ? containing : entries;
          candidates.sort((lhs, rhs) => {
            if (containing.length > 0) {
              const sourceSpan = (lhs.end - lhs.start) - (rhs.end - rhs.start);
              if (sourceSpan !== 0) return sourceSpan;
              const visualSpan = lhs.rect.height - rhs.rect.height;
              if (visualSpan !== 0) return visualSpan;
            }
            return Math.abs(lhs.rect.top - anchorY) - Math.abs(rhs.rect.top - anchorY);
          });
          return candidates[0]?.start || null;
        };
        const report = () => {
          pending = null;
          window.webkit.messageHandlers.\(Self.viewportMessageHandlerName).postMessage(sourceLine());
        };
        window.__org2ReportViewportSourceLine = () => {
          if (pending !== null) clearTimeout(pending);
          pending = setTimeout(report, 80);
        };
        window.addEventListener('scroll', window.__org2ReportViewportSourceLine, { passive: true });
        window.addEventListener('resize', window.__org2ReportViewportSourceLine, { passive: true });
        requestAnimationFrame(window.__org2ReportViewportSourceLine);
      })();
      """
      webView.evaluateJavaScript(script)
    }

    func installRichCopyHandler(in webView: WKWebView) {
      webView.evaluateJavaScript(OrgHTMLRichCopy.installationScript)
    }

    func applyLayout(to webView: WKWebView) {
      let script = """
      document.documentElement.style.setProperty('--org2-content-width', '\(layout.width.cssValue)');
      document.documentElement.style.setProperty('--org2-page-padding', '\(layout.margin.cssValue)');
      """
      webView.evaluateJavaScript(script)
    }

    func applyTablePersistence(to webView: WKWebView) {
      let enabled = allowsTablePersistence ? "true" : "false"
      webView.evaluateJavaScript("window.__org2SetTablePersistenceEnabled?.(\(enabled));")
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.allow)
        return
      }

      if url.scheme?.lowercased() == OpenClawFileReference.deepLinkScheme,
         url.host == "ask-ai",
         let rawLine = URLComponents(url: url, resolvingAgainstBaseURL: false)?
           .queryItems?
           .first(where: { $0.name == "line" })?
           .value,
         let line = Int(rawLine),
         line > 0 {
        askAIAboutHeading(line)
        decisionHandler(.cancel)
        return
      }

      if url.scheme?.lowercased() == OpenClawFileReference.deepLinkScheme,
         url.host == "open-link",
         let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
           .queryItems?
           .first(where: { $0.name == "target" })?
           .value {
        open(target: target)
        decisionHandler(.cancel)
        return
      }

      if url.scheme?.lowercased() == OpenClawFileReference.deepLinkScheme {
        decisionHandler(.cancel)
        return
      }

      guard navigationAction.navigationType == .linkActivated else {
        decisionHandler(.allow)
        return
      }

      if url.scheme?.lowercased() == "http"
          || url.scheme?.lowercased() == "https"
          || url.scheme?.lowercased() == "mailto" {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
      }

      if url.fragment != nil {
        decisionHandler(.allow)
        return
      }

      decisionHandler(.cancel)
    }

    func applySearch(to webView: WKWebView, backwards: Bool) {
      let query = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let configuration = WKFindConfiguration()
      configuration.caseSensitive = false
      configuration.wraps = true
      configuration.backwards = backwards
      webView.find(query, configuration: configuration) { _ in }
    }

    func applyScrollRequest(_ request: DetailScrollRequest?, to webView: WKWebView) {
      scrollRequest = request
      guard let request else { return }
      if case .sourceLine(let line) = request.target {
        applySourceLineScroll(line, to: webView)
        return
      }
      guard case .page(let direction) = request.target else { return }
      guard let scrollView = webView.subviews.compactMap({ $0 as? NSScrollView }).first else { return }
      guard let documentView = scrollView.documentView else { return }
      let clipView = scrollView.contentView
      let visibleHeight = clipView.bounds.height
      guard visibleHeight > 0 else { return }

      let distance = max(120, visibleHeight * 0.8)
      let directionMultiplier: CGFloat = direction == .down ? 1 : -1
      let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
      let maxY = max(0, documentView.bounds.height - visibleHeight)
      var origin = clipView.bounds.origin
      origin.y = min(max(0, origin.y + distance * directionMultiplier * flippedMultiplier), maxY)
      clipView.scroll(to: origin)
      scrollView.reflectScrolledClipView(clipView)
    }

    private func applySourceLineScroll(_ line: Int, to webView: WKWebView) {
      let script = """
        (() => {
          const line = \(line);
          const reveal = () => {
            const elements = Array.from(document.querySelectorAll('[data-org2-start-line]'));
            const candidates = elements.filter((element) => {
              const start = Number(element.dataset.org2StartLine || 0);
              const end = Number(element.dataset.org2EndLine || start);
              return start <= line && end >= line;
            });
            const containingTarget = candidates.sort((lhs, rhs) => {
              const lhsSpan = Number(lhs.dataset.org2EndLine || 0) - Number(lhs.dataset.org2StartLine || 0);
              const rhsSpan = Number(rhs.dataset.org2EndLine || 0) - Number(rhs.dataset.org2StartLine || 0);
              return lhsSpan - rhsSpan;
            })[0];
            const followingTarget = elements
              .filter((element) => Number(element.dataset.org2StartLine || 0) >= line)
              .sort((lhs, rhs) =>
                Number(lhs.dataset.org2StartLine || 0) - Number(rhs.dataset.org2StartLine || 0)
              )[0];
            const precedingTarget = elements
              .filter((element) => Number(element.dataset.org2StartLine || 0) < line)
              .sort((lhs, rhs) =>
                Number(rhs.dataset.org2StartLine || 0) - Number(lhs.dataset.org2StartLine || 0)
              )[0];
            const target = containingTarget || followingTarget || precedingTarget;
            if (target) {
              const viewportHeight = Math.max(1, window.innerHeight || 1);
              const anchorY = Math.min(Math.max(viewportHeight * 0.32, 48), viewportHeight - 1);
              const targetY = window.scrollY + target.getBoundingClientRect().top;
              window.scrollTo({ top: Math.max(0, targetY - anchorY), behavior: 'auto' });
            }
          };
          requestAnimationFrame(() => requestAnimationFrame(reveal));
          setTimeout(reveal, 120);
          setTimeout(reveal, 350);
        })();
        """
      webView.evaluateJavaScript(script)
    }

    private func open(target rawTarget: String) {
      let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !target.isEmpty else { return }

      if let resolved = linkResolver.resolve(target: target) {
        openOrgFileReference(resolved.fileReference)
        return
      }

      if let externalURL = OrgHTMLDocumentLinkRouting.externalURL(
        for: target,
        linkResolver: linkResolver
      ) {
        NSWorkspace.shared.open(externalURL)
        return
      }

      guard let source,
            let fileTarget = OrgHTMLLinkTarget.resolve(
              target,
              relativeTo: source.file,
              corpusRoot: corpusRoot
            )
      else {
        reportStatus("Could not resolve link: \(target)")
        return
      }

      if OrgHTMLDocumentLinkRouting.opensInWorkspace(fileTarget.url) {
        openOrgFileReference(OpenClawFileReference(path: fileTarget.url.path, line: fileTarget.line))
      } else if FileManager.default.fileExists(atPath: fileTarget.url.path) {
        NSWorkspace.shared.open(fileTarget.url)
      } else {
        reportStatus("Linked file not found: \(fileTarget.url.lastPathComponent)")
      }
    }
  }
}

enum OrgHTMLDocumentLinkRouting {
  private static let workspaceExtensions = Set(["org", "org2", "md", "csv", "pdf"])

  static func externalURL(
    for rawTarget: String,
    linkResolver: OrgRoamLinkResolver
  ) -> URL? {
    let expandedTarget = linkResolver.expandedLinkTarget(rawTarget)
    guard let url = URL(string: expandedTarget),
          let scheme = url.scheme?.lowercased(),
          Set(["http", "https", "mailto"]).contains(scheme)
    else {
      return nil
    }
    return url
  }

  static func opensInWorkspace(_ url: URL) -> Bool {
    workspaceExtensions.contains(url.pathExtension.lowercased())
  }
}

enum OrgHTMLRichCopy {
  nonisolated static let installationScript = #"""
  (() => {
    if (window.__org2RichCopyInstalled) return;
    window.__org2RichCopyInstalled = true;

    const copyPayload = () => {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
    const range = selection.getRangeAt(0);
    const selectedText = selection.toString();
    if (!selectedText) return null;

    const tables = Array.from(document.querySelectorAll('table')).filter((table) => {
      try { return range.intersectsNode(table); } catch (_) { return false; }
    });
    const selectedTable = tables.find((table) => {
      const cells = Array.from(table.querySelectorAll('th, td')).filter((cell) => {
        try { return range.intersectsNode(cell); } catch (_) { return false; }
      });
      return cells.length >= 2;
    });

    if (selectedTable) {
      const clone = selectedTable.cloneNode(true);
      clone.removeAttribute('id');
      clone.querySelectorAll('.org2-column-resizer, .org2-table-sort-button').forEach((element) => element.remove());
      clone.querySelectorAll('tr[hidden]').forEach((row) => row.remove());
      clone.style.borderCollapse = 'collapse';
      clone.style.borderSpacing = '0';
      clone.style.fontFamily = '-apple-system, BlinkMacSystemFont, sans-serif';
      clone.style.fontSize = '13px';
      clone.style.color = '#1f2328';
      clone.style.backgroundColor = '#ffffff';
      clone.querySelectorAll('th, td').forEach((cell) => {
        cell.style.border = '1px solid #c8cdd3';
        cell.style.padding = '6px 10px';
        cell.style.textAlign = 'left';
        cell.style.verticalAlign = 'top';
      });
      clone.querySelectorAll('th').forEach((cell) => {
        cell.style.fontWeight = '600';
        cell.style.backgroundColor = '#f2f4f7';
      });
      const text = Array.from(clone.rows).map((row) =>
        Array.from(row.cells).map((cell) => cell.innerText.trim()).join('\t')
      ).join('\n');
      return { html: clone.outerHTML, text };
    }

    const container = document.createElement('div');
    container.appendChild(range.cloneContents());
    return { html: container.innerHTML, text: selectedText };
    };

    document.addEventListener('copy', (event) => {
      const payload = copyPayload();
      if (!payload || !event.clipboardData) return;
      event.clipboardData.setData('text/html', payload.html);
      event.clipboardData.setData('text/plain', payload.text);
      event.preventDefault();
    });
  })();
  """#
}

struct OrgHTMLResolvedFileTarget: Equatable {
  let url: URL
  let line: Int?
}

enum OrgHTMLLinkTarget {
  static func resolve(
    _ rawTarget: String,
    relativeTo sourceFile: String,
    corpusRoot: URL?
  ) -> OrgHTMLResolvedFileTarget? {
    var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    if target.lowercased().hasPrefix("file:") {
      target = String(target.dropFirst(5))
    } else {
      let pathExtension = URL(fileURLWithPath: target).pathExtension
      guard target.contains("/") || !pathExtension.isEmpty else { return nil }
    }

    let components = target.components(separatedBy: "::")
    let rawPath = components[0].removingPercentEncoding ?? components[0]
    guard !rawPath.isEmpty else { return nil }

    let expandedPath: String
    if rawPath == "~" {
      expandedPath = FileManager.default.homeDirectoryForCurrentUser.path
    } else if rawPath.hasPrefix("~/") {
      expandedPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(String(rawPath.dropFirst(2)))
        .path
    } else {
      expandedPath = rawPath
    }

    let url: URL
    if expandedPath.hasPrefix("/") {
      url = URL(fileURLWithPath: expandedPath).standardizedFileURL
    } else {
      let sourceDirectory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
      let sourceRelative = sourceDirectory.appendingPathComponent(expandedPath).standardizedFileURL
      if FileManager.default.fileExists(atPath: sourceRelative.path) || corpusRoot == nil {
        url = sourceRelative
      } else {
        url = corpusRoot!.appendingPathComponent(expandedPath).standardizedFileURL
      }
    }

    let search = components.dropFirst().joined(separator: "::").trimmingCharacters(in: .whitespacesAndNewlines)
    let line: Int?
    if let explicitLine = Int(search) {
      line = max(1, explicitLine)
    } else if !search.isEmpty {
      line = headingLine(search, in: url)
    } else {
      line = nil
    }

    return OrgHTMLResolvedFileTarget(url: url, line: line)
  }

  private static func headingLine(_ rawHeading: String, in url: URL) -> Int? {
    let expected = rawHeading
      .replacingOccurrences(of: #"^\*+\s*"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !expected.isEmpty,
          let source = try? String(contentsOf: url, encoding: .utf8)
    else {
      return nil
    }

    for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let raw = String(line)
      guard raw.first == "*",
            let space = raw.firstIndex(of: " ")
      else {
        continue
      }
      var title = String(raw[raw.index(after: space)...])
        .replacingOccurrences(of: #"\s+:[A-Za-z0-9_@#%:]+:\s*$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
      title = title
        .replacingOccurrences(of: #"^(?:TODO|IN_PROGRESS|DONE|CANCELED|CANCELLED|WAITING|NEXT)\s+"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
      if Org2Display.cleanInline(title).caseInsensitiveCompare(Org2Display.cleanInline(expected)) == .orderedSame {
        return index + 1
      }
    }
    return nil
  }
}
