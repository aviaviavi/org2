import SwiftUI

struct ParagraphInlineFormatBar: View {
  @Binding var text: String
  @Binding var selectedRange: NSRange

  var body: some View {
    HStack(spacing: 4) {
      ForEach(OrgEditableInlineMarkup.Kind.allCases, id: \.self) { kind in
        let shortcut = keyboardShortcut(for: kind)
        Button {
          wrapSelection(kind)
        } label: {
          Image(systemName: kind.editorIcon)
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        .help("Format as \(kind.displayTitle) (\(shortcut.title))")
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func wrapSelection(_ kind: OrgEditableInlineMarkup.Kind) {
    let edit = OrgEditableInlineMarkupSet.wrappingSelection(in: text, range: selectedRange, kind: kind)
    text = edit.text
    selectedRange = edit.selectedRange
  }

  private func keyboardShortcut(for kind: OrgEditableInlineMarkup.Kind) -> InlineFormatShortcut {
    switch kind {
    case .code:
      return InlineFormatShortcut(key: "c", modifiers: [.command, .shift], title: "Command-Shift-C")
    case .bold:
      return InlineFormatShortcut(key: "b", modifiers: .command, title: "Command-B")
    case .italic:
      return InlineFormatShortcut(key: "i", modifiers: .command, title: "Command-I")
    case .underline:
      return InlineFormatShortcut(key: "u", modifiers: .command, title: "Command-U")
    case .strike:
      return InlineFormatShortcut(key: "x", modifiers: [.command, .shift], title: "Command-Shift-X")
    }
  }
}

private struct InlineFormatShortcut {
  let key: KeyEquivalent
  let modifiers: EventModifiers
  let title: String
}

struct ParagraphFocusedInlineEditor: View {
  @Binding var text: String
  @Binding var selectedRange: NSRange
  let token: OrgEditableInlineToken

  nonisolated static func shouldRender(
    text: String,
    selectedRange: NSRange,
    showsInlineDetails: Bool
  ) -> Bool {
    !showsInlineDetails
      && OrgEditableInlineToken.boundedUTF16Length(in: text) != nil
      && OrgEditableInlineToken.hasFocusedInlineSyntaxCandidate(in: text, selection: selectedRange)
  }

  nonisolated static func focusedToken(
    text: String,
    selectedRange: NSRange,
    showsInlineDetails: Bool
  ) -> OrgEditableInlineToken? {
    guard !showsInlineDetails else { return nil }
    return OrgEditableInlineToken.focused(in: text, selection: selectedRange)
  }

  var body: some View {
    focusedEditor(for: token)
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
      .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  @ViewBuilder
  private func focusedEditor(for token: OrgEditableInlineToken) -> some View {
    switch token {
    case .link(let link):
      focusedLinkEditor(link)
    case .timestamp(let timestamp):
      focusedTimestampEditor(timestamp)
    case .markup(let markup):
      focusedMarkupEditor(markup)
    }
  }

  private func focusedLinkEditor(_ link: OrgEditableInlineLink) -> some View {
    HStack(spacing: 8) {
      Label("Link", systemImage: linkIcon(for: link))
        .font(.caption.weight(.medium))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)

      TextField("label", text: focusedLinkLabelBinding(link))
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 120)

      TextField("target", text: focusedLinkTargetBinding(link))
        .textFieldStyle(.roundedBorder)
        .font(.caption.monospaced())
        .frame(minWidth: 220)
    }
    .controlSize(.small)
  }

  private func focusedTimestampEditor(_ timestamp: OrgEditableInlineTimestamp) -> some View {
    HStack(spacing: 8) {
      Toggle("", isOn: focusedTimestampActiveBinding(timestamp))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .help("Active timestamp")

      Label("Date", systemImage: timestamp.isActive ? "calendar" : "calendar.badge.clock")
        .font(.caption.weight(.medium))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)

      TextField("YYYY-MM-DD", text: focusedTimestampDateBinding(timestamp))
        .textFieldStyle(.roundedBorder)
        .font(.caption.monospacedDigit())
        .frame(width: 108)

      TextField("time", text: focusedTimestampTimeBinding(timestamp))
        .textFieldStyle(.roundedBorder)
        .font(.caption.monospacedDigit())
        .frame(width: 92)

      TextField("repeat/note", text: focusedTimestampDetailBinding(timestamp))
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 120)
    }
    .controlSize(.small)
  }

  private func focusedMarkupEditor(_ markup: OrgEditableInlineMarkup) -> some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(OrgEditableInlineMarkup.Kind.allCases, id: \.self) { kind in
          Button(kind.displayTitle) {
            updateInlineMarkup(markup, kind: kind)
          }
        }
      } label: {
        Label(markup.kind.displayTitle, systemImage: markup.kind.editorIcon)
          .font(.caption.weight(.medium))
          .labelStyle(.titleAndIcon)
          .frame(width: 104, alignment: .leading)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()

      TextField(markup.kind.displayTitle.lowercased(), text: focusedMarkupTextBinding(markup))
        .textFieldStyle(.roundedBorder)
        .font(markup.kind == .code ? .caption.monospaced() : .caption)
    }
    .controlSize(.small)
  }

  private func linkIcon(for link: OrgEditableInlineLink) -> String {
    switch link.kind {
    case .orgBracket, .markdown, .plainURL:
      return "link"
    case .fileReference:
      return "doc.text.magnifyingglass"
    }
  }

  private func focusedLinkLabelBinding(_ link: OrgEditableInlineLink) -> Binding<String> {
    Binding(
      get: { currentLink(matching: link)?.label ?? link.label },
      set: { updateInlineLink(link, label: $0) }
    )
  }

  private func focusedLinkTargetBinding(_ link: OrgEditableInlineLink) -> Binding<String> {
    Binding(
      get: { currentLink(matching: link)?.target ?? link.target },
      set: { updateInlineLink(link, target: $0) }
    )
  }

  private func currentLink(matching link: OrgEditableInlineLink) -> OrgEditableInlineLink? {
    OrgEditableInlineLinkSet(rawText: text)
      .links
      .first { $0.id == link.id }
  }

  private func updateInlineLink(_ link: OrgEditableInlineLink, label: String? = nil, target: String? = nil) {
    let set = OrgEditableInlineLinkSet(rawText: text)
    guard let current = set.links.first(where: { $0.id == link.id }) else { return }
    text = set.replacing(link: current, label: label, target: target)
  }

  private func focusedTimestampActiveBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<Bool> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.isActive ?? timestamp.isActive },
      set: { updateInlineTimestamp(timestamp, isActive: $0) }
    )
  }

  private func focusedTimestampDateBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<String> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.date ?? timestamp.date },
      set: { updateInlineTimestamp(timestamp, date: $0) }
    )
  }

  private func focusedTimestampTimeBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<String> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.time ?? timestamp.time },
      set: { updateInlineTimestamp(timestamp, time: $0) }
    )
  }

  private func focusedTimestampDetailBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<String> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.detail ?? timestamp.detail },
      set: { updateInlineTimestamp(timestamp, detail: $0) }
    )
  }

  private func currentTimestamp(matching timestamp: OrgEditableInlineTimestamp) -> OrgEditableInlineTimestamp? {
    OrgEditableInlineTimestampSet(rawText: text)
      .timestamps
      .first { $0.id == timestamp.id }
  }

  private func updateInlineTimestamp(
    _ timestamp: OrgEditableInlineTimestamp,
    date: String? = nil,
    time: String? = nil,
    detail: String? = nil,
    isActive: Bool? = nil
  ) {
    let set = OrgEditableInlineTimestampSet(rawText: text)
    guard let current = set.timestamps.first(where: { $0.id == timestamp.id }) else { return }
    text = set.replacing(
      timestamp: current,
      date: date,
      time: time,
      detail: detail,
      isActive: isActive
    )
  }

  private func focusedMarkupTextBinding(_ markup: OrgEditableInlineMarkup) -> Binding<String> {
    Binding(
      get: { currentMarkup(matching: markup)?.text ?? markup.text },
      set: { updateInlineMarkup(markup, text: $0) }
    )
  }

  private func currentMarkup(matching markup: OrgEditableInlineMarkup) -> OrgEditableInlineMarkup? {
    OrgEditableInlineMarkupSet(rawText: text)
      .markups
      .first { $0.id == markup.id }
  }

  private func updateInlineMarkup(
    _ markup: OrgEditableInlineMarkup,
    text nextText: String? = nil,
    kind nextKind: OrgEditableInlineMarkup.Kind? = nil
  ) {
    let set = OrgEditableInlineMarkupSet(rawText: text)
    guard let current = set.markups.first(where: { $0.id == markup.id }) else { return }
    text = set.replacing(markup: current, text: nextText, kind: nextKind)
  }
}

struct ParagraphInlineMarkupEditor: View {
  @Binding var text: String

  var body: some View {
    let markups = inlineMarkupSet.markups
    if !markups.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(markups) { markup in
          HStack(spacing: 8) {
            Menu {
              ForEach(OrgEditableInlineMarkup.Kind.allCases, id: \.self) { kind in
                Button(kind.displayTitle) {
                  updateInlineMarkup(markup, kind: kind)
                }
              }
            } label: {
              Label(markup.kind.displayTitle, systemImage: markup.kind.editorIcon)
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
                .frame(width: 104, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            TextField(markup.kind.displayTitle.lowercased(), text: markupTextBinding(markup))
              .textFieldStyle(.roundedBorder)
              .font(markup.kind == .code ? .caption.monospaced() : .caption)
          }
          .controlSize(.small)
        }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
  }

  private var inlineMarkupSet: OrgEditableInlineMarkupSet {
    OrgEditableInlineMarkupSet(rawText: text)
  }

  private func markupTextBinding(_ markup: OrgEditableInlineMarkup) -> Binding<String> {
    Binding(
      get: { currentMarkup(matching: markup)?.text ?? markup.text },
      set: { updateInlineMarkup(markup, text: $0) }
    )
  }

  private func currentMarkup(matching markup: OrgEditableInlineMarkup) -> OrgEditableInlineMarkup? {
    OrgEditableInlineMarkupSet(rawText: text)
      .markups
      .first { $0.id == markup.id }
  }

  private func updateInlineMarkup(
    _ markup: OrgEditableInlineMarkup,
    text nextText: String? = nil,
    kind nextKind: OrgEditableInlineMarkup.Kind? = nil
  ) {
    let set = OrgEditableInlineMarkupSet(rawText: text)
    guard let current = set.markups.first(where: { $0.id == markup.id }) else { return }
    text = set.replacing(markup: current, text: nextText, kind: nextKind)
  }
}

private extension OrgEditableInlineMarkup.Kind {
  var editorIcon: String {
    switch self {
    case .code:
      return "curlybraces"
    case .bold:
      return "bold"
    case .italic:
      return "italic"
    case .underline:
      return "underline"
    case .strike:
      return "strikethrough"
    }
  }
}

struct ParagraphInlineLinkEditor: View {
  @Binding var text: String

  var body: some View {
    let links = inlineLinkSet.links
    if !links.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(links) { link in
          HStack(spacing: 8) {
            Image(systemName: linkIcon(for: link))
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 18)

            TextField("label", text: linkLabelBinding(link))
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 120)

            TextField("target", text: linkTargetBinding(link))
              .textFieldStyle(.roundedBorder)
              .font(.caption.monospaced())
              .frame(minWidth: 220)
          }
          .controlSize(.small)
        }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
  }

  private var inlineLinkSet: OrgEditableInlineLinkSet {
    OrgEditableInlineLinkSet(rawText: text)
  }

  private func linkIcon(for link: OrgEditableInlineLink) -> String {
    switch link.kind {
    case .orgBracket, .markdown, .plainURL:
      return "link"
    case .fileReference:
      return "doc.text.magnifyingglass"
    }
  }

  private func linkLabelBinding(_ link: OrgEditableInlineLink) -> Binding<String> {
    Binding(
      get: { currentLink(matching: link)?.label ?? link.label },
      set: { updateInlineLink(link, label: $0) }
    )
  }

  private func linkTargetBinding(_ link: OrgEditableInlineLink) -> Binding<String> {
    Binding(
      get: { currentLink(matching: link)?.target ?? link.target },
      set: { updateInlineLink(link, target: $0) }
    )
  }

  private func currentLink(matching link: OrgEditableInlineLink) -> OrgEditableInlineLink? {
    OrgEditableInlineLinkSet(rawText: text)
      .links
      .first { $0.id == link.id }
  }

  private func updateInlineLink(_ link: OrgEditableInlineLink, label: String? = nil, target: String? = nil) {
    let set = OrgEditableInlineLinkSet(rawText: text)
    guard let current = set.links.first(where: { $0.id == link.id }) else { return }
    text = set.replacing(link: current, label: label, target: target)
  }
}

struct ParagraphInlineTimestampEditor: View {
  @Binding var text: String

  var body: some View {
    let timestamps = inlineTimestampSet.timestamps
    if !timestamps.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(timestamps) { timestamp in
          HStack(spacing: 8) {
            Toggle("", isOn: timestampActiveBinding(timestamp))
              .toggleStyle(.checkbox)
              .labelsHidden()
              .help("Active timestamp")

            Image(systemName: timestamp.isActive ? "calendar" : "calendar.badge.clock")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 18)

            TextField("YYYY-MM-DD", text: timestampDateBinding(timestamp))
              .textFieldStyle(.roundedBorder)
              .font(.caption.monospacedDigit())
              .frame(width: 108)

            TextField("time", text: timestampTimeBinding(timestamp))
              .textFieldStyle(.roundedBorder)
              .font(.caption.monospacedDigit())
              .frame(width: 92)

            TextField("repeat/note", text: timestampDetailBinding(timestamp))
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 120)
          }
          .controlSize(.small)
        }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
  }

  private var inlineTimestampSet: OrgEditableInlineTimestampSet {
    OrgEditableInlineTimestampSet(rawText: text)
  }

  private func timestampActiveBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<Bool> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.isActive ?? timestamp.isActive },
      set: { updateInlineTimestamp(timestamp, isActive: $0) }
    )
  }

  private func timestampDateBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<String> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.date ?? timestamp.date },
      set: { updateInlineTimestamp(timestamp, date: $0) }
    )
  }

  private func timestampTimeBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<String> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.time ?? timestamp.time },
      set: { updateInlineTimestamp(timestamp, time: $0) }
    )
  }

  private func timestampDetailBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<String> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.detail ?? timestamp.detail },
      set: { updateInlineTimestamp(timestamp, detail: $0) }
    )
  }

  private func currentTimestamp(matching timestamp: OrgEditableInlineTimestamp) -> OrgEditableInlineTimestamp? {
    OrgEditableInlineTimestampSet(rawText: text)
      .timestamps
      .first { $0.id == timestamp.id }
  }

  private func updateInlineTimestamp(
    _ timestamp: OrgEditableInlineTimestamp,
    date: String? = nil,
    time: String? = nil,
    detail: String? = nil,
    isActive: Bool? = nil
  ) {
    let set = OrgEditableInlineTimestampSet(rawText: text)
    guard let current = set.timestamps.first(where: { $0.id == timestamp.id }) else { return }
    text = set.replacing(
      timestamp: current,
      date: date,
      time: time,
      detail: detail,
      isActive: isActive
    )
  }
}
