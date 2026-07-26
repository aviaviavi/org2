import PDFKit
import SwiftUI

struct OrgPDFDocumentView: NSViewRepresentable {
  let data: Data

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.backgroundColor = .textBackgroundColor
    view.displayDirection = .vertical
    view.displayMode = .singlePageContinuous
    view.displaysPageBreaks = true
    view.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    update(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
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
  }

  final class Coordinator {
    var data: Data?
  }
}
