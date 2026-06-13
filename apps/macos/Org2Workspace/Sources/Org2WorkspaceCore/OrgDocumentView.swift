import SwiftUI

struct OrgRenderedEntryView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let blocks: [OrgEditableBlock]

  var body: some View {
    let source = store.selectedEntrySource
    let sourceFile = source?.file
    let corpusRoot = store.corpusRoot
    let isSourceEditable = source?.isEditable == true
    let selectedBlockID = store.selectedBlockID
    let moveAvailability = Self.moveAvailability(for: blocks, source: source)

    LazyVStack(alignment: .leading, spacing: 8) {
      ForEach(blocks) { block in
        if store.editingBlockID == block.id {
          InlineBlockEditorView(block: block)
        } else {
          EditableRenderedBlockView(
            block: block,
            isSourceEditable: isSourceEditable,
            isSelected: selectedBlockID == block.id,
            canMoveUp: moveAvailability[block.id]?.up == true,
            canMoveDown: moveAvailability[block.id]?.down == true,
            actions: actions(for: block)
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

  private static func moveAvailability(
    for blocks: [OrgEditableBlock],
    source: EntrySource?
  ) -> [OrgEditableBlock.ID: (up: Bool, down: Bool)] {
    guard let source, source.isEditable else { return [:] }

    let movableBlocks = blocks.filter { block in
      guard block.isEditable,
            block.startLine >= source.startLine,
            block.endLineExclusive <= source.endLineExclusive
      else {
        return false
      }
      return !(source.isSubtree && block.startLine == source.startLine)
    }

    var availability: [OrgEditableBlock.ID: (up: Bool, down: Bool)] = [:]
    availability.reserveCapacity(movableBlocks.count)
    for (index, block) in movableBlocks.enumerated() {
      availability[block.id] = (
        up: index > 0,
        down: index < movableBlocks.count - 1
      )
    }
    return availability
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

      if showsControls {
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
}

private struct RenderedBlockActions {
  let select: () -> Void
  let beginEditing: () -> Void
  let insert: (OrgInsertBlockKind) -> Void
  let move: (OrgBlockMoveDirection) -> Void
  let duplicate: () -> Void
  let delete: () -> Void
}
