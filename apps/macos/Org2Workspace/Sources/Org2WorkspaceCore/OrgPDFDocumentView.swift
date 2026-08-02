import PDFKit
import SwiftUI

struct OrgPDFDocumentView: NSViewRepresentable {
  let data: Data
  var scrollRequest: DetailScrollRequest? = nil
  var restorationSourceLine: Int? = nil
  var restorationPageIndex: Int? = nil
  var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }
  var reportViewportPageIndex: @MainActor (Int?) -> Void = { _ in }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      reportViewportSourceLine: reportViewportSourceLine,
      reportViewportPageIndex: reportViewportPageIndex
    )
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
    context.coordinator.reportViewportPageIndex = reportViewportPageIndex
    update(view, coordinator: context.coordinator)
  }

  func update(_ view: PDFView, coordinator: Coordinator) {
    if coordinator.data != data {
      let currentPageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
      let currentSourceLine = view.currentPage.flatMap(Self.sourceLine(for:))
      guard let document = PDFDocument(data: data) else { return }

      coordinator.data = data
      coordinator.scrollRequestID = scrollRequest?.id
      coordinator.isReplacingDocument = true
      view.document = document
      let requestedSourceLine = scrollRequest.flatMap(Self.sourceLine(from:))
      let restoredPageIndex = requestedSourceLine
        .flatMap { Self.pageIndex(nearestSourceLine: $0, in: document) }
        ?? restorationPageIndex.map {
          min(max(0, $0), max(0, document.pageCount - 1))
        }
        ?? restorationSourceLine.flatMap { Self.pageIndex(nearestSourceLine: $0, in: document) }
        ?? currentPageIndex
        ?? currentSourceLine.flatMap { Self.pageIndex(nearestSourceLine: $0, in: document) }
      if let restoredPageIndex,
         let page = document.page(at: min(restoredPageIndex, max(0, document.pageCount - 1))) {
        view.go(to: page)
      }
      coordinator.isReplacingDocument = false
      coordinator.reportCurrentPage(in: view)
    }

    guard coordinator.scrollRequestID != scrollRequest?.id else { return }
    coordinator.scrollRequestID = scrollRequest?.id
    guard let sourceLine = scrollRequest.flatMap(Self.sourceLine(from:)),
          let document = view.document,
          let pageIndex = Self.pageIndex(nearestSourceLine: sourceLine, in: document),
          let page = document.page(at: pageIndex)
    else {
      return
    }
    coordinator.isReplacingDocument = true
    view.go(to: page)
    coordinator.isReplacingDocument = false
    coordinator.reportCurrentPage(in: view)
  }

  nonisolated static func sourceLine(from request: DetailScrollRequest) -> Int? {
    guard case .sourceLine(let line) = request.target else { return nil }
    return line
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

  nonisolated static func sourceLine(for page: PDFPage) -> Int? {
    page.annotations
      .lazy
      .compactMap(\.url)
      .compactMap(sourceLine(from:))
      .first
  }

  nonisolated static func pageIndex(
    nearestSourceLine sourceLine: Int,
    in document: PDFDocument
  ) -> Int? {
    (0..<document.pageCount)
      .compactMap { index -> (index: Int, distance: Int)? in
        guard let page = document.page(at: index),
              let markerLine = Self.sourceLine(for: page)
        else {
          return nil
        }
        return (index, abs(markerLine - sourceLine))
      }
      .min {
        if $0.distance != $1.distance {
          return $0.distance < $1.distance
        }
        return $0.index < $1.index
      }?
      .index
  }

  @MainActor
  final class Coordinator {
    var data: Data?
    var scrollRequestID: Int?
    var reportViewportSourceLine: @MainActor (Int?) -> Void
    var reportViewportPageIndex: @MainActor (Int?) -> Void
    var isReplacingDocument = false
    nonisolated(unsafe) private var pageChangeObserver: NSObjectProtocol?

    init(
      reportViewportSourceLine: @escaping @MainActor (Int?) -> Void,
      reportViewportPageIndex: @escaping @MainActor (Int?) -> Void
    ) {
      self.reportViewportSourceLine = reportViewportSourceLine
      self.reportViewportPageIndex = reportViewportPageIndex
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
          guard let self, let view, !self.isReplacingDocument else { return }
          self.reportCurrentPage(in: view)
        }
      }
    }

    func reportCurrentPage(in view: PDFView) {
      let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
      reportViewportPageIndex(pageIndex)
      reportViewportSourceLine(view.currentPage.flatMap(OrgPDFDocumentView.sourceLine(for:)))
    }
  }
}
