import AppKit
import SwiftUI
import WebKit

/// One document owns wrapping, list layout, hit testing and the selection range.
/// There are no event monitors or independently measured selection rectangles.
struct AIChatDocumentBody: View {
  @Environment(\.aiChatMediaCorpusRoot) private var corpusRoot
  @Environment(\.openOrgFileReference) private var openFileReference
  @Environment(\.orgRoamLinkResolver) private var linkResolver
  @State private var html: String?
  @State private var renderedText: String?
  @State private var height: CGFloat = 24
  let text: String
  let formatted: Bool
  private struct RenderKey: Equatable { let text: String; let sourcePath: String; let formatted: Bool }

  var body: some View {
    AIChatDocumentWebView(
      html: renderedText == text ? (html ?? AIChatDocumentHTML.plain(text)) : AIChatDocumentHTML.plain(text),
      sourcePath: sourcePath,
      corpusRoot: corpusRoot,
      linkResolver: linkResolver,
      height: $height,
      openFileReference: openFileReference
    )
    .frame(height: height)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: RenderKey(text: text, sourcePath: sourcePath, formatted: formatted)) {
      guard formatted else { html = nil; renderedText = nil; return }
      do {
        // Coalesce streaming updates. Completed messages share a bounded render cache.
        try await Task.sleep(for: .milliseconds(120))
        let result = try await AIChatDocumentRenderCache.shared.render(text, sourcePath: sourcePath)
        try Task.checkCancellation()
        html = result
        renderedText = text
      } catch is CancellationError {
      } catch {
        // Keep a fully selectable plain document if the compiler is unavailable.
        html = nil
        renderedText = text
      }
    }
  }

  private var sourcePath: String {
    (corpusRoot ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("chat-message.org").path
  }
}

actor AIChatDocumentRenderCache {
  static let shared = AIChatDocumentRenderCache()
  private struct Key: Hashable { let text: String; let sourcePath: String }
  private var cache: [Key: String] = [:]
  private var order: [Key] = []
  private var pending: [Key: Task<String, Error>] = [:]
  private var tail: Task<String, Error>?

  func render(_ text: String, sourcePath: String) async throws -> String {
    let key = Key(text: text, sourcePath: sourcePath)
    if let cached = cache[key] { return cached }
    if let task = pending[key] { return try await task.value }
    let previous = tail
    let task = Task {
      _ = try? await previous?.value
      try Task.checkCancellation()
      let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
      return try await cli.renderAppHTML(text, sourcePath: sourcePath)
    }
    pending[key] = task
    tail = task
    do {
      let html = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      pending[key] = nil
      cache[key] = html
      order.append(key)
      while order.count > 32 { cache[order.removeFirst()] = nil }
      return html
    } catch {
      pending[key] = nil
      throw error
    }
  }
}

enum AIChatDocumentHTML {
  static func plain(_ text: String) -> String {
    let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body><main class=\"org2-document\"><div class=\"chat-plain\">\(escaped)</div></main></body></html>"
  }

  static let style = """
  :root { color-scheme: light dark; }
  html, body { margin:0!important; padding:0!important; min-height:0!important; height:auto!important; background:transparent!important; }
  body { font: 13px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; color: light-dark(#202020,#e7e7e7); overflow-wrap:anywhere; -webkit-user-select:text; }
  main.org2-document { width:100%!important; max-width:none!important; margin:0!important; padding:0!important; }
  main.org2-document > :first-child { margin-top:0; }
  main.org2-document > :last-child { margin-bottom:0; }
  .org2-document-header { display:none; }
  .chat-plain { white-space:pre-wrap; }
  li > p:first-child { margin-top:0; }
  li > p:last-child { margin-bottom:0; }
  pre { white-space:pre; overflow-x:auto; }
  .chat-code { position:relative; }
  .chat-code pre { padding-top:32px; }
  .chat-copy-code { position:absolute; top:5px; right:6px; font:11px -apple-system; color:inherit; background:transparent; border:0; border-radius:4px; padding:3px 6px; cursor:pointer; -webkit-user-select:none; }
  .chat-copy-code:hover { background:rgba(128,128,128,.16); }
  img { max-width:100%; height:auto; }
  """

  static let updateScript = #"""
  (() => {
    let pending = null;
    const selected = () => { const s = getSelection(); return s && !s.isCollapsed; };
    const measure = () => requestAnimationFrame(() => {
      const root = document.querySelector('main') || document.body;
      const height = Math.ceil(root.getBoundingClientRect().height);
      window.webkit.messageHandlers.chatHeight.postMessage(Math.max(24, height));
    });
    window.__chatUpdate = html => {
      if (selected()) { pending = html; return; }
      const next = new DOMParser().parseFromString(html, 'text/html');
      const styles = next.querySelectorAll('style');
      document.querySelectorAll('style[data-chat-renderer]').forEach(s => s.remove());
      for (const style of styles) {
        const copy = document.createElement('style'); copy.dataset.chatRenderer = '1';
        copy.textContent = style.textContent; document.head.prepend(copy);
      }
      // Message HTML is compiler output. Imported scripts are deliberately not executed.
      next.querySelectorAll('script, .org2-document-header').forEach(s => s.remove());
      for (const pre of next.querySelectorAll('pre')) {
        const wrapper=next.createElement('div'); wrapper.className='chat-code';
        pre.replaceWith(wrapper); wrapper.append(pre);
        const button=next.createElement('button'); button.className='chat-copy-code';
        button.textContent='Copy code'; button.setAttribute('aria-label','Copy code');
        button.addEventListener('click', () => {
          window.webkit.messageHandlers.chatCopyCode.postMessage(pre.textContent.replace(/\n$/, ''));
        });
        wrapper.append(button);
      }
      document.body.replaceChildren(...next.body.childNodes);
      pending = null;
      measure();
    };
    document.addEventListener('selectionchange', () => {
      if (!selected() && pending !== null) window.__chatUpdate(pending);
    });
    new ResizeObserver(measure).observe(document.body);
    document.addEventListener('load', measure, true);
    measure();
  })();
  """#
}

struct AIChatDocumentWebView: NSViewRepresentable {
  let html: String
  let sourcePath: String
  let corpusRoot: URL?
  let linkResolver: OrgRoamLinkResolver
  @Binding var height: CGFloat
  let openFileReference: (OpenClawFileReference) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(context.coordinator, name: "chatHeight")
    configuration.userContentController.add(context.coordinator, name: "chatCopyCode")
    configuration.userContentController.addUserScript(WKUserScript(
      source: AIChatDocumentHTML.updateScript + "\n" + OrgHTMLRichCopy.installationScript,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true
    ))
    configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme)
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.underPageBackgroundColor = .clear
    view.setValue(false, forKey: "drawsBackground")
    view.setAccessibilityLabel("Chat message document")
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onHeight = { next in if abs(height - next) > 0.5 { height = next } }
    coordinator.openFileReference = openFileReference
    coordinator.linkResolver = linkResolver
    coordinator.sourcePath = sourcePath
    coordinator.corpusRoot = corpusRoot
    coordinator.resources.configure(source: EntrySource(file: sourcePath, startLine: 1,
      endLineExclusive: 1, text: "", isSubtree: false), corpusRoot: corpusRoot)
    guard coordinator.html != html else { return }
    coordinator.html = html
    if !coordinator.loaded {
      if !coordinator.loading {
        coordinator.loading = true
        view.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src https: http: data: org2-resource:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'\"><style>\(AIChatDocumentHTML.style)</style></head><body><main></main></body></html>",
          baseURL: URL(fileURLWithPath: sourcePath).deletingLastPathComponent())
      }
    } else {
      coordinator.update(view)
    }
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.linkTask?.cancel()
    view.navigationDelegate = nil
    view.configuration.userContentController.removeScriptMessageHandler(forName: "chatHeight")
    view.configuration.userContentController.removeScriptMessageHandler(forName: "chatCopyCode")
    view.stopLoading()
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let resources = OrgHTMLLocalResourceSchemeHandler()
    var html: String?
    var loaded = false
    var loading = false
    var onHeight: ((CGFloat) -> Void)?
    var openFileReference: ((OpenClawFileReference) -> Void)?
    var linkResolver = OrgRoamLinkResolver.empty
    var sourcePath = ""
    var corpusRoot: URL?
    var linkTask: Task<Void, Never>?


    func update(_ view: WKWebView) {
      guard let html else { return }
      let rewritten = OrgHTMLLocalResourceSchemeHandler.rewritingLocalImageSources(in: html)
      view.callAsyncJavaScript("window.__chatUpdate(html)", arguments: ["html": rewritten], in: nil, in: .page)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded = true
      update(webView)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.frameInfo.isMainFrame else { return }
      if message.name == "chatCopyCode", let text = message.body as? String {
        OpenClawMessageClipboard.write(text)
        return
      }
      guard let value = message.body as? Double,
        value.isFinite, value >= 0 else { return }
      onHeight?(CGFloat(value))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
      guard navigationAction.navigationType == .linkActivated,
        let url = navigationAction.request.url else { decisionHandler(.allow); return }
      decisionHandler(.cancel)
      if url.scheme == OpenClawFileReference.deepLinkScheme, url.host == "open-link",
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "target" })?.value {
        if let resolved = linkResolver.resolve(target: target) {
          openFileReference?(resolved.fileReference)
        } else if let external = OrgHTMLDocumentLinkRouting.externalURL(for: target, linkResolver: linkResolver) {
          NSWorkspace.shared.open(external)
        } else {
          linkTask?.cancel()
          linkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await OrgHTMLLinkTarget.resolve(target, relativeTo: sourcePath, corpusRoot: corpusRoot)
            guard !Task.isCancelled, let resolved else { return }
            openFileReference?(OpenClawFileReference(path: resolved.url.path, line: resolved.line))
          }
        }
      } else if let reference = OpenClawFileReference.fromDeepLinkURL(url) {
        openFileReference?(reference)
      } else if url.isFileURL {
        openFileReference?(OpenClawFileReference(path: url.path, line: nil))
      } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
        NSWorkspace.shared.open(url)
      }
    }
  }
}
