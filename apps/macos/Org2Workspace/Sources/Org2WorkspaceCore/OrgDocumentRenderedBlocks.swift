import AppKit
import AVKit
import ImageIO
import SwiftUI

struct RenderedBlockView: View, Equatable {
  let block: OrgRenderedBlock
  let rawText: String?
  let editableBlock: OrgEditableBlock?
  let sourceFile: String?
  let corpusRoot: URL?
  let inlineActions: RenderedBlockInlineActions

  init(
    block: OrgRenderedBlock,
    rawText: String? = nil,
    editableBlock: OrgEditableBlock? = nil,
    sourceFile: String? = nil,
    corpusRoot: URL? = nil,
    inlineActions: RenderedBlockInlineActions = .readOnly
  ) {
    self.block = block
    self.rawText = rawText
    self.editableBlock = editableBlock
    self.sourceFile = sourceFile
    self.corpusRoot = corpusRoot
    self.inlineActions = inlineActions
  }

  nonisolated static func == (lhs: RenderedBlockView, rhs: RenderedBlockView) -> Bool {
    if let lhsEditableBlock = lhs.editableBlock,
       let rhsEditableBlock = rhs.editableBlock {
      return lhsEditableBlock.renderIdentity == rhsEditableBlock.renderIdentity
        && lhs.sourceFile == rhs.sourceFile
        && lhs.corpusRoot == rhs.corpusRoot
        && lhs.inlineActions.isSourceEditable == rhs.inlineActions.isSourceEditable
        && lhs.inlineActions.sourceBlockRunState == rhs.inlineActions.sourceBlockRunState
    }

    return lhs.block == rhs.block
      && lhs.rawText == rhs.rawText
      && lhs.editableBlock == rhs.editableBlock
      && lhs.sourceFile == rhs.sourceFile
      && lhs.corpusRoot == rhs.corpusRoot
      && lhs.inlineActions.isSourceEditable == rhs.inlineActions.isSourceEditable
      && lhs.inlineActions.sourceBlockRunState == rhs.inlineActions.sourceBlockRunState
  }

  var body: some View {
    switch block {
    case .heading(let heading):
      RenderedHeadingView(
        heading: heading,
        rawText: rawText,
        editableBlock: editableBlock,
        inlineActions: inlineActions
      )
    case .planning(let planning):
      RenderedPlanningView(planning: planning, inlineActions: inlineActions)
    case .properties(let rows):
      RenderedPropertiesView(rows: rows, rawText: rawText, inlineActions: inlineActions)
    case .quote(let lines):
      RenderedQuoteView(lines: lines, rawText: rawText)
    case .source(let language, let lines):
      RenderedSourceView(language: language, lines: lines, inlineActions: inlineActions)
    case .table(let table):
      RenderedTableView(table: table)
    case .horizontalRule:
      RenderedHorizontalRuleView()
    case .listItem(let indent, let marker, let checkbox, let text):
      RenderedListItemView(
        indent: indent,
        marker: marker,
        checkbox: checkbox,
        text: text,
        rawText: rawText,
        editableBlock: editableBlock,
        inlineActions: inlineActions
      )
    case .paragraph(let text):
      let paragraphText = rawText ?? text
      if let attachment = OrgMediaAttachmentRenderCache.standalone(
          raw: paragraphText,
          sourceFile: sourceFile,
          corpusRoot: corpusRoot
         ) {
        OrgMediaAttachmentView(attachment: attachment)
      } else {
        OrgInlineText(paragraphText)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    case .keyword(let key, let value):
      RenderedKeywordView(key: key, value: value, rawText: rawText)
    case .blank:
      Spacer()
        .frame(height: 4)
    }
  }
}

enum OrgMediaAttachmentRenderCache {
  final class CacheKey: NSObject {
    let raw: String
    let sourceFile: String
    let corpusRootPath: String
    private let cachedHash: Int

    init(raw: String, sourceFile: String?, corpusRoot: URL?) {
      self.raw = raw
      self.sourceFile = sourceFile ?? ""
      self.corpusRootPath = corpusRoot?.standardizedFileURL.path ?? ""
      self.cachedHash = Self.makeHash(
        raw: raw,
        sourceFile: self.sourceFile,
        corpusRootPath: self.corpusRootPath
      )
    }

    override var hash: Int {
      cachedHash
    }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return raw == other.raw
        && sourceFile == other.sourceFile
        && corpusRootPath == other.corpusRootPath
    }

    private static func makeHash(raw: String, sourceFile: String, corpusRootPath: String) -> Int {
      var hasher = Hasher()
      hasher.combine(raw)
      hasher.combine(sourceFile)
      hasher.combine(corpusRootPath)
      return hasher.finalize()
    }
  }

  private final class CachedValue {
    let attachment: OrgMediaAttachment?

    init(_ attachment: OrgMediaAttachment?) {
      self.attachment = attachment
    }
  }

  nonisolated(unsafe) private static let cache: NSCache<CacheKey, CachedValue> = {
    let cache = NSCache<CacheKey, CachedValue>()
    cache.countLimit = 4_096
    return cache
  }()

  nonisolated static func standalone(raw: String, sourceFile: String? = nil, corpusRoot: URL? = nil) -> OrgMediaAttachment? {
    guard shouldAttemptStandaloneLookup(raw: raw) else { return nil }
    let key = CacheKey(raw: raw, sourceFile: sourceFile, corpusRoot: corpusRoot)
    if let cached = cache.object(forKey: key) {
      return cached.attachment
    }

    let attachment = OrgMediaAttachment.standalone(raw: raw, sourceFile: sourceFile, corpusRoot: corpusRoot)
    cache.setObject(CachedValue(attachment), forKey: key)
    return attachment
  }

  nonisolated static func shouldAttemptStandaloneLookup(raw: String) -> Bool {
    OrgMediaAttachment.mayContainStandaloneMedia(raw)
  }
}

enum OrgPropertyDrawerRawValueCache {
  final class CacheKey: NSObject {
    let rawText: String
    private let cachedHash: Int

    init(rawText: String) {
      self.rawText = rawText
      self.cachedHash = rawText.hashValue
    }

    override var hash: Int {
      cachedHash
    }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return rawText == other.rawText
    }
  }

  private final class CachedValue {
    let values: [String: String]

    init(_ values: [String: String]) {
      self.values = values
    }
  }

  nonisolated(unsafe) private static let cache: NSCache<CacheKey, CachedValue> = {
    let cache = NSCache<CacheKey, CachedValue>()
    cache.countLimit = 4_096
    return cache
  }()

  nonisolated static func values(_ rawText: String?) -> [String: String] {
    guard let rawText else { return [:] }

    let key = CacheKey(rawText: rawText)
    if let cached = cache.object(forKey: key) {
      return cached.values
    }

    let parsedValues = parseValues(rawText)
    cache.setObject(CachedValue(parsedValues), forKey: key)
    return parsedValues
  }

  private static func parseValues(_ rawText: String) -> [String: String] {
    var values: [String: String] = [:]
    for line in rawText.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(":"),
            let secondColon = trimmed.dropFirst().firstIndex(of: ":")
      else {
        continue
      }
      let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<secondColon]).uppercased()
      let value = String(trimmed[trimmed.index(after: secondColon)...]).trimmingCharacters(in: .whitespaces)
      guard key != "PROPERTIES", key != "END" else { continue }
      values[key] = value
    }
    return values
  }
}

enum OrgRenderedLineDisplayCache {
  final class CacheKey: NSObject {
    let kind: String
    let rawText: String
    let fallback: String
    private let cachedHash: Int

    init(kind: String, rawText: String, fallback: String) {
      self.kind = kind
      self.rawText = rawText
      self.fallback = fallback
      var hasher = Hasher()
      hasher.combine(kind)
      hasher.combine(rawText)
      hasher.combine(fallback)
      self.cachedHash = hasher.finalize()
    }

    override var hash: Int {
      cachedHash
    }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return kind == other.kind
        && rawText == other.rawText
        && fallback == other.fallback
    }
  }

  private final class CachedValue {
    let value: String

    init(_ value: String) {
      self.value = value
    }
  }

  nonisolated(unsafe) private static let cache: NSCache<CacheKey, CachedValue> = {
    let cache = NSCache<CacheKey, CachedValue>()
    cache.countLimit = 8_192
    return cache
  }()

  nonisolated static func headingTitle(rawText: String?, fallback: String) -> String {
    cached(kind: "heading-title", rawText: rawText, fallback: fallback, parse: parseHeadingTitle)
  }

  nonisolated static func listText(rawText: String?, fallback: String) -> String {
    cached(kind: "list-text", rawText: rawText, fallback: fallback, parse: parseListText)
  }

  nonisolated static func keywordValue(rawText: String?, fallback: String) -> String {
    cached(kind: "keyword-value", rawText: rawText, fallback: fallback, parse: parseKeywordValue)
  }

  private static func cached(
    kind: String,
    rawText: String?,
    fallback: String,
    parse: (String, String) -> String
  ) -> String {
    guard let rawText else { return fallback }
    let key = CacheKey(kind: kind, rawText: rawText, fallback: fallback)
    if let cached = cache.object(forKey: key) {
      return cached.value
    }

    let value = parse(rawText, fallback)
    cache.setObject(CachedValue(value), forKey: key)
    return value
  }

  private static func parseHeadingTitle(rawText: String, fallback: String) -> String {
    guard let line = firstLine(in: rawText) else { return fallback }
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return fallback }

    var rest = String(line.dropFirst(stars.count)).trimmingCharacters(in: .whitespaces)
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if let first = tokens.first, todoKeywords.contains(first.uppercased()) {
      tokens.removeFirst()
    }
    if let first = tokens.first,
       first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }
    return tokens.joined(separator: " ")
  }

  private static func parseListText(rawText: String, fallback: String) -> String {
    guard let line = firstLine(in: rawText) else { return fallback }
    let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
    let rest = String(line.dropFirst(leadingWhitespace.count))
    guard let separator = rest.firstIndex(where: { $0.isWhitespace }) else { return fallback }
    let textStart = rest[separator...].firstIndex { !$0.isWhitespace } ?? rest.endIndex
    return stripCheckbox(String(rest[textStart...]))
  }

  private static func parseKeywordValue(rawText: String, fallback: String) -> String {
    guard let line = firstLine(in: rawText) else { return fallback }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let separator = trimmed.firstIndex(of: ":") else { return fallback }
    return String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
  }

  private static func firstLine(in rawText: String) -> Substring? {
    guard !rawText.isEmpty else { return nil }
    guard let newline = rawText.firstIndex(of: "\n") else {
      return rawText[...]
    }
    return rawText[..<newline]
  }

  private static func stripCheckbox(_ text: String) -> String {
    if text.hasPrefix("[ ] ") || text.hasPrefix("[X] ") || text.hasPrefix("[x] ") || text.hasPrefix("[-] ") {
      return String(text.dropFirst(4))
    }
    return text
  }

  private static let todoKeywords = Set(["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"])
}

struct RenderedBlockInlineActions: Sendable {
  let isSourceEditable: Bool
  let toggleHeadingTodo: (@MainActor @Sendable () -> Void)?
  let setHeadingPriority: (@MainActor @Sendable (String?) -> Void)?
  let setHeadingTags: (@MainActor @Sendable ([String]) -> Void)?
  let setPlanningBlock: (@MainActor @Sendable (_ kind: String, _ value: String) -> Void)?
  let setPropertyValue: (@MainActor @Sendable (_ key: String, _ value: String) -> Void)?
  let toggleListItemCheckbox: (@MainActor @Sendable () -> Void)?
  let sourceBlockRunState: SourceBlockRunState?
  let runSourceBlock: (@MainActor @Sendable () -> Void)?

  static let readOnly = RenderedBlockInlineActions(
    isSourceEditable: false,
    toggleHeadingTodo: nil,
    setHeadingPriority: nil,
    setHeadingTags: nil,
    setPlanningBlock: nil,
    setPropertyValue: nil,
    toggleListItemCheckbox: nil,
    sourceBlockRunState: nil,
    runSourceBlock: nil
  )
}

private struct RenderedHorizontalRuleView: View {
  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.24))
      .frame(height: 1)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel("Divider")
  }
}

private struct OrgMediaAttachmentView: View {
  let attachment: OrgMediaAttachment

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch attachment.kind {
      case .image:
        OrgImageAttachmentView(attachment: attachment)
      case .video:
        OrgVideoAttachmentView(attachment: attachment)
      }

      HStack(spacing: 8) {
        Label(attachment.displayName, systemImage: attachment.kind == .image ? "photo" : "film")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        if let url = attachment.resolvedURL {
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          } label: {
            Image(systemName: "folder")
          }
          .buttonStyle(.borderless)
          .help("Reveal")

          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Image(systemName: "arrow.up.right.square")
          }
          .buttonStyle(.borderless)
          .help("Open")
        }
      }
      .controlSize(.small)
    }
    .frame(maxWidth: 760, alignment: .leading)
    .padding(.vertical, 4)
  }
}

enum RenderedMediaPreviewPolicy {
  static let autoloadsVideoPlayerOnAppear = false
}

private struct OrgImageAttachmentView: View {
  let attachment: OrgMediaAttachment
  @State private var image: NSImage?
  @State private var attemptedLoad = false
  @State private var activeLoadPath: String?

  @MainActor private static let thumbnailCache = NSCache<NSString, NSImage>()

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 760, maxHeight: 460, alignment: .leading)
      } else {
        MissingMediaView(kind: attachment.kind, name: attachment.displayName, attemptedLoad: attemptedLoad)
          .frame(maxWidth: 760, minHeight: 96)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.secondary.opacity(0.16))
    )
    .task(id: attachment.resolvedPath) {
      guard let url = attachment.resolvedURL else {
        attemptedLoad = true
        image = nil
        activeLoadPath = nil
        return
      }

      let cacheKey = url.standardizedFileURL.path as NSString
      if let cached = Self.thumbnailCache.object(forKey: cacheKey) {
        image = cached
        attemptedLoad = true
        activeLoadPath = nil
        return
      }

      activeLoadPath = url.standardizedFileURL.path
      attemptedLoad = false
      let loaded = await Task.detached(priority: .utility) {
        LoadedAttachmentImage(image: Self.previewImage(for: url))
      }.value
      guard !Task.isCancelled else { return }
      guard activeLoadPath == url.standardizedFileURL.path else { return }
      if let loadedImage = loaded.image {
        Self.thumbnailCache.setObject(loadedImage, forKey: cacheKey)
      }
      image = loaded.image
      attemptedLoad = true
      activeLoadPath = nil
    }
  }

  nonisolated private static func previewImage(for url: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [
      kCGImageSourceShouldCache: false
    ] as CFDictionary) else {
      return NSImage(contentsOf: url)
    }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCache: false,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: 1_520
    ]

    if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
      return NSImage(
        cgImage: thumbnail,
        size: NSSize(width: thumbnail.width, height: thumbnail.height)
      )
    }

    return NSImage(contentsOf: url)
  }

  private struct LoadedAttachmentImage: @unchecked Sendable {
    let image: NSImage?
  }
}

private struct OrgVideoAttachmentView: View {
  let attachment: OrgMediaAttachment
  @State private var player: AVPlayer?
  @State private var isPlaying = false

  var body: some View {
    Group {
      if isPlaying, let player {
        VideoPlayer(player: player)
          .frame(maxWidth: 760, minHeight: 260, maxHeight: 420)
      } else {
        videoPoster
          .frame(maxWidth: 760, minHeight: 180)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.secondary.opacity(0.16))
    )
    .onAppear {
      if RenderedMediaPreviewPolicy.autoloadsVideoPlayerOnAppear {
        startPlayback()
      }
    }
    .onDisappear {
      player?.pause()
    }
  }

  private var videoPoster: some View {
    Button {
      startPlayback()
    } label: {
      VStack(spacing: 10) {
        Image(systemName: attachment.resolvedURL == nil ? "film" : "play.circle.fill")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(attachment.resolvedURL == nil ? .secondary : .primary)
        Text(attachment.resolvedURL == nil ? "Video unavailable" : "Play video")
          .font(.callout.weight(.medium))
        Text(attachment.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(16)
      .background(Color.secondary.opacity(0.06))
    }
    .buttonStyle(.plain)
    .disabled(attachment.resolvedURL == nil)
  }

  private func startPlayback() {
    guard let url = attachment.resolvedURL else { return }
    if player == nil {
      player = AVPlayer(url: url)
    }
    isPlaying = true
    player?.play()
  }
}

private struct MissingMediaView: View {
  let kind: OrgMediaAttachment.Kind
  let name: String
  let attemptedLoad: Bool

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: kind == .image ? "photo" : "film")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(attemptedLoad ? "Media unavailable" : "Loading media")
        .font(.callout.weight(.medium))
      Text(name)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(14)
    .background(Color.secondary.opacity(0.06))
  }
}

private struct RenderedHeadingView: View {
  let heading: OrgHeadingBlock
  let rawText: String?
  let editableBlock: OrgEditableBlock?
  let inlineActions: RenderedBlockInlineActions

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let todo = heading.todo {
        RenderedHeadingTodoButton(todo: todo, inlineActions: inlineActions)
      }
      if let priority = heading.priority {
        RenderedHeadingPriorityMenu(priority: priority, inlineActions: inlineActions)
      }
      OrgInlineText(rawTitle, font: font)
      if !heading.tags.isEmpty {
        RenderedHeadingTagsButton(tags: heading.tags, inlineActions: inlineActions)
      }
      Spacer(minLength: 0)
    }
    .padding(.top, topPadding)
    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 14)
  }

  private var font: Font {
    switch heading.level {
    case 1:
      return .title3.weight(.semibold)
    case 2:
      return .headline.weight(.semibold)
    case 3:
      return .callout.weight(.semibold)
    default:
      return .body.weight(.semibold)
    }
  }

  private var topPadding: CGFloat {
    heading.level == 1 ? 2 : 8
  }

  private var rawTitle: String {
    OrgRenderedLineDisplayCache.headingTitle(rawText: rawText, fallback: heading.title)
  }
}

private struct RenderedHeadingTodoButton: View {
  let todo: String
  let inlineActions: RenderedBlockInlineActions

  var body: some View {
    Button {
      inlineActions.toggleHeadingTodo?()
    } label: {
      StatusPill(text: todo)
    }
    .buttonStyle(.plain)
    .disabled(inlineActions.toggleHeadingTodo == nil || !inlineActions.isSourceEditable)
    .help(nextStatus.map { "Mark \($0)" } ?? "Status")
  }

  private var nextStatus: String? {
    WorkspaceStore.nextHeadingTodoStatus(after: todo)
  }
}

private struct RenderedHeadingPriorityMenu: View {
  let priority: String
  let inlineActions: RenderedBlockInlineActions

  var body: some View {
    Menu {
      Button("None") {
        setPriority(nil)
      }
      Divider()
      ForEach(["A", "B", "C"], id: \.self) { value in
        Button("[#\(value)]") {
          setPriority(value)
        }
      }
    } label: {
      Label(priority, systemImage: "flag.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
        .labelStyle(.titleAndIcon)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(inlineActions.setHeadingPriority == nil || !inlineActions.isSourceEditable)
    .help("Priority")
  }

  private func setPriority(_ value: String?) {
    inlineActions.setHeadingPriority?(value)
  }
}

private struct RenderedHeadingTagsButton: View {
  let tags: [String]
  let inlineActions: RenderedBlockInlineActions
  @State private var isPresented = false
  @State private var draftTags = ""

  var body: some View {
    Button {
      draftTags = tags.joined(separator: " ")
      isPresented = true
    } label: {
      Text(tags.map { "#\($0)" }.joined(separator: " "))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .disabled(inlineActions.setHeadingTags == nil || !inlineActions.isSourceEditable)
    .help("Tags")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        Label("Tags", systemImage: "tag")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        TextField("work focus", text: $draftTags)
          .textFieldStyle(.roundedBorder)
          .frame(width: 220)

        HStack(spacing: 8) {
          Button("Clear") {
            saveTags([])
          }
          Spacer(minLength: 0)
          Button("Save") {
            saveTags(parsedDraftTags)
          }
          .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
      }
      .padding(12)
    }
  }

  private var parsedDraftTags: [String] {
    draftTags
      .split { $0.isWhitespace || $0 == "," }
      .map { token in
        String(token).trimmingCharacters(in: CharacterSet(charactersIn: "#:"))
      }
      .filter { !$0.isEmpty }
  }

  private func saveTags(_ tags: [String]) {
    inlineActions.setHeadingTags?(tags)
    isPresented = false
  }
}

private struct RenderedPlanningView: View {
  let planning: OrgPlanningBlock
  let inlineActions: RenderedBlockInlineActions
  @State private var isEditingValue = false
  @State private var draftValue = ""

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(["SCHEDULED", "DEADLINE", "CLOSED"], id: \.self) { kind in
          Button(kind.capitalized) {
            setPlanning(kind: kind, value: planning.value)
          }
        }
      } label: {
        Text(planning.kind.capitalized)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(width: 78, alignment: .leading)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(!isEditable)
      .help("Planning kind")

      if let timestamp = OrgTimestampDisplay.parse(planning.value) {
        Button {
          beginEditingValue()
        } label: {
          HStack(spacing: 6) {
            TimestampPill(systemImage: "calendar", text: timestamp.dateLabel)
            if let time = timestamp.timeLabel {
              TimestampPill(systemImage: "clock", text: time)
            }
            if let detail = timestamp.detail {
              Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .help("Planning value")
        .popover(isPresented: $isEditingValue, arrowEdge: .bottom) {
          planningValuePopover
        }
      } else {
        Button {
          beginEditingValue()
        } label: {
          Text(planning.value)
            .font(.callout.monospacedDigit())
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .help("Planning value")
        .popover(isPresented: $isEditingValue, arrowEdge: .bottom) {
          planningValuePopover
        }
      }
    }
    .padding(.leading, 2)
  }

  private var planningValuePopover: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(planning.kind.capitalized, systemImage: "calendar")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      TextField("<yyyy-mm-dd>", text: $draftValue)
        .textFieldStyle(.roundedBorder)
        .font(.callout.monospacedDigit())
        .frame(width: 240)
        .onSubmit {
          saveValue()
        }

      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Save") {
          saveValue()
        }
        .keyboardShortcut(.defaultAction)
      }
      .controlSize(.small)
    }
    .padding(12)
  }

  private var isEditable: Bool {
    inlineActions.setPlanningBlock != nil && inlineActions.isSourceEditable
  }

  private func beginEditingValue() {
    draftValue = planning.value
    isEditingValue = true
  }

  private func saveValue() {
    setPlanning(kind: planning.kind, value: draftValue)
    isEditingValue = false
  }

  private func setPlanning(kind: String, value: String) {
    inlineActions.setPlanningBlock?(kind, value)
  }
}

private struct TimestampPill: View {
  let systemImage: String
  let text: String

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption.monospacedDigit().weight(.medium))
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color.accentColor.opacity(0.12), in: Capsule())
      .foregroundStyle(.primary)
  }
}

private struct OrgTimestampDisplay {
  let dateLabel: String
  let timeLabel: String?
  let detail: String?

  static func parse(_ raw: String) -> OrgTimestampDisplay? {
    guard let dateRange = raw.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
      return nil
    }

    let dateToken = String(raw[dateRange])
    let dateLabel = formattedDate(dateToken)
    let timeLabel = raw
      .range(of: #"\b\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?\b"#, options: .regularExpression)
      .map { String(raw[$0]) }

    let compactRaw = raw
      .replacingOccurrences(of: #"[<\[]\d{4}-\d{2}-\d{2}(?:\s+[A-Za-z]{3})?"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\b\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?\b"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"[>\]]"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = compactRaw.isEmpty ? nil : compactRaw

    return OrgTimestampDisplay(dateLabel: dateLabel, timeLabel: timeLabel, detail: detail)
  }

  private static func formattedDate(_ raw: String) -> String {
    let parts = raw.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          parts[1] >= 1,
          parts[1] <= monthNames.count
    else {
      return raw
    }
    return "\(monthNames[parts[1] - 1]) \(parts[2]), \(parts[0])"
  }

  private static let monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
  ]
}

private struct RenderedPropertiesView: View {
  let rows: [OrgPropertyRow]
  let rawText: String?
  let inlineActions: RenderedBlockInlineActions

  var body: some View {
    if !rows.isEmpty {
      let rawPropertyValues = OrgPropertyDrawerRawValueCache.values(rawText)
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
        ForEach(rows, id: \.key) { row in
          GridRow {
            Text(row.key)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            if row.key.uppercased() == "ID",
               row.value.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil {
              Text(Org2Display.shortID(row.value))
                .font(.callout)
                .textSelection(.enabled)
            } else {
              RenderedPropertyValueButton(
                row: row,
                value: propertyValue(row, rawPropertyValues: rawPropertyValues),
                inlineActions: inlineActions
              )
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func propertyValue(_ row: OrgPropertyRow, rawPropertyValues: [String: String]) -> String {
    rawPropertyValues[row.key.uppercased()] ?? row.value
  }
}

private struct RenderedPropertyValueButton: View {
  let row: OrgPropertyRow
  let value: String
  let inlineActions: RenderedBlockInlineActions
  @State private var isPresented = false
  @State private var draftValue = ""

  var body: some View {
    Button {
      draftValue = value
      isPresented = true
    } label: {
      OrgInlineText(value, font: .callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .disabled(inlineActions.setPropertyValue == nil || !inlineActions.isSourceEditable)
    .help("Edit \(row.key)")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        Label(row.key, systemImage: "tag")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        TextField("Value", text: $draftValue)
          .textFieldStyle(.roundedBorder)
          .frame(width: 280)
          .onSubmit {
            saveValue()
          }

        HStack(spacing: 8) {
          Spacer(minLength: 0)
          Button("Save") {
            saveValue()
          }
          .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
      }
      .padding(12)
    }
  }

  private func saveValue() {
    inlineActions.setPropertyValue?(row.key, draftValue)
    isPresented = false
  }
}

private struct RenderedQuoteView: View {
  let lines: [String]
  let rawText: String?
  @State private var visibleLineLimit = QuoteLineWindow.defaultLimit

  var body: some View {
    let allLines = displayLines
    let lineWindow = QuoteLineWindow.make(lines: allLines, visibleLimit: visibleLineLimit)
    HStack(alignment: .top, spacing: 10) {
      Rectangle()
        .fill(Color.accentColor.opacity(0.45))
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(lineWindow.visibleLines.indices, id: \.self) { index in
          OrgInlineText(lineWindow.visibleLines[index], font: .body.italic())
            .foregroundStyle(.secondary)
        }

        if allLines.count > QuoteLineWindow.defaultLimit {
          Button {
            if lineWindow.hiddenLineCount == 0 {
              visibleLineLimit = QuoteLineWindow.defaultLimit
            } else {
              visibleLineLimit = min(allLines.count, visibleLineLimit + QuoteLineWindow.pageSize)
            }
          } label: {
            Label(
              lineWindow.hiddenLineCount == 0
                ? "Show first \(QuoteLineWindow.defaultLimit) quote lines"
                : "Show \(min(QuoteLineWindow.pageSize, lineWindow.hiddenLineCount)) more quote lines",
              systemImage: lineWindow.hiddenLineCount == 0 ? "chevron.up" : "chevron.down"
            )
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .foregroundStyle(.secondary)
          .padding(.top, 2)
        }
      }
    }
    .padding(.vertical, 5)
    .padding(.leading, 8)
  }

  private var displayLines: [String] {
    QuoteLineWindow.displayLines(rawText: rawText, fallback: lines)
  }
}

struct QuoteLineWindow: Equatable {
  static let defaultLimit = 40
  static let pageSize = 80

  final class CacheKey: NSObject {
    let rawText: String
    private let cachedHash: Int

    init(rawText: String) {
      self.rawText = rawText
      self.cachedHash = rawText.hashValue
    }

    override var hash: Int {
      cachedHash
    }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return rawText == other.rawText
    }
  }

  private final class CachedDisplayLines {
    let lines: [String]?

    init(_ lines: [String]?) {
      self.lines = lines
    }
  }

  nonisolated(unsafe) private static let displayLineCache: NSCache<CacheKey, CachedDisplayLines> = {
    let cache = NSCache<CacheKey, CachedDisplayLines>()
    cache.countLimit = 512
    return cache
  }()

  let visibleLines: [String]
  let totalLineCount: Int
  let limit: Int

  var isTruncated: Bool {
    totalLineCount > limit
  }

  var hiddenLineCount: Int {
    max(0, totalLineCount - visibleLines.count)
  }

  static func make(lines: [String], visibleLimit: Int = defaultLimit) -> QuoteLineWindow {
    let safeLimit = max(1, visibleLimit)
    let clampedLimit = min(lines.count, safeLimit)
    return QuoteLineWindow(
      visibleLines: lines.count <= clampedLimit ? lines : Array(lines.prefix(clampedLimit)),
      totalLineCount: lines.count,
      limit: safeLimit
    )
  }

  static func displayLines(rawText: String?, fallback lines: [String]) -> [String] {
    guard let rawText else {
      return lines
    }

    let key = CacheKey(rawText: rawText)
    if let cached = displayLineCache.object(forKey: key) {
      return cached.lines ?? lines
    }

    guard rawBodyMayContainInlineSyntax(rawText) else {
      displayLineCache.setObject(CachedDisplayLines(nil), forKey: key)
      return lines
    }

    let rawLines = rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard rawLines.count >= 2 else {
      displayLineCache.setObject(CachedDisplayLines(nil), forKey: key)
      return lines
    }
    let displayLines = Array(rawLines.dropFirst().dropLast())
    displayLineCache.setObject(CachedDisplayLines(displayLines), forKey: key)
    return displayLines
  }

  static func rawBodyMayContainInlineSyntax(_ rawText: String) -> Bool {
    guard let firstBreak = rawText.firstIndex(of: "\n"),
          let lastBreak = rawText.lastIndex(of: "\n"),
          firstBreak < lastBreak
    else {
      return false
    }

    var cursor = rawText.index(after: firstBreak)
    while cursor < lastBreak {
      switch rawText[cursor] {
      case "[", "]", "<", ">", "`", "~", "=", "*", "/", "_", "+":
        return true
      case ".":
        if rawText[cursor...].hasPrefix(".org")
          || rawText[cursor...].hasPrefix(".md") {
          return true
        }
      case "h", "H":
        if rawText[cursor...].hasPrefix("http")
          || rawText[cursor...].hasPrefix("https")
          || rawText[cursor...].hasPrefix("HTTP")
          || rawText[cursor...].hasPrefix("HTTPS") {
          return true
        }
      default:
        break
      }
      cursor = rawText.index(after: cursor)
    }
    return false
  }
}

private struct RenderedSourceView: View {
  let language: String?
  let lines: [String]
  let inlineActions: RenderedBlockInlineActions
  @State private var visibleLineLimit = SourceBlockLineWindow.defaultLimit

  var body: some View {
    let lineWindow = SourceBlockLineWindow.make(lines: lines, visibleLimit: visibleLineLimit)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if let language, !language.isEmpty {
          Text(language)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
        } else {
          Text("source")
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        SourceRunHeaderAccessory(language: language, inlineActions: inlineActions)
      }

      ScrollView(.horizontal) {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(lineWindow.visibleLines.indices, id: \.self) { index in
            let line = lineWindow.visibleLines[index]
            Text(line.isEmpty ? " " : line)
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(color(for: line))
              .textSelection(.enabled)
          }
        }
        .padding(10)
      }
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.secondary.opacity(0.16))
      )

      if lines.count > SourceBlockLineWindow.defaultLimit {
        Button {
          if lineWindow.hiddenLineCount == 0 {
            visibleLineLimit = SourceBlockLineWindow.defaultLimit
          } else {
            visibleLineLimit = min(lines.count, visibleLineLimit + SourceBlockLineWindow.pageSize)
          }
        } label: {
          Label(
            lineWindow.hiddenLineCount == 0
              ? "Show first \(SourceBlockLineWindow.defaultLimit) lines"
              : "Show \(min(SourceBlockLineWindow.pageSize, lineWindow.hiddenLineCount)) more lines",
            systemImage: lineWindow.hiddenLineCount == 0 ? "chevron.up" : "chevron.down"
          )
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
      }

      SourceRunOutputAccessory(runState: inlineActions.sourceBlockRunState)
    }
    .padding(.vertical, 4)
  }

  private func color(for line: String) -> Color {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix("--") {
      return .secondary
    }
    if trimmed.hasPrefix("import ") || trimmed.hasPrefix("let ") || trimmed.hasPrefix("const ") || trimmed.hasPrefix("func ") {
      return .purple
    }
    return .primary
  }
}

struct SourceBlockLineWindow: Equatable {
  static let defaultLimit = 80
  static let pageSize = 160

  let visibleLines: [String]
  let totalLineCount: Int
  let limit: Int
  let isExpanded: Bool

  var isTruncated: Bool {
    totalLineCount > limit
  }

  var hiddenLineCount: Int {
    max(0, totalLineCount - visibleLines.count)
  }

  static func make(
    lines: [String],
    isExpanded: Bool,
    limit: Int = defaultLimit
  ) -> SourceBlockLineWindow {
    let safeLimit = max(1, limit)
    let visibleLines = isExpanded || lines.count <= safeLimit
      ? lines
      : Array(lines.prefix(safeLimit))
    return SourceBlockLineWindow(
      visibleLines: visibleLines,
      totalLineCount: lines.count,
      limit: safeLimit,
      isExpanded: isExpanded
    )
  }

  static func make(
    lines: [String],
    visibleLimit: Int
  ) -> SourceBlockLineWindow {
    let safeLimit = max(1, visibleLimit)
    let clampedLimit = min(lines.count, safeLimit)
    return SourceBlockLineWindow(
      visibleLines: lines.count <= clampedLimit ? lines : Array(lines.prefix(clampedLimit)),
      totalLineCount: lines.count,
      limit: safeLimit,
      isExpanded: clampedLimit >= lines.count
    )
  }
}

private struct SourceRunHeaderAccessory: View {
  let language: String?
  let inlineActions: RenderedBlockInlineActions

  var body: some View {
    if inlineActions.runSourceBlock != nil {
      HStack(spacing: 8) {
        if let state = runState {
          SourceRunStatusLabel(state: state)
        }

        Button {
          inlineActions.runSourceBlock?()
        } label: {
          Label("Run", systemImage: "play.fill")
        }
        .controlSize(.small)
        .disabled(isRunning)
        .help(runHelp)
      }
    }
  }

  private var runState: SourceBlockRunState? {
    inlineActions.sourceBlockRunState
  }

  private var isRunning: Bool {
    runState?.status == .running
  }

  private var runHelp: String {
    if SourceBlockRunPlan.plan(for: language) == nil {
      return "Unsupported source language"
    }
    return "Run source block"
  }
}

private struct SourceRunOutputAccessory: View {
  let runState: SourceBlockRunState?

  var body: some View {
    if let state = runState, state.status != .running || state.message != nil {
      SourceRunOutputView(state: state)
    }
  }
}

struct SourceRunStatusLabel: View {
  let state: SourceBlockRunState

  var body: some View {
    Label(label, systemImage: icon)
      .font(.caption.monospacedDigit())
      .foregroundStyle(color)
      .labelStyle(.titleAndIcon)
  }

  private var label: String {
    switch state.status {
    case .running:
      return "running"
    case .succeeded:
      return state.duration.map { String(format: "%.1fs", $0) } ?? "done"
    case .failed:
      return state.exitCode.map { "exit \($0)" } ?? "failed"
    case .timedOut:
      return "timed out"
    case .unsupported:
      return "unsupported"
    }
  }

  private var icon: String {
    switch state.status {
    case .running:
      return "play.circle"
    case .succeeded:
      return "checkmark.circle"
    case .failed:
      return "xmark.circle"
    case .timedOut:
      return "clock.badge.exclamationmark"
    case .unsupported:
      return "questionmark.circle"
    }
  }

  private var color: Color {
    switch state.status {
    case .running:
      return .secondary
    case .succeeded:
      return .green
    case .failed, .timedOut:
      return .red
    case .unsupported:
      return .secondary
    }
  }
}

struct SourceRunOutputView: View {
  let state: SourceBlockRunState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("Output")
          .font(.caption.weight(.medium))
        Text(state.commandLabel)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }

      if let message = state.message, !message.isEmpty {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if !state.stdout.isEmpty {
        outputBlock(title: "stdout", text: state.stdout)
      }
      if !state.stderr.isEmpty {
        outputBlock(title: "stderr", text: state.stderr)
      }
      if state.stdout.isEmpty, state.stderr.isEmpty, state.status == .succeeded {
        Text("No output")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.14))
    )
  }

  private func outputBlock(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption2.monospaced().weight(.medium))
        .foregroundStyle(.secondary)
      outputBody(for: SourceRunOutputPresentationCache.presentation(from: text))
    }
  }

  @ViewBuilder
  private func outputBody(for presentation: SourceRunOutputPresentation) -> some View {
    switch presentation {
    case .text(let text):
      Text(text.isEmpty ? " " : text)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .table(let table):
      SourceRunTableView(table: table)
    case .bars(let bars):
      SourceRunBarsView(bars: bars)
    case .line(let chart):
      SourceRunLineChartView(chart: chart)
    }
  }
}

enum SourceRunOutputPresentationCache {
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
    let presentation: SourceRunOutputPresentation

    init(_ presentation: SourceRunOutputPresentation) {
      self.presentation = presentation
    }
  }

  nonisolated(unsafe) private static let cache: NSCache<CacheKey, CachedValue> = {
    let cache = NSCache<CacheKey, CachedValue>()
    cache.countLimit = 512
    return cache
  }()

  nonisolated static func presentation(from raw: String) -> SourceRunOutputPresentation {
    let key = CacheKey(raw: raw)
    if let cached = cache.object(forKey: key) {
      return cached.presentation
    }

    let presentation = SourceRunOutputPresentation.make(from: raw)
    cache.setObject(CachedValue(presentation), forKey: key)
    return presentation
  }
}

private struct SourceRunTableView: View {
  let table: SourceRunTable

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(0..<columnCount, id: \.self) { columnIndex in
            Text(columnTitle(at: columnIndex))
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .padding(.horizontal, 9)
              .padding(.vertical, 6)
              .frame(minWidth: 92, alignment: .leading)
              .background(Color.secondary.opacity(0.08))
              .overlay(alignment: .trailing) {
                Divider()
              }
          }
        }

        ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
          GridRow {
            ForEach(0..<columnCount, id: \.self) { columnIndex in
              Text(cellText(row, at: columnIndex))
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(minWidth: 92, alignment: .leading)
                .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.04))
                .overlay(alignment: .trailing) {
                  Divider()
                }
            }
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.16))
    )
  }

  private var columnCount: Int {
    max(1, table.columns.count)
  }

  private func columnTitle(at index: Int) -> String {
    guard table.columns.indices.contains(index) else { return "Value" }
    let title = table.columns[index].trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Column \(index + 1)" : title
  }

  private func cellText(_ row: [String], at index: Int) -> String {
    guard row.indices.contains(index) else { return "" }
    return row[index]
  }
}

private struct SourceRunBarsView: View {
  let bars: [SourceRunBar]

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(bars, id: \.label) { bar in
        HStack(spacing: 8) {
          Text(bar.label)
            .font(.caption)
            .lineLimit(1)
            .frame(width: 120, alignment: .leading)
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color.secondary.opacity(0.12))
              Capsule()
                .fill(Color.accentColor.opacity(0.72))
                .frame(width: barWidth(for: bar.value, availableWidth: proxy.size.width))
            }
          }
          .frame(height: 8)
          Text(formattedValue(bar.value))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .trailing)
        }
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.14))
    )
  }

  private var maximumMagnitude: Double {
    max(1, bars.map { abs($0.value) }.max() ?? 1)
  }

  private func barWidth(for value: Double, availableWidth: CGFloat) -> CGFloat {
    guard availableWidth.isFinite, availableWidth > 0 else { return 0 }
    let fraction = min(1, abs(value) / maximumMagnitude)
    return max(value == 0 ? 0 : 2, availableWidth * CGFloat(fraction))
  }

  private func formattedValue(_ value: Double) -> String {
    if value.rounded() == value {
      return String(format: "%.0f", value)
    }
    return String(format: "%.2f", value)
  }
}

private struct SourceRunLineChartView: View {
  let chart: SourceRunLineChart

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(yTitle)
          .font(.caption.weight(.medium))
        Text("\(chart.points.count) points")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }

      GeometryReader { proxy in
        ZStack {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.secondary.opacity(0.045))

          chartGrid

          linePath(in: proxy.size)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

          ForEach(Array(displayPoints.enumerated()), id: \.offset) { _, point in
            Circle()
              .fill(Color.accentColor)
              .frame(width: 5, height: 5)
              .position(position(for: point, in: proxy.size))
          }
        }
      }
      .frame(height: 150)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.secondary.opacity(0.14))
      )

      HStack {
        Text(formattedValue(xBounds.min))
        Spacer(minLength: 0)
        Text(xTitle)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Text(formattedValue(xBounds.max))
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var displayPoints: [SourceRunLinePoint] {
    chart.points.sorted {
      if $0.x != $1.x {
        return $0.x < $1.x
      }
      return $0.y < $1.y
    }
  }

  private var xTitle: String {
    chart.xLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "x" : chart.xLabel
  }

  private var yTitle: String {
    chart.yLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "y" : chart.yLabel
  }

  private var xBounds: (min: Double, max: Double) {
    bounds(displayPoints.map(\.x))
  }

  private var yBounds: (min: Double, max: Double) {
    bounds(displayPoints.map(\.y))
  }

  private var chartGrid: some View {
    VStack(spacing: 0) {
      ForEach(0..<4, id: \.self) { index in
        Divider()
          .opacity(index == 0 ? 0 : 0.55)
        if index < 3 {
          Spacer(minLength: 0)
        }
      }
    }
    .padding(.vertical, 12)
  }

  private func linePath(in size: CGSize) -> Path {
    var path = Path()
    for (index, point) in displayPoints.enumerated() {
      let cgPoint = position(for: point, in: size)
      if index == 0 {
        path.move(to: cgPoint)
      } else {
        path.addLine(to: cgPoint)
      }
    }
    return path
  }

  private func position(for point: SourceRunLinePoint, in size: CGSize) -> CGPoint {
    let inset: CGFloat = 14
    let width = max(1, size.width - inset * 2)
    let height = max(1, size.height - inset * 2)
    let currentXBounds = xBounds
    let currentYBounds = yBounds
    let xSpan = currentXBounds.max - currentXBounds.min
    let ySpan = currentYBounds.max - currentYBounds.min
    let xFraction = xSpan == 0 ? 0.5 : (point.x - currentXBounds.min) / xSpan
    let yFraction = ySpan == 0 ? 0.5 : (point.y - currentYBounds.min) / ySpan
    return CGPoint(
      x: inset + width * CGFloat(xFraction),
      y: inset + height * CGFloat(1 - yFraction)
    )
  }

  private func bounds(_ values: [Double]) -> (min: Double, max: Double) {
    let minValue = values.min() ?? 0
    let maxValue = values.max() ?? 1
    if minValue == maxValue {
      return (minValue - 1, maxValue + 1)
    }
    return (minValue, maxValue)
  }

  private func formattedValue(_ value: Double) -> String {
    if value.rounded() == value {
      return String(format: "%.0f", value)
    }
    return String(format: "%.2f", value)
  }
}

private struct RenderedTableView: View {
  let table: OrgTableBlock
  @State private var visibleRowLimit = TableRowWindow.defaultLimit
  @State private var visibleColumnLimit = TableColumnWindow.defaultLimit

  var body: some View {
    let rowWindow = TableRowWindow.make(
      rows: table.rows,
      headerRowIndex: table.headerRowIndex,
      visibleLimit: visibleRowLimit
    )
    let columnWindow = TableColumnWindow.make(
      columnCount: columnCount,
      visibleLimit: visibleColumnLimit
    )
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal) {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
          ForEach(rowWindow.visibleRows) { visibleRow in
            switch visibleRow.row {
            case .cells(let cells):
              GridRow {
                ForEach(columnWindow.visibleColumns, id: \.self) { columnIndex in
                  OrgInlineText(cellText(cells, at: columnIndex), font: cellFont(rowIndex: visibleRow.index))
                    .lineLimit(table.headerRowIndex == visibleRow.index ? 2 : 4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, table.headerRowIndex == visibleRow.index ? 7 : 6)
                    .frame(minWidth: 96, alignment: .leading)
                    .background(cellBackground(rowIndex: visibleRow.index))
                    .overlay(alignment: .trailing) {
                      Divider()
                    }
                    .overlay(alignment: .bottom) {
                      Divider()
                        .opacity(table.headerRowIndex == visibleRow.index ? 0 : 0.65)
                  }
                }
              }
            case .separator:
              Rectangle()
                .fill(separatorColor(rowIndex: visibleRow.index))
                .frame(height: isHeaderSeparator(rowIndex: visibleRow.index) ? 1.5 : 1)
                .gridCellColumns(columnWindow.visibleColumns.count)
            }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.secondary.opacity(0.18))
      )

      if columnCount > TableColumnWindow.defaultLimit {
        Button {
          if columnWindow.hiddenColumnCount == 0 {
            visibleColumnLimit = TableColumnWindow.defaultLimit
          } else {
            visibleColumnLimit = min(columnCount, visibleColumnLimit + TableColumnWindow.pageSize)
          }
        } label: {
          Label(
            columnWindow.hiddenColumnCount == 0
              ? "Show first \(TableColumnWindow.defaultLimit) columns"
              : "Show \(min(TableColumnWindow.pageSize, columnWindow.hiddenColumnCount)) more columns",
            systemImage: columnWindow.hiddenColumnCount == 0 ? "chevron.left" : "chevron.right"
          )
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
      }

      if table.rows.count > TableRowWindow.defaultLimit {
        Button {
          if rowWindow.hiddenRowCount == 0 {
            visibleRowLimit = TableRowWindow.defaultLimit
          } else {
            visibleRowLimit = min(table.rows.count, visibleRowLimit + TableRowWindow.pageSize)
          }
        } label: {
          Label(
            rowWindow.hiddenRowCount == 0
              ? "Show first \(TableRowWindow.defaultLimit) rows"
              : "Show \(min(TableRowWindow.pageSize, rowWindow.hiddenRowCount)) more rows",
            systemImage: rowWindow.hiddenRowCount == 0 ? "chevron.up" : "chevron.down"
          )
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private var columnCount: Int {
    max(1, table.columnCount)
  }

  private func cellText(_ cells: [String], at index: Int) -> String {
    guard cells.indices.contains(index) else { return "" }
    return cells[index]
  }

  private func cellFont(rowIndex: Int) -> Font {
    if table.headerRowIndex == rowIndex {
      return .callout.weight(.semibold)
    }
    return .callout
  }

  private func cellBackground(rowIndex: Int) -> Color {
    if table.headerRowIndex == rowIndex {
      return Color.secondary.opacity(0.08)
    }
    return rowIndex.isMultiple(of: 2)
      ? Color(nsColor: .textBackgroundColor)
      : Color.secondary.opacity(0.035)
  }

  private func separatorColor(rowIndex: Int) -> Color {
    if isHeaderSeparator(rowIndex: rowIndex) {
      return Color.secondary.opacity(0.34)
    }
    return Color.secondary.opacity(0.20)
  }

  private func isHeaderSeparator(rowIndex: Int) -> Bool {
    table.headerRowIndex.map { $0 + 1 } == Optional(rowIndex)
  }
}

struct TableRowWindow: Equatable {
  struct VisibleRow: Identifiable, Equatable {
    let index: Int
    let row: OrgTableRow

    var id: Int { index }
  }

  static let defaultLimit = 40
  static let pageSize = 120

  let visibleRows: [VisibleRow]
  let totalRowCount: Int
  let limit: Int
  let isExpanded: Bool

  var isTruncated: Bool {
    totalRowCount > limit
  }

  var hiddenRowCount: Int {
    max(0, totalRowCount - visibleRows.count)
  }

  static func make(
    rows: [OrgTableRow],
    headerRowIndex: Int?,
    isExpanded: Bool,
    limit: Int = defaultLimit
  ) -> TableRowWindow {
    let safeLimit = max(1, limit)
    let visibleRows: [VisibleRow]
    if isExpanded || rows.count <= safeLimit {
      visibleRows = rows.enumerated().map { VisibleRow(index: $0.offset, row: $0.element) }
    } else {
      var includedIndexes = Set(0..<min(safeLimit, rows.count))
      if let headerRowIndex, rows.indices.contains(headerRowIndex) {
        includedIndexes.insert(headerRowIndex)
        let separatorIndex = headerRowIndex + 1
        if rows.indices.contains(separatorIndex),
           case .separator = rows[separatorIndex] {
          includedIndexes.insert(separatorIndex)
        }
      }
      visibleRows = includedIndexes.sorted().map { VisibleRow(index: $0, row: rows[$0]) }
    }

    return TableRowWindow(
      visibleRows: visibleRows,
      totalRowCount: rows.count,
      limit: safeLimit,
      isExpanded: isExpanded
    )
  }

  static func make(
    rows: [OrgTableRow],
    headerRowIndex: Int?,
    visibleLimit: Int
  ) -> TableRowWindow {
    let safeLimit = max(1, visibleLimit)
    return make(
      rows: rows,
      headerRowIndex: headerRowIndex,
      isExpanded: safeLimit >= rows.count,
      limit: safeLimit
    )
  }
}

struct TableColumnWindow: Equatable {
  static let defaultLimit = 12
  static let pageSize = 12

  let visibleColumns: [Int]
  let totalColumnCount: Int
  let limit: Int

  var hiddenColumnCount: Int {
    max(0, totalColumnCount - visibleColumns.count)
  }

  static func make(columnCount: Int, visibleLimit: Int = defaultLimit) -> TableColumnWindow {
    let safeTotal = max(1, columnCount)
    let safeLimit = max(1, visibleLimit)
    let visibleCount = min(safeTotal, safeLimit)
    return TableColumnWindow(
      visibleColumns: Array(0..<visibleCount),
      totalColumnCount: safeTotal,
      limit: safeLimit
    )
  }
}

private struct RenderedListItemView: View {
  let indent: Int
  let marker: String
  let checkbox: OrgListCheckbox?
  let text: String
  let rawText: String?
  let editableBlock: OrgEditableBlock?
  let inlineActions: RenderedBlockInlineActions

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(marker)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .frame(width: 28, alignment: .trailing)

      if let checkbox {
        RenderedListCheckboxButton(checkbox: checkbox, inlineActions: inlineActions)
      }

      OrgInlineText(rawListText)
        .strikethrough(checkbox == .checked)
        .foregroundStyle(checkbox == .checked ? .secondary : .primary)
      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(indent) * 16)
  }

  private var rawListText: String {
    OrgRenderedLineDisplayCache.listText(rawText: rawText, fallback: text)
  }
}

private struct RenderedListCheckboxButton: View {
  let checkbox: OrgListCheckbox
  let inlineActions: RenderedBlockInlineActions

  var body: some View {
    Button {
      inlineActions.toggleListItemCheckbox?()
    } label: {
      Image(systemName: checkboxImageName)
        .font(.callout.weight(.medium))
        .foregroundStyle(checkbox == .checked ? Color.accentColor : Color.secondary)
    }
    .buttonStyle(.plain)
    .disabled(inlineActions.toggleListItemCheckbox == nil || !inlineActions.isSourceEditable)
    .help(checkbox == .checked ? "Mark incomplete" : "Mark complete")
  }

  private var checkboxImageName: String {
    switch checkbox {
    case .unchecked:
      return "square"
    case .checked:
      return "checkmark.square.fill"
    case .mixed:
      return "minus.square"
    }
  }
}

private struct RenderedKeywordView: View {
  let key: String
  let value: String
  let rawText: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(key)
        .font(.caption.monospaced().weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: 78, alignment: .leading)
      OrgInlineText(rawValue, font: .callout)
    }
  }

  private var rawValue: String {
    OrgRenderedLineDisplayCache.keywordValue(rawText: rawText, fallback: value)
  }
}
