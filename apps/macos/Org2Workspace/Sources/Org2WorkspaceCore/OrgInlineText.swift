import AppKit
import SwiftUI

struct OrgInlineText: View {
  @EnvironmentObject private var store: WorkspaceStore
  let raw: String
  let font: Font
  let lineSpacing: CGFloat

  init(_ raw: String, font: Font = .body, lineSpacing: CGFloat = 2) {
    self.raw = raw
    self.font = font
    self.lineSpacing = lineSpacing
  }

  var body: some View {
    Text(OrgInlineAttributedString.make(OrgInlineParser.parse(raw), baseFont: font))
      .font(font)
      .lineSpacing(lineSpacing)
      .textSelection(.enabled)
      .environment(\.openURL, OpenURLAction { url in
        if let reference = OpenClawFileReference.fromDeepLinkURL(url) {
          store.openChatFileReference(reference)
          return .handled
        }

        if url.isFileURL {
          store.openChatFileReference(OpenClawFileReference(path: url.path, line: nil))
          return .handled
        }

        if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
          NSWorkspace.shared.open(url)
          return .handled
        }

        return .systemAction
      })
  }
}

enum OrgInlineAttributedString {
  static func make(_ spans: [OrgInlineSpan], baseFont: Font = .body) -> AttributedString {
    var output = AttributedString()
    for span in spans {
      output.append(chunk(for: span, baseFont: baseFont))
    }
    return output
  }

  private static func chunk(for span: OrgInlineSpan, baseFont: Font) -> AttributedString {
    switch span {
    case .text(let text):
      return styledText(text, font: baseFont)
    case .code(let code):
      return styledText(code, font: .system(.body, design: .monospaced), background: Color.secondary.opacity(0.14))
    case .bold(let text):
      return styledText(text, font: baseFont.weight(.semibold))
    case .italic(let text):
      return styledText(text, font: baseFont.italic())
    case .underline(let text):
      var chunk = styledText(text, font: baseFont)
      chunk.underlineStyle = .single
      return chunk
    case .strike(let text):
      var chunk = styledText(text, font: baseFont)
      chunk.strikethroughStyle = .single
      return chunk
    case .timestamp(let timestamp):
      var label = timestamp.dateLabel
      if let timeLabel = timestamp.timeLabel {
        label += " \(timeLabel)"
      }
      var chunk = styledText(label, font: baseFont.monospacedDigit(), background: Color.accentColor.opacity(0.12))
      chunk.foregroundColor = .primary
      return chunk
    case .link(let label, let target, let fileReference):
      var chunk = styledText(label, font: baseFont)
      chunk.foregroundColor = .accentColor
      if let fileReference {
        chunk.link = fileReference.deepLinkURL
      } else if let url = URL(string: target),
                url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
        chunk.link = url
      }
      return chunk
    }
  }

  private static func styledText(_ text: String, font: Font, background: Color? = nil) -> AttributedString {
    var chunk = AttributedString(text)
    chunk.font = font
    if let background {
      chunk.backgroundColor = background
    }
    return chunk
  }
}
