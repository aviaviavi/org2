import Darwin
import Foundation

/// A supervisor pipe can become nonblocking when an agent child inherits it.
/// Poll on a dedicated thread so temporary EAGAIN reads never stop the server
/// or block its main actor. The caller retains ownership of the descriptor.
public enum HeadlessControlInput {
  private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
  }

  public static func lines(descriptor: Int32) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let cancellation = Cancellation()
      let worker = Thread {
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while !cancellation.isCancelled {
          var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
          let ready = poll(&event, 1, 100)
          if ready == 0 { continue }
          if ready < 0 {
            if errno == EINTR { continue }
            continuation.finish(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            return
          }
          let count = Darwin.read(descriptor, &bytes, bytes.count)
          if count < 0 {
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            continuation.finish(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            return
          }
          if count == 0 {
            if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
            continuation.finish()
            return
          }
          pending.append(contentsOf: bytes.prefix(count))
          while let newline = pending.firstIndex(of: 10) {
            continuation.yield(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
          }
        }
        continuation.finish()
      }
      worker.name = "OpenOrg supervisor input"
      continuation.onTermination = { _ in cancellation.cancel() }
      worker.start()
    }
  }
}
