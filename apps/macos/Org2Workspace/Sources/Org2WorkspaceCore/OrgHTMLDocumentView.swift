import AppKit
import SwiftUI
import WebKit

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
  let reportStatus: @MainActor (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.websiteDataStore = .nonPersistent()

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
    coordinator.reportStatus = reportStatus

    let renderID = "\(source.id)|\(html.utf8.count)|\(html.hashValue)"
    if coordinator.renderID != renderID {
      coordinator.renderID = renderID
      coordinator.searchQuery = searchQuery
      coordinator.searchOccurrenceIndex = searchOccurrenceIndex
      webView.loadHTMLString(
        html,
        baseURL: URL(fileURLWithPath: source.file).deletingLastPathComponent()
      )
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

  private static func movesSearchBackward(from previous: Int?, to next: Int?, count: Int) -> Bool {
    guard let previous, let next, count > 1 else { return false }
    if previous == 0 && next == count - 1 { return true }
    if previous == count - 1 && next == 0 { return false }
    return next < previous
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var renderID: String?
    var searchQuery: String?
    var searchOccurrenceIndex: Int?
    var scrollRequestID: Int?
    var openOrgFileReference: @MainActor (OpenClawFileReference) -> Void = { _ in }
    var linkResolver = OrgRoamLinkResolver.empty
    var source: EntrySource?
    var corpusRoot: URL?
    var reportStatus: @MainActor (String) -> Void = { _ in }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
      applySearch(to: webView, backwards: false)
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard navigationAction.navigationType == .linkActivated,
            let url = navigationAction.request.url
      else {
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

      if url.scheme == OpenClawFileReference.deepLinkScheme,
         url.host == "open-link",
         let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
           .queryItems?
           .first(where: { $0.name == "target" })?
           .value {
        open(target: target)
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
      guard let request, case .page(let direction) = request.target else { return }
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
