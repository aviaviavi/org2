import Foundation

/// A corpus-relative daily note path format from `roam.dailyFileTemplate`,
/// such as `journal/{YYYY}/{MM}/{YYYY}-{MM}-{DD}-wind-down.md`.
///
/// Mirrors `src/dailyNoteTemplate.ts`; both implementations are checked
/// against `test/fixtures/daily-note-templates.json`. Inference from an
/// example file lives only in the CLI (`org2 daily-config infer`).
public struct DailyNoteTemplate: Hashable, Sendable {
  public static let tokens = ["YYYY", "YY", "MMMM", "MMM", "MM", "M", "DD", "D", "dddd", "ddd"]

  public let template: String

  public init?(_ template: String) {
    let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.problem(trimmed) == nil else { return nil }
    self.template = trimmed
  }

  /// A user-facing validation problem, or nil when `template` is usable.
  public static func problem(_ template: String) -> String? {
    let value = template.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return "The daily note format is empty." }
    if value.contains("\0") { return "The daily note format contains a NUL character." }
    if value.hasPrefix("/") || value.hasPrefix("~")
      || value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
      return "The daily note format must be relative to the corpus folder."
    }
    if value.contains("\\") { return "Use / to separate folders in the daily note format." }
    let segments = value.components(separatedBy: "/")
    if segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
      return "The daily note format cannot contain empty, . or .. folder names."
    }
    var used = Set<String>()
    var remainder = ""
    var index = value.startIndex
    while index < value.endIndex {
      let character = value[index]
      if character == "{",
         let close = value[index...].firstIndex(of: "}"),
         !value[value.index(after: index)..<close].contains("{") {
        let name = String(value[value.index(after: index)..<close])
        guard tokens.contains(name) else {
          return "Unknown date token {\(name)}. Use \(tokens.map { "{\($0)}" }.joined(separator: ", "))."
        }
        used.insert(name)
        index = value.index(after: close)
        continue
      }
      remainder.append(character)
      index = value.index(after: index)
    }
    if remainder.contains("{") || remainder.contains("}") {
      return "The daily note format has an unmatched { or }."
    }
    if !used.contains("DD") && !used.contains("D") {
      return "The daily note format needs a day token: {DD} or {D}."
    }
    if !["MM", "M", "MMM", "MMMM"].contains(where: used.contains) {
      return "The daily note format needs a month token: {MM}, {M}, {MMM}, or {MMMM}."
    }
    if let basename = segments.last, basename.hasPrefix(".") {
      return "The daily note filename cannot start with a dot."
    }
    return nil
  }

  /// The corpus-relative path for `date` in the Gregorian calendar and the
  /// current time zone.
  public func relativePath(for date: Date, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    return render(
      year: parts.year ?? 1970,
      month: parts.month ?? 1,
      day: parts.day ?? 1,
      weekday: (parts.weekday ?? 1) - 1
    )
  }

  /// Renders an explicit calendar day. `weekday` is 0 for Sunday.
  func render(year: Int, month: Int, day: Int, weekday: Int) -> String {
    let months = [
      "January", "February", "March", "April", "May", "June", "July",
      "August", "September", "October", "November", "December",
    ]
    let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    func pad(_ value: Int, _ width: Int) -> String {
      let text = String(value)
      return String(repeating: "0", count: max(0, width - text.count)) + text
    }
    var output = ""
    var index = template.startIndex
    while index < template.endIndex {
      if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
        let name = template[template.index(after: index)..<close]
        switch name {
        case "YYYY": output += pad(year, 4)
        case "YY": output += pad(year % 100, 2)
        case "MMMM": output += months[month - 1]
        case "MMM": output += String(months[month - 1].prefix(3))
        case "MM": output += pad(month, 2)
        case "M": output += String(month)
        case "DD": output += pad(day, 2)
        case "D": output += String(day)
        case "dddd": output += weekdays[weekday]
        case "ddd": output += String(weekdays[weekday].prefix(3))
        default: output += "{\(name)}"
        }
        index = template.index(after: close)
      } else {
        output.append(template[index])
        index = template.index(after: index)
      }
    }
    return output
  }

  public func url(for date: Date, corpusRoot: URL) -> URL {
    corpusRoot.standardizedFileURL
      .appendingPathComponent(relativePath(for: date), isDirectory: false)
      .standardizedFileURL
  }

  /// Initial content for a newly created daily note of this format.
  static func initialContent(for url: URL) -> String {
    let title = url.deletingPathExtension().lastPathComponent
    switch url.pathExtension.lowercased() {
    case "org", "org2": return "#+TITLE: \(title)\n\n"
    case "md", "markdown": return "# \(title)\n\n"
    default: return ""
    }
  }
}

/// `org2 daily-config show|set` output.
public struct DailyNoteConfiguration: Decodable, Sendable {
  public struct PathPreview: Decodable, Sendable, Hashable {
    public let date: String
    public let relativePath: String
    public let exists: Bool
  }

  public struct Paths: Decodable, Sendable, Hashable {
    public let yesterday: PathPreview?
    public let today: PathPreview?
    public let tomorrow: PathPreview?
  }

  public let revision: String
  public let template: String?
  public let problem: String?
  public let paths: Paths
}

/// `org2 daily-config infer` output.
public struct DailyNoteTemplateInference: Decodable, Sendable {
  public struct Candidate: Decodable, Sendable, Hashable {
    public let template: String
    public let date: String
    public let hasYear: Bool
    public let paths: DailyNoteConfiguration.Paths
  }

  public let revision: String
  public let example: String
  public let candidates: [Candidate]
}
