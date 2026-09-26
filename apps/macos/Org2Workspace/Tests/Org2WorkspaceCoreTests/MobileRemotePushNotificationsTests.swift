import CryptoKit
import Foundation
import XCTest
@testable import Org2WorkspaceCore

private final class MobileRemotePushTestURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: ((URLRequest) throws -> Void)?

  static func setHandler(_ handler: @escaping (URLRequest) throws -> Void) {
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
      try XCTUnwrap(handler)(request)
      let response = try XCTUnwrap(HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      ))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data())
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

final class MobileRemotePushNotificationsTests: XCTestCase {
  override func tearDown() {
    MobileRemotePushTestURLProtocol.reset()
    super.tearDown()
  }

  func testReplyPushIsNotStoredForDelayedRedelivery() async throws {
    let messageID = UUID()
    let threadID = UUID()
    MobileRemotePushTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "apns-expiration"), "0")
      XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "10")
      XCTAssertEqual(request.value(forHTTPHeaderField: "apns-collapse-id"), threadID.uuidString)
      XCTAssertEqual(request.value(forHTTPHeaderField: "apns-id"), messageID.uuidString)
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MobileRemotePushTestURLProtocol.self]
    let sender = MobileRemotePushSender(session: URLSession(configuration: configuration))
    let privateKey = P256.Signing.PrivateKey()

    try await sender.send(
      MobileRemotePushEnvelope(
        messageID: messageID,
        threadID: threadID,
        title: "Recent reply",
        body: "This should arrive now or not at all."
      ),
      to: MobileRemoteStoredPushRegistration(
        deviceToken: "abcdef0123456789",
        environment: "sandbox"
      ),
      credentials: MobileRemotePushProviderCredentials(
        teamID: "TEAM123",
        keyID: "KEY123",
        privateKeyPEM: privateKey.pemRepresentation
      )
    )
  }
}
