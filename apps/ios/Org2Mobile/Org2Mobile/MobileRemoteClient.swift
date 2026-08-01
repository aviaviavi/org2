import Foundation
import Network

enum MobileRemoteClientError: LocalizedError {
  case invalidEndpoint
  case connection(String)
  case malformedResponse
  case server(String)
  case incompatibleProtocol

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "Enter a Tailscale URL such as http://100.64.0.1:48922."
    case .connection(let detail):
      "Could not reach the Mac: \(detail)"
    case .malformedResponse:
      "The Mac returned an unreadable response."
    case .server(let message):
      message
    case .incompatibleProtocol:
      "This Mac uses a different Mobile Remote protocol version. Update both Org2 apps."
    }
  }
}

struct MobileRemoteClient: Sendable {
  let endpoint: URL
  let accessToken: String?

  init(endpoint rawEndpoint: String, accessToken: String?) throws {
    let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
          components.scheme?.lowercased() == "http",
          let host = components.host,
          Self.isTailscaleIPv4(host)
    else {
      throw MobileRemoteClientError.invalidEndpoint
    }
    if components.port == nil {
      components.port = Int(MobileRemoteWire.defaultPort)
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let normalized = components.url else {
      throw MobileRemoteClientError.invalidEndpoint
    }
    endpoint = normalized
    self.accessToken = accessToken
  }

  func get<Response: Decodable>(_ path: String, as type: Response.Type) async throws -> Response {
    try await request(method: "GET", path: path, body: nil, as: type)
  }

  func post<Payload: Encodable, Response: Decodable>(
    _ path: String,
    payload: Payload,
    timeout: TimeInterval = 15,
    as type: Response.Type
  ) async throws -> Response {
    let body = try MobileRemoteWire.encoder().encode(payload)
    return try await request(method: "POST", path: path, body: body, timeout: timeout, as: type)
  }

  private func request<Response: Decodable>(
    method: String,
    path: String,
    body: Data?,
    timeout: TimeInterval = 15,
    as type: Response.Type
  ) async throws -> Response {
    guard let host = endpoint.host else {
      throw MobileRemoteClientError.invalidEndpoint
    }
    let portValue = endpoint.port ?? Int(MobileRemoteWire.defaultPort)
    guard let rawPort = UInt16(exactly: portValue),
          let port = NWEndpoint.Port(rawValue: rawPort)
    else {
      throw MobileRemoteClientError.invalidEndpoint
    }

    var headers = [
      "Accept: application/json",
      "Connection: close",
      "Host: \(host):\(portValue)"
    ]
    if let accessToken {
      headers.append("Authorization: Bearer \(accessToken)")
    }
    if let body {
      headers.append("Content-Type: application/json")
      headers.append("Content-Length: \(body.count)")
    } else {
      headers.append("Content-Length: 0")
    }

    var requestData = Data("\(method) \(path) HTTP/1.1\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8)
    if let body {
      requestData.append(body)
    }
    let response = try await MobileRemoteHTTPExchange(
      host: NWEndpoint.Host(host),
      port: port,
      request: requestData,
      timeout: timeout
    ).run()

    guard (200..<300).contains(response.statusCode) else {
      let envelope = try? MobileRemoteWire.decoder().decode(MobileRemoteErrorEnvelope.self, from: response.body)
      throw MobileRemoteClientError.server(envelope?.error ?? "The Mac rejected this request.")
    }
    return try MobileRemoteWire.decoder().decode(type, from: response.body)
  }

  private static func isTailscaleIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".").compactMap { UInt8($0) }
    return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
  }
}

private struct MobileRemoteRawResponse: Sendable {
  let statusCode: Int
  let body: Data
}

private final class MobileRemoteHTTPExchange: @unchecked Sendable {
  private let host: NWEndpoint.Host
  private let port: NWEndpoint.Port
  private let request: Data
  private let timeout: TimeInterval
  private let queue = DispatchQueue(label: "org.org2.mobile.remote-http", qos: .userInitiated)
  private let lock = NSLock()
  private var connection: NWConnection?
  private var continuation: CheckedContinuation<MobileRemoteRawResponse, Error>?
  private var received = Data()
  private var isFinished = false

  init(host: NWEndpoint.Host, port: NWEndpoint.Port, request: Data, timeout: TimeInterval) {
    self.host = host
    self.port = port
    self.request = request
    self.timeout = timeout
  }

  func run() async throws -> MobileRemoteRawResponse {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let connection = NWConnection(host: host, port: port, using: .tcp)
      self.connection = connection
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          self.sendRequest()
        case .failed(let error):
          self.finish(.failure(MobileRemoteClientError.connection(error.localizedDescription)))
        case .cancelled:
          self.finish(.failure(MobileRemoteClientError.connection("The connection closed.")))
        default:
          break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
        self?.finish(.failure(MobileRemoteClientError.connection("The request timed out.")))
      }
    }
  }

  private func sendRequest() {
    connection?.send(content: request, completion: .contentProcessed { [weak self] error in
      if let error {
        self?.finish(.failure(MobileRemoteClientError.connection(error.localizedDescription)))
      } else {
        self?.receiveNext()
      }
    })
  }

  private func receiveNext() {
    connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      guard let self else { return }
      if let data {
        self.received.append(data)
      }
      if let parsed = Self.parseResponseIfComplete(self.received) {
        self.finish(.success(parsed))
      } else if let error {
        self.finish(.failure(MobileRemoteClientError.connection(error.localizedDescription)))
      } else if complete {
        self.finish(.failure(MobileRemoteClientError.malformedResponse))
      } else {
        self.receiveNext()
      }
    }
  }

  private func finish(_ result: Result<MobileRemoteRawResponse, Error>) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isFinished = true
    let continuation = continuation
    self.continuation = nil
    let connection = connection
    self.connection = nil
    lock.unlock()

    connection?.stateUpdateHandler = nil
    connection?.cancel()
    continuation?.resume(with: result)
  }

  private static func parseResponseIfComplete(_ data: Data) -> MobileRemoteRawResponse? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: delimiter),
          let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
    else {
      return nil
    }
    let lines = headerText.components(separatedBy: "\r\n")
    let statusParts = lines.first?.split(separator: " ") ?? []
    guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else { return nil }
    var contentLength: Int?
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
      if key == "content-length" {
        contentLength = Int(String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces))
      }
    }
    guard let contentLength, contentLength >= 0 else { return nil }
    let bodyStart = headerRange.upperBound
    guard data.count >= bodyStart + contentLength else { return nil }
    return MobileRemoteRawResponse(
      statusCode: statusCode,
      body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
    )
  }
}
