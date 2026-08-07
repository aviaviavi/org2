import AppKit
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
    if mimeType.hasPrefix("image/") || imageExtensions.contains(fileExtension) {
      return .image
    }
    if mimeType == "application/pdf" || fileExtension == "pdf" {
      return .pdf
    }
    let mayInferGenericText = mimeType.isEmpty || mimeType == "application/octet-stream"
    if mimeType.hasPrefix("text/")
      || textMIMETypes.contains(mimeType)
      || textExtensions.contains(fileExtension)
      || (mayInferGenericText && decodedText(for: attachment) != nil) {
      return .text
    }
    return .unsupported
  }

  static func decodedText(for attachment: OpenClawChatAttachment) -> String? {
    let data = attachment.data
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

struct OpenClawAttachmentPreviewView: View {
  @Environment(\.dismiss) private var dismiss
  let attachment: OpenClawChatAttachment

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

      Button {
        dismiss()
      } label: {
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
    switch OpenClawAttachmentPresentation.previewKind(for: attachment) {
    case .image:
      imagePreview
    case .pdf:
      OrgPDFDocumentView(data: attachment.data)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .text:
      textPreview
    case .unsupported:
      unavailablePreview
    }
  }

  @ViewBuilder
  private var imagePreview: some View {
    if let image = NSImage(data: attachment.data) {
      GeometryReader { proxy in
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
      .padding(20)
      .background(WorkspaceDesign.subtleFill)
    } else {
      unavailablePreview
    }
  }

  @ViewBuilder
  private var textPreview: some View {
    if let text = OpenClawAttachmentPresentation.decodedText(for: attachment) {
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
    } else {
      unavailablePreview
    }
  }

  private var unavailablePreview: some View {
    ContentUnavailableView {
      Label("Preview Unavailable", systemImage: "doc.questionmark")
    } description: {
      Text("Org2 can enlarge images and preview PDF and text attachments in chat.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
