import AppKit
import SwiftUI

struct OpenOrgFileReferenceActionKey: EnvironmentKey {
  static let defaultValue: @MainActor @Sendable (OpenClawFileReference) -> Void = { _ in }
}

struct OrgRoamLinkResolverKey: EnvironmentKey {
  static let defaultValue = OrgRoamLinkResolver.empty
}

struct OrgInlineSearchHighlightQueryKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  var openOrgFileReference: @MainActor @Sendable (OpenClawFileReference) -> Void {
    get { self[OpenOrgFileReferenceActionKey.self] }
    set { self[OpenOrgFileReferenceActionKey.self] = newValue }
  }

  var orgRoamLinkResolver: OrgRoamLinkResolver {
    get { self[OrgRoamLinkResolverKey.self] }
    set { self[OrgRoamLinkResolverKey.self] = newValue }
  }

  var orgInlineSearchHighlightQuery: String? {
    get { self[OrgInlineSearchHighlightQueryKey.self] }
    set { self[OrgInlineSearchHighlightQueryKey.self] = newValue }
  }
}

struct OrgInlineText: View {
  @Environment(\.openOrgFileReference) private var openOrgFileReference
  @Environment(\.orgRoamLinkResolver) private var orgRoamLinkResolver
  @Environment(\.orgInlineSearchHighlightQuery) private var searchHighlightQuery
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
    if let searchHighlightQuery,
       !searchHighlightQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let attributedString = Self.usesAttributedRendering(raw)
        ? OrgInlineAttributedString.cached(raw: raw, baseFont: font, linkResolver: orgRoamLinkResolver)
        : OrgInlineAttributedString.plain(raw, baseFont: font)
      Text(OrgInlineAttributedString.highlightingSearchMatches(
        in: attributedString,
        query: searchHighlightQuery
      ))
    } else if Self.usesAttributedRendering(raw) {
      Text(OrgInlineAttributedString.cached(raw: raw, baseFont: font, linkResolver: orgRoamLinkResolver))
    } else {
      Text(raw)
    }
  }

  nonisolated static func usesAttributedRendering(_ raw: String) -> Bool {
    OrgInlineSyntaxCandidateCache.containsSyntax(raw)
  }
}

enum OrgInlineSyntaxCandidateCache {
  final class CacheKey: NSObject {
    let raw: String
    private let cachedHash: Int

    init(raw: String) {
      self.raw = raw
      self.cachedHash = raw.hashValue
    }

    override var hash: Int {
      cachedHash
    }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return raw == other.raw
    }
  }

  private final class CachedValue {
    let containsSyntax: Bool

    init(_ containsSyntax: Bool) {
      self.containsSyntax = containsSyntax
    }
  }

  nonisolated(unsafe) private static let cache: NSCache<CacheKey, CachedValue> = {
    let cache = NSCache<CacheKey, CachedValue>()
    cache.countLimit = 8_192
    return cache
  }()

  nonisolated static func containsSyntax(_ raw: String) -> Bool {
    guard shouldCacheLookup(raw) else {
      return OrgInlineParser.hasInlineSyntaxCandidate(raw)
    }

    let key = CacheKey(raw: raw)
    if let cached = cache.object(forKey: key) {
      return cached.containsSyntax
    }

    let containsSyntax = OrgInlineParser.hasInlineSyntaxCandidate(raw)
    cache.setObject(CachedValue(containsSyntax), forKey: key)
    return containsSyntax
  }

  nonisolated static func shouldCacheLookup(_ raw: String) -> Bool {
    var count = 0
    for _ in raw.utf8 {
      count += 1
      if count > cacheLookupUTF8Threshold {
        return true
      }
    }
    return false
  }

  private static let cacheLookupUTF8Threshold = 96
}

enum OrgInlineAttributedString {
  final class CacheKey: NSObject {
    let raw: String
    let fontDescription: String
    let linkResolverSignature: String
    private let cachedHash: Int

    init(raw: String, baseFont: Font, linkResolverSignature: String = OrgRoamLinkResolver.empty.signature) {
      self.raw = raw
      self.fontDescription = String(describing: baseFont)
      self.linkResolverSignature = linkResolverSignature
      self.cachedHash = Self.makeHash(
        raw: raw,
        fontDescription: self.fontDescription,
        linkResolverSignature: linkResolverSignature
      )
    }

    init(raw: String, fontDescription: String, linkResolverSignature: String = OrgRoamLinkResolver.empty.signature) {
      self.raw = raw
      self.fontDescription = fontDescription
      self.linkResolverSignature = linkResolverSignature
      self.cachedHash = Self.makeHash(
        raw: raw,
        fontDescription: fontDescription,
        linkResolverSignature: linkResolverSignature
      )
    }

    override var hash: Int {
      cachedHash
    }

    private static func makeHash(raw: String, fontDescription: String, linkResolverSignature: String) -> Int {
      var hasher = Hasher()
      hasher.combine(raw)
      hasher.combine(fontDescription)
      hasher.combine(linkResolverSignature)
      return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return raw == other.raw
        && fontDescription == other.fontDescription
        && linkResolverSignature == other.linkResolverSignature
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
  static func cached(
    raw: String,
    baseFont: Font = .body,
    linkResolver: OrgRoamLinkResolver = .empty
  ) -> AttributedString {
    let key = CacheKey(raw: raw, baseFont: baseFont, linkResolverSignature: linkResolver.signature)
    if let cached = cache.object(forKey: key) {
      return cached.attributedString
    }

    let attributedString = make(OrgInlineParser.parse(raw, linkResolver: linkResolver), baseFont: baseFont)
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

  static func plain(_ raw: String, baseFont: Font = .body) -> AttributedString {
    styledText(raw, font: baseFont)
  }

  static func highlightingSearchMatches(
    in attributedString: AttributedString,
    query rawQuery: String
  ) -> AttributedString {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return attributedString }

    var output = attributedString
    let displayText = String(output.characters)
    var searchStart = displayText.startIndex
    var highlightedAny = false

    while searchStart < displayText.endIndex,
          let range = displayText.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchStart..<displayText.endIndex
          ) {
      guard let lowerBound = AttributedString.Index(range.lowerBound, within: output),
            let upperBound = AttributedString.Index(range.upperBound, within: output)
      else {
        break
      }

      output[lowerBound..<upperBound].backgroundColor = searchHighlightColor
      output[lowerBound..<upperBound].foregroundColor = .primary
      highlightedAny = true
      searchStart = range.upperBound
    }

    return highlightedAny ? output : attributedString
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

  private static let searchHighlightColor = Color.yellow.opacity(0.45)
}
