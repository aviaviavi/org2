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

struct OrgInlineTextSelectionEnabledKey: EnvironmentKey {
  static let defaultValue = true
}

struct OrgInlineTextSelectionOwnerEnabledKey: EnvironmentKey {
  static let defaultValue = true
}

struct OrgInlineTextActivation {
  let activate: @MainActor (NSRange) -> Void
}

struct OrgInlineTextLinkActivation {
  let activate: @MainActor (URL) -> Void
}

struct OrgInlineTextActivationKey: EnvironmentKey {
  static let defaultValue: OrgInlineTextActivation? = nil
}

struct OrgInlineTextLinkActivationKey: EnvironmentKey {
  static let defaultValue: OrgInlineTextLinkActivation? = nil
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

  var orgInlineTextSelectionEnabled: Bool {
    get { self[OrgInlineTextSelectionEnabledKey.self] }
    set { self[OrgInlineTextSelectionEnabledKey.self] = newValue }
  }

  var orgInlineTextSelectionOwnerEnabled: Bool {
    get { self[OrgInlineTextSelectionOwnerEnabledKey.self] }
    set { self[OrgInlineTextSelectionOwnerEnabledKey.self] = newValue }
  }

  var orgInlineTextActivation: OrgInlineTextActivation? {
    get { self[OrgInlineTextActivationKey.self] }
    set { self[OrgInlineTextActivationKey.self] = newValue }
  }

  var orgInlineTextLinkActivation: OrgInlineTextLinkActivation? {
    get { self[OrgInlineTextLinkActivationKey.self] }
    set { self[OrgInlineTextLinkActivationKey.self] = newValue }
  }
}

struct OrgInlineText: View {
  @Environment(\.openOrgFileReference) private var openOrgFileReference
  @Environment(\.orgRoamLinkResolver) private var orgRoamLinkResolver
  @Environment(\.orgInlineSearchHighlightQuery) private var searchHighlightQuery
  @Environment(\.orgInlineTextSelectionEnabled) private var textSelectionEnabled
  @Environment(\.orgInlineTextSelectionOwnerEnabled) private var textSelectionOwnerEnabled
  @Environment(\.orgInlineTextActivation) private var textActivation
  @Environment(\.orgInlineTextLinkActivation) private var linkActivation
  let raw: String
  let font: Font
  let lineSpacing: CGFloat
  let managesTextSelection: Bool

  init(
    _ raw: String,
    font: Font = .body,
    lineSpacing: CGFloat = 2,
    managesTextSelection: Bool = true
  ) {
    self.raw = raw
    self.font = font
    self.lineSpacing = lineSpacing
    self.managesTextSelection = managesTextSelection
  }

  @ViewBuilder
  var body: some View {
    if textSelectionEnabled {
      if managesTextSelection, textSelectionOwnerEnabled {
        baseText
          .textSelection(.enabled)
      } else {
        baseText
      }
    } else {
      baseText
        .textSelection(.disabled)
        .overlay(alignment: .topLeading) {
          if let textActivation {
            OrgInlineTextActivationOverlay(
              raw: raw,
              font: font,
              lineSpacing: lineSpacing,
              linkResolver: orgRoamLinkResolver,
              activateLink: linkActivation?.activate,
              activate: textActivation.activate
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
          }
        }
    }
  }

  private var baseText: some View {
    renderedText
      .font(font)
      .lineSpacing(lineSpacing)
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

private struct OrgInlineTextActivationOverlay: NSViewRepresentable {
  let raw: String
  let font: Font
  let lineSpacing: CGFloat
  let linkResolver: OrgRoamLinkResolver
  let activateLink: (@MainActor (URL) -> Void)?
  let activate: @MainActor (NSRange) -> Void

  func makeNSView(context: Context) -> HitView {
    let view = HitView()
    view.raw = raw
    view.font = font
    view.lineSpacing = lineSpacing
    view.linkResolver = linkResolver
    view.activateLink = activateLink
    view.activate = activate
    return view
  }

  func updateNSView(_ view: HitView, context: Context) {
    view.raw = raw
    view.font = font
    view.lineSpacing = lineSpacing
    view.linkResolver = linkResolver
    view.activateLink = activateLink
    view.activate = activate
  }

  final class HitView: NSView {
    var raw = ""
    var font = Font.body
    var lineSpacing: CGFloat = 2
    var linkResolver = OrgRoamLinkResolver.empty
    var activateLink: (@MainActor (URL) -> Void)?
    var activate: (@MainActor (NSRange) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
      guard event.type == .leftMouseDown else {
        super.mouseDown(with: event)
        return
      }
      let point = convert(event.locationInWindow, from: nil)
      if let activateLink,
         let url = OrgInlineTextLinkHitTester.linkURL(
          raw: raw,
          linkResolver: linkResolver,
          font: font,
          lineSpacing: lineSpacing,
          bounds: bounds,
          point: point
         ) {
        activateLink(url)
        return
      }
      let range = OrgInlineTextSelectionMapper.selectionRange(
        in: raw,
        font: font,
        lineSpacing: lineSpacing,
        bounds: bounds,
        point: point
      )
      activate?(range)
    }
  }
}

struct OrgInlineRenderedLink: Equatable {
  let label: String
  let target: String
  let url: URL
  let displayRange: NSRange
}

struct OrgInlineRenderedTextLinkMap: Equatable {
  let displayText: String
  let links: [OrgInlineRenderedLink]

  static func make(raw: String, linkResolver: OrgRoamLinkResolver = .empty) -> OrgInlineRenderedTextLinkMap {
    var displayText = ""
    var links: [OrgInlineRenderedLink] = []

    for span in OrgInlineParser.parse(raw, linkResolver: linkResolver) {
      switch span {
      case .text(let text),
           .code(let text),
           .bold(let text),
           .italic(let text),
           .underline(let text),
           .strike(let text):
        displayText += text
      case .color(let binding):
        displayText += binding.label
      case .timestamp(let timestamp):
        displayText += timestampDisplayText(timestamp)
      case .link(let label, let target, let fileReference):
        let start = (displayText as NSString).length
        displayText += label
        guard let url = linkURL(target: target, fileReference: fileReference) else {
          continue
        }
        links.append(OrgInlineRenderedLink(
          label: label,
          target: target,
          url: url,
          displayRange: NSRange(location: start, length: (label as NSString).length)
        ))
      }
    }

    return OrgInlineRenderedTextLinkMap(displayText: displayText, links: links)
  }

  func link(atDisplayUTF16Location location: Int) -> OrgInlineRenderedLink? {
    links.first { link in
      let start = link.displayRange.location
      let end = start + link.displayRange.length
      if link.displayRange.length == 0 {
        return location == start
      }
      return location >= start && location < end
    }
  }

  private static func linkURL(target: String, fileReference: OpenClawFileReference?) -> URL? {
    if let fileReference {
      return fileReference.deepLinkURL
    }
    guard let url = URL(string: target),
          url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
    else {
      return nil
    }
    return url
  }

  private static func timestampDisplayText(_ timestamp: OrgInlineTimestamp) -> String {
    if let timeLabel = timestamp.timeLabel {
      return "\(timestamp.dateLabel) \(timeLabel)"
    }
    return timestamp.dateLabel
  }
}

enum OrgInlineTextLinkHitTester {
  static func linkURL(
    raw: String,
    linkResolver: OrgRoamLinkResolver,
    font: Font,
    lineSpacing: CGFloat,
    bounds: CGRect,
    point: CGPoint
  ) -> URL? {
    let linkMap = OrgInlineRenderedTextLinkMap.make(raw: raw, linkResolver: linkResolver)
    guard !linkMap.links.isEmpty else { return nil }
    let location = OrgInlineTextSelectionMapper.characterLocation(
      in: linkMap.displayText,
      font: font,
      lineSpacing: lineSpacing,
      bounds: bounds,
      point: point
    )
    return linkMap.link(atDisplayUTF16Location: location)?.url
  }
}

enum OrgInlineTextSelectionMapper {
  static func selectionRange(
    in text: String,
    font: Font,
    lineSpacing: CGFloat,
    bounds: CGRect,
    point: CGPoint
  ) -> NSRange {
    NSRange(
      location: mappedUTF16Location(
        in: text,
        font: font,
        lineSpacing: lineSpacing,
        bounds: bounds,
        point: point,
        advancesPastHalfGlyph: true
      ),
      length: 0
    )
  }

  static func characterLocation(
    in text: String,
    font: Font,
    lineSpacing: CGFloat,
    bounds: CGRect,
    point: CGPoint
  ) -> Int {
    mappedUTF16Location(
      in: text,
      font: font,
      lineSpacing: lineSpacing,
      bounds: bounds,
      point: point,
      advancesPastHalfGlyph: false
    )
  }

  private static func mappedUTF16Location(
    in text: String,
    font: Font,
    lineSpacing: CGFloat,
    bounds: CGRect,
    point: CGPoint,
    advancesPastHalfGlyph: Bool
  ) -> Int {
    let utf16Length = (text as NSString).length
    guard utf16Length > 0 else {
      return 0
    }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = lineSpacing
    paragraphStyle.lineBreakMode = .byWordWrapping

    let storage = NSTextStorage(
      string: text,
      attributes: [
        .font: appKitFont(for: font),
        .paragraphStyle: paragraphStyle
      ]
    )
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(
      width: max(1, bounds.width),
      height: CGFloat.greatestFiniteMagnitude
    ))
    container.lineFragmentPadding = 0
    container.lineBreakMode = .byWordWrapping
    container.maximumNumberOfLines = 0

    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: container)

    let glyphRange = layoutManager.glyphRange(for: container)
    guard glyphRange.length > 0 else {
      return utf16Length
    }

    let usedRect = layoutManager.usedRect(for: container)
    let clampedX = min(max(0, point.x), max(0, bounds.width))
    let clampedY = min(max(0, point.y), max(0, max(bounds.height, usedRect.maxY)))
    if clampedY > usedRect.maxY {
      return utf16Length
    }

    var fraction: CGFloat = 0
    let glyphIndex = layoutManager.glyphIndex(
      for: CGPoint(x: clampedX, y: clampedY),
      in: container,
      fractionOfDistanceThroughGlyph: &fraction
    )
    let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
    let adjustedIndex = characterIndex + (advancesPastHalfGlyph && fraction > 0.5 ? 1 : 0)
    return min(utf16Length, max(0, adjustedIndex))
  }

  private static func appKitFont(for font: Font) -> NSFont {
    let description = String(describing: font).lowercased()
    if description.contains("title") {
      return NSFont.systemFont(ofSize: 20, weight: .semibold)
    }
    if description.contains("headline") {
      return NSFont.systemFont(ofSize: 13, weight: .semibold)
    }
    if description.contains("caption") {
      return NSFont.systemFont(ofSize: 11, weight: .regular)
    }
    if description.contains("callout") {
      return NSFont.systemFont(ofSize: 13, weight: .regular)
    }
    if description.contains("monospaced") {
      return NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }
    return NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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
    case .color(let binding):
      var chunk = styledText(binding.label, font: baseFont)
      if let foreground = binding.foreground {
        chunk.foregroundColor = color(foreground)
      }
      if let background = binding.background {
        chunk.backgroundColor = color(background)
      }
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

  private static func color(_ value: OrgColorValue) -> Color {
    Color(
      red: Double((value.rgb >> 16) & 0xff) / 255,
      green: Double((value.rgb >> 8) & 0xff) / 255,
      blue: Double(value.rgb & 0xff) / 255
    )
  }

  private static let searchHighlightColor = Color.yellow.opacity(0.45)
}
