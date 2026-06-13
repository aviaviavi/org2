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
    renderedText
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

  @ViewBuilder
  private var renderedText: some View {
    if Self.usesAttributedRendering(raw) {
      Text(OrgInlineAttributedString.cached(raw: raw, baseFont: font))
    } else {
      Text(raw)
    }
  }

  nonisolated static func usesAttributedRendering(_ raw: String) -> Bool {
    OrgInlineParser.hasInlineSyntaxCandidate(raw)
  }
}

enum OrgInlineAttributedString {
  final class CacheKey: NSObject {
    let raw: String
    let fontDescription: String
    private let cachedHash: Int

    init(raw: String, baseFont: Font) {
      self.raw = raw
      self.fontDescription = String(describing: baseFont)
      self.cachedHash = Self.makeHash(raw: raw, fontDescription: self.fontDescription)
    }

    init(raw: String, fontDescription: String) {
      self.raw = raw
      self.fontDescription = fontDescription
      self.cachedHash = Self.makeHash(raw: raw, fontDescription: fontDescription)
    }

    override var hash: Int {
      cachedHash
    }

    private static func makeHash(raw: String, fontDescription: String) -> Int {
      var hasher = Hasher()
      hasher.combine(raw)
      hasher.combine(fontDescription)
      return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return raw == other.raw && fontDescription == other.fontDescription
    }
  }

  private final class CachedValue {
    let attributedString: AttributedString

    init(_ attributedString: AttributedString) {
      self.attributedString = attributedString
    }
  }

  @MainActor private static let cache: NSCache<CacheKey, CachedValue> = {
    let cache = NSCache<CacheKey, CachedValue>()
    cache.countLimit = 4_096
    return cache
  }()

  @MainActor
  static func cached(raw: String, baseFont: Font = .body) -> AttributedString {
    let key = CacheKey(raw: raw, baseFont: baseFont)
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
