import Foundation
import WebKit

enum Org2PDFExporterError: LocalizedError, Equatable {
  case invalidPDF

  var errorDescription: String? {
    "The document renderer completed without producing a PDF."
  }
}

@MainActor
final class Org2PDFExporter: NSObject, WKNavigationDelegate {
  private var webView: WKWebView?
  private var navigationContinuation: CheckedContinuation<Void, Error>?

  func data(for html: String, baseURL: URL?) async throws -> Data {
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056))
    self.webView = webView
    webView.navigationDelegate = self
    webView.loadHTMLString(Self.preparedHTML(for: html), baseURL: baseURL)
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
    return try Self.validated(data)
  }

  nonisolated static func validated(_ data: Data) throws -> Data {
    guard data.starts(with: Data("%PDF".utf8)) else {
      throw Org2PDFExporterError.invalidPDF
    }
    return data
  }

  nonisolated static func preparedHTML(for html: String) -> String {
    let printStyle = #"""
    <style id="org2-pdf-document-style">
      @page { margin: 0.55in; }
      :root {
        color-scheme: light only;
        --org2-text: #1f2421 !important;
        --org2-muted: #5e6b66 !important;
        --org2-faint: rgba(40, 84, 215, 0.065) !important;
        --org2-rule: #d7d6ce !important;
        --org2-code: #f1f3ef !important;
        --org2-surface: #fcfbf7 !important;
        --org2-elevated-surface: #ffffff !important;
        --org2-shadow: transparent !important;
        --org2-link: #2854d7 !important;
        --org2-accent: #2854d7 !important;
        --org2-signal: #c2472c !important;
      }
      html, body {
        background: #ffffff !important;
        color: #1f2421 !important;
        overflow: visible !important;
      }
      body { padding: 0 !important; }
      main.org2-document {
        box-sizing: border-box !important;
        width: 100% !important;
        max-width: none !important;
        min-height: 0 !important;
        margin: 0 !important;
        background: transparent !important;
        border: 0 !important;
        box-shadow: none !important;
      }
      .org2-file-properties,
      .org2-properties-drawer,
      .org2-drawer,
      .org2-heading-ai-action,
      .org2-column-resizer,
      .org2-table-controls,
      .org2-table-sort-button,
      .org2-large-source > summary {
        display: none !important;
      }
      .org2-headline-summary {
        padding-left: 0 !important;
        cursor: default !important;
      }
      .org2-document-title::before,
      .org2-headline-summary::before,
      .org2-headline-summary > h1::before,
      .org2-headline-summary > h2::before,
      .org2-headline-summary > h3::before,
      .org2-headline-summary > h4::before,
      .org2-headline-summary > h5::before,
      .org2-headline-summary > h6::before,
      .org2-section-label::before,
      summary::-webkit-details-marker {
        display: none !important;
        content: none !important;
      }
      .org2-headline-body > .org2-headline {
        border-left: 0 !important;
        margin-left: 0 !important;
        padding-left: 0 !important;
      }
      .org2-table-scroll { overflow: visible !important; }
      img, table, pre, blockquote, figure, .org2-chart {
        break-inside: avoid;
      }
      a { color: inherit; text-decoration: underline; }
    </style>
    """#

    // Reader disclosures defer large source layout, but exports must include
    // the complete source even when it was never expanded in the reader.
    var prepared = html.replacingOccurrences(
      of: "<details class=\"org2-large-source\"",
      with: "<details open class=\"org2-large-source\""
    )
    guard let headEnd = prepared.range(of: "</head>", options: .caseInsensitive) else {
      return printStyle + "\n" + prepared
    }
    prepared.insert(contentsOf: printStyle + "\n", at: headEnd.lowerBound)
    return prepared
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
