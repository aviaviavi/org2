import Foundation
import WebKit

/// Live HTML previews and plugin renderers in chat are script-enabled,
/// opaque-origin sandboxed frames.
///
/// The compiler emits them as `srcdoc` frames. An `about:srcdoc` document
/// inherits its parent's Content Security Policy, and the chat page forbids all
/// page scripts, so a `srcdoc` frame could never run its own scripts there.
/// Before such a frame is attached, the chat page moves its document into an
/// `org2-frame:` URL. This handler serves that document as a separate
/// navigation, so only the frame's own policy applies and the chat page keeps
/// `script-src 'none'`.
enum AIChatSandboxFrames {
  static let scheme = "org2-frame"
  static let documentQueryItem = "document"
  static let sizeMessageType = "org2-frame-size"
  static let maximumHeight = 1600

  /// Page-world JavaScript shared by both chat web views. Defines
  /// `__org2PrepareSandboxFrames(root)` and resizes frames that ask for it.
  /// Frames that keep same-origin access or have no script permission (for
  /// example live embeds) stay `srcdoc` documents under the chat page policy.
  static let script = #"""
  (() => {
    if (window.__org2PrepareSandboxFrames) return;
    window.__org2PrepareSandboxFrames = root => {
      for (const frame of root.querySelectorAll('iframe[srcdoc][sandbox]')) {
        const tokens = (frame.getAttribute('sandbox') || '').toLowerCase().split(/\s+/);
        if (!tokens.includes('allow-scripts') || tokens.includes('allow-same-origin')) continue;
        const source = frame.getAttribute('srcdoc');
        frame.removeAttribute('srcdoc');
        frame.setAttribute('src', '\#(scheme)://frame/?\#(documentQueryItem)=' + encodeURIComponent(source));
      }
    };
    addEventListener('message', event => {
      const data = event.data;
      if (!data || data.type !== '\#(sizeMessageType)' || !Number.isFinite(data.height)) return;
      for (const frame of document.querySelectorAll('iframe[data-org2-autosize="true"]')) {
        if (frame.contentWindow !== event.source) continue;
        const chrome = frame.offsetHeight - frame.clientHeight;
        frame.style.height = Math.min(\#(maximumHeight), Math.max(24, Math.ceil(data.height))) + chrome + 'px';
        break;
      }
    });
  })();
  """#

  /// The policy every served frame document also carries in its own `<meta>`
  /// element: no nested frames, plugins, base rewriting, or form targets.
  static let baselinePolicy = "base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'"

  static func document(from url: URL) -> String? {
    guard url.scheme?.lowercased() == scheme,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    return components.queryItems?.first(where: { $0.name == documentQueryItem })?.value
  }
}

final class AIChatSandboxFrameSchemeHandler: NSObject, WKURLSchemeHandler {
  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url,
          let document = AIChatSandboxFrames.document(from: url),
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": AIChatSandboxFrames.baselinePolicy,
            "Cache-Control": "no-store",
          ])
    else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(Data(document.utf8))
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
