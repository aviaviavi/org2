import AppKit
import SwiftUI

struct OpenOrgFileReferenceActionKey: EnvironmentKey {
  static let defaultValue: @MainActor @Sendable (OpenClawFileReference) -> Void = { _ in }
}

extension EnvironmentValues {
  var openOrgFileReference: @MainActor @Sendable (OpenClawFileReference) -> Void {
    get { self[OpenOrgFileReferenceActionKey.self] }
    set { self[OpenOrgFileReferenceActionKey.self] = newValue }
  }
}

struct OrgInlineText: View {
  @Environment(\.openOrgFileReference) private var openOrgFileReference
  let raw: String
  let font: Font
  let lineSpacing: CGFloat

  init(_ raw: String, font: Font = .body, lineSpacing: CGFloat = 2) {
    self.raw = raw
    self.font = font
    self.lineSpacing = lineSpacing
  }

  var body: some View {
    Text(OrgInlineAttributedString.cached(raw: raw, baseFont: font))
      .font(font)
      .lineSpacing(lineSpacing)
      .textSelection(.enabled)
      .environment(\.openURL, OpenURLAction { url in
        if let reference = OpenClawFileReference.fromDeepLinkURL(url) {
          openOrgFileReference(reference)
          return .handled
        }

        if url.isFileURL {
          openOrgFileReference(OpenClawFileReference(path: url.path, line: nil))
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
  private final class CachedValue {
    let attributedString: AttributedString

    init(_ attributedString: AttributedString) {
      self.attributedString = attributedString
    }
  }

  @MainActor private static let cache = NSCache<NSString, CachedValue>()

  @MainActor
  static func cached(raw: String, baseFont: Font = .body) -> AttributedString {
    let key = cacheKey(raw: raw, baseFont: baseFont)
    if let cached = cache.object(forKey: key) {
      return cached.attributedString
    }

    let attributedString = make(OrgInlineParser.parse(raw), baseFont: baseFont)
    cache.setObject(CachedValue(attributedString), forKey: key)
    return attributedString
  }

  static func make(_ spans: [OrgInlineSpan], baseFont: Font = .body) -> AttributedString {
    var output = AttributedString()
    for span in spans {
      output.append(chunk(for: span, baseFont: baseFont))
    }
    return output
  }

  private static func cacheKey(raw: String, baseFont: Font) -> NSString {
    "\(String(describing: baseFont))\u{1F}\(raw)" as NSString
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
