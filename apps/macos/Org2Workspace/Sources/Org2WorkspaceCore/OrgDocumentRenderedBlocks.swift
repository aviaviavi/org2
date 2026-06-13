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

  init(
    block: OrgRenderedBlock,
    rawText: String? = nil,
    editableBlock: OrgEditableBlock? = nil,
    sourceFile: String? = nil,
    corpusRoot: URL? = nil
  ) {
    self.block = block
    self.rawText = rawText
    self.editableBlock = editableBlock
    self.sourceFile = sourceFile
    self.corpusRoot = corpusRoot
  }

  nonisolated static func == (lhs: RenderedBlockView, rhs: RenderedBlockView) -> Bool {
    lhs.block == rhs.block
      && lhs.rawText == rhs.rawText
      && lhs.editableBlock == rhs.editableBlock
      && lhs.sourceFile == rhs.sourceFile
      && lhs.corpusRoot == rhs.corpusRoot
  }

  var body: some View {
    switch block {
    case .heading(let heading):
      RenderedHeadingView(heading: heading, rawText: rawText)
    case .planning(let planning):
      RenderedPlanningView(planning: planning)
    case .properties(let rows):
      RenderedPropertiesView(rows: rows, rawText: rawText)
    case .quote(let lines):
      RenderedQuoteView(lines: lines, rawText: rawText)
    case .source(let language, let lines):
      RenderedSourceView(language: language, lines: lines, editableBlock: editableBlock)
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
        editableBlock: editableBlock
      )
    case .paragraph(let text):
      if let attachment = OrgMediaAttachment.standalone(
        raw: rawText ?? text,
        sourceFile: sourceFile,
        corpusRoot: corpusRoot
      ) {
        OrgMediaAttachmentView(attachment: attachment)
      } else {
        OrgInlineText(rawText ?? text)
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

private struct OrgImageAttachmentView: View {
  let attachment: OrgMediaAttachment
  @State private var image: NSImage?
  @State private var attemptedLoad = false

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
        return
      }
      attemptedLoad = false
      image = nil
      let loaded = await Task.detached(priority: .utility) {
        LoadedAttachmentImage(image: Self.previewImage(for: url))
      }.value
      guard !Task.isCancelled else { return }
      image = loaded.image
      attemptedLoad = true
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

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
          .frame(maxWidth: 760, minHeight: 260, maxHeight: 420)
      } else {
        MissingMediaView(kind: attachment.kind, name: attachment.displayName, attemptedLoad: true)
          .frame(maxWidth: 760, minHeight: 120)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.secondary.opacity(0.16))
    )
    .onAppear {
      if player == nil, let url = attachment.resolvedURL {
        player = AVPlayer(url: url)
      }
    }
    .onDisappear {
      player?.pause()
    }
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

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let todo = heading.todo {
        StatusPill(text: todo)
      }
      if let priority = heading.priority {
        Label(priority, systemImage: "flag.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
          .labelStyle(.titleAndIcon)
      }
      OrgInlineText(rawTitle, font: font)
      if !heading.tags.isEmpty {
        Text(heading.tags.map { "#\($0)" }.joined(separator: " "))
          .font(.caption)
          .foregroundStyle(.secondary)
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
    guard let rawText,
          let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first
    else {
      return heading.title
    }

    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return heading.title }
    var rest = String(line.dropFirst(stars.count)).trimmingCharacters(in: .whitespaces)
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if let first = tokens.first, Self.todoKeywords.contains(first.uppercased()) {
      tokens.removeFirst()
    }
    if let first = tokens.first,
       first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }
    return tokens.joined(separator: " ")
  }

  private static let todoKeywords = Set(["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"])
}

private struct RenderedPlanningView: View {
  let planning: OrgPlanningBlock

  var body: some View {
    HStack(spacing: 8) {
      Text(planning.kind.capitalized)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: 78, alignment: .leading)
      if let timestamp = OrgTimestampDisplay.parse(planning.value) {
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
        .textSelection(.enabled)
      } else {
        Text(planning.value)
          .font(.callout.monospacedDigit())
          .textSelection(.enabled)
      }
    }
    .padding(.leading, 2)
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

  var body: some View {
    if !rows.isEmpty {
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
              OrgInlineText(propertyValue(row), font: .callout)
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func propertyValue(_ row: OrgPropertyRow) -> String {
    rawPropertyValues[row.key.uppercased()] ?? row.value
  }

  private var rawPropertyValues: [String: String] {
    guard let rawText else { return [:] }
    var values: [String: String] = [:]
    for line in rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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

private struct RenderedQuoteView: View {
  let lines: [String]
  let rawText: String?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Rectangle()
        .fill(Color.accentColor.opacity(0.45))
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(displayLines.indices, id: \.self) { index in
          OrgInlineText(displayLines[index], font: .body.italic())
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 5)
    .padding(.leading, 8)
  }

  private var displayLines: [String] {
    guard let rawText else { return lines }
    let rawLines = rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard rawLines.count >= 2 else { return lines }
    return Array(rawLines.dropFirst().dropLast())
  }
}

private struct RenderedSourceView: View {
  let language: String?
  let lines: [String]
  let editableBlock: OrgEditableBlock?

  var body: some View {
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
        SourceRunHeaderAccessory(language: language, editableBlock: editableBlock)
      }

      ScrollView(.horizontal) {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(lines.indices, id: \.self) { index in
            let line = lines[index]
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

      SourceRunOutputAccessory(editableBlock: editableBlock)
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

private struct SourceRunHeaderAccessory: View {
  @EnvironmentObject private var store: WorkspaceStore
  let language: String?
  let editableBlock: OrgEditableBlock?

  var body: some View {
    if let editableBlock {
      HStack(spacing: 8) {
        if let state = runState {
          SourceRunStatusLabel(state: state)
        }

        Button {
          Task { await store.runSourceBlock(editableBlock) }
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
    guard let editableBlock else { return nil }
    return store.sourceBlockRunState(for: editableBlock)
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
  @EnvironmentObject private var store: WorkspaceStore
  let editableBlock: OrgEditableBlock?

  var body: some View {
    if let state = runState, state.status != .running || state.message != nil {
      SourceRunOutputView(state: state)
    }
  }

  private var runState: SourceBlockRunState? {
    guard let editableBlock else { return nil }
    return store.sourceBlockRunState(for: editableBlock)
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
      outputBody(for: SourceRunOutputPresentation.make(from: text))
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

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
          switch row {
          case .cells(let cells):
            GridRow {
              ForEach(0..<columnCount, id: \.self) { columnIndex in
                OrgInlineText(cellText(cells, at: columnIndex), font: cellFont(rowIndex: rowIndex))
                  .lineLimit(table.headerRowIndex == rowIndex ? 2 : 4)
                  .padding(.horizontal, 10)
                  .padding(.vertical, table.headerRowIndex == rowIndex ? 7 : 6)
                  .frame(minWidth: 96, alignment: .leading)
                  .background(cellBackground(rowIndex: rowIndex))
                  .overlay(alignment: .trailing) {
                    Divider()
                  }
                  .overlay(alignment: .bottom) {
                    Divider()
                      .opacity(table.headerRowIndex == rowIndex ? 0 : 0.65)
                  }
              }
            }
          case .separator:
            Rectangle()
              .fill(separatorColor(rowIndex: rowIndex))
              .frame(height: isHeaderSeparator(rowIndex: rowIndex) ? 1.5 : 1)
              .gridCellColumns(columnCount)
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.18))
    )
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

private struct RenderedListItemView: View {
  let indent: Int
  let marker: String
  let checkbox: OrgListCheckbox?
  let text: String
  let rawText: String?
  let editableBlock: OrgEditableBlock?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(marker)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .frame(width: 28, alignment: .trailing)

      if let checkbox {
        RenderedListCheckboxButton(checkbox: checkbox, editableBlock: editableBlock)
      }

      OrgInlineText(rawListText)
        .strikethrough(checkbox == .checked)
        .foregroundStyle(checkbox == .checked ? .secondary : .primary)
      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(indent) * 16)
  }

  private var rawListText: String {
    guard let rawText,
          let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first
    else {
      return text
    }
    let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
    let rest = String(line.dropFirst(leadingWhitespace.count))
    guard let separator = rest.firstIndex(where: { $0.isWhitespace }) else { return text }
    let textStart = rest[separator...].firstIndex { !$0.isWhitespace } ?? rest.endIndex
    return Self.stripCheckbox(String(rest[textStart...]))
  }

  private static func stripCheckbox(_ text: String) -> String {
    if text.hasPrefix("[ ] ") || text.hasPrefix("[X] ") || text.hasPrefix("[x] ") || text.hasPrefix("[-] ") {
      return String(text.dropFirst(4))
    }
    return text
  }
}

private struct RenderedListCheckboxButton: View {
  @EnvironmentObject private var store: WorkspaceStore
  let checkbox: OrgListCheckbox
  let editableBlock: OrgEditableBlock?

  var body: some View {
    Button {
      if let editableBlock {
        Task { await store.toggleListItemCheckbox(editableBlock) }
      }
    } label: {
      Image(systemName: checkboxImageName)
        .font(.callout.weight(.medium))
        .foregroundStyle(checkbox == .checked ? Color.accentColor : Color.secondary)
    }
    .buttonStyle(.plain)
    .disabled(editableBlock == nil || store.selectedEntrySource?.isEditable != true)
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
    guard let rawText,
          let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first
    else {
      return value
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let separator = trimmed.firstIndex(of: ":") else { return value }
    return String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
  }
}
