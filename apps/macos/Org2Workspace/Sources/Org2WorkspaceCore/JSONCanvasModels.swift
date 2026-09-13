import Foundation
import SwiftUI

public struct JSONCanvasPayload: Decodable, Sendable {
  public let file: String
  public let revision: String
  public let document: JSONCanvasDocument
  public let resources: [String: JSONCanvasResource]
}

public struct JSONCanvasMutationPayload: Decodable, Sendable {
  public let file: String
  public let applied: Bool
  public let revision: String
}

public struct JSONCanvasDocument: Decodable, Sendable {
  public let nodes: [JSONCanvasNode]?
  public let edges: [JSONCanvasEdge]?
}

public struct JSONCanvasNode: Decodable, Identifiable, Sendable {
  public let id: String
  public let type: String
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
  public let text: String?
  public let file: String?
  public let subpath: String?
  public let org2Ref: String?
  public let url: String?
  public let label: String?
  public let color: String?
  public let backgroundStyle: String?

  public var rectangle: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  public var displayTitle: String { label ?? file ?? (type == "text" ? "Text" : url ?? type.capitalized) }
}

public struct JSONCanvasEdge: Decodable, Identifiable, Sendable {
  public let id: String
  public let fromNode: String
  public let toNode: String
  public let fromSide: String?
  public let toSide: String?
  public let fromEnd: String?
  public let toEnd: String?
  public let label: String?
  public let color: String?
}

public struct JSONCanvasResource: Decodable, Sendable {
  public let status: String
  public let title: String
  public let message: String?
  public let file: String?
  public let line: Int?
  public let id: String?
  public let text: String?
  public let imageData: String?
  public let imageMime: String?
  public let url: String?

  public var location: WorkspaceLocation? {
    guard let file else { return nil }
    return .search(SearchResult(
      file: file, line: line ?? 1, lineEnd: nil, heading: title, headingLine: line,
      headingLevel: nil, headingAncestry: nil, idValue: id, todo: nil, tags: [],
      snippet: text ?? title, sourceRange: nil, matchedLines: nil, date: nil
    ))
  }
}

public struct JSONCanvasTargetsPayload: Decodable, Sendable {
  public let targets: [JSONCanvasTarget]
  public let truncated: Bool
}

public struct JSONCanvasTarget: Decodable, Identifiable, Sendable {
  public let title: String
  public let file: String
  public let line: Int
  public let nodeID: String?
  public let org2Ref: String?
  public let subpath: String?
  public var id: String { "\(file):\(line):\(nodeID ?? "")" }
  enum CodingKeys: String, CodingKey { case title, file, line, nodeID = "id", org2Ref, subpath }
}

public enum JSONCanvasGeometry {
  public static func bounds(_ nodes: [JSONCanvasNode]) -> CGRect {
    nodes.reduce(CGRect.null) { $0.union($1.rectangle) }
  }

  public static func anchor(_ rectangle: CGRect, side: String?) -> CGPoint {
    switch side {
    case "top": CGPoint(x: rectangle.midX, y: rectangle.minY)
    case "bottom": CGPoint(x: rectangle.midX, y: rectangle.maxY)
    case "left": CGPoint(x: rectangle.minX, y: rectangle.midY)
    default: CGPoint(x: rectangle.maxX, y: rectangle.midY)
    }
  }

  public static func color(_ raw: String?) -> Color {
    switch raw {
    case "1": return .red
    case "2": return .orange
    case "3": return .yellow
    case "4": return .green
    case "5": return .cyan
    case "6": return .purple
    default:
      if let raw, raw.hasPrefix("#"), let value = UInt64(raw.dropFirst(), radix: 16) {
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
      }
      return .accentColor
    }
  }
}
