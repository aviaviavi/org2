import SwiftUI

struct OrgRenderedEntryView: View, Equatable {
  @EnvironmentObject private var store: WorkspaceStore
  let blocks: [OrgEditableBlock]
  let blocksRenderSignature: String
  let source: EntrySource?
  let corpusRoot: URL?
  let selectedBlockID: OrgEditableBlock.ID?
  let selectedBlockIndex: Int?
  let editingBlockID: OrgEditableBlock.ID?
  let isSavingBlock: Bool
  let sourceBlockRuns: [String: SourceBlockRunState]
  @State private var renderedBlockWindow: Range<Int>?
  @State private var renderWindowResetKey = ""
  @State private var moveAvailability = OrgRenderedEntryMoveAvailability.empty

  nonisolated static func == (lhs: OrgRenderedEntryView, rhs: OrgRenderedEntryView) -> Bool {
    lhs.blocksRenderSignature == rhs.blocksRenderSignature
      && lhs.source == rhs.source
      && lhs.corpusRoot == rhs.corpusRoot
      && lhs.selectedBlockID == rhs.selectedBlockID
      && lhs.selectedBlockIndex == rhs.selectedBlockIndex
      && lhs.editingBlockID == rhs.editingBlockID
      && lhs.isSavingBlock == rhs.isSavingBlock
      && lhs.sourceBlockRuns == rhs.sourceBlockRuns
  }

  var body: some View {
    let sourceFile = source?.file
    let isSourceEditable = source?.isEditable == true
    let resetKey = Self.renderWindowResetKey(for: source)
    let visibleWindow = Self.visibleWindow(
      requestedWindow: renderedBlockWindow,
      blocks: blocks,
      selectedBlockIndex: selectedBlockIndex
    )
    let visibleRange = visibleWindow.range
    let visibleBlocks = blocks[visibleWindow.range]
    let allowsHoverChrome = Self.allowsHoverChrome(blockCount: blocks.count)
    let moveAvailabilitySignature = OrgRenderedEntryMoveAvailability.signature(
      blocksSignature: blocksRenderSignature,
      source: source,
      visibleRange: visibleRange
    )
    let moveAvailabilityValues = moveAvailability.signature == moveAvailabilitySignature ? moveAvailability.values : [:]

    LazyVStack(alignment: .leading, spacing: 8) {
      if visibleWindow.hasPrevious {
        ProgressiveRenderFooter(
          visibleRange: visibleWindow.displayRange,
          totalCount: blocks.count,
          direction: .previous,
          autoLoadsOnAppear: false,
          loadMore: expandRenderedBlocks
        )
      }

      ForEach(visibleBlocks) { block in
        OrgRenderedEntryRow(
          block: block,
          isSourceEditable: isSourceEditable,
          isSelected: selectedBlockID == block.id,
          isEditing: editingBlockID == block.id,
          canMoveUp: moveAvailabilityValues[block.id]?.up == true,
          canMoveDown: moveAvailabilityValues[block.id]?.down == true,
          sourceFile: sourceFile,
          corpusRoot: corpusRoot,
          allowsHoverChrome: allowsHoverChrome,
          actions: actions(for: block),
          inlineActions: inlineActions(for: block, isSourceEditable: isSourceEditable)
        )
        .equatable()
      }

      if visibleWindow.hasNext {
        ProgressiveRenderFooter(
          visibleRange: visibleWindow.displayRange,
          totalCount: blocks.count,
          direction: .next,
          autoLoadsOnAppear: Self.shouldAutoExpandNextFooter(visibleWindow: visibleWindow),
          loadMore: expandRenderedBlocks
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      resetRenderedBlockLimitIfNeeded(resetKey: resetKey)
      refreshMoveAvailabilityIfNeeded(signature: moveAvailabilitySignature, source: source, visibleRange: visibleRange)
    }
    .onChange(of: resetKey) { _, newResetKey in
      resetRenderedBlockLimitIfNeeded(resetKey: newResetKey)
    }
    .onChange(of: selectedBlockID) { _, _ in
      if let selectedBlockIndex,
         let renderedBlockWindow,
         !renderedBlockWindow.contains(selectedBlockIndex) {
        self.renderedBlockWindow = nil
      }
    }
    .onChange(of: moveAvailabilitySignature) { _, newSignature in
      refreshMoveAvailabilityIfNeeded(signature: newSignature, source: source, visibleRange: visibleRange)
    }
  }

  private func resetRenderedBlockLimitIfNeeded(resetKey: String) {
    guard resetKey != renderWindowResetKey else { return }
    renderWindowResetKey = resetKey
    renderedBlockWindow = nil
  }

  private func refreshMoveAvailabilityIfNeeded(signature: String, source: EntrySource?, visibleRange: Range<Int>) {
    guard moveAvailability.signature != signature else { return }
    moveAvailability = OrgRenderedEntryMoveAvailability.make(
      for: blocks,
      source: source,
      visibleRange: visibleRange,
      precomputedSignature: signature
    )
  }

  private func expandRenderedBlocks(_ direction: OrgRenderedBlockWindowExpansionDirection) {
    let visibleWindow = Self.visibleWindow(
      requestedWindow: renderedBlockWindow,
      blocks: blocks,
      selectedBlockIndex: selectedBlockIndex
    )
    renderedBlockWindow = visibleWindow.expanding(
      direction,
      by: Self.renderedBlockPageSize(for: blocks.count),
      totalCount: blocks.count
    )
  }

  private func actions(for block: OrgEditableBlock) -> RenderedBlockActions {
    RenderedBlockActions(
      select: {
        store.selectBlock(block)
      },
      beginEditing: {
        store.beginEditingBlock(block)
      },
      insert: { kind in
        Task { await store.insertBlock(after: block, kind: kind) }
      },
      move: { direction in
        Task { await store.moveBlock(block, direction: direction) }
      },
      duplicate: {
        Task { await store.duplicateBlock(block) }
      },
      delete: {
        Task { await store.deleteBlock(block) }
      }
    )
  }

  private func inlineActions(for block: OrgEditableBlock, isSourceEditable: Bool) -> RenderedBlockInlineActions {
    guard block.isEditable else {
      return .readOnly
    }
    let isSourceBlock: Bool = {
      if case .source = block.rendered {
        return true
      }
      return false
    }()
    let sourceBlockRunState = isSourceBlock ? sourceBlockRuns[store.sourceBlockRunKey(for: block)] : nil
    let runSourceBlock: (@MainActor @Sendable () -> Void)?
    if isSourceBlock {
      runSourceBlock = { @MainActor @Sendable in
        let _: Task<Void, Never> = Task { await store.runSourceBlock(block) }
      }
    } else {
      runSourceBlock = nil
    }
    return RenderedBlockInlineActions(
      isSourceEditable: isSourceEditable,
      toggleHeadingTodo: {
        Task { await store.toggleHeadingTodo(block) }
      },
      setHeadingPriority: { priority in
        Task { await store.setHeadingPriority(block, priority: priority) }
      },
      setHeadingTags: { tags in
        Task { await store.setHeadingTags(block, tags: tags) }
      },
      setPlanningBlock: { kind, value in
        Task { await store.setPlanningBlock(block, kind: kind, value: value) }
      },
      setPropertyValue: { key, value in
        Task { await store.setPropertyValue(block, key: key, value: value) }
      },
      toggleListItemCheckbox: {
        Task { await store.toggleListItemCheckbox(block) }
      },
      sourceBlockRunState: sourceBlockRunState,
      runSourceBlock: runSourceBlock
    )
  }

  nonisolated static func visibleWindow(
    requestedWindow: Range<Int>?,
    blocks: [OrgEditableBlock],
    selectedBlockIndex: Int?
  ) -> OrgRenderedBlockWindow {
    guard !blocks.isEmpty else {
      return OrgRenderedBlockWindow(range: 0..<0, totalCount: 0)
    }

    if let requestedWindow {
      return OrgRenderedBlockWindow(
        range: clampedWindow(requestedWindow, totalCount: blocks.count, selectedBlockIndex: selectedBlockIndex),
        totalCount: blocks.count
      )
    }

    if let selectedBlockIndex,
       blocks.indices.contains(selectedBlockIndex),
       selectedBlockIndex >= selectedBlockAnchorThreshold {
      return OrgRenderedBlockWindow(
        range: anchoredWindow(around: selectedBlockIndex, totalCount: blocks.count),
        totalCount: blocks.count
      )
    }

    return OrgRenderedBlockWindow(
      range: 0..<min(blocks.count, initialRenderedBlockLimit(for: blocks.count)),
      totalCount: blocks.count
    )
  }

  nonisolated static func renderWindowResetKey(for source: EntrySource?) -> String {
    guard let source else { return "none" }
    return "\(source.file):\(source.startLine):\(source.isSubtree):\(source.isEditable)"
  }

  nonisolated static func allowsHoverChrome(blockCount: Int) -> Bool {
    blockCount <= hoverChromeBlockLimit
  }

  nonisolated static func shouldAutoExpandNextFooter(visibleWindow: OrgRenderedBlockWindow) -> Bool {
    visibleWindow.hasNext
      && visibleWindow.totalCount < largePageBlockThreshold
      && visibleWindow.range.upperBound <= initialRenderedBlockLimit(for: visibleWindow.totalCount)
  }

  nonisolated static func initialRenderedBlockLimit(for blockCount: Int) -> Int {
    blockCount >= largePageBlockThreshold ? largePageRenderedBlockLimit : defaultRenderedBlockLimit
  }

  nonisolated static func renderedBlockPageSize(for blockCount: Int) -> Int {
    blockCount >= largePageBlockThreshold ? largePageRenderedBlockLimit : defaultRenderedBlockLimit
  }

  nonisolated private static let defaultRenderedBlockLimit = 80
  nonisolated private static let largePageRenderedBlockLimit = 48
  nonisolated private static let largePageBlockThreshold = 1_000
  nonisolated private static let hoverChromeBlockLimit = 180
  nonisolated private static let selectedBlockAnchorThreshold = 120
  nonisolated private static let selectedBlockLookbehind = 24
  nonisolated private static let selectedBlockLookahead = 48

  nonisolated private static func anchoredWindow(around selectedIndex: Int, totalCount: Int) -> Range<Int> {
    let start = max(0, selectedIndex - selectedBlockLookbehind)
    let end = min(totalCount, selectedIndex + selectedBlockLookahead + 1)
    return start..<max(start, end)
  }

  nonisolated private static func clampedWindow(
    _ window: Range<Int>,
    totalCount: Int,
    selectedBlockIndex: Int?
  ) -> Range<Int> {
    let start = min(max(0, window.lowerBound), totalCount)
    let end = min(max(start, window.upperBound), totalCount)

    if let selectedBlockIndex,
       selectedBlockIndex >= 0,
       selectedBlockIndex < totalCount {
      if selectedBlockIndex < start || selectedBlockIndex >= end {
        return anchoredWindow(around: selectedBlockIndex, totalCount: totalCount)
      }
    }

    return start..<max(start, end)
  }
}

enum OrgRenderedBlockWindowExpansionDirection: Equatable, Sendable {
  case previous
  case next

  var title: String {
    switch self {
    case .previous: "Load previous"
    case .next: "Load more"
    }
  }

  var systemImage: String {
    switch self {
    case .previous: "arrow.up.circle"
    case .next: "arrow.down.circle"
    }
  }
}

struct OrgRenderedBlockWindow: Equatable, Sendable {
  let range: Range<Int>
  let totalCount: Int

  var hasPrevious: Bool {
    range.lowerBound > 0
  }

  var hasNext: Bool {
    range.upperBound < totalCount
  }

  var displayRange: String {
    guard !range.isEmpty else { return "0" }
    return "\(range.lowerBound + 1)-\(range.upperBound)"
  }

  func expanding(
    _ direction: OrgRenderedBlockWindowExpansionDirection,
    by count: Int,
    totalCount nextTotalCount: Int
  ) -> Range<Int> {
    let safeCount = max(1, count)
    let safeTotal = max(0, nextTotalCount)
    switch direction {
    case .previous:
      return max(0, range.lowerBound - safeCount)..<min(range.upperBound, safeTotal)
    case .next:
      return min(range.lowerBound, safeTotal)..<min(safeTotal, range.upperBound + safeCount)
    }
  }
}

private struct OrgRenderedEntryRow: View, Equatable {
  let block: OrgEditableBlock
  let isSourceEditable: Bool
  let isSelected: Bool
  let isEditing: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let sourceFile: String?
  let corpusRoot: URL?
  let allowsHoverChrome: Bool
  let actions: RenderedBlockActions
  let inlineActions: RenderedBlockInlineActions

  nonisolated static func == (lhs: OrgRenderedEntryRow, rhs: OrgRenderedEntryRow) -> Bool {
    if lhs.isEditing || rhs.isEditing {
      return lhs.isEditing == rhs.isEditing
        && lhs.block.renderIdentity == rhs.block.renderIdentity
        && lhs.isSourceEditable == rhs.isSourceEditable
        && lhs.isSelected == rhs.isSelected
        && lhs.sourceFile == rhs.sourceFile
        && lhs.corpusRoot == rhs.corpusRoot
        && lhs.allowsHoverChrome == rhs.allowsHoverChrome
        && lhs.inlineActions.isSourceEditable == rhs.inlineActions.isSourceEditable
        && lhs.inlineActions.sourceBlockRunState == rhs.inlineActions.sourceBlockRunState
    }
    return lhs.block.renderIdentity == rhs.block.renderIdentity
      && lhs.isSourceEditable == rhs.isSourceEditable
      && lhs.isSelected == rhs.isSelected
      && lhs.isEditing == rhs.isEditing
      && lhs.canMoveUp == rhs.canMoveUp
      && lhs.canMoveDown == rhs.canMoveDown
      && lhs.sourceFile == rhs.sourceFile
      && lhs.corpusRoot == rhs.corpusRoot
      && lhs.allowsHoverChrome == rhs.allowsHoverChrome
      && lhs.inlineActions.isSourceEditable == rhs.inlineActions.isSourceEditable
      && lhs.inlineActions.sourceBlockRunState == rhs.inlineActions.sourceBlockRunState
  }

  var body: some View {
    if isEditing {
      InlineBlockEditorView(block: block)
    } else {
      EditableRenderedBlockView(
        block: block,
        isSourceEditable: isSourceEditable,
        isSelected: isSelected,
        canMoveUp: canMoveUp,
        canMoveDown: canMoveDown,
        allowsHoverChrome: allowsHoverChrome,
        actions: actions
      ) {
        RenderedBlockView(
          block: block.rendered,
          rawText: block.rawText,
          editableBlock: block,
          sourceFile: sourceFile,
          corpusRoot: corpusRoot,
          inlineActions: inlineActions
        )
        .equatable()
      }
    }
  }
}

struct OrgRenderedEntryBlockMoveAvailability: Equatable, Sendable {
  let up: Bool
  let down: Bool
}

struct OrgRenderedEntryMoveAvailability: Sendable {
  let signature: String
  let values: [OrgEditableBlock.ID: OrgRenderedEntryBlockMoveAvailability]

  static let empty = OrgRenderedEntryMoveAvailability(signature: "empty", values: [:])

  static func make(
    for blocks: [OrgEditableBlock],
    source: EntrySource?,
    visibleRange: Range<Int>? = nil,
    precomputedSignature: String? = nil
  ) -> OrgRenderedEntryMoveAvailability {
    let signature = precomputedSignature ?? signature(for: blocks, source: source, visibleRange: visibleRange)
    guard let source, source.isEditable else {
      return OrgRenderedEntryMoveAvailability(signature: signature, values: [:])
    }

    let targetRange = clampedVisibleRange(visibleRange, totalCount: blocks.count)
    guard let movableBounds = movableBounds(in: blocks, source: source) else {
      return OrgRenderedEntryMoveAvailability(signature: signature, values: [:])
    }
    var values: [OrgEditableBlock.ID: OrgRenderedEntryBlockMoveAvailability] = [:]
    values.reserveCapacity(targetRange.count)
    for index in targetRange {
      let block = blocks[index]
      guard isMovable(block, in: source) else { continue }
      values[block.id] = OrgRenderedEntryBlockMoveAvailability(
        up: index > movableBounds.first,
        down: index < movableBounds.last
      )
    }

    return OrgRenderedEntryMoveAvailability(signature: signature, values: values)
  }

  static func signature(
    for blocks: [OrgEditableBlock],
    source: EntrySource?,
    visibleRange: Range<Int>? = nil
  ) -> String {
    signature(blocksSignature: Self.blocksSignature(for: blocks), source: source, visibleRange: visibleRange)
  }

  static func signature(
    blocksSignature: String,
    source: EntrySource?,
    visibleRange: Range<Int>? = nil
  ) -> String {
    let rangeSignature: String = {
      guard let visibleRange else { return "all" }
      return "\(visibleRange.lowerBound)..<\(visibleRange.upperBound)"
    }()
    guard let source, source.isEditable else {
      return "read-only:\(source?.id ?? "none"):\(rangeSignature)"
    }
    return "editable:\(source.id):\(source.isSubtree):\(source.isEditable):\(rangeSignature):\(blocksSignature)"
  }

  private static func blocksSignature(for blocks: [OrgEditableBlock]) -> String {
    guard !blocks.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(blocks.count)
    for block in blocks {
      hasher.combine(block.id)
      hasher.combine(block.startLine)
      hasher.combine(block.endLineExclusive)
      hasher.combine(block.isEditable)
    }
    return "\(blocks.count):\(hasher.finalize())"
  }

  private static func clampedVisibleRange(_ visibleRange: Range<Int>?, totalCount: Int) -> Range<Int> {
    guard let visibleRange else {
      return 0..<totalCount
    }
    let start = min(max(0, visibleRange.lowerBound), totalCount)
    let end = min(max(start, visibleRange.upperBound), totalCount)
    return start..<end
  }

  private static func isMovable(_ block: OrgEditableBlock, in source: EntrySource) -> Bool {
    guard block.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      return false
    }
    return !(source.isSubtree && block.startLine == source.startLine)
  }

  private static func movableBounds(
    in blocks: [OrgEditableBlock],
    source: EntrySource
  ) -> (first: Int, last: Int)? {
    guard let first = blocks.indices.first(where: { isMovable(blocks[$0], in: source) }) else {
      return nil
    }
    let last = blocks.indices.reversed().first(where: { isMovable(blocks[$0], in: source) }) ?? first
    return (first, last)
  }
}

private struct ProgressiveRenderFooter: View {
  let visibleRange: String
  let totalCount: Int
  let direction: OrgRenderedBlockWindowExpansionDirection
  let autoLoadsOnAppear: Bool
  let loadMore: (OrgRenderedBlockWindowExpansionDirection) -> Void

  var body: some View {
    Button {
      loadMore(direction)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: direction.systemImage)
        Text("Showing blocks \(visibleRange) of \(totalCount)")
          .font(.caption.weight(.medium))
        Text(direction.title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .onAppear {
      if autoLoadsOnAppear {
        loadMore(direction)
      }
    }
  }
}

enum RenderedRowChrome {
  static let controlsReserveWidth: CGFloat = 92

  static func rendersControls(isVisible: Bool) -> Bool {
    true
  }

  static func rendersControlLayer(
    isSourceEditable: Bool,
    allowsHoverChrome: Bool,
    isSelected: Bool
  ) -> Bool {
    isSourceEditable && (allowsHoverChrome || isSelected)
  }

  static func contentTrailingPadding(
    isSourceEditable: Bool,
    allowsHoverChrome: Bool,
    isSelected: Bool
  ) -> CGFloat {
    guard isSourceEditable else { return 0 }
    return allowsHoverChrome || isSelected ? controlsReserveWidth : 0
  }

  static func controlsOpacity(isVisible: Bool) -> Double {
    isVisible ? 1 : 0
  }

  static func allowsHitTesting(isVisible: Bool) -> Bool {
    isVisible
  }
}

private struct EditableRenderedBlockView<Content: View>: View {
  let block: OrgEditableBlock
  let isSourceEditable: Bool
  let isSelected: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let allowsHoverChrome: Bool
  let actions: RenderedBlockActions
  @ViewBuilder let content: Content
  @State private var isHovered = false

  var body: some View {
    Group {
      if allowsHoverChrome {
        rowContent
          .onHover { hovering in
            isHovered = hovering
          }
      } else {
        rowContent
      }
    }
  }

  private var rowContent: some View {
    rowInnerContent
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(isSelected ? Color.accentColor.opacity(0.32) : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(count: 1) {
      actions.select()
      if startsEditingOnSingleClick {
        actions.beginEditing()
      }
    }
    .onTapGesture(count: 2) {
      if block.isEditable {
        actions.beginEditing()
      }
    }
  }

  @ViewBuilder
  private var rowInnerContent: some View {
    if rendersControlLayer {
      ZStack(alignment: .topTrailing) {
        renderedContent

        if RenderedRowChrome.rendersControls(isVisible: showsControls) {
          rowControls
            .opacity(RenderedRowChrome.controlsOpacity(isVisible: showsControls))
            .allowsHitTesting(RenderedRowChrome.allowsHitTesting(isVisible: showsControls))
        }
      }
    } else {
      renderedContent
    }
  }

  private var renderedContent: some View {
    content
      .padding(.trailing, contentTrailingPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var backgroundColor: Color {
    guard isSourceEditable else { return .clear }
    if isSelected {
      return Color.accentColor.opacity(0.075)
    }
    if allowsHoverChrome && isHovered {
      return Color.secondary.opacity(0.08)
    }
    return .clear
  }

  private var showsControls: Bool {
    isSourceEditable && (isSelected || (allowsHoverChrome && isHovered))
  }

  private var rendersControlLayer: Bool {
    RenderedRowChrome.rendersControlLayer(
      isSourceEditable: isSourceEditable,
      allowsHoverChrome: allowsHoverChrome,
      isSelected: isSelected
    )
  }

  private var contentTrailingPadding: CGFloat {
    RenderedRowChrome.contentTrailingPadding(
      isSourceEditable: isSourceEditable,
      allowsHoverChrome: allowsHoverChrome,
      isSelected: isSelected
    )
  }

  private var rowControls: some View {
    HStack(spacing: 3) {
      Menu {
        ForEach(OrgInsertBlockKind.allCases) { kind in
          Button {
            actions.insert(kind)
          } label: {
            Label(kind.title, systemImage: kind.systemImage)
          }
        }
      } label: {
        Image(systemName: "plus")
          .font(.caption.weight(.semibold))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .controlSize(.small)
      .help("Add block after line \(block.displayRange)")

      if block.isEditable {
        Button {
          actions.beginEditing()
        } label: {
          Image(systemName: "pencil")
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Edit line \(block.displayRange)")

        Menu {
          Button {
            actions.move(.up)
          } label: {
            Label("Move Up", systemImage: "arrow.up")
          }
          .disabled(!canMoveUp)

          Button {
            actions.move(.down)
          } label: {
            Label("Move Down", systemImage: "arrow.down")
          }
          .disabled(!canMoveDown)

          Divider()

          Button {
            actions.duplicate()
          } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
          }

          Button(role: .destructive) {
            actions.delete()
          } label: {
            Label("Delete", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .help("Block actions")
      }
    }
  }

  private var startsEditingOnSingleClick: Bool {
    guard isSourceEditable, block.isEditable else { return false }
    switch block.rendered {
    case .heading, .planning, .paragraph, .listItem, .keyword:
      return true
    case .blank, .horizontalRule, .properties, .quote, .source, .table:
      return false
    }
  }
}

private struct RenderedBlockActions {
  let select: () -> Void
  let beginEditing: () -> Void
  let insert: (OrgInsertBlockKind) -> Void
  let move: (OrgBlockMoveDirection) -> Void
  let duplicate: () -> Void
  let delete: () -> Void
}
