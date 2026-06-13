import SwiftUI

struct OrgRenderedEntryView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let blocks: [OrgEditableBlock]

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 8) {
      ForEach(blocks) { block in
        if store.editingBlockID == block.id {
          InlineBlockEditorView(block: block)
        } else {
          EditableRenderedBlockView(block: block) {
            RenderedBlockView(
              block: block.rendered,
              rawText: block.rawText,
              editableBlock: block,
              sourceFile: store.selectedEntrySource?.file,
              corpusRoot: store.corpusRoot
            )
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct EditableRenderedBlockView<Content: View>: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @ViewBuilder let content: Content
  @State private var isHovered = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      content
        .padding(.trailing, store.selectedEntrySource?.isEditable == true ? 92 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)

      if store.selectedEntrySource?.isEditable == true {
        HStack(spacing: 3) {
          Menu {
            ForEach(OrgInsertBlockKind.allCases) { kind in
              Button {
                Task { await store.insertBlock(after: block, kind: kind) }
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
              store.beginEditingBlock(block)
            } label: {
              Image(systemName: "pencil")
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Edit line \(block.displayRange)")

            Menu {
              Button {
                Task { await store.moveBlock(block, direction: .up) }
              } label: {
                Label("Move Up", systemImage: "arrow.up")
              }
              .disabled(!store.canMoveBlock(block, direction: .up))

              Button {
                Task { await store.moveBlock(block, direction: .down) }
              } label: {
                Label("Move Down", systemImage: "arrow.down")
              }
              .disabled(!store.canMoveBlock(block, direction: .down))

              Divider()

              Button {
                Task { await store.duplicateBlock(block) }
              } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
              }

              Button(role: .destructive) {
                Task { await store.deleteBlock(block) }
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
        .opacity(isHovered || isSelected ? 1 : 0)
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
      store.selectBlock(block)
    }
    .onTapGesture(count: 2) {
      if block.isEditable {
        store.beginEditingBlock(block)
      }
    }
  }

  private var isSelected: Bool {
    store.selectedBlockID == block.id
  }

  private var backgroundColor: Color {
    guard store.selectedEntrySource?.isEditable == true else { return .clear }
    if isSelected {
      return Color.accentColor.opacity(0.075)
    }
    if isHovered {
      return Color.secondary.opacity(0.08)
    }
    return .clear
  }
}
