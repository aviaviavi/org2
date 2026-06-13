import Foundation

public struct Org2CanonicalDocument: Decodable, Equatable, Sendable {
  public let type: String
  public let version: String
  public let children: [Org2CanonicalNode]
}

public struct Org2CanonicalSourceRange: Decodable, Equatable, Sendable {
  public let startLine: Int
  public let endLine: Int
}

public enum Org2CanonicalNode: Decodable, Equatable, Sendable {
  case headline(Org2CanonicalHeadline)
  case paragraph(Org2CanonicalParagraph)
  case keywordLine(Org2CanonicalKeywordLine)
  case planning(Org2CanonicalPlanning)
  case propertyDrawer(Org2CanonicalPropertyDrawer)
  case srcBlock(Org2CanonicalSrcBlock)
  case block(Org2CanonicalBlock)
  case table(Org2CanonicalTable)
  case unsupported(type: String, sourceRange: Org2CanonicalSourceRange?)

  private enum CodingKeys: String, CodingKey {
    case type
    case sourceRange
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "Headline":
      self = .headline(try Org2CanonicalHeadline(from: decoder))
    case "Paragraph":
      self = .paragraph(try Org2CanonicalParagraph(from: decoder))
    case "KeywordLine":
      self = .keywordLine(try Org2CanonicalKeywordLine(from: decoder))
    case "Planning":
      self = .planning(try Org2CanonicalPlanning(from: decoder))
    case "PropertyDrawer":
      self = .propertyDrawer(try Org2CanonicalPropertyDrawer(from: decoder))
    case "SrcBlock":
      self = .srcBlock(try Org2CanonicalSrcBlock(from: decoder))
    case "Block":
      self = .block(try Org2CanonicalBlock(from: decoder))
    case "Table":
      self = .table(try Org2CanonicalTable(from: decoder))
    default:
      self = .unsupported(
        type: type,
        sourceRange: try? container.decode(Org2CanonicalSourceRange.self, forKey: .sourceRange)
      )
    }
  }
}

public struct Org2CanonicalHeadline: Decodable, Equatable, Sendable {
  public let type: String
  public let level: Int
  public let todo: String?
  public let tags: [String]?
  public let title: [Org2CanonicalInline]
  public let children: [Org2CanonicalNode]
  public let sourceRange: Org2CanonicalSourceRange?
}

public struct Org2CanonicalParagraph: Decodable, Equatable, Sendable {
  public let type: String
  public let children: [Org2CanonicalInline]
  public let sourceRange: Org2CanonicalSourceRange?
}

public struct Org2CanonicalKeywordLine: Decodable, Equatable, Sendable {
  public let type: String
  public let raw: String
  public let indent: String
  public let keyRaw: String
  public let valueRaw: String
  public let sourceRange: Org2CanonicalSourceRange?
}

public struct Org2CanonicalPlanning: Decodable, Equatable, Sendable {
  public let type: String
  public let kind: String
  public let raw: String
  public let sourceRange: Org2CanonicalSourceRange?
}

public struct Org2CanonicalPropertyDrawer: Decodable, Equatable, Sendable {
  public let type: String
  public let properties: [Org2CanonicalProperty]
  public let sourceRange: Org2CanonicalSourceRange?
}

public struct Org2CanonicalProperty: Decodable, Equatable, Sendable {
  public let key: String
  public let value: String
}

public struct Org2CanonicalSrcBlock: Decodable, Equatable, Sendable {
  public let type: String
  public let terminated: Bool
  public let begin: Org2CanonicalBlockLine
  public let bodyRaw: String
  public let end: Org2CanonicalBlockLine?
  public let sourceRange: Org2CanonicalSourceRange?
}

public struct Org2CanonicalBlock: Decodable, Equatable, Sendable {
  public let type: String
  public let kind: String
  public let terminated: Bool
  public let begin: Org2CanonicalBlockLine
  public let bodyRaw: String
  public let end: Org2CanonicalBlockLine?
  public let sourceRange: Org2CanonicalSourceRange?
}

public struct Org2CanonicalBlockLine: Decodable, Equatable, Sendable {
  public let indent: String
  public let keywordRaw: String
  public let afterKeywordRaw: String
}

public struct Org2CanonicalTable: Decodable, Equatable, Sendable {
  public let type: String
  public let rows: [Org2CanonicalTableRow]
  public let sourceRange: Org2CanonicalSourceRange?
}

public enum Org2CanonicalTableRow: Decodable, Equatable, Sendable {
  case row(Org2CanonicalTableDataRow)
  case hline(Org2CanonicalTableHline)
  case unsupported(type: String)

  private enum CodingKeys: String, CodingKey {
    case type
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "TableRow":
      self = .row(try Org2CanonicalTableDataRow(from: decoder))
    case "TableHline":
      self = .hline(try Org2CanonicalTableHline(from: decoder))
    default:
      self = .unsupported(type: type)
    }
  }
}

public struct Org2CanonicalTableDataRow: Decodable, Equatable, Sendable {
  public let type: String
  public let indent: String
  public let cells: [String]
}

public struct Org2CanonicalTableHline: Decodable, Equatable, Sendable {
  public let type: String
  public let indent: String
  public let raw: String
}

public enum Org2CanonicalInline: Decodable, Equatable, Sendable {
  case text(Org2CanonicalText)
  case timestamp(Org2CanonicalTimestamp)
  case timestampRange(Org2CanonicalTimestampRange)
  case emphasis(Org2CanonicalEmphasis)
  case link(Org2CanonicalLink)
  case progressCookie(raw: String)
  case unsupported(type: String)

  private enum CodingKeys: String, CodingKey {
    case type
    case raw
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "Text":
      self = .text(try Org2CanonicalText(from: decoder))
    case "Timestamp":
      self = .timestamp(try Org2CanonicalTimestamp(from: decoder))
    case "TimestampRange":
      self = .timestampRange(try Org2CanonicalTimestampRange(from: decoder))
    case "Emphasis":
      self = .emphasis(try Org2CanonicalEmphasis(from: decoder))
    case "Link":
      self = .link(try Org2CanonicalLink(from: decoder))
    case "ProgressCookie":
      self = .progressCookie(raw: (try? container.decode(String.self, forKey: .raw)) ?? "")
    default:
      self = .unsupported(type: type)
    }
  }
}

public struct Org2CanonicalText: Decodable, Equatable, Sendable {
  public let type: String
  public let value: String
}

public struct Org2CanonicalTimestamp: Decodable, Equatable, Sendable {
  public let type: String
  public let active: Bool
  public let raw: String
}

public struct Org2CanonicalTimestampRange: Decodable, Equatable, Sendable {
  public let type: String
  public let start: Org2CanonicalTimestamp
  public let separatorRaw: String
  public let end: Org2CanonicalTimestamp
}

public struct Org2CanonicalEmphasis: Decodable, Equatable, Sendable {
  public let type: String
  public let kind: String
  public let marker: String
  public let content: String
}

public struct Org2CanonicalLink: Decodable, Equatable, Sendable {
  public let type: String
  public let format: String
  public let raw: String
  public let targetRaw: String
  public let descriptionRaw: String?
}
