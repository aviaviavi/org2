import Foundation
import SwiftUI

/// An `@date` mention being typed immediately before the caret, such as
/// `@today`, `@tomorrow`, `@july 10`, or `@2026-07-10`.
struct WorkspaceDateMentionMatch: Equatable, Sendable {
  /// Text after `@`, exactly as typed.
  let query: String
  /// UTF-16 range of `@query` in the text that was matched.
  let replacementRange: NSRange
}

/// One calendar day that a date mention query resolves to.
struct WorkspaceDateMentionCandidate: Identifiable, Equatable, Sendable {
  /// Start of the day in the calendar used to resolve it.
  let date: Date
  /// `yyyy-MM-dd`, which is also the daily note base name.
  let dayKey: String
  /// Human title, such as "Today" or "Friday, July 10, 2026".
  let title: String
  /// Org date stamp, such as `<2026-07-10 Fri>`.
  let timestamp: String

  var id: String { dayKey }
}

/// One insertable completion for a date mention in the document editors.
struct WorkspaceDateMentionOption: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case timestamp
    case dailyNote(path: String, relativePath: String)
  }

  let candidate: WorkspaceDateMentionCandidate
  let kind: Kind
  /// Org text that replaces the typed `@query`.
  let insertion: String

  var id: String {
    switch kind {
    case .timestamp: "timestamp:\(candidate.dayKey)"
    case .dailyNote(let path, _): "daily:\(path)"
    }
  }

  var title: String {
    switch kind {
    case .timestamp: candidate.timestamp
    case .dailyNote: candidate.dayKey
    }
  }

  var detail: String {
    switch kind {
    case .timestamp: "Date · \(candidate.title)"
    case .dailyNote(_, let relativePath): "Daily note · \(relativePath)"
    }
  }

  var systemImage: String {
    switch kind {
    case .timestamp: "calendar"
    case .dailyNote: "doc.text"
    }
  }

  func replacement(in text: String, match: WorkspaceDateMentionMatch) -> InlineSelectionReplacement? {
    guard let range = Range(match.replacementRange, in: text),
          text[range] == "@\(match.query)"
    else { return nil }
    var output = text
    output.replaceSubrange(range, with: insertion)
    return InlineSelectionReplacement(
      text: output,
      selectedRange: NSRange(
        location: match.replacementRange.location + (insertion as NSString).length,
        length: 0
      )
    )
  }
}

enum WorkspaceDateMentions {
  /// Longest query considered after `@`; "september 30, 2026" fits comfortably.
  static let maximumQueryUTF16Length = 32

  // MARK: Matching

  static func match(in text: String, selectedRange: NSRange) -> WorkspaceDateMentionMatch? {
    guard selectedRange.length == 0 else { return nil }
    let ns = text as NSString
    let cursor = min(max(0, selectedRange.location), ns.length)
    let windowStart = max(0, cursor - maximumQueryUTF16Length - 2)
    let window = ns.substring(with: NSRange(location: windowStart, length: cursor - windowStart))
    return match(inLocalText: window, cursorOffset: (window as NSString).length, replacementOffset: windowStart)
  }

  static func match(in snapshot: OrgSyntaxTextEditorSelectionSnapshot) -> WorkspaceDateMentionMatch? {
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

  /// Matches a mention that ends at the end of `text`, as in the chat composer.
  static func matchAtEnd(of text: String) -> WorkspaceDateMentionMatch? {
    match(in: text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
  }

  static func removingMatch(_ match: WorkspaceDateMentionMatch, in text: String) -> String {
    guard let range = Range(match.replacementRange, in: text) else { return text }
    return text.replacingCharacters(in: range, with: "")
  }

  private static func match(
    inLocalText localText: String,
    cursorOffset: Int,
    replacementOffset: Int
  ) -> WorkspaceDateMentionMatch? {
    let ns = localText as NSString
    let cursor = min(max(0, cursorOffset), ns.length)
    guard cursor > 0 else { return nil }
    let searchStart = max(0, cursor - maximumQueryUTF16Length - 1)
    let atRange = ns.range(
      of: "@",
      options: .backwards,
      range: NSRange(location: searchStart, length: cursor - searchStart)
    )
    guard atRange.location != NSNotFound else { return nil }
    if atRange.location > 0 {
      guard let previous = UnicodeScalar(ns.character(at: atRange.location - 1)),
            CharacterSet.whitespacesAndNewlines.contains(previous) || "([{\"'".unicodeScalars.contains(previous)
      else { return nil }
    }
    let queryRange = NSRange(location: atRange.location + 1, length: cursor - atRange.location - 1)
    let query = ns.substring(with: queryRange)
    guard !query.isEmpty,
          query.first?.isWhitespace == false,
          query.unicodeScalars.allSatisfy(isQueryScalar)
    else { return nil }
    return WorkspaceDateMentionMatch(
      query: query,
      replacementRange: NSRange(location: replacementOffset + atRange.location, length: 1 + queryRange.length)
    )
  }

  private static func isQueryScalar(_ scalar: UnicodeScalar) -> Bool {
    if scalar == " " || scalar == "/" || scalar == "-" || scalar == "," || scalar == "." { return true }
    return CharacterSet.alphanumerics.contains(scalar)
  }

  // MARK: Resolving

  static func candidates(
    for rawQuery: String,
    now: Date = Date(),
    calendar: Calendar = WorkspaceDateMentions.calendar
  ) -> [WorkspaceDateMentionCandidate] {
    var query = rawQuery
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    while let last = query.last, last == "," || last == "." {
      query.removeLast()
    }
    guard !query.isEmpty else { return [] }
    let today = calendar.startOfDay(for: now)

    let relative: [(keyword: String, title: String, offset: Int)] = [
      ("today", "Today", 0),
      ("tomorrow", "Tomorrow", 1),
      ("yesterday", "Yesterday", -1),
    ]
    let relativeMatches = relative.filter { $0.keyword.hasPrefix(query) }
    if !relativeMatches.isEmpty {
      return relativeMatches.compactMap { item in
        calendar.date(byAdding: .day, value: item.offset, to: today).map {
          candidate(for: $0, title: item.title, calendar: calendar)
        }
      }
    }

    guard let date = absoluteDate(for: query, today: today, calendar: calendar) else { return [] }
    return [candidate(for: date, title: relativeTitle(for: date, today: today, calendar: calendar), calendar: calendar)]
  }

  static func candidate(
    for date: Date,
    title: String? = nil,
    calendar: Calendar = WorkspaceDateMentions.calendar
  ) -> WorkspaceDateMentionCandidate {
    let day = calendar.startOfDay(for: date)
    return WorkspaceDateMentionCandidate(
      date: day,
      dayKey: formatted(day, format: "yyyy-MM-dd", calendar: calendar),
      title: title ?? formatted(day, format: "EEEE, MMMM d, yyyy", calendar: calendar),
      timestamp: "<\(formatted(day, format: "yyyy-MM-dd EEE", calendar: calendar))>"
    )
  }

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone.current
    return calendar
  }

  private static func relativeTitle(for date: Date, today: Date, calendar: Calendar) -> String? {
    let offset = calendar.dateComponents([.day], from: today, to: date).day
    switch offset {
    case 0: return "Today"
    case 1: return "Tomorrow"
    case -1: return "Yesterday"
    default: return nil
    }
  }

  private static func absoluteDate(for query: String, today: Date, calendar: Calendar) -> Date? {
    let currentYear = calendar.component(.year, from: today)

    // 2026-07-10
    if let groups = captures(#"^(\d{4})-(\d{1,2})-(\d{1,2})$"#, in: query) {
      return makeDate(year: Int(groups[0]), month: Int(groups[1]), day: Int(groups[2]), calendar: calendar)
    }

    // 7/10 or 7/10/2026
    if let groups = captures(#"^(\d{1,2})/(\d{1,2})(?:/(\d{2}|\d{4}))?$"#, in: query) {
      return makeDate(
        year: groups[2].isEmpty ? currentYear : expandedYear(groups[2]),
        month: Int(groups[0]),
        day: Int(groups[1]),
        calendar: calendar
      )
    }

    // july 10, jul 10th, july 10 2026, july 10, 2026
    if let groups = captures(#"^([a-z]+)\.? ?(\d{1,2})(?:st|nd|rd|th)?(?:,? (\d{4}))?$"#, in: query),
       let month = month(named: groups[0]) {
      return makeDate(
        year: groups[2].isEmpty ? currentYear : Int(groups[2]),
        month: month,
        day: Int(groups[1]),
        calendar: calendar
      )
    }

    // 10 july, 10th jul 2026
    if let groups = captures(#"^(\d{1,2})(?:st|nd|rd|th)? ([a-z]+)\.?(?:,? (\d{4}))?$"#, in: query),
       let month = month(named: groups[1]) {
      return makeDate(
        year: groups[2].isEmpty ? currentYear : Int(groups[2]),
        month: month,
        day: Int(groups[0]),
        calendar: calendar
      )
    }

    return nil
  }

  private static let monthNames = [
    "january", "february", "march", "april", "may", "june",
    "july", "august", "september", "october", "november", "december",
  ]

  private static func month(named word: String) -> Int? {
    guard word.count >= 3 else { return nil }
    let matches = monthNames.enumerated().filter { $0.element.hasPrefix(word) }
    guard matches.count == 1 else { return nil }
    return matches[0].offset + 1
  }

  private static func expandedYear(_ raw: String) -> Int? {
    guard let value = Int(raw) else { return nil }
    return raw.count == 2 ? 2000 + value : value
  }

  private static func makeDate(year: Int?, month: Int?, day: Int?, calendar: Calendar) -> Date? {
    guard let year, let month, let day,
          (1...12).contains(month), (1...31).contains(day), (1...9999).contains(year)
    else { return nil }
    let components = DateComponents(year: year, month: month, day: day)
    guard let date = calendar.date(from: components) else { return nil }
    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    guard resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
    return calendar.startOfDay(for: date)
  }

  private static func captures(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    else { return nil }
    return (1..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      return range.location == NSNotFound ? "" : (text as NSString).substring(with: range)
    }
  }

  private static func formatted(_ date: Date, format: String, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = format
    return formatter.string(from: date)
  }

  // MARK: Editor options

  /// Date stamp plus the existing daily note link for each resolved day.
  static func editorOptions(
    for match: WorkspaceDateMentionMatch,
    now: Date = Date(),
    calendar: Calendar = WorkspaceDateMentions.calendar,
    sourceFile: String?,
    corpusRoot: URL?,
    dailyNoteFile: (WorkspaceDateMentionCandidate) -> CorpusFile?
  ) -> [WorkspaceDateMentionOption] {
    candidates(for: match.query, now: now, calendar: calendar).flatMap { candidate in
      var options = [
        WorkspaceDateMentionOption(candidate: candidate, kind: .timestamp, insertion: candidate.timestamp)
      ]
      if let file = dailyNoteFile(candidate) {
        let target = linkPath(to: file.path, from: sourceFile, corpusRoot: corpusRoot)
        options.append(WorkspaceDateMentionOption(
          candidate: candidate,
          kind: .dailyNote(path: file.path, relativePath: file.relativePath),
          insertion: "[[file:\(target)][\(candidate.dayKey)]]"
        ))
      }
      return options
    }
  }

  /// A `file:` link target for `target`, relative to the directory of the
  /// document that will contain it. Falls back to a corpus-relative path.
  static func linkPath(to target: String, from sourceFile: String?, corpusRoot: URL?) -> String {
    let targetComponents = URL(fileURLWithPath: target).standardizedFileURL.pathComponents
    let baseComponents: [String]
    if let sourceFile {
      baseComponents = URL(fileURLWithPath: sourceFile).standardizedFileURL
        .deletingLastPathComponent().pathComponents
    } else if let corpusRoot {
      baseComponents = corpusRoot.standardizedFileURL.pathComponents
    } else {
      return target
    }
    var common = 0
    while common < baseComponents.count,
          common < targetComponents.count - 1,
          baseComponents[common] == targetComponents[common] {
      common += 1
    }
    guard common > 1 || baseComponents.count <= 1 else { return target }
    let ups = Array(repeating: "..", count: baseComponents.count - common)
    return (ups + targetComponents[common...]).joined(separator: "/")
  }
}

// MARK: Editor keyboard + panel

/// Per-editor selection and dismissal state for the date mention panel.
struct WorkspaceDateMentionCompletionState: Equatable {
  var query: String?
  var selectedIndex = 0
  var dismissed: WorkspaceDateMentionMatch?

  func isDismissed(_ match: WorkspaceDateMentionMatch) -> Bool {
    dismissed == match
  }

  func selectedIndex(for match: WorkspaceDateMentionMatch, optionCount: Int) -> Int {
    guard optionCount > 0 else { return 0 }
    let index = query == match.query ? selectedIndex : 0
    return min(max(0, index), optionCount - 1)
  }

  /// Applies a completion key to the visible options. Returns the edit to
  /// perform, `.handled` for navigation, or `.ignored` to let the editor
  /// process the key normally.
  mutating func handle(
    _ key: OrgSyntaxTextEditorCompletionKey,
    match: WorkspaceDateMentionMatch,
    options: [WorkspaceDateMentionOption]
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
      return .replace(range: match.replacementRange, text: options[current].insertion)
    case .dismiss:
      dismissed = match
      return .handled
    }
  }
}

struct WorkspaceDateMentionCompletionPanel: View {
  let options: [WorkspaceDateMentionOption]
  let selectedIndex: Int
  let choose: (WorkspaceDateMentionOption) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label("Insert date", systemImage: "calendar.badge.plus")
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
                .lineLimit(1)
              Text(option.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
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

      Text("↑↓ Navigate · Tab or Return Insert · Esc Dismiss")
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
