import AppKit
import ImageIO
import SwiftUI

enum OpenClawAttachmentPreviewKind: Equatable, Sendable {
  case image
  case pdf
  case text
  case unsupported
}

extension OpenClawAttachmentPresentation {
  static func previewKind(for attachment: OpenClawChatAttachment) -> OpenClawAttachmentPreviewKind {
    let mimeType = attachment.mimeType.lowercased()
    let fileExtension = URL(fileURLWithPath: attachment.fileName).pathExtension.lowercased()
    if mimeType.hasPrefix("image/") || imageExtensions.contains(fileExtension) { return .image }
    if mimeType == "application/pdf" || fileExtension == "pdf" { return .pdf }
    if mimeType.hasPrefix("text/")
      || textMIMETypes.contains(mimeType)
      || textExtensions.contains(fileExtension) {
      return .text
    }
    return .unsupported
  }

  static func decodedText(data: Data) -> String? {
    let value: String?
    if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
      value = String(data: data, encoding: .utf16)
    } else {
      value = String(data: data, encoding: .utf8)
    }
    guard let value else { return nil }
    let hasBinaryControlCharacter = value.unicodeScalars.contains { scalar in
      scalar.value < 0x20
        && scalar.value != 0x09
        && scalar.value != 0x0a
        && scalar.value != 0x0d
    }
    return hasBinaryControlCharacter ? nil : value
  }

  private static let imageExtensions: Set<String> = [
    "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
  ]

  private static let textMIMETypes: Set<String> = [
    "application/javascript", "application/json", "application/sql", "application/xml",
    "application/x-httpd-php", "application/x-sh", "application/x-yaml"
  ]

  private static let textExtensions: Set<String> = [
    "c", "cc", "conf", "cpp", "css", "csv", "go", "h", "hpp", "html", "java", "js", "json",
    "jsx", "kt", "log", "md", "markdown", "mjs", "org", "org2", "php", "plist", "py", "rb",
    "rs", "sh", "sql", "swift", "toml", "ts", "tsv", "tsx", "txt", "xml", "yaml", "yml", "zsh"
  ]
}

/// Decoded Core Graphics images are immutable after construction. The wrapper
/// makes that ownership explicit while I/O and ImageIO decoding happen on the
/// cache actor rather than in a SwiftUI body.
final class OpenClawAttachmentImageBox: @unchecked Sendable {
  let image: CGImage
  init(_ image: CGImage) { self.image = image }
}

enum OpenClawLoadedAttachmentPreview: @unchecked Sendable {
  case image(OpenClawAttachmentImageBox)
  case pdf(Data)
  case text(String)
  case unavailable
}

actor OpenClawAttachmentBackgroundCache {
  static let shared = OpenClawAttachmentBackgroundCache()
  private static let imageLimit = 24

  private var images: [String: OpenClawAttachmentImageBox] = [:]
  private var imageOrder: [String] = []

  func image(for attachment: OpenClawChatAttachment) throws -> OpenClawAttachmentImageBox {
    let key = attachment.persistedContentDigest
    if let cached = images[key] {
      touch(key)
      return cached
    }
    let data = try attachment.loadData()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
          )
    else {
      throw OpenClawChatAttachment.DataError.unreadableBlob(attachment.fileName)
    }
    let box = OpenClawAttachmentImageBox(image)
    images[key] = box
    touch(key)
    while imageOrder.count > Self.imageLimit, let oldest = imageOrder.first {
      imageOrder.removeFirst()
      images.removeValue(forKey: oldest)
    }
    return box
  }

  func preview(for attachment: OpenClawChatAttachment) throws -> OpenClawLoadedAttachmentPreview {
    switch OpenClawAttachmentPresentation.previewKind(for: attachment) {
    case .image:
      return .image(try image(for: attachment))
    case .pdf:
      return .pdf(try attachment.loadData())
    case .text:
      let data = try attachment.loadData()
      guard let text = OpenClawAttachmentPresentation.decodedText(data: data) else {
        return .unavailable
      }
      return .text(text)
    case .unsupported:
      let mimeType = attachment.mimeType.lowercased()
      if mimeType.isEmpty || mimeType == "application/octet-stream" {
        let data = try attachment.loadData()
        if let text = OpenClawAttachmentPresentation.decodedText(data: data) {
          return .text(text)
        }
      }
      return .unavailable
    }
  }

  private func touch(_ key: String) {
    imageOrder.removeAll { $0 == key }
    imageOrder.append(key)
  }
}

struct OpenClawAsyncAttachmentImage<Placeholder: View>: View {
  let attachment: OpenClawChatAttachment
  let placeholder: (_ error: String?) -> Placeholder
  @State private var image: OpenClawAttachmentImageBox?
  @State private var errorText: String?

  init(
    attachment: OpenClawChatAttachment,
    @ViewBuilder placeholder: @escaping (_ error: String?) -> Placeholder
  ) {
    self.attachment = attachment
    self.placeholder = placeholder
  }

  var body: some View {
    Group {
      if let image {
        Image(decorative: image.image, scale: 1)
          .resizable()
          .scaledToFill()
      } else {
        placeholder(errorText)
      }
    }
    .task(id: "\(attachment.id.uuidString)-\(attachment.persistedContentDigest)") {
      guard OpenClawAttachmentPresentation.previewKind(for: attachment) == .image else {
        image = nil
        errorText = nil
        return
      }
      do {
        image = try await OpenClawAttachmentBackgroundCache.shared.image(for: attachment)
        errorText = nil
      } catch {
        image = nil
        errorText = error.localizedDescription
      }
    }
  }
}

struct OpenClawAttachmentPreviewView: View {
  @Environment(\.dismiss) private var dismiss
  let attachment: OpenClawChatAttachment
  @State private var loadedPreview: OpenClawLoadedAttachmentPreview?
  @State private var loadError: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      preview
    }
    .frame(
      minWidth: 640,
      idealWidth: 960,
      maxWidth: .infinity,
      minHeight: 480,
      idealHeight: 720,
      maxHeight: .infinity
    )
    .background(WorkspaceDesign.surfaceBackground)
    .task(id: "\(attachment.id.uuidString)-\(attachment.persistedContentDigest)") {
      do {
        loadedPreview = try await OpenClawAttachmentBackgroundCache.shared.preview(for: attachment)
        loadError = nil
      } catch {
        loadedPreview = nil
        loadError = error.localizedDescription
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: OpenClawAttachmentPresentation.systemImage(for: attachment.mimeType))
        .font(.headline)
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(attachment.fileName)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 20)

      Button { dismiss() } label: {
        Image(systemName: "xmark")
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .help("Close attachment preview")
      .accessibilityLabel("Close attachment preview")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var preview: some View {
    if let loadError {
      unavailablePreview(detail: loadError)
    } else if let loadedPreview {
      switch loadedPreview {
      case .image(let box):
        GeometryReader { proxy in
          Image(decorative: box.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(20)
        .background(WorkspaceDesign.subtleFill)
      case .pdf(let data):
        OrgPDFDocumentView(data: data)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .text(let text):
        ScrollView([.horizontal, .vertical]) {
          Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
      case .unavailable:
        unavailablePreview(detail: "OpenOrg can enlarge images and preview PDF and text attachments in chat.")
      }
    } else {
      ProgressView("Loading attachment…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func unavailablePreview(detail: String) -> some View {
    ContentUnavailableView {
      Label("Preview Unavailable", systemImage: "doc.questionmark")
    } description: {
      Text(detail)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
