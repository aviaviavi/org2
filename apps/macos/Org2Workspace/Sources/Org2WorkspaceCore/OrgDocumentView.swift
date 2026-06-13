import SwiftUI

struct OrgRenderedEntryView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let blocks: [OrgEditableBlock]
  @State private var renderedBlockLimit = Self.initialRenderedBlockLimit
  @State private var renderWindowResetKey = ""
  @State private var moveAvailability = OrgRenderedEntryMoveAvailability.empty

  var body: some View {
    let source = store.selectedEntrySource
    let sourceFile = source?.file
    let corpusRoot = store.corpusRoot
    let isSourceEditable = source?.isEditable == true
    let selectedBlockID = store.selectedBlockID
    let blocksSignature = store.selectedRenderedBlocksSignature
    let moveAvailabilitySignature = OrgRenderedEntryMoveAvailability.signature(
      blocksSignature: blocksSignature,
      source: source
    )
    let moveAvailabilityValues = moveAvailability.signature == moveAvailabilitySignature ? moveAvailability.values : [:]
    let selectedBlockIndex = selectedBlockID.flatMap { store.selectedRenderedBlockIndexes[$0] }
    let resetKey = Self.renderWindowResetKey(for: source)
    let visibleLimit = Self.visibleLimit(
      requestedLimit: renderedBlockLimit,
      blocks: blocks,
      selectedBlockIndex: selectedBlockIndex
    )
    let visibleBlocks = blocks.prefix(visibleLimit)

    LazyVStack(alignment: .leading, spacing: 8) {
      ForEach(visibleBlocks) { block in
        OrgRenderedEntryRow(
          block: block,
          isSourceEditable: isSourceEditable,
          isSelected: selectedBlockID == block.id,
          isEditing: store.editingBlockID == block.id,
          canMoveUp: moveAvailabilityValues[block.id]?.up == true,
          canMoveDown: moveAvailabilityValues[block.id]?.down == true,
          sourceFile: sourceFile,
          corpusRoot: corpusRoot
        )
        .equatable()
      }

      if visibleLimit < blocks.count {
        ProgressiveRenderFooter(
          visibleCount: visibleLimit,
          totalCount: blocks.count,
          loadMore: expandRenderedBlocks
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      resetRenderedBlockLimitIfNeeded(resetKey: resetKey)
      refreshMoveAvailabilityIfNeeded(signature: moveAvailabilitySignature, source: source)
    }
    .onChange(of: resetKey) { _, newResetKey in
      resetRenderedBlockLimitIfNeeded(resetKey: newResetKey)
    }
    .onChange(of: moveAvailabilitySignature) { _, newSignature in
      refreshMoveAvailabilityIfNeeded(signature: newSignature, source: source)
    }
  }

  private func resetRenderedBlockLimitIfNeeded(resetKey: String) {
    guard resetKey != renderWindowResetKey else { return }
    renderWindowResetKey = resetKey
    renderedBlockLimit = Self.initialRenderedBlockLimit
  }

  private func refreshMoveAvailabilityIfNeeded(signature: String, source: EntrySource?) {
    guard moveAvailability.signature != signature else { return }
    moveAvailability = OrgRenderedEntryMoveAvailability.make(
      for: blocks,
      source: source,
      precomputedSignature: signature
    )
  }

  private func expandRenderedBlocks() {
    guard renderedBlockLimit < blocks.count else { return }
    renderedBlockLimit = min(blocks.count, renderedBlockLimit + Self.renderedBlockPageSize)
  }

  private static func visibleLimit(
    requestedLimit: Int,
    blocks: [OrgEditableBlock],
    selectedBlockIndex: Int?
  ) -> Int {
    guard !blocks.isEmpty else { return 0 }
    var limit = min(max(requestedLimit, initialRenderedBlockLimit), blocks.count)
    if let selectedIndex = selectedBlockIndex,
       blocks.indices.contains(selectedIndex) {
      limit = min(blocks.count, max(limit, selectedIndex + selectedBlockLookahead))
    }
    return limit
  }

  nonisolated static func renderWindowResetKey(for source: EntrySource?) -> String {
    guard let source else { return "none" }
    return "\(source.file):\(source.startLine):\(source.isSubtree):\(source.isEditable)"
  }

  private static let initialRenderedBlockLimit = 220
  private static let renderedBlockPageSize = 180
  private static let selectedBlockLookahead = 48
}

private struct OrgRenderedEntryRow: View, Equatable {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  let isSourceEditable: Bool
  let isSelected: Bool
  let isEditing: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let sourceFile: String?
  let corpusRoot: URL?

  nonisolated static func == (lhs: OrgRenderedEntryRow, rhs: OrgRenderedEntryRow) -> Bool {
    if lhs.isEditing || rhs.isEditing {
      return lhs.isEditing == rhs.isEditing
        && lhs.block.id == rhs.block.id
        && lhs.block.startLine == rhs.block.startLine
        && lhs.block.endLineExclusive == rhs.block.endLineExclusive
        && lhs.isSourceEditable == rhs.isSourceEditable
        && lhs.isSelected == rhs.isSelected
        && lhs.sourceFile == rhs.sourceFile
        && lhs.corpusRoot == rhs.corpusRoot
    }
    return lhs.block == rhs.block
      && lhs.isSourceEditable == rhs.isSourceEditable
      && lhs.isSelected == rhs.isSelected
      && lhs.isEditing == rhs.isEditing
      && lhs.canMoveUp == rhs.canMoveUp
      && lhs.canMoveDown == rhs.canMoveDown
      && lhs.sourceFile == rhs.sourceFile
      && lhs.corpusRoot == rhs.corpusRoot
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
        actions: actions
      ) {
        RenderedBlockView(
          block: block.rendered,
          rawText: block.rawText,
          editableBlock: block,
          sourceFile: sourceFile,
          corpusRoot: corpusRoot
        )
        .equatable()
      }
    }
  }

  private var actions: RenderedBlockActions {
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
    precomputedSignature: String? = nil
  ) -> OrgRenderedEntryMoveAvailability {
    let signature = precomputedSignature ?? signature(for: blocks, source: source)
    guard let source, source.isEditable else {
      return OrgRenderedEntryMoveAvailability(signature: signature, values: [:])
    }

    let movableBlocks = blocks.filter { block in
      guard block.isEditable,
            block.startLine >= source.startLine,
            block.endLineExclusive <= source.endLineExclusive
      else {
        return false
      }
      return !(source.isSubtree && block.startLine == source.startLine)
    }

    var values: [OrgEditableBlock.ID: OrgRenderedEntryBlockMoveAvailability] = [:]
    values.reserveCapacity(movableBlocks.count)
    for (index, block) in movableBlocks.enumerated() {
      values[block.id] = OrgRenderedEntryBlockMoveAvailability(
        up: index > 0,
        down: index < movableBlocks.count - 1
      )
    }

    return OrgRenderedEntryMoveAvailability(signature: signature, values: values)
  }

  static func signature(for blocks: [OrgEditableBlock], source: EntrySource?) -> String {
    signature(blocksSignature: Self.blocksSignature(for: blocks), source: source)
  }

  static func signature(blocksSignature: String, source: EntrySource?) -> String {
    guard let source, source.isEditable else {
      return "read-only:\(source?.id ?? "none")"
    }
    return "editable:\(source.id):\(source.isSubtree):\(source.isEditable):\(blocksSignature)"
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
}

private struct ProgressiveRenderFooter: View {
  let visibleCount: Int
  let totalCount: Int
  let loadMore: () -> Void

  var body: some View {
    Button {
      loadMore()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "arrow.down.circle")
        Text("Showing \(visibleCount) of \(totalCount) blocks")
          .font(.caption.weight(.medium))
        Text("Load more")
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
      loadMore()
    }
  }
}

private struct EditableRenderedBlockView<Content: View>: View {
  let block: OrgEditableBlock
  let isSourceEditable: Bool
  let isSelected: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let actions: RenderedBlockActions
  @ViewBuilder let content: Content
  @State private var isHovered = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      content
        .padding(.trailing, isSourceEditable ? 92 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)

      if isSourceEditable {
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
        .opacity(showsControls ? 1 : 0)
        .allowsHitTesting(showsControls)
        .accessibilityHidden(!showsControls)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(isSelected ? Color.accentColor.opacity(0.32) : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
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

  private var backgroundColor: Color {
    guard isSourceEditable else { return .clear }
    if isSelected {
      return Color.accentColor.opacity(0.075)
    }
    if isHovered {
      return Color.secondary.opacity(0.08)
    }
    return .clear
  }

  private var showsControls: Bool {
    isSourceEditable && (isHovered || isSelected)
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
