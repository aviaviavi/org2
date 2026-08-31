import Foundation

public enum AutomationScheduleFrequency: String, CaseIterable, Identifiable, Sendable {
  case interval
  case daily
  case weekdays
  case weekly
  case monthly
  case advanced

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .interval: "Every few hours"
    case .daily: "Every day"
    case .weekdays: "Weekdays"
    case .weekly: "Every week"
    case .monthly: "Every month"
    case .advanced: "Advanced (cron)"
    }
  }
}

public struct AutomationScheduleDraft: Equatable, Sendable {
  public var frequency: AutomationScheduleFrequency
  public var hour: Int
  public var minute: Int
  public var weekday: Int
  public var monthDay: Int
  public var intervalHours: Int
  public var advancedExpression: String

  public init(expression: String) {
    let normalized = expression.trimmingCharacters(in: .whitespacesAndNewlines)
    frequency = .advanced
    hour = 9
    minute = 0
    weekday = 1
    monthDay = 1
    intervalHours = 4
    advancedExpression = normalized

    let intervalParts = normalized.lowercased().split(whereSeparator: { $0.isWhitespace })
    if intervalParts.count == 2,
       intervalParts[0] == "every",
       intervalParts[1].hasSuffix("h"),
       let hours = Int(intervalParts[1].dropLast()),
       (1...24).contains(hours) {
      frequency = .interval
      intervalHours = hours
      return
    }

    let fields = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard fields.count == 5,
          let parsedMinute = Int(fields[0]), (0...59).contains(parsedMinute),
          let parsedHour = Int(fields[1]), (0...23).contains(parsedHour)
    else { return }

    minute = parsedMinute
    hour = parsedHour
    switch (fields[2], fields[3], fields[4]) {
    case ("*", "*", "*"):
      frequency = .daily
    case ("*", "*", "1-5"):
      frequency = .weekdays
    case ("*", "*", let day):
      guard let parsedDay = Int(day), (0...7).contains(parsedDay) else { return }
      frequency = .weekly
      weekday = parsedDay == 7 ? 0 : parsedDay
    case (let day, "*", "*"):
      guard let parsedDay = Int(day), (1...31).contains(parsedDay) else { return }
      frequency = .monthly
      monthDay = parsedDay
    default:
      return
    }
  }

  public var expression: String {
    switch frequency {
    case .interval:
      "every \(min(max(intervalHours, 1), 24))h"
    case .daily:
      "\(minute) \(hour) * * *"
    case .weekdays:
      "\(minute) \(hour) * * 1-5"
    case .weekly:
      "\(minute) \(hour) * * \(min(max(weekday, 0), 6))"
    case .monthly:
      "\(minute) \(hour) \(min(max(monthDay, 1), 31)) * *"
    case .advanced:
      advancedExpression.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  public var summary: String {
    let time = Self.timeString(hour: hour, minute: minute)
    switch frequency {
    case .interval:
      return intervalHours == 1 ? "Every hour" : "Every \(intervalHours) hours"
    case .daily:
      return "Every day at \(time)"
    case .weekdays:
      return "Weekdays at \(time)"
    case .weekly:
      return "Every \(Self.weekdayNames[min(max(weekday, 0), 6)]) at \(time)"
    case .monthly:
      return "Day \(monthDay) of every month at \(time)"
    case .advanced:
      return advancedExpression.isEmpty ? "Enter a cron or interval expression" : advancedExpression
    }
  }

  public static let weekdayNames = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
  ]

  private static func timeString(hour: Int, minute: Int) -> String {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.hour = hour
    components.minute = minute
    let date = components.date ?? Date(timeIntervalSince1970: 0)
    return date.formatted(date: .omitted, time: .shortened)
  }
}
