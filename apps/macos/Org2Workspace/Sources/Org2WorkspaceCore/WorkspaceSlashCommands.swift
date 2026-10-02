import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Commands offered while typing `/` in the source editor, such as `/image`.
enum WorkspaceSlashCommand: String, CaseIterable, Identifiable, Equatable, Sendable {
  case image

  var id: String { rawValue }
  var keyword: String { rawValue }

  var title: String {
    switch self {
    case .image: "/image"
    }
  }

  var detail: String {
    switch self {
    case .image: "Choose an image to embed in this note"
    }
  }

  var systemImage: String {
    switch self {
    case .image: "photo"
    }
  }
}

/// A `/query` that ends at the caret.
struct WorkspaceSlashCommandMatch: Equatable {
  let query: String
  let replacementRange: NSRange
}

enum WorkspaceSlashCommands {
  static let maximumQueryUTF16Length = 16

  static func match(in snapshot: OrgSyntaxTextEditorSelectionSnapshot) -> WorkspaceSlashCommandMatch? {
    guard snapshot.selectedRange.length == 0,
          snapshot.selectedRange.location >= snapshot.localTextRange.location,
          snapshot.selectedRange.location <= NSMaxRange(snapshot.localTextRange)
    else { return nil }
    return match(
      inLocalText: snapshot.localText,
      cursorOffset: snapshot.selectedRange.location - snapshot.localTextRange.location,
      replacementOffset: snapshot.localTextRange.location
    )
  }

  static func match(in text: String, selectedRange: NSRange) -> WorkspaceSlashCommandMatch? {
    guard selectedRange.length == 0 else { return nil }
    return match(inLocalText: text, cursorOffset: selectedRange.location, replacementOffset: 0)
  }

  /// Commands whose keyword starts with the typed query.
  static func options(for match: WorkspaceSlashCommandMatch) -> [WorkspaceSlashCommand] {
    let query = match.query.lowercased()
    return WorkspaceSlashCommand.allCases.filter { $0.keyword.hasPrefix(query) }
  }

  /// The `/` must start a line or follow whitespace, and the query is letters
  /// only, so paths (`/Users/…`), `and/or`, and URLs never open the panel.
  private static func match(
    inLocalText localText: String,
    cursorOffset: Int,
    replacementOffset: Int
  ) -> WorkspaceSlashCommandMatch? {
    let ns = localText as NSString
    let cursor = min(max(0, cursorOffset), ns.length)
    guard cursor > 0 else { return nil }
    let searchStart = max(0, cursor - maximumQueryUTF16Length - 1)
    let slashRange = ns.range(
      of: "/",
      options: .backwards,
      range: NSRange(location: searchStart, length: cursor - searchStart)
    )
    guard slashRange.location != NSNotFound else { return nil }
    if slashRange.location > 0 {
      guard let previous = UnicodeScalar(ns.character(at: slashRange.location - 1)),
            CharacterSet.whitespacesAndNewlines.contains(previous)
      else { return nil }
    }
    let queryRange = NSRange(location: slashRange.location + 1, length: cursor - slashRange.location - 1)
    let query = ns.substring(with: queryRange)
    guard query.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return nil }
    let match = WorkspaceSlashCommandMatch(
      query: query,
      replacementRange: NSRange(
        location: replacementOffset + slashRange.location,
        length: cursor - slashRange.location
      )
    )
    return options(for: match).isEmpty ? nil : match
  }

  /// Image types the `/image` picker accepts.
  static var imageContentTypes: [UTType] {
    var types: [UTType] = [.image]
    if let webp = UTType(filenameExtension: "webp") { types.append(webp) }
    return types
  }

  @MainActor
  static func chooseImage() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Embed Image"
    panel.prompt = "Embed"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = imageContentTypes
    return panel.runModal() == .OK ? panel.url : nil
  }
}

/// Per-editor selection and dismissal state for the slash command panel.
struct WorkspaceSlashCommandCompletionState: Equatable {
  var query: String?
  var selectedIndex = 0
  var dismissed: WorkspaceSlashCommandMatch?

  func isDismissed(_ match: WorkspaceSlashCommandMatch) -> Bool {
    dismissed == match
  }

  func selectedIndex(for match: WorkspaceSlashCommandMatch, optionCount: Int) -> Int {
    guard optionCount > 0 else { return 0 }
    let index = query == match.query ? selectedIndex : 0
    return min(max(0, index), optionCount - 1)
  }

  /// Applies a completion key. Accepting removes the typed `/query` and
  /// reports the chosen command through `accepted`.
  mutating func handle(
    _ key: OrgSyntaxTextEditorCompletionKey,
    match: WorkspaceSlashCommandMatch,
    options: [WorkspaceSlashCommand],
    accepted: inout WorkspaceSlashCommand?
  ) -> OrgSyntaxTextEditorCompletionKeyResult {
    guard !options.isEmpty, !isDismissed(match) else { return .ignored }
    let current = selectedIndex(for: match, optionCount: options.count)
    switch key {
    case .moveUp, .moveDown:
      let offset = key == .moveUp ? -1 : 1
      query = match.query
      selectedIndex = (current + offset + options.count) % options.count
      return .handled
    case .accept:
      query = nil
      selectedIndex = 0
      accepted = options[current]
      return .replace(range: match.replacementRange, text: "")
    case .dismiss:
      dismissed = match
      return .handled
    }
  }
}

struct WorkspaceSlashCommandPanel: View {
  let options: [WorkspaceSlashCommand]
  let selectedIndex: Int
  let choose: (WorkspaceSlashCommand) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label("Insert", systemImage: "plus.square.on.square")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)

      ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
        Button {
          choose(option)
        } label: {
          HStack(spacing: 7) {
            Image(systemName: option.systemImage)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
              Text(option.title)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.primary)
              Text(option.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 5)
          .padding(.vertical, 3)
          .background(
            index == selectedIndex ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      Text("↑↓ Navigate · Tab or Return Choose · Esc Dismiss")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 7)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.accentColor.opacity(0.20))
    )
    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    .frame(width: 300, alignment: .leading)
  }
}
