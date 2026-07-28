import PDFKit
import SwiftUI

struct OrgPDFDocumentView: NSViewRepresentable {
  let data: Data
  var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }

  func makeCoordinator() -> Coordinator {
    Coordinator(reportViewportSourceLine: reportViewportSourceLine)
  }

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.backgroundColor = .textBackgroundColor
    view.displayDirection = .vertical
    view.displayMode = .singlePageContinuous
    view.displaysPageBreaks = true
    view.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    context.coordinator.observePageChanges(in: view)
    update(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
    context.coordinator.reportViewportSourceLine = reportViewportSourceLine
    update(view, coordinator: context.coordinator)
  }

  private func update(_ view: PDFView, coordinator: Coordinator) {
    guard coordinator.data != data else { return }
    let currentPageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
    guard let document = PDFDocument(data: data) else { return }

    coordinator.data = data
    view.document = document
    if let currentPageIndex,
       let page = document.page(at: min(currentPageIndex, max(0, document.pageCount - 1))) {
      view.go(to: page)
    }
    coordinator.reportCurrentPage(in: view)
  }

  nonisolated static func sourceLine(from url: URL?) -> Int? {
    guard let url,
          url.scheme?.lowercased() == "org2-source-line",
          let host = url.host,
          let line = Int(host),
          line > 0
    else {
      return nil
    }
    return line
  }

  @MainActor
  final class Coordinator {
    var data: Data?
    var reportViewportSourceLine: @MainActor (Int?) -> Void
    nonisolated(unsafe) private var pageChangeObserver: NSObjectProtocol?

    init(reportViewportSourceLine: @escaping @MainActor (Int?) -> Void) {
      self.reportViewportSourceLine = reportViewportSourceLine
    }

    deinit {
      if let pageChangeObserver {
        NotificationCenter.default.removeObserver(pageChangeObserver)
      }
    }

    func observePageChanges(in view: PDFView) {
      if let pageChangeObserver {
        NotificationCenter.default.removeObserver(pageChangeObserver)
      }
      pageChangeObserver = NotificationCenter.default.addObserver(
        forName: .PDFViewPageChanged,
        object: view,
        queue: .main
      ) { [weak self, weak view] _ in
        MainActor.assumeIsolated {
          guard let self, let view else { return }
          self.reportCurrentPage(in: view)
        }
      }
    }

    func reportCurrentPage(in view: PDFView) {
      let sourceLine = view.currentPage?
        .annotations
        .lazy
        .compactMap(\.url)
        .compactMap(OrgPDFDocumentView.sourceLine(from:))
        .first
      reportViewportSourceLine(sourceLine)
    }
  }
}
