import Foundation
import WebKit

@MainActor
final class Org2PDFExporter: NSObject, WKNavigationDelegate {
  private var webView: WKWebView?
  private var navigationContinuation: CheckedContinuation<Void, Error>?

  func data(for html: String, baseURL: URL?) async throws -> Data {
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056))
    self.webView = webView
    webView.navigationDelegate = self
    webView.loadHTMLString(html, baseURL: baseURL)
    try await withCheckedThrowingContinuation { continuation in
      navigationContinuation = continuation
    }
    let configuration = WKPDFConfiguration()
    let data = try await withCheckedThrowingContinuation { continuation in
      webView.createPDF(configuration: configuration) { result in
        continuation.resume(with: result)
      }
    }
    self.webView = nil
    return data
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    navigationContinuation?.resume()
    navigationContinuation = nil
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    navigationContinuation?.resume(throwing: error)
    navigationContinuation = nil
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    navigationContinuation?.resume(throwing: error)
    navigationContinuation = nil
  }
}
