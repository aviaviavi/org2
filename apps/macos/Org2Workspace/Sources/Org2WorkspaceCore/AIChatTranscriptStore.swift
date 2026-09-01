import CryptoKit
import Foundation

struct AIChatTranscriptSnapshot: Sendable {
  let threads: [OpenClawChatThread]
  let selectedThreadID: UUID?
  let settlementSettings: OpenClawThreadSettlementSettings
}

enum AIChatTranscriptRecoveryStatus: Equatable, Sendable {
  case healthy
  case recoveredPreviousManifest
  case unrecoverable(String)

  var blocksWrites: Bool {
    if case .unrecoverable = self { return true }
    return false
  }
}

struct AIChatTranscriptLoadResult: Sendable {
  let snapshot: AIChatTranscriptSnapshot
  let unloadedThreadIDs: Set<UUID>
  let recoveryStatus: AIChatTranscriptRecoveryStatus
}

/// A coalescing, serial persistence service for AI chat state.
///
/// A tiny marker is the commit point. It references immutable, versioned
/// manifests, each of which references immutable, content-addressed thread
/// shards and attachment blobs. A crash before the marker update leaves the
/// previous commit authoritative; a crash afterwards can recover through the
/// marker's previous-manifest reference. `manifest.json` and
/// `manifest.previous.json` are inspectable, redundant derived copies.
final class AIChatTranscriptStore: @unchecked Sendable {
  static let shared = AIChatTranscriptStore()
  static let eagerWorkingSetLimit = 16

  private struct PendingWrite {
    let generation: UInt64
    let legacyURL: URL
    let snapshot: AIChatTranscriptSnapshot
  }

  private struct PersistenceWaiter {
    let generation: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let condition = NSCondition()
  private let queue = DispatchQueue(
    label: "org.org2.workspace.ai-chat-transcript-store",
    qos: .utility
  )
  private var nextGeneration: UInt64 = 0
  private var pendingWrites: [String: PendingWrite] = [:]
  private var exactPendingWrites: [PendingWrite] = []
  private var persistedGenerations: [String: UInt64] = [:]
  private var failedGenerations: [String: (generation: UInt64, error: Error)] = [:]
  private var latestSnapshots: [String: PendingWrite] = [:]
  private var persistenceWaiters: [String: [PersistenceWaiter]] = [:]
  private var validatedStoreStates: [String: StoreState] = [:]
  private var suspendedWritePathsForTesting: Set<String> = []
  private var garbageCollectionPaths: Set<String> = []
  private var isDraining = false

  private init() {}

  @discardableResult
  func enqueue(_ snapshot: AIChatTranscriptSnapshot, legacyURL: URL) -> UInt64 {
    enqueue(snapshot, legacyURL: legacyURL, requiresExactCommit: false)
  }

  @discardableResult
  func enqueueDurabilityBarrier(
    _ snapshot: AIChatTranscriptSnapshot,
    legacyURL: URL
  ) -> UInt64 {
    enqueue(snapshot, legacyURL: legacyURL, requiresExactCommit: true)
  }

  private func enqueue(
    _ snapshot: AIChatTranscriptSnapshot,
    legacyURL: URL,
    requiresExactCommit: Bool
  ) -> UInt64 {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    condition.lock()
    validatedStoreStates.removeValue(forKey: key)
    nextGeneration &+= 1
    let pending = PendingWrite(
      generation: nextGeneration,
      legacyURL: url,
      snapshot: snapshot
    )
    latestSnapshots[key] = pending
    if requiresExactCommit {
      exactPendingWrites.append(pending)
    } else {
      pendingWrites[key] = pending
    }
    let startsDrain = !isDraining
    if startsDrain { isDraining = true }
    condition.unlock()
    if startsDrain {
      queue.async { [weak self] in self?.drainWrites() }
    }
    return pending.generation
  }

  /// Waits for the exact snapshot generation (or a newer coalesced snapshot)
  /// to reach the commit marker. This never blocks the calling executor.
  func waitUntilPersisted(generation: UInt64, legacyURL: URL) async throws {
    let key = legacyURL.standardizedFileURL.path
    try await withCheckedThrowingContinuation { continuation in
      condition.lock()
      if persistedGenerations[key, default: 0] >= generation {
        condition.unlock()
        continuation.resume()
        return
      }
      if let failure = failedGenerations[key], failure.generation >= generation {
        condition.unlock()
        continuation.resume(throwing: failure.error)
        return
      }
      persistenceWaiters[key, default: []].append(PersistenceWaiter(
        generation: generation,
        continuation: continuation
      ))
      condition.unlock()
    }
  }

  /// Synchronous only for process-shutdown/test boundaries. Production
  /// interaction paths use `enqueue` + `waitUntilPersisted`.
  func flush(_ snapshot: AIChatTranscriptSnapshot, legacyURL: URL) throws {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    let generation = enqueue(snapshot, legacyURL: url)
    condition.lock()
    defer { condition.unlock() }
    while persistedGenerations[key, default: 0] < generation {
      if let failure = failedGenerations[key], failure.generation >= generation {
        throw failure.error
      }
      condition.wait()
    }
  }

  func loadIfAvailable(legacyURL: URL) -> AIChatTranscriptLoadResult? {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    condition.lock()
    let pending = latestSnapshots[key]
    condition.unlock()
    if let pending {
      return Self.materializePendingSnapshot(pending.snapshot, legacyURL: url)
    }
    guard let state = Self.loadStoreState(legacyURL: url) else { return nil }
    condition.lock()
    validatedStoreStates[key] = state
    condition.unlock()
    return Self.loadShardedSnapshot(legacyURL: url, state: state)
  }

  func setWritesSuspendedForTesting(_ suspended: Bool, legacyURL: URL) {
    let key = legacyURL.standardizedFileURL.path
    condition.lock()
    if suspended {
      suspendedWritePathsForTesting.insert(key)
    } else {
      suspendedWritePathsForTesting.remove(key)
      condition.broadcast()
    }
    condition.unlock()
  }

  func waitUntilIdleForTesting() {
    condition.lock()
    defer { condition.unlock() }
    while isDraining { condition.wait() }
  }

  func loadThread(
    id: UUID,
    metadata: OpenClawChatThread,
    legacyURL: URL
  ) -> OpenClawChatThread? {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    condition.lock()
    let cached = validatedStoreStates[key]
    condition.unlock()
    if let manifest = cached?.current,
       let loaded = Self.loadThread(id: id, metadata: metadata, manifest: manifest, legacyURL: url) {
      return loaded
    }
    // A failed cached shard read may mean storage changed underneath the app.
    // Revalidate the complete commit chain once so recovery can select the
    // previous manifest instead of returning stale or partial data.
    guard let refreshed = Self.loadStoreState(legacyURL: url) else { return nil }
    condition.lock()
    validatedStoreStates[key] = refreshed
    condition.unlock()
    guard let manifest = refreshed.current else { return nil }
    return Self.loadThread(id: id, metadata: metadata, manifest: manifest, legacyURL: url)
  }

  func loadAllThreads(
    replacingMetadata metadata: [OpenClawChatThread],
    legacyURL: URL
  ) -> [OpenClawChatThread] {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    condition.lock()
    let cached = validatedStoreStates[key]
    condition.unlock()
    let state: StoreState?
    if let cached {
      state = cached
    } else {
      state = Self.loadStoreState(legacyURL: url)
      if let state {
        condition.lock()
        validatedStoreStates[key] = state
        condition.unlock()
      }
    }
    guard let manifest = state?.current else { return metadata }
    return metadata.map { thread in
      guard thread.storedMessageCount != nil else { return thread }
      return Self.loadThread(
        id: thread.id,
        metadata: thread,
        manifest: manifest,
        legacyURL: url
      ) ?? thread
    }
  }

  nonisolated static func storeDirectory(for legacyURL: URL) -> URL {
    legacyURL.standardizedFileURL
      .deletingPathExtension()
      .appendingPathExtension("store")
  }

  private func drainWrites() {
    while true {
      condition.lock()
      let writablePending = Array(pendingWrites.values)
        .filter { !suspendedWritePathsForTesting.contains($0.legacyURL.path) }
        + exactPendingWrites.filter {
          !suspendedWritePathsForTesting.contains($0.legacyURL.path)
        }
      guard let pending = writablePending.min(by: { $0.generation < $1.generation }) else {
        if !pendingWrites.isEmpty || !exactPendingWrites.isEmpty {
          condition.wait()
          condition.unlock()
          continue
        }
        let cleanupPaths = garbageCollectionPaths
        garbageCollectionPaths.removeAll()
        condition.unlock()
        // No other writer can start while `isDraining` remains true. Re-read
        // the committed marker and collect only artifacts it no longer
        // references, then check once more for writes enqueued during cleanup.
        for key in cleanupPaths {
          Self.garbageCollect(legacyURL: URL(fileURLWithPath: key))
        }
        condition.lock()
        if pendingWrites.isEmpty && exactPendingWrites.isEmpty {
          isDraining = false
          condition.broadcast()
          condition.unlock()
          return
        }
        condition.unlock()
        continue
      }
      if let exactIndex = exactPendingWrites.firstIndex(where: {
        $0.generation == pending.generation
      }) {
        exactPendingWrites.remove(at: exactIndex)
      } else if pendingWrites[pending.legacyURL.path]?.generation == pending.generation {
        pendingWrites.removeValue(forKey: pending.legacyURL.path)
      }
      condition.unlock()

      let result = Result { try Self.write(pending.snapshot, legacyURL: pending.legacyURL) }
      var resumptions: [(CheckedContinuation<Void, Error>, Result<Void, Error>)] = []
      condition.lock()
      let key = pending.legacyURL.path
      switch result {
      case .success:
        persistedGenerations[key] = max(persistedGenerations[key, default: 0], pending.generation)
        garbageCollectionPaths.insert(key)
        if pendingWrites[key] == nil,
           !exactPendingWrites.contains(where: { $0.legacyURL.path == key }) {
          latestSnapshots.removeValue(forKey: key)
        }
        if let failure = failedGenerations[key], failure.generation <= pending.generation {
          failedGenerations.removeValue(forKey: key)
        }
      case .failure(let error):
        failedGenerations[key] = (pending.generation, error)
      }
      let persisted = persistedGenerations[key, default: 0]
      let failure = failedGenerations[key]
      var retained: [PersistenceWaiter] = []
      for waiter in persistenceWaiters[key] ?? [] {
        if persisted >= waiter.generation {
          resumptions.append((waiter.continuation, .success(())))
        } else if let failure, failure.generation >= waiter.generation {
          resumptions.append((waiter.continuation, .failure(failure.error)))
        } else {
          retained.append(waiter)
        }
      }
      persistenceWaiters[key] = retained.isEmpty ? nil : retained
      condition.broadcast()
      condition.unlock()
      for (continuation, result) in resumptions {
        continuation.resume(with: result)
      }
    }
  }

  private static func materializePendingSnapshot(
    _ snapshot: AIChatTranscriptSnapshot,
    legacyURL: URL
  ) -> AIChatTranscriptLoadResult {
    var unloaded = Set(snapshot.threads.compactMap { thread in
      thread.storedMessageCount == nil ? nil : thread.id
    })
    let eagerIDs = eagerThreadIDs(
      threads: snapshot.threads,
      selectedThreadID: snapshot.selectedThreadID
    )
    let state = loadStoreState(legacyURL: legacyURL)
    let threads = snapshot.threads.map { metadata -> OpenClawChatThread in
      guard metadata.storedMessageCount != nil, eagerIDs.contains(metadata.id),
            let manifest = state?.current,
            let loaded = loadThread(
              id: metadata.id,
              metadata: metadata,
              manifest: manifest,
              legacyURL: legacyURL
            )
      else { return metadata }
      unloaded.remove(metadata.id)
      return loaded
    }
    let recoveryStatus = state?.recoveryStatus ?? .healthy
    return AIChatTranscriptLoadResult(
      snapshot: AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: snapshot.selectedThreadID,
        settlementSettings: snapshot.settlementSettings
      ),
      unloadedThreadIDs: unloaded,
      recoveryStatus: recoveryStatus
    )
  }

  private static func loadShardedSnapshot(
    legacyURL: URL,
    state: StoreState
  ) -> AIChatTranscriptLoadResult {
    guard let manifest = state.current else {
      return AIChatTranscriptLoadResult(
        snapshot: AIChatTranscriptSnapshot(
          threads: [],
          selectedThreadID: nil,
          settlementSettings: OpenClawThreadSettlementSettings()
        ),
        unloadedThreadIDs: [],
        recoveryStatus: state.recoveryStatus
      )
    }
    let metadata = manifest.threads.map(\.metadata)
    let eagerIDs = eagerThreadIDs(
      threads: metadata,
      selectedThreadID: manifest.selectedThreadID
    )
    var unloaded = Set<UUID>()
    let threads = metadata.map { thread -> OpenClawChatThread in
      guard eagerIDs.contains(thread.id),
            let loaded = loadThread(
              id: thread.id,
              metadata: thread,
              manifest: manifest,
              legacyURL: legacyURL
            )
      else {
        if thread.storedMessageCount != nil { unloaded.insert(thread.id) }
        return thread
      }
      return loaded
    }
    return AIChatTranscriptLoadResult(
      snapshot: AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: manifest.selectedThreadID,
        settlementSettings: manifest.settlementSettings
      ),
      unloadedThreadIDs: unloaded,
      recoveryStatus: state.recoveryStatus
    )
  }

  private static func eagerThreadIDs(
    threads: [OpenClawChatThread],
    selectedThreadID: UUID?
  ) -> Set<UUID> {
    var ids = Set(threads.compactMap { thread in
      thread.id == selectedThreadID || thread.pendingTurn != nil ? thread.id : nil
    })
    for thread in threads where !thread.isSettled && ids.count < eagerWorkingSetLimit {
      ids.insert(thread.id)
    }
    return ids
  }

  private static func loadThread(
    id: UUID,
    metadata: OpenClawChatThread,
    manifest: Manifest,
    legacyURL: URL
  ) -> OpenClawChatThread? {
    guard let entry = manifest.threads.first(where: { $0.metadata.id == id }) else { return nil }
    let storeURL = storeDirectory(for: legacyURL)
    guard let shard = loadThreadShard(entry, storeURL: storeURL) else { return nil }
    let attachmentDirectory = attachmentsDirectory(storeURL: storeURL)
    let messages = shard.messages.map { stored in
      stored.message.replacingAttachments(
        stored.attachments.map { reference in
          OpenClawChatAttachment(
            id: reference.id,
            fileName: reference.fileName,
            mimeType: reference.mimeType,
            blobURL: attachmentDirectory.appendingPathComponent(reference.blob),
            byteCount: reference.byteCount,
            contentDigest: reference.digest
          )
        }
      )
    }
    return metadata.hydrating(messages: messages)
  }

  private static func write(
    _ snapshot: AIChatTranscriptSnapshot,
    legacyURL: URL
  ) throws {
    let fileManager = FileManager.default
    let storeURL = storeDirectory(for: legacyURL)
    let threadDirectory = threadsDirectory(storeURL: storeURL)
    let attachmentDirectory = attachmentsDirectory(storeURL: storeURL)
    let manifestDirectory = manifestsDirectory(storeURL: storeURL)
    try fileManager.createDirectory(at: threadDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
    guard ![storeURL, threadDirectory, attachmentDirectory, manifestDirectory]
      .contains(where: isSymbolicLink)
    else { throw TranscriptStoreError.unsafeStorePath }
    for directory in [storeURL, threadDirectory, attachmentDirectory, manifestDirectory] {
      try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    let priorState = loadStoreState(legacyURL: legacyURL)
    if let priorState, priorState.recoveryStatus.blocksWrites {
      throw TranscriptStoreError.unrecoverableStore(priorState.recoveryStatus.description)
    }
    let priorManifest = priorState?.current
    var entries: [ManifestThread] = []
    entries.reserveCapacity(snapshot.threads.count)

    for thread in snapshot.threads {
      if thread.storedMessageCount != nil {
        if let prior = priorManifest?.threads.first(where: { $0.metadata.id == thread.id }) {
          guard loadThreadShard(prior, storeURL: storeURL) != nil
          else { throw TranscriptStoreError.missingShard(thread.id) }
          entries.append(ManifestThread(
            metadata: thread.metadataOnly(),
            shard: prior.shard,
            shardDigest: prior.shardDigest,
            blobs: prior.blobs
          ))
          continue
        }
        guard thread.messageCount == 0 else {
          throw TranscriptStoreError.missingShard(thread.id)
        }
      }

      var storedMessages: [StoredMessage] = []
      var threadBlobs = Set<String>()
      storedMessages.reserveCapacity(thread.messages.count)
      for message in thread.messages {
        var references: [StoredAttachment] = []
        references.reserveCapacity(message.attachments.count)
        for attachment in message.attachments {
          let attachmentData = try attachment.loadData()
          let attachmentDigest = attachment.persistedContentDigest
          guard digest(attachmentData) == attachmentDigest,
                attachmentData.count == attachment.byteCount
          else { throw TranscriptStoreError.invalidAttachment(attachment.fileName) }
          let blobName = "\(attachmentDigest).blob"
          threadBlobs.insert(blobName)
          let blobURL = attachmentDirectory.appendingPathComponent(blobName)
          if fileManager.fileExists(atPath: blobURL.path) {
            let existing = try Data(contentsOf: blobURL, options: .mappedIfSafe)
            guard existing.count == attachment.byteCount, digest(existing) == attachmentDigest else {
              // Never replace corrupt bytes under a digest-derived identity.
              throw TranscriptStoreError.invalidAttachmentBlob(blobName)
            }
          } else {
            try attachmentData.write(to: blobURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blobURL.path)
          }
          references.append(StoredAttachment(
            id: attachment.id,
            fileName: attachment.fileName,
            mimeType: attachment.mimeType,
            blob: blobName,
            byteCount: attachment.byteCount,
            digest: attachmentDigest
          ))
        }
        storedMessages.append(StoredMessage(
          message: message.replacingAttachments([]),
          attachments: references
        ))
      }
      let shardData = try encoder.encode(ThreadShard(
        schema: ThreadShard.schemaValue,
        version: 1,
        messages: storedMessages
      ))
      let shardDigest = digest(shardData)
      let shardName = "threads/\(thread.id.uuidString.lowercased())-\(shardDigest.prefix(20)).json"
      try writeIfChanged(shardData, to: storeURL.appendingPathComponent(shardName))
      entries.append(ManifestThread(
        metadata: thread.metadataOnly(),
        shard: shardName,
        shardDigest: shardDigest,
        blobs: threadBlobs.sorted()
      ))
    }

    let commitID = UUID().uuidString.lowercased()
    let manifest = Manifest(
      schema: Manifest.schemaValue,
      version: 2,
      generation: (priorManifest?.generation ?? 0) &+ 1,
      commitID: commitID,
      parentCommitID: priorManifest?.commitID,
      threads: entries,
      selectedThreadID: snapshot.selectedThreadID,
      settlementSettings: snapshot.settlementSettings
    )
    let manifestData = try encoder.encode(manifest)
    let manifestName = "\(commitID).json"
    let versionedManifestURL = manifestDirectory.appendingPathComponent(manifestName)
    try writeIfChanged(manifestData, to: versionedManifestURL)

    // Updating this marker is the only commit point.
    let hasVersionedPrior = priorManifest.map {
      FileManager.default.fileExists(
        atPath: manifestDirectory.appendingPathComponent("\($0.commitID).json").path
      )
    } ?? false
    let previousData = hasVersionedPrior ? priorManifest.flatMap { try? encoder.encode($0) } : nil
    let previousName = hasVersionedPrior ? priorManifest.map { "\($0.commitID).json" } : nil
    let marker = StoreMarker(
      schema: StoreMarker.schemaValue,
      version: 1,
      currentManifest: manifestName,
      currentDigest: digest(manifestData),
      previousManifest: previousName,
      previousDigest: previousData.map(digest)
    )
    let markerURL = storeURL.appendingPathComponent("migration-marker.json")
    let previousMarkerURL = storeURL.appendingPathComponent("migration-marker.previous.json")
    let markerData = try encoder.encode(marker)
    if let existingMarker = try? Data(contentsOf: markerURL, options: .mappedIfSafe) {
      try existingMarker.write(to: previousMarkerURL, options: [.atomic])
    } else {
      // The first commit is redundant too; losing one marker must never make
      // the stale legacy monolith eligible again.
      try markerData.write(to: previousMarkerURL, options: [.atomic])
    }
    try markerData.write(
      to: markerURL,
      options: [.atomic]
    )
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previousMarkerURL.path)

    // Human-inspectable redundant views. Recovery does not depend on these
    // when the marker and its immutable manifests are intact.
    try writeIfChanged(manifestData, to: storeURL.appendingPathComponent("manifest.json"))
    if let previousData {
      try writeIfChanged(previousData, to: storeURL.appendingPathComponent("manifest.previous.json"))
    }

    // New corpora still get a small compatibility pointer at the historical
    // path. Existing monoliths remain untouched as an offline recovery source.
    if !fileManager.fileExists(atPath: legacyURL.path) {
      try fileManager.createDirectory(
        at: legacyURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try manifestData.write(to: legacyURL, options: [.atomic])
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyURL.path)
    }
  }

  private static func loadStoreState(legacyURL: URL) -> StoreState? {
    let storeURL = storeDirectory(for: legacyURL)
    let markerURL = storeURL.appendingPathComponent("migration-marker.json")
    let previousMarkerURL = storeURL.appendingPathComponent("migration-marker.previous.json")
    let currentViewURL = storeURL.appendingPathComponent("manifest.json")
    let previousViewURL = storeURL.appendingPathComponent("manifest.previous.json")
    let markerURLs = [markerURL, previousMarkerURL]
    let markerExists = markerURLs.contains { FileManager.default.fileExists(atPath: $0.path) }

    var recoveryCandidates: [Manifest] = []
    if let markerData = try? Data(contentsOf: markerURL, options: .mappedIfSafe),
       let marker = try? JSONDecoder().decode(StoreMarker.self, from: markerData),
       marker.schema == StoreMarker.schemaValue,
       marker.version == 1,
       isValidDigest(marker.currentDigest),
       marker.previousManifest == nil || marker.previousDigest.map(isValidDigest) == true {
      if let current = loadManifest(
        named: marker.currentManifest,
        expectedDigest: marker.currentDigest,
        storeURL: storeURL
      ) {
        let previous = marker.previousManifest.flatMap {
          loadManifest(named: $0, expectedDigest: marker.previousDigest, storeURL: storeURL)
        }
        return StoreState(current: current, previous: previous, recoveryStatus: .healthy)
      }
      if let previousName = marker.previousManifest,
         let previous = loadManifest(
          named: previousName,
          expectedDigest: marker.previousDigest,
          storeURL: storeURL
         ) {
        recoveryCandidates.append(previous)
      }
    }

    if let markerData = try? Data(contentsOf: previousMarkerURL, options: .mappedIfSafe),
       let marker = try? JSONDecoder().decode(StoreMarker.self, from: markerData),
       marker.schema == StoreMarker.schemaValue,
       marker.version == 1,
       isValidDigest(marker.currentDigest),
       marker.previousManifest == nil || marker.previousDigest.map(isValidDigest) == true {
      if let current = loadManifest(
        named: marker.currentManifest,
        expectedDigest: marker.currentDigest,
        storeURL: storeURL
      ) {
        recoveryCandidates.append(current)
      }
      if let previousName = marker.previousManifest,
         let previous = loadManifest(
          named: previousName,
          expectedDigest: marker.previousDigest,
          storeURL: storeURL
         ) {
        recoveryCandidates.append(previous)
      }
    }

    // A corrupt marker never authorizes falling back to the stale monolith.
    // Try the two redundant manifest views, newest valid generation first.
    if markerExists {
      recoveryCandidates += [currentViewURL, previousViewURL].compactMap { loadManifest(at: $0) }
      let candidates = Dictionary(
        recoveryCandidates.map { ($0.commitID, $0) },
        uniquingKeysWith: { first, _ in first }
      ).values.sorted { $0.generation > $1.generation }
      if let recovered = candidates.first {
        return StoreState(
          current: recovered,
          previous: candidates.dropFirst().first,
          recoveryStatus: .recoveredPreviousManifest
        )
      }
      return StoreState(
        current: nil,
        previous: nil,
        recoveryStatus: .unrecoverable(
          "AI chat storage metadata is corrupt. The stale legacy transcript was not loaded and writes are disabled."
        )
      )
    }

    if let current = loadManifest(at: currentViewURL) {
      return StoreState(
        current: current,
        previous: loadManifest(at: previousViewURL),
        recoveryStatus: .healthy
      )
    }

    // Backward-read the first sharded implementation. Its in-place shards are
    // converted to immutable entries on the next successful write.
    if let data = try? Data(contentsOf: currentViewURL, options: .mappedIfSafe),
       let legacy = try? JSONDecoder().decode(LegacyManifest.self, from: data),
       legacy.schema == LegacyManifest.schemaValue {
      let entries = legacy.threads.map { thread in
        let shard = "threads/\(thread.id.uuidString.lowercased()).json"
        let shardData = try? Data(
          contentsOf: storeURL.appendingPathComponent(shard),
          options: .mappedIfSafe
        )
        let decodedShard = shardData.flatMap { try? JSONDecoder().decode(ThreadShard.self, from: $0) }
        return ManifestThread(
          metadata: thread,
          shard: shard,
          shardDigest: shardData.map(digest) ?? "",
          blobs: decodedShard.map {
            Array(Set($0.messages.flatMap { message in message.attachments.map(\.blob) })).sorted()
          }
        )
      }
      return StoreState(
        current: Manifest(
          schema: Manifest.schemaValue,
          version: 2,
          generation: 0,
          commitID: "legacy-sharded-v1",
          parentCommitID: nil,
          threads: entries,
          selectedThreadID: legacy.selectedThreadID,
          settlementSettings: legacy.settlementSettings
        ),
        previous: nil,
        recoveryStatus: .healthy
      )
    }

    let hasCommittedManifestView = FileManager.default.fileExists(atPath: currentViewURL.path)
      || FileManager.default.fileExists(atPath: previousViewURL.path)
    if hasCommittedManifestView {
      return StoreState(
        current: nil,
        previous: nil,
        recoveryStatus: .unrecoverable(
          "AI chat storage exists but no valid manifest can be recovered. Writes are disabled."
        )
      )
    }
    return nil
  }

  private static func loadManifest(
    named name: String,
    expectedDigest: String?,
    storeURL: URL
  ) -> Manifest? {
    guard name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
    let url = manifestsDirectory(storeURL: storeURL).appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          expectedDigest == nil || digest(data) == expectedDigest,
          let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
          manifest.schema == Manifest.schemaValue,
          manifest.version == 2,
          isComplete(manifest, storeURL: storeURL)
    else { return nil }
    return manifest
  }

  private static func loadManifest(at url: URL) -> Manifest? {
    let storeURL = url.deletingLastPathComponent()
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
          manifest.schema == Manifest.schemaValue,
          manifest.version == 2,
          isComplete(manifest, storeURL: storeURL)
    else { return nil }
    return manifest
  }

  /// A manifest is a usable commit only when every immutable shard it names
  /// is present and independently verifies. Validating this transitively at
  /// commit selection keeps a corrupt newest shard from being mistaken for a
  /// healthy metadata-only thread and lets recovery choose the previous
  /// complete commit instead.
  private static func isComplete(_ manifest: Manifest, storeURL: URL) -> Bool {
    guard !manifest.commitID.isEmpty,
          manifest.commitID == URL(fileURLWithPath: manifest.commitID).lastPathComponent,
          manifest.selectedThreadID == nil
            || manifest.threads.contains(where: { $0.metadata.id == manifest.selectedThreadID })
    else { return false }
    var threadIDs = Set<UUID>()
    for entry in manifest.threads {
      guard threadIDs.insert(entry.metadata.id).inserted,
            loadThreadShard(entry, storeURL: storeURL) != nil
      else { return false }
    }
    return true
  }

  private static func loadThreadShard(
    _ entry: ManifestThread,
    storeURL: URL
  ) -> ThreadShard? {
    let threadDirectory = threadsDirectory(storeURL: storeURL)
    let shardName = URL(fileURLWithPath: entry.shard).lastPathComponent
    guard entry.shard == "threads/\(shardName)",
          isValidDigest(entry.shardDigest)
    else { return nil }
    let shardURL = storeURL.appendingPathComponent(entry.shard)
    guard isDescendant(shardURL, of: threadDirectory),
          !isSymbolicLink(shardURL),
          let data = try? Data(contentsOf: shardURL, options: .mappedIfSafe),
          digest(data) == entry.shardDigest,
          let shard = try? JSONDecoder().decode(ThreadShard.self, from: data),
          shard.schema == ThreadShard.schemaValue,
          shard.version == 1,
          validateStoredReferences(shard, storeURL: storeURL)
    else { return nil }
    if let storedCount = entry.metadata.storedMessageCount {
      let visibleCount = shard.messages.lazy.filter { !$0.message.isRoomDispatchCopy }.count
      guard storedCount == visibleCount else { return nil }
    } else {
      return nil
    }
    if let blobs = entry.blobs {
      let referenced = Set(shard.messages.flatMap { $0.attachments.map(\.blob) })
      guard Set(blobs) == referenced, Set(blobs).count == blobs.count else { return nil }
    }
    return shard
  }

  private static func validateStoredReferences(
    _ shard: ThreadShard,
    storeURL: URL
  ) -> Bool {
    let attachmentDirectory = attachmentsDirectory(storeURL: storeURL)
    return shard.messages.allSatisfy { stored in
      stored.attachments.allSatisfy { reference in
        guard reference.byteCount >= 0,
              isValidDigest(reference.digest),
              reference.blob == "\(reference.digest).blob",
              reference.blob == URL(fileURLWithPath: reference.blob).lastPathComponent
        else { return false }
        return isDescendant(
          attachmentDirectory.appendingPathComponent(reference.blob),
          of: attachmentDirectory
        )
      }
    }
  }

  private static func isValidDigest(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (97...102).contains(byte)
    }
  }

  private static func garbageCollect(legacyURL: URL) {
    guard let state = loadStoreState(legacyURL: legacyURL),
          !state.recoveryStatus.blocksWrites,
          let current = state.current
    else { return }
    let storeURL = storeDirectory(for: legacyURL)
    let retainedManifests = [current, state.previous].compactMap { $0 }
    let retainedCommitFiles = Set(retainedManifests.map { "\($0.commitID).json" })
    let retainedShards = Set(retainedManifests.flatMap { $0.threads.map(\.shard) })
    var retainedBlobs = Set(retainedManifests.flatMap { manifest in
      manifest.threads.flatMap { $0.blobs ?? [] }
    })
    let entriesWithoutBlobIndexes = retainedManifests
      .flatMap(\.threads)
      .filter { $0.blobs == nil }
    for entry in entriesWithoutBlobIndexes {
      let shard = entry.shard
      let shardURL = storeURL.appendingPathComponent(shard)
      guard isDescendant(shardURL, of: threadsDirectory(storeURL: storeURL)),
            let data = try? Data(contentsOf: shardURL, options: .mappedIfSafe),
            let decoded = try? JSONDecoder().decode(ThreadShard.self, from: data)
      else { continue }
      retainedBlobs.formUnion(decoded.messages.flatMap { $0.attachments.map(\.blob) })
    }

    removeUnretainedFiles(
      in: manifestsDirectory(storeURL: storeURL),
      retaining: retainedCommitFiles
    )
    removeUnretainedFiles(
      in: threadsDirectory(storeURL: storeURL),
      retaining: Set(retainedShards.map { URL(fileURLWithPath: $0).lastPathComponent })
    )
    removeUnretainedFiles(
      in: attachmentsDirectory(storeURL: storeURL),
      retaining: retainedBlobs
    )
  }

  private static func removeUnretainedFiles(in directory: URL, retaining names: Set<String>) {
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    for url in urls where !names.contains(url.lastPathComponent) {
      guard isDescendant(url, of: directory),
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true || values.isSymbolicLink == true
      else { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func writeIfChanged(_ data: Data, to url: URL) throws {
    if let existing = try? Data(contentsOf: url, options: .mappedIfSafe), existing == data { return }
    try data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func isDescendant(_ url: URL, of directory: URL) -> Bool {
    let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
    return resolvedURL.path.hasPrefix(resolvedDirectory.path + "/")
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private static func threadsDirectory(storeURL: URL) -> URL {
    storeURL.appendingPathComponent("threads", isDirectory: true)
  }

  private static func attachmentsDirectory(storeURL: URL) -> URL {
    storeURL.appendingPathComponent("attachments", isDirectory: true)
  }

  private static func manifestsDirectory(storeURL: URL) -> URL {
    storeURL.appendingPathComponent("manifests", isDirectory: true)
  }
}

private struct StoreState {
  let current: Manifest?
  let previous: Manifest?
  let recoveryStatus: AIChatTranscriptRecoveryStatus
}

private struct StoreMarker: Codable {
  static let schemaValue = "org2:ai-chat-transcript-store-marker:v1"
  let schema: String
  let version: Int
  let currentManifest: String
  let currentDigest: String
  let previousManifest: String?
  let previousDigest: String?
}

private struct Manifest: Codable {
  static let schemaValue = "org2:ai-chat-transcript-manifest:v2"
  let schema: String
  let version: Int
  let generation: UInt64
  let commitID: String
  let parentCommitID: String?
  let threads: [ManifestThread]
  let selectedThreadID: UUID?
  let settlementSettings: OpenClawThreadSettlementSettings
}

private struct ManifestThread: Codable {
  let metadata: OpenClawChatThread
  let shard: String
  let shardDigest: String
  let blobs: [String]?
}

private struct LegacyManifest: Codable {
  static let schemaValue = "org2:ai-chat-transcript-manifest:v1"
  let schema: String
  let version: Int
  let threads: [OpenClawChatThread]
  let selectedThreadID: UUID?
  let settlementSettings: OpenClawThreadSettlementSettings
}

private struct ThreadShard: Codable {
  static let schemaValue = "org2:ai-chat-thread:v1"
  let schema: String
  let version: Int
  let messages: [StoredMessage]
}

private struct StoredMessage: Codable {
  let message: OpenClawChatMessage
  let attachments: [StoredAttachment]
}

private struct StoredAttachment: Codable {
  let id: UUID
  let fileName: String
  let mimeType: String
  let blob: String
  let byteCount: Int
  let digest: String
}

private enum TranscriptStoreError: LocalizedError {
  case missingShard(UUID)
  case invalidAttachment(String)
  case invalidAttachmentBlob(String)
  case unrecoverableStore(String)
  case unsafeStorePath

  var errorDescription: String? {
    switch self {
    case .missingShard(let id):
      "Cannot persist metadata-only AI chat thread \(id) because its message shard is missing."
    case .invalidAttachment(let name):
      "AI chat attachment \(name) does not match its stored size or digest."
    case .invalidAttachmentBlob(let name):
      "AI chat attachment blob \(name) is corrupt; it was not overwritten."
    case .unrecoverableStore(let message):
      message
    case .unsafeStorePath:
      "AI chat storage directories must not be symbolic links."
    }
  }
}

private extension AIChatTranscriptRecoveryStatus {
  var description: String {
    switch self {
    case .healthy: "AI chat storage is healthy."
    case .recoveredPreviousManifest: "AI chat storage recovered its previous manifest."
    case .unrecoverable(let message): message
    }
  }
}
