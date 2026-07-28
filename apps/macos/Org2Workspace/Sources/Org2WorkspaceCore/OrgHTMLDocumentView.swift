import AppKit
import SwiftUI
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

struct OrgHTMLDocumentLayout: Equatable {
  let width: RenderedDocumentWidth
  let margin: RenderedDocumentMargin
}

struct OrgHTMLDocumentView: NSViewRepresentable {
  @Environment(\.openOrgFileReference) private var openOrgFileReference
  @Environment(\.orgRoamLinkResolver) private var linkResolver

  let html: String
  let source: EntrySource
  let corpusRoot: URL?
  let searchQuery: String?
  let searchOccurrenceIndex: Int?
  let searchOccurrenceCount: Int
  let scrollRequest: DetailScrollRequest?
  let layout: OrgHTMLDocumentLayout
  let askAIAboutHeading: @MainActor (Int) -> Void
  let reportStatus: @MainActor (String) -> Void
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
    coordinator.askAIAboutHeading = askAIAboutHeading
    coordinator.reportStatus = reportStatus
    coordinator.reportViewportSourceLine = reportViewportSourceLine
    let layoutChanged = coordinator.layout != layout
    coordinator.layout = layout

    let renderID = "\(source.id)|\(html.utf8.count)|\(html.hashValue)"
    if coordinator.renderID != renderID {
      coordinator.renderID = renderID
      coordinator.searchQuery = searchQuery
      coordinator.searchOccurrenceIndex = searchOccurrenceIndex
      webView.loadHTMLString(
        html,
        baseURL: URL(fileURLWithPath: source.file).deletingLastPathComponent()
      )
    } else if layoutChanged {
      coordinator.applyLayout(to: webView)
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
  }

  private static func movesSearchBackward(from previous: Int?, to next: Int?, count: Int) -> Bool {
    guard let previous, let next, count > 1 else { return false }
    if previous == 0 && next == count - 1 { return true }
    if previous == count - 1 && next == 0 { return false }
    return next < previous
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    nonisolated static let viewportMessageHandlerName = "org2ViewportSourceLine"
    var renderID: String?
    var searchQuery: String?
    var searchOccurrenceIndex: Int?
    var scrollRequestID: Int?
    var scrollRequest: DetailScrollRequest?
    var layout = OrgHTMLDocumentLayout(width: .comfortable, margin: .standard)
    var openOrgFileReference: @MainActor (OpenClawFileReference) -> Void = { _ in }
    var linkResolver = OrgRoamLinkResolver.empty
    var source: EntrySource?
    var corpusRoot: URL?
    var askAIAboutHeading: @MainActor (Int) -> Void = { _ in }
    var reportStatus: @MainActor (String) -> Void = { _ in }
    var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
      applyLayout(to: webView)
      installRichCopyHandler(in: webView)
      installViewportSourceLineReporter(in: webView)
      applySearch(to: webView, backwards: false)
      applyScrollRequest(scrollRequest, to: webView)
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == Self.viewportMessageHandlerName else { return }
      let line = (message.body as? NSNumber)?.intValue
      reportViewportSourceLine(line.flatMap { $0 > 0 ? $0 : nil })
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
            const target = candidates.sort((lhs, rhs) => {
              const lhsSpan = Number(lhs.dataset.org2EndLine || 0) - Number(lhs.dataset.org2StartLine || 0);
              const rhsSpan = Number(rhs.dataset.org2EndLine || 0) - Number(rhs.dataset.org2StartLine || 0);
              return lhsSpan - rhsSpan;
            })[0];
            target?.scrollIntoView({ block: 'center', behavior: 'auto' });
          };
          requestAnimationFrame(() => requestAnimationFrame(reveal));
          setTimeout(reveal, 120);
          setTimeout(reveal, 350);
        })();
        """
        webView.evaluateJavaScript(script)
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

    private func open(target rawTarget: String) {
      let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !target.isEmpty else { return }

      if let resolved = linkResolver.resolve(target: target) {
        openOrgFileReference(resolved.fileReference)
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

      let fileExtension = fileTarget.url.pathExtension.lowercased()
      if ["org", "org2", "md"].contains(fileExtension) {
        openOrgFileReference(OpenClawFileReference(path: fileTarget.url.path, line: fileTarget.line))
      } else if FileManager.default.fileExists(atPath: fileTarget.url.path) {
        NSWorkspace.shared.open(fileTarget.url)
      } else {
        reportStatus("Linked file not found: \(fileTarget.url.lastPathComponent)")
      }
    }
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
      const text = Array.from(selectedTable.rows).map((row) =>
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
