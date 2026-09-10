import Foundation
import JavaScriptCore

// Confined to the background operation that creates it; JSContext never crosses tasks.
final class MobileDocumentRuntime {
  private let context: JSContext

  init() throws {
    guard let context = JSContext(),
          let url = Bundle.main.url(forResource: "Org2MobileDocument", withExtension: "js")
    else { throw RuntimeError("The local document renderer is unavailable.") }
    self.context = context
    context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
    if let exception = context.exception { throw RuntimeError(exception.toString()) }
  }

  func index(source: String, path: String, sequences: [String]) throws -> [MobileSearchEntry] {
    try call("indexDocument", arguments: [source, path, sequences])
  }

  func render(source: String, path: String, entry: MobileSearchEntry?, sequences: [String]) throws -> MobileRenderedDocument {
    try call("renderDocument", arguments: [source, path, entry?.line ?? 0, entry?.nodeID ?? "", sequences, entry?.title ?? ""])
  }

  private func call<T: Decodable>(_ name: String, arguments: [Any]) throws -> T {
    context.exception = nil
    guard let value = context.objectForKeyedSubscript("Org2MobileDocument")?.invokeMethod(name, withArguments: arguments),
          context.exception == nil, let object = value.toObject()
    else { throw RuntimeError(context.exception?.toString() ?? "Could not read this Org document.") }
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

struct MobileRenderedDocument: Decodable, Sendable {
  let title: String
  let html: String
}
