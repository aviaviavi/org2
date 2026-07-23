import CoreServices
import Foundation

/// Recursive, low-latency corpus notifications backed by macOS FSEvents. The
/// watcher reports paths only; parsing and index updates stay in WorkspaceStore.
final class CorpusFileWatcher: @unchecked Sendable {
  typealias Handler = @Sendable (_ paths: [String], _ requiresFullScan: Bool) -> Void

  private let rootPath: String
  private let handler: Handler
  private let queue = DispatchQueue(label: "org.org2.workspace.corpus-events", qos: .utility)
  private var stream: FSEventStreamRef?

  init(rootURL: URL, handler: @escaping Handler) {
    rootPath = rootURL.standardizedFileURL.path
    self.handler = handler
    start()
  }

  deinit {
    stop()
  }

  private func start() {
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
      guard let info else { return }
      let watcher = Unmanaged<CorpusFileWatcher>.fromOpaque(info).takeUnretainedValue()
      let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
      var changedPaths: [String] = []
      var requiresFullScan = false
      for index in 0..<min(Int(count), paths.count) {
        let flags = eventFlags[index]
        if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 ||
            flags & UInt32(kFSEventStreamEventFlagUserDropped) != 0 ||
            flags & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 ||
            flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
          requiresFullScan = true
        }
        if flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 ||
            flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
          changedPaths.append(paths[index])
        }
      }
      if requiresFullScan || !changedPaths.isEmpty {
        watcher.handler(changedPaths, requiresFullScan)
      }
    }
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagUseCFTypes |
      kFSEventStreamCreateFlagFileEvents |
      kFSEventStreamCreateFlagNoDefer |
      kFSEventStreamCreateFlagWatchRoot
    )
    guard let stream = FSEventStreamCreate(
      nil,
      callback,
      &context,
      [rootPath] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.08,
      flags
    ) else { return }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
  }

  private func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }
}
