import Foundation
import XCTest
@testable import Org2WorkspaceCore

private final class AIProviderTestURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (Int, [String: Any]))?

  static func setHandler(_ handler: @escaping (URLRequest) throws -> (Int, [String: Any])) {
    lock.withLock { self.handler = handler }
  }

  static func reset() {
    lock.withLock { handler = nil }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = Self.lock.withLock { Self.handler }
      let (status, object) = try XCTUnwrap(handler)(request)
      let response = try XCTUnwrap(HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      ))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

final class AIProviderChatClientTests: XCTestCase {
  override func tearDown() {
    AIProviderTestURLProtocol.reset()
    super.tearDown()
  }

  func testOpenAISendsBearerAuthContextAndImage() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat/completions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
      let body = try self.requestBodyData(request)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(object["model"] as? String, "gpt-test")
      let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.first?["role"] as? String, "system")
      XCTAssertTrue((messages.first?["content"] as? String)?.contains("no tools") == true)
      let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
      XCTAssertEqual(content.last?["type"] as? String, "image_url")
      let imageURL = (content.last?["image_url"] as? [String: Any])?["url"] as? String
      XCTAssertEqual(imageURL, "data:image/png;base64,AQID")
      return (200, ["choices": [["message": ["content": "OpenAI reply"]]]])
    }

    let reply = try await client(.openAI, apiKey: "secret").send(
      messages: [
        OpenClawChatMessage(
          role: .user,
          content: "What is this?",
          attachments: [
            OpenClawChatAttachment(
              fileName: "sample.png",
              mimeType: "image/png",
              data: Data([1, 2, 3])
            )
          ]
        )
      ],
      model: "gpt-test",
      workspaceContext: emptyContext,
      destinationName: "OpenAI"
    )

    XCTAssertEqual(reply, "OpenAI reply")
  }

  func testAnthropicUsesMessagesContractAndAPIKeyHeader() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/messages")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
      XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try self.requestBodyData(request)) as? [String: Any]
      )
      XCTAssertEqual(object["model"] as? String, "claude-test")
      XCTAssertNotNil(object["system"] as? String)
      return (200, ["content": [
        ["type": "text", "text": "First"],
        ["type": "text", "text": "Second"],
      ]])
    }

    let reply = try await client(.anthropic, apiKey: "anthropic-secret").send(
      messages: [OpenClawChatMessage(role: .user, content: "Hello")],
      model: "claude-test",
      workspaceContext: emptyContext,
      destinationName: "Anthropic"
    )

    XCTAssertEqual(reply, "First\nSecond")
  }

  func testOpenRouterUsesCompatibleEndpointAndAttributionHeaders() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat/completions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer router-secret")
      XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), "https://org2.avi.press")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Org2 Workspace")
      return (200, ["choices": [["message": ["content": "Router reply"]]]])
    }

    let reply = try await client(.openRouter, apiKey: "router-secret").send(
      messages: [OpenClawChatMessage(role: .user, content: "Hello")],
      model: "vendor/model",
      workspaceContext: emptyContext,
      destinationName: "OpenRouter"
    )

    XCTAssertEqual(reply, "Router reply")
  }

  func testOllamaUsesLocalChatContractAndListsInstalledModels() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      if request.url?.path.hasSuffix("/tags") == true {
        return (200, ["models": [["name": "gemma:test"], ["model": "llama:test"]]])
      }
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try self.requestBodyData(request)) as? [String: Any]
      )
      XCTAssertEqual(object["stream"] as? Bool, false)
      return (200, ["message": ["content": "Local reply"]])
    }
    let client = try client(.ollama, apiKey: nil)

    let reply = try await client.send(
      messages: [OpenClawChatMessage(role: .user, content: "Hello")],
      model: "gemma:test",
      workspaceContext: emptyContext,
      destinationName: "Ollama"
    )
    let models = try await client.listModels()

    XCTAssertEqual(reply, "Local reply")
    XCTAssertEqual(models.map(\.id), ["gemma:test", "llama:test"])
  }

  func testHostedProviderRequiresAPIKeyWithoutMakingARequest() {
    XCTAssertThrowsError(try AIProviderChatSettings(
      adapter: .openAI,
      endpoint: "https://api.example.test/v1",
      apiKey: nil
    )) { error in
      XCTAssertEqual(error as? AIProviderChatError, .apiKeyRequired("OpenAI API"))
    }
  }

  func testRejectsNonImageAttachmentsBeforeMakingARequest() async throws {
    let client = try client(.ollama, apiKey: nil)
    do {
      _ = try await client.send(
        messages: [
          OpenClawChatMessage(
            role: .user,
            content: "Read this",
            attachments: [
              OpenClawChatAttachment(
                fileName: "report.pdf",
                mimeType: "application/pdf",
                data: Data([1])
              )
            ]
          )
        ],
        model: "gemma:test",
        workspaceContext: emptyContext,
        destinationName: "Ollama"
      )
      XCTFail("Expected a non-image attachment error")
    } catch {
      XCTAssertEqual(error as? AIProviderChatError, .unsupportedAttachment("report.pdf"))
    }
  }

  private func client(
    _ adapter: AIChatDestinationAdapter,
    apiKey: String?
  ) throws -> AIProviderChatClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AIProviderTestURLProtocol.self]
    return AIProviderChatClient(
      settings: try AIProviderChatSettings(
        adapter: adapter,
        endpoint: "https://api.example.test/v1",
        apiKey: apiKey
      ),
      session: URLSession(configuration: configuration)
    )
  }

  private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { throw try XCTUnwrap(stream.streamError) }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }

  private var emptyContext: OpenClawWorkspaceContext {
    OpenClawWorkspaceContext(
      localCorpusRoot: nil,
      remoteCorpusRoot: nil,
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )
  }
}
