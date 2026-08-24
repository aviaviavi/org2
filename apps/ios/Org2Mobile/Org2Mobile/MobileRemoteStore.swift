@preconcurrency import Foundation
import Security
import UIKit
@preconcurrency import UserNotifications

@MainActor
final class MobileRemoteStore: ObservableObject {
  @Published private(set) var isPaired = false
  @Published private(set) var isConnected = false
  @Published private(set) var connectionError: String?
  @Published private(set) var serverName = "Org2 on Mac"
  @Published private(set) var status: MobileRemoteServerStatus?
  @Published private(set) var threads: [MobileRemoteThreadSummary] = []
  @Published private(set) var threadDetail: MobileRemoteThreadDetail?
  @Published private(set) var threadConfiguration: MobileRemoteThreadConfiguration?
  @Published private(set) var threadConnectionError: String?
  @Published private(set) var configurationError: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var isPairing = false
  @Published private(set) var isRefreshingConfiguration = false
  @Published private(set) var isUpdatingConfiguration = false
  @Published private(set) var mutatingThreadIDs: Set<UUID> = []
  @Published private(set) var loadingThreadID: UUID?
  @Published private(set) var externalThreads: [MobileExternalThreadSummary] = []
  @Published private(set) var externalThreadDetail: MobileExternalThreadDetail?
  @Published private(set) var isRefreshingExternalThreads = false
  @Published private(set) var isLoadingExternalThread = false
  @Published private(set) var workspaceAgenda: [AgendaEntry] = []
  @Published private(set) var workspaceApprovals: [ApprovalEntry] = []
  @Published private(set) var workspaceWorkflows: [MobileRemoteWorkflowItem] = []
  @Published private(set) var workspaceUpdatedAt: Date?
  @Published private(set) var workspaceConnectionError: String?
  @Published private(set) var isRefreshingWorkspace = false
  @Published private(set) var mutatingWorkspaceItemIDs: Set<String> = []
  @Published private(set) var threadNotificationsEnabled: Bool
  @Published private(set) var threadNotificationsUnavailable = false
  @Published private(set) var realTimeNotificationsActive = false
  @Published private(set) var pushNotificationStatusText = "Waiting for Apple Push Notifications"
  @Published var endpointDraft = ""
  @Published var codeDraft = ""
  @Published var errorMessage: String?

  private static let endpointKey = "Org2Mobile.remote.endpoint.v1"
  private static let serverNameKey = "Org2Mobile.remote.serverName.v1"
  private static let deviceIDKey = "Org2Mobile.remote.deviceID.v1"
  private static let threadNotificationsEnabledKey = "Org2Mobile.remote.threadNotificationsEnabled.v1"
  private static let replyNotificationBaselineKey = MobileRemoteNotification.replyBaselineKey
  private static let tokenService = "org.org2.mobile.remote"
  private static let tokenAccount = "mac-access-token"

  private let defaults: UserDefaults
  private var accessToken: String?
  private var pushRegistrationFingerprint: String?
  private var isSyncingPushRegistration = false
  private var notificationObservers: [NSObjectProtocol] = []
  private var pollingTask: Task<Void, Never>?
  private var foregroundReplyPollingTask: Task<Void, Never>?
  private var appIsActive = false
  private var pollingThreadID: UUID?
  private var pollingLeaseID: UUID?
  private var configurationRequestID: UUID?
  private var threadDetailCache: [UUID: MobileRemoteThreadDetail] = [:]
  private var threadDetailCacheOrder: [UUID] = []
  private static let threadDetailCacheLimit = 6
  private var externalThreadLoadRequestID: UUID?
  private var externalThreadDetailCache: [String: MobileExternalThreadDetail] = [:]
  private var externalThreadDetailCacheOrder: [String] = []
  private static let externalThreadDetailCacheLimit = 6

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    threadNotificationsEnabled = defaults.object(forKey: Self.threadNotificationsEnabledKey) as? Bool ?? true
    endpointDraft = defaults.string(forKey: Self.endpointKey) ?? ""
    serverName = defaults.string(forKey: Self.serverNameKey) ?? "Org2 on Mac"
    accessToken = Self.loadToken()
    isPaired = !endpointDraft.isEmpty && accessToken != nil
    notificationObservers = [
      NotificationCenter.default.addObserver(
        forName: .org2RemotePushTokenUpdated,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.pushNotificationStatusText = "Connecting real-time notifications"
          await self?.syncPushRegistrationIfNeeded(force: true)
        }
      },
      NotificationCenter.default.addObserver(
        forName: .org2RemotePushRegistrationFailed,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let detail = notification.userInfo?["error"] as? String
        Task { @MainActor [weak self] in
          self?.realTimeNotificationsActive = false
          self?.pushNotificationStatusText = detail.map { "Push registration failed: \($0)" }
            ?? "Push registration failed"
        }
      }
    ]
  }

  deinit {
    pollingTask?.cancel()
    foregroundReplyPollingTask?.cancel()
    notificationObservers.forEach(NotificationCenter.default.removeObserver)
  }

  func applyPairingPayload(_ payload: String) -> Bool {
    guard let components = URLComponents(string: payload),
          components.scheme == "org2-remote",
          components.host == "pair",
          let endpoint = components.queryItems?.first(where: { $0.name == "endpoint" })?.value,
          let code = components.queryItems?.first(where: { $0.name == "code" })?.value
    else {
      errorMessage = "That QR code is not an OpenOrg pairing code."
      return false
    }
    endpointDraft = endpoint
    codeDraft = code
    if let name = components.queryItems?.first(where: { $0.name == "name" })?.value {
      serverName = name
    }
    return true
  }

  func pair() async {
    guard !isPairing else { return }
    isPairing = true
    defer { isPairing = false }
    do {
      let client = try MobileRemoteClient(endpoint: endpointDraft, accessToken: nil)
      let response: MobileRemotePairResponse = try await client.post(
        "/v1/pair",
        payload: MobileRemotePairRequest(
          code: codeDraft.trimmingCharacters(in: .whitespacesAndNewlines),
          deviceName: UIDevice.current.name
        ),
        as: MobileRemotePairResponse.self
      )
      guard response.protocolVersion == MobileRemoteWire.version else {
        throw MobileRemoteClientError.incompatibleProtocol
      }
      try Self.saveToken(response.accessToken)
      accessToken = response.accessToken
      serverName = response.serverName
      codeDraft = ""
      defaults.set(endpointDraft, forKey: Self.endpointKey)
      defaults.set(serverName, forKey: Self.serverNameKey)
      defaults.set(response.deviceID.uuidString, forKey: Self.deviceIDKey)
      isPaired = true
      await prepareThreadNotifications()
      await refresh()
      await syncPushRegistrationIfNeeded(force: true)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func disconnect() {
    if isPaired, accessToken != nil, let client = try? pairedClient() {
      Task {
        _ = try? await client.post(
          "/v1/push-registration",
          payload: MobileRemotePushRegistrationRequest(
            deviceToken: nil,
            environment: nil,
            enabled: false
          ),
          as: MobileRemotePushRegistrationResponse.self
        )
      }
    }
    pollingTask?.cancel()
    pollingTask = nil
    pollingThreadID = nil
    pollingLeaseID = nil
    foregroundReplyPollingTask?.cancel()
    foregroundReplyPollingTask = nil
    Self.deleteToken()
    accessToken = nil
    isPaired = false
    isConnected = false
    connectionError = nil
    realTimeNotificationsActive = false
    pushNotificationStatusText = "Pair with a Mac for real-time notifications"
    pushRegistrationFingerprint = nil
    status = nil
    threads = []
    threadDetail = nil
    loadingThreadID = nil
    threadDetailCache.removeAll()
    threadDetailCacheOrder.removeAll()
    threadConfiguration = nil
    externalThreads = []
    externalThreadDetail = nil
    externalThreadLoadRequestID = nil
    externalThreadDetailCache.removeAll()
    externalThreadDetailCacheOrder.removeAll()
    workspaceAgenda = []
    workspaceApprovals = []
    workspaceWorkflows = []
    workspaceUpdatedAt = nil
    workspaceConnectionError = nil
    isRefreshingWorkspace = false
    mutatingWorkspaceItemIDs = []
    threadConnectionError = nil
    configurationError = nil
    defaults.removeObject(forKey: Self.endpointKey)
    defaults.removeObject(forKey: Self.serverNameKey)
    defaults.removeObject(forKey: Self.deviceIDKey)
    defaults.removeObject(forKey: Self.replyNotificationBaselineKey)
    defaults.removeObject(forKey: MobileRemoteNotification.pendingReplyThreadIDKey)
  }

  func refresh(reportsErrors: Bool = true) async {
    guard isPaired, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let client = try pairedClient()
      async let statusRequest = client.get("/v1/status", as: MobileRemoteServerStatus.self)
      async let threadsRequest = client.get("/v1/threads", as: MobileRemoteThreadList.self)
      let (nextStatus, nextThreads) = try await (statusRequest, threadsRequest)
      guard nextStatus.protocolVersion == MobileRemoteWire.version else {
        throw MobileRemoteClientError.incompatibleProtocol
      }
      status = nextStatus
      isConnected = true
      connectionError = nil
      serverName = nextStatus.serverName
      await syncPushRegistrationIfNeeded(force: false)
      await reconcileReplyNotifications(with: nextThreads.threads)
      threads = nextThreads.threads
      pruneThreadDetailCache(keeping: Set(nextThreads.threads.map(\.id)))
      defaults.set(serverName, forKey: Self.serverNameKey)
    } catch {
      isConnected = false
      connectionError = error.localizedDescription
      if reportsErrors {
        errorMessage = error.localizedDescription
      }
    }
  }

  func refreshWorkspace(reportsErrors: Bool = true) async {
    guard isPaired, !isRefreshingWorkspace else { return }
    isRefreshingWorkspace = true
    defer { isRefreshingWorkspace = false }
    do {
      let snapshot = try await pairedClient().get(
        "/v1/workspace",
        timeout: 60,
        as: MobileRemoteWorkspaceSnapshot.self
      )
      apply(snapshot)
      workspaceConnectionError = nil
      isConnected = true
    } catch {
      workspaceConnectionError = error.localizedDescription
      if reportsErrors, workspaceUpdatedAt == nil {
        errorMessage = "Could not load canonical workspace data from the Mac. \(error.localizedDescription)"
      }
    }
  }

  func setAgendaStatus(_ status: OrgTodoStatus, for entry: AgendaEntry) async {
    let canonicalStatus: String
    switch status {
    case .done:
      canonicalStatus = "done"
    case .canceled, .cancelled:
      canonicalStatus = "canceled"
    case .inProgress, .prog, .started, .doing:
      canonicalStatus = "in_progress"
    default:
      canonicalStatus = "todo"
    }
    await mutateWorkspaceItem(entry.id) {
      try await self.pairedClient().post(
        self.workspacePath(collection: "agenda", id: entry.id, action: "status"),
        payload: MobileRemoteAgendaStatusRequest(status: canonicalStatus),
        timeout: 60,
        as: MobileRemoteWorkspaceSnapshot.self
      )
    }
  }

  func decideApproval(
    _ approval: ApprovalEntry,
    decision: String,
    note: String? = nil,
    endStatus: OrgTodoStatus? = nil
  ) async {
    let canonicalEndStatus: String?
    switch endStatus {
    case .done?: canonicalEndStatus = "done"
    case .canceled?, .cancelled?: canonicalEndStatus = "canceled"
    default: canonicalEndStatus = nil
    }
    await mutateWorkspaceItem(approval.id) {
      try await self.pairedClient().post(
        self.workspacePath(collection: "approvals", id: approval.id, action: "decision"),
        payload: MobileRemoteApprovalDecisionRequest(
          decision: decision,
          note: note,
          endStatus: canonicalEndStatus
        ),
        timeout: 90,
        as: MobileRemoteWorkspaceSnapshot.self
      )
    }
  }

  func setWorkflowState(_ state: String, for workflow: MobileRemoteWorkflowItem) async {
    await mutateWorkspaceItem(workflow.id) {
      try await self.pairedClient().post(
        self.workspacePath(collection: "workflows", id: workflow.id, action: "state"),
        payload: MobileRemoteWorkflowStateRequest(state: state),
        timeout: 60,
        as: MobileRemoteWorkspaceSnapshot.self
      )
    }
  }

  func runWorkflow(_ workflow: MobileRemoteWorkflowItem, inputs: [String: String]) async -> UUID? {
    guard !mutatingWorkspaceItemIDs.contains(workflow.id) else { return nil }
    mutatingWorkspaceItemIDs.insert(workflow.id)
    defer { mutatingWorkspaceItemIDs.remove(workflow.id) }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        workspacePath(collection: "workflows", id: workflow.id, action: "run"),
        payload: MobileRemoteWorkflowRunRequest(inputs: inputs),
        timeout: 60,
        as: MobileRemoteMutationResponse.self
      )
      await refresh()
      return response.threadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func mutateWorkspaceItem(
    _ id: String,
    operation: () async throws -> MobileRemoteWorkspaceSnapshot
  ) async {
    guard !mutatingWorkspaceItemIDs.contains(id) else { return }
    mutatingWorkspaceItemIDs.insert(id)
    defer { mutatingWorkspaceItemIDs.remove(id) }
    do {
      apply(try await operation())
      workspaceConnectionError = nil
      isConnected = true
    } catch {
      errorMessage = error.localizedDescription
      await refreshWorkspace(reportsErrors: false)
    }
  }

  private func apply(_ snapshot: MobileRemoteWorkspaceSnapshot) {
    workspaceAgenda = snapshot.agenda.map(\.localEntry)
    workspaceApprovals = snapshot.approvals.map(\.localEntry)
    workspaceWorkflows = snapshot.workflows
    workspaceUpdatedAt = snapshot.updatedAt
  }

  private func workspacePath(collection: String, id: String, action: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#%")
    let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    return "/v1/workspace/\(collection)/\(encodedID)/\(action)"
  }

  func setAppActive(_ isActive: Bool) {
    appIsActive = isActive
    foregroundReplyPollingTask?.cancel()
    foregroundReplyPollingTask = nil
    guard isActive, isPaired, threadNotificationsEnabled else { return }
    foregroundReplyPollingTask = Task { [weak self] in
      guard let self else { return }
      await self.prepareThreadNotifications()
      while !Task.isCancelled {
        await self.refresh(reportsErrors: false)
        try? await Task.sleep(for: .seconds(15))
      }
    }
  }

  func setThreadNotificationsEnabled(_ enabled: Bool) {
    guard threadNotificationsEnabled != enabled else { return }
    threadNotificationsEnabled = enabled
    defaults.set(enabled, forKey: Self.threadNotificationsEnabledKey)
    if !enabled {
      realTimeNotificationsActive = false
      pushNotificationStatusText = "Reply notifications are off"
      pushRegistrationFingerprint = nil
      Task { await syncPushRegistrationIfNeeded(force: true, enabled: false) }
    }
    if enabled, appIsActive {
      // Establish a fresh baseline before alerting so enabling the option does
      // not replay replies that arrived while notifications were disabled.
      defaults.removeObject(forKey: Self.replyNotificationBaselineKey)
      pushNotificationStatusText = "Connecting real-time notifications"
      setAppActive(true)
    } else {
      foregroundReplyPollingTask?.cancel()
      foregroundReplyPollingTask = nil
      threadNotificationsUnavailable = false
    }
  }

  func refreshReplyNotificationsInBackground() async -> Bool {
    guard isPaired, threadNotificationsEnabled else { return true }
    await refresh(reportsErrors: false)
    return isConnected
  }

  func consumePendingReplyThreadID() -> UUID? {
    guard let rawID = defaults.string(forKey: MobileRemoteNotification.pendingReplyThreadIDKey),
          let threadID = UUID(uuidString: rawID)
    else { return nil }
    defaults.removeObject(forKey: MobileRemoteNotification.pendingReplyThreadIDKey)
    return threadID
  }

  private func prepareThreadNotifications() async {
    #if DEBUG
    if ProcessInfo.processInfo.environment["ORG2_DEBUG_SUPPRESS_NOTIFICATIONS"] == "1" {
      return
    }
    #endif
    guard threadNotificationsEnabled else { return }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined {
      _ = try? await center.requestAuthorization(options: [.alert])
    }
    let refreshedSettings = await center.notificationSettings()
    threadNotificationsUnavailable = !Self.notificationAuthorizationAllowsAlerts(
      refreshedSettings.authorizationStatus
    )
    if !threadNotificationsUnavailable {
      UIApplication.shared.registerForRemoteNotifications()
      await syncPushRegistrationIfNeeded(force: false)
    } else {
      realTimeNotificationsActive = false
      pushNotificationStatusText = "Notifications are disabled in iOS Settings"
    }
  }

  private func syncPushRegistrationIfNeeded(
    force: Bool,
    enabled requestedEnabled: Bool? = nil
  ) async {
    guard isPaired, !isSyncingPushRegistration else { return }
    let enabled = requestedEnabled ?? threadNotificationsEnabled
    let token = enabled
      ? defaults.string(forKey: MobileRemoteNotification.deviceTokenKey)
      : nil
    let environment = enabled
      ? defaults.string(forKey: MobileRemoteNotification.pushEnvironmentKey)
      : nil
    if enabled, token == nil {
      realTimeNotificationsActive = false
      pushNotificationStatusText = "Waiting for Apple Push Notifications"
      return
    }
    if enabled, status?.pushNotificationsSupported == false {
      realTimeNotificationsActive = false
      pushNotificationStatusText = "Update Org2 on the Mac to enable real-time notifications"
      return
    }
    let fingerprint = "\(enabled):\(environment ?? "none"):\(token ?? "none")"
    guard force || fingerprint != pushRegistrationFingerprint else { return }
    isSyncingPushRegistration = true
    defer { isSyncingPushRegistration = false }
    do {
      let response: MobileRemotePushRegistrationResponse = try await pairedClient().post(
        "/v1/push-registration",
        payload: MobileRemotePushRegistrationRequest(
          deviceToken: token,
          environment: environment,
          enabled: enabled
        ),
        as: MobileRemotePushRegistrationResponse.self
      )
      pushRegistrationFingerprint = fingerprint
      realTimeNotificationsActive = response.enabled && response.providerConfigured
      if !enabled {
        pushNotificationStatusText = "Reply notifications are off"
      } else if response.providerConfigured {
        pushNotificationStatusText = "Real-time notifications are active"
      } else {
        pushNotificationStatusText = "Finish push setup in Org2 on the Mac"
      }
    } catch {
      realTimeNotificationsActive = false
      if status?.pushNotificationsSupported == true {
        pushNotificationStatusText = "Could not sync push notifications: \(error.localizedDescription)"
      } else {
        pushNotificationStatusText = "Update Org2 on the Mac to enable real-time notifications"
      }
    }
  }

  private func reconcileReplyNotifications(
    with nextThreads: [MobileRemoteThreadSummary]
  ) async {
    let baseline = replyNotificationBaseline()
    let hasBaseline = defaults.data(forKey: Self.replyNotificationBaselineKey) != nil
    let nextBaseline = Dictionary(uniqueKeysWithValues: nextThreads.compactMap { thread in
      thread.latestAssistantMessageID.map { (thread.id.uuidString, $0.uuidString) }
    })
    persistReplyNotificationBaseline(nextBaseline)
    guard hasBaseline, threadNotificationsEnabled else { return }

    let settings = await UNUserNotificationCenter.current().notificationSettings()
    guard Self.notificationAuthorizationAllowsAlerts(settings.authorizationStatus) else {
      threadNotificationsUnavailable = true
      return
    }
    threadNotificationsUnavailable = false
    let candidates = nextThreads.filter { thread in
      guard pollingThreadID != thread.id,
            let nextMessageID = thread.latestAssistantMessageID?.uuidString
      else { return false }
      return baseline[thread.id.uuidString] != nextMessageID
    }
    for thread in candidates {
      await scheduleReplyNotification(for: thread)
    }
  }

  private func recordReplyNotificationBaseline(for thread: MobileRemoteThreadSummary) {
    guard let messageID = thread.latestAssistantMessageID else { return }
    var baseline = replyNotificationBaseline()
    baseline[thread.id.uuidString] = messageID.uuidString
    persistReplyNotificationBaseline(baseline)
  }

  private func replyNotificationBaseline() -> [String: String] {
    guard let data = defaults.data(forKey: Self.replyNotificationBaselineKey),
          let baseline = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return baseline
  }

  private func persistReplyNotificationBaseline(_ baseline: [String: String]) {
    guard let data = try? JSONEncoder().encode(baseline) else { return }
    defaults.set(data, forKey: Self.replyNotificationBaselineKey)
  }

  private func scheduleReplyNotification(for thread: MobileRemoteThreadSummary) async {
    guard let messageID = thread.latestAssistantMessageID else { return }
    let content = UNMutableNotificationContent()
    content.title = thread.title
    let runtimeTitle = thread.runtime == "codex" ? "Codex" : "OpenClaw"
    let preview = thread.latestAssistantPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let preview, !preview.isEmpty {
      content.body = preview
    } else {
      content.body = runtimeTitle + " replied."
    }
    content.categoryIdentifier = MobileRemoteNotification.replyCategory
    content.threadIdentifier = thread.id.uuidString
    content.userInfo = [
      "threadID": thread.id.uuidString,
      "messageID": messageID.uuidString
    ]
    // Show a normal banner without adding sound or a badge. `.passive` often
    // deposits the reply directly in Notification Center with no visible cue.
    content.interruptionLevel = .active
    let request = UNNotificationRequest(
      identifier: "org2.thread.reply.\(thread.id.uuidString).\(messageID.uuidString)",
      content: content,
      trigger: nil
    )
    try? await UNUserNotificationCenter.current().add(request)
  }

  func sendTestReplyNotification() async {
    await prepareThreadNotifications()
    guard !threadNotificationsUnavailable else { return }
    await syncPushRegistrationIfNeeded(force: true)
    guard realTimeNotificationsActive else { return }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/push-test",
        payload: MobileRemotePushRegistrationRequest(
          deviceToken: nil,
          environment: nil,
          enabled: true
        ),
        as: MobileRemoteMutationResponse.self
      )
      if !response.accepted {
        pushNotificationStatusText = "The Mac did not accept the test push"
      }
    } catch {
      pushNotificationStatusText = "Test push failed: \(error.localizedDescription)"
    }
  }

  nonisolated private static func notificationAuthorizationAllowsAlerts(
    _ status: UNAuthorizationStatus
  ) -> Bool {
    status == .authorized || status == .provisional || status == .ephemeral
  }

  func createThread(destination: MobileRemoteAIDestination) async -> UUID? {
    guard isConnected else {
      errorMessage = connectionError.map {
        "Reconnect to the Mac before creating a chat. \($0)"
      } ?? "Reconnect to the Mac before creating a chat."
      return nil
    }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads",
        payload: MobileRemoteCreateThreadRequest(
          runtime: destination.runtime,
          destinationID: destination.id
        ),
        as: MobileRemoteMutationResponse.self
      )
      guard let threadID = response.threadID else {
        throw MobileRemoteClientError.malformedResponse
      }
      // The thread detail endpoint can serve this new in-memory thread
      // immediately. Do not hold navigation behind a complete status and
      // thread-list refresh, which can be noticeably slower on a large chat
      // history or a weak Tailscale connection.
      Task { [weak self] in
        await self?.refresh(reportsErrors: false)
      }
      return threadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func refreshExternalThreads() async {
    guard !isRefreshingExternalThreads else { return }
    isRefreshingExternalThreads = true
    defer { isRefreshingExternalThreads = false }
    do {
      let response = try await pairedClient().get(
        "/v1/external-threads",
        timeout: 45,
        as: MobileExternalThreadList.self
      )
      externalThreads = response.threads
      let summariesByID = Dictionary(uniqueKeysWithValues: response.threads.map { ($0.id, $0) })
      externalThreadDetailCache = externalThreadDetailCache.filter { id, detail in
        summariesByID[id]?.updatedAt == detail.thread.updatedAt
      }
      externalThreadDetailCacheOrder.removeAll { externalThreadDetailCache[$0] == nil }
      isConnected = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func loadExternalThread(_ thread: MobileExternalThreadSummary) async {
    let requestID = UUID()
    externalThreadLoadRequestID = requestID
    if let cached = externalThreadDetailCache[thread.id] {
      externalThreadDetail = cached
      touchExternalThreadDetailCache(thread.id)
      isLoadingExternalThread = false
      return
    }
    isLoadingExternalThread = true
    externalThreadDetail = nil
    defer {
      if externalThreadLoadRequestID == requestID {
        externalThreadLoadRequestID = nil
        isLoadingExternalThread = false
      }
    }
    do {
      let detail = try await pairedClient().get(
        externalThreadPath(thread),
        timeout: 60,
        as: MobileExternalThreadDetail.self
      )
      guard externalThreadLoadRequestID == requestID else { return }
      externalThreadDetail = detail
      externalThreadDetailCache[thread.id] = detail
      touchExternalThreadDetailCache(thread.id)
      while externalThreadDetailCacheOrder.count > Self.externalThreadDetailCacheLimit {
        externalThreadDetailCache.removeValue(forKey: externalThreadDetailCacheOrder.removeFirst())
      }
    } catch {
      if externalThreadLoadRequestID == requestID {
        errorMessage = error.localizedDescription
      }
    }
  }

  func clearExternalThreadDetail() {
    externalThreadLoadRequestID = nil
    isLoadingExternalThread = false
    externalThreadDetail = nil
  }

  private func touchExternalThreadDetailCache(_ id: String) {
    externalThreadDetailCacheOrder.removeAll { $0 == id }
    externalThreadDetailCacheOrder.append(id)
  }

  func continueExternalThread(_ thread: MobileExternalThreadSummary) async -> UUID? {
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        externalThreadPath(thread) + "/continue",
        payload: EmptyPayload(),
        timeout: 30,
        as: MobileRemoteMutationResponse.self
      )
      await refresh()
      return response.threadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func forkThread(_ threadID: UUID) async -> UUID? {
    guard !mutatingThreadIDs.contains(threadID) else { return nil }
    mutatingThreadIDs.insert(threadID)
    defer { mutatingThreadIDs.remove(threadID) }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/fork",
        payload: EmptyPayload(),
        as: MobileRemoteMutationResponse.self
      )
      await refresh()
      return response.threadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func externalThreadPath(_ thread: MobileExternalThreadSummary) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    let externalID = thread.externalID.addingPercentEncoding(withAllowedCharacters: allowed)
      ?? thread.externalID
    return "/v1/external-threads/\(thread.harness.rawValue)/\(externalID)"
  }

  @discardableResult
  func beginPolling(threadID: UUID) -> UUID {
    pollingTask?.cancel()
    let leaseID = UUID()
    if pollingThreadID != threadID {
      threadDetail = threadDetailCache[threadID]
      threadConfiguration = nil
      threadConnectionError = nil
      configurationError = nil
    }
    pollingThreadID = threadID
    pollingLeaseID = leaseID
    loadingThreadID = threadDetail?.thread.id == threadID ? nil : threadID
    Task { [weak self] in
      await self?.refreshThreadConfiguration(threadID, pollingLeaseID: leaseID)
    }
    pollingTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.refreshThread(threadID, pollingLeaseID: leaseID)
        guard self.pollingLeaseID == leaseID else { return }
        let isActivelyChanging = self.threadDetail?.thread.id == threadID
          && (self.threadDetail?.thread.isRunning == true
            || self.threadDetail?.streamingReply.isEmpty == false)
        try? await Task.sleep(for: .seconds(isActivelyChanging ? 1 : 4))
      }
    }
    return leaseID
  }

  func endPolling(threadID: UUID, leaseID: UUID) {
    guard pollingThreadID == threadID, pollingLeaseID == leaseID else { return }
    pollingTask?.cancel()
    pollingTask = nil
    pollingThreadID = nil
    pollingLeaseID = nil
    if loadingThreadID == threadID {
      loadingThreadID = nil
    }
    if threadDetail?.thread.id == threadID {
      threadDetail = nil
    }
    if threadConfiguration?.threadID == threadID {
      threadConfiguration = nil
    }
  }

  func send(
    _ rawMessage: String,
    attachments: [MobileRemoteAttachment],
    threadID: UUID,
    delivery: String? = nil
  ) async -> UUID? {
    let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty || !attachments.isEmpty else { return nil }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/messages",
        payload: MobileRemoteSendMessageRequest(
          content: message,
          attachments: attachments,
          delivery: delivery
        ),
        timeout: attachments.isEmpty ? 15 : 45,
        as: MobileRemoteMutationResponse.self
      )
      let destinationThreadID = response.threadID ?? threadID
      if destinationThreadID == threadID {
        await refreshThread(threadID)
      } else {
        await refresh()
      }
      return destinationThreadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func filePreview(path: String, line: Int?) async throws -> MobileRemoteFilePreview {
    try await pairedClient().post(
      "/v1/files/preview",
      payload: MobileRemoteFilePreviewRequest(path: path, line: line),
      timeout: 60,
      as: MobileRemoteFilePreview.self
    )
  }

  func setModel(_ model: String?, threadID: UUID) async {
    await updateThreadConfiguration(
      MobileRemoteUpdateThreadConfigurationRequest(model: model),
      threadID: threadID
    )
  }

  func setReasoningEffort(_ effort: String?, threadID: UUID) async {
    await updateThreadConfiguration(
      MobileRemoteUpdateThreadConfigurationRequest(reasoningEffort: effort),
      threadID: threadID
    )
  }

  private func updateThreadConfiguration(
    _ request: MobileRemoteUpdateThreadConfigurationRequest,
    threadID: UUID
  ) async {
    guard !isUpdatingConfiguration else { return }
    isUpdatingConfiguration = true
    defer { isUpdatingConfiguration = false }
    do {
      let configuration: MobileRemoteThreadConfiguration = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/configuration",
        payload: request,
        as: MobileRemoteThreadConfiguration.self
      )
      guard pollingThreadID == threadID else { return }
      threadConfiguration = configuration
      configurationError = nil
      await refreshThread(threadID)
    } catch {
      configurationError = error.localizedDescription
      errorMessage = error.localizedDescription
    }
  }

  func setPinned(_ isPinned: Bool, threadID: UUID) async {
    await updateThreadState(
      MobileRemoteUpdateThreadStateRequest(isPinned: isPinned, isSettled: nil),
      threadID: threadID
    )
  }

  func setSettled(_ isSettled: Bool, threadID: UUID) async {
    await updateThreadState(
      MobileRemoteUpdateThreadStateRequest(isPinned: nil, isSettled: isSettled),
      threadID: threadID
    )
  }

  func stop(threadID: UUID) async {
    do {
      let _: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/stop",
        payload: EmptyPayload(),
        as: MobileRemoteMutationResponse.self
      )
      await refreshThread(threadID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func refreshThread(_ threadID: UUID, pollingLeaseID expectedLeaseID: UUID? = nil) async {
    do {
      let detail = try await pairedClient().get(
        "/v1/threads/\(threadID.uuidString)",
        as: MobileRemoteThreadDetail.self
      )
      guard pollingThreadID == threadID,
            expectedLeaseID == nil || pollingLeaseID == expectedLeaseID
      else { return }
      recordReplyNotificationBaseline(for: detail.thread)
      cacheThreadDetail(detail)
      if threadDetail != detail {
        threadDetail = detail
      }
      loadingThreadID = nil
      isConnected = true
      threadConnectionError = nil
      if let index = threads.firstIndex(where: { $0.id == threadID }) {
        threads[index] = detail.thread
      }
    } catch {
      if !Task.isCancelled,
         pollingThreadID == threadID,
         expectedLeaseID == nil || pollingLeaseID == expectedLeaseID {
        loadingThreadID = nil
        isConnected = false
        threadConnectionError = error.localizedDescription
      }
    }
  }

  private func refreshThreadConfiguration(
    _ threadID: UUID,
    pollingLeaseID expectedLeaseID: UUID? = nil
  ) async {
    let requestID = UUID()
    configurationRequestID = requestID
    isRefreshingConfiguration = true
    defer {
      if configurationRequestID == requestID {
        isRefreshingConfiguration = false
      }
    }
    do {
      let configuration = try await pairedClient().get(
        "/v1/threads/\(threadID.uuidString)/configuration",
        as: MobileRemoteThreadConfiguration.self
      )
      guard pollingThreadID == threadID,
            expectedLeaseID == nil || pollingLeaseID == expectedLeaseID
      else { return }
      threadConfiguration = configuration
      configurationError = nil
    } catch {
      guard !Task.isCancelled,
            pollingThreadID == threadID,
            expectedLeaseID == nil || pollingLeaseID == expectedLeaseID
      else { return }
      configurationError = error.localizedDescription
    }
  }

  private func updateThreadState(
    _ request: MobileRemoteUpdateThreadStateRequest,
    threadID: UUID
  ) async {
    guard !mutatingThreadIDs.contains(threadID) else { return }
    mutatingThreadIDs.insert(threadID)
    defer { mutatingThreadIDs.remove(threadID) }
    do {
      let summary: MobileRemoteThreadSummary = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/state",
        payload: request,
        as: MobileRemoteThreadSummary.self
      )
      apply(summary)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func apply(_ summary: MobileRemoteThreadSummary) {
    if let index = threads.firstIndex(where: { $0.id == summary.id }) {
      threads[index] = summary
    } else {
      threads.append(summary)
    }
    threads.sort {
      if $0.isSettled != $1.isSettled { return !$0.isSettled }
      if $0.isPinned != $1.isPinned { return $0.isPinned }
      return $0.updatedAt > $1.updatedAt
    }
    if let detail = threadDetailCache[summary.id] {
      let updatedDetail = MobileRemoteThreadDetail(
        thread: summary,
        messages: detail.messages,
        activeDestinationName: detail.activeDestinationName,
        streamingReply: detail.streamingReply,
        reasoning: detail.reasoning,
        activities: detail.activities,
        connectionState: detail.connectionState,
        connectionDetail: detail.connectionDetail
      )
      cacheThreadDetail(updatedDetail)
      if threadDetail?.thread.id == summary.id {
        threadDetail = updatedDetail
      }
    }
  }

  private func cacheThreadDetail(_ detail: MobileRemoteThreadDetail) {
    let id = detail.thread.id
    threadDetailCache[id] = detail
    threadDetailCacheOrder.removeAll { $0 == id }
    threadDetailCacheOrder.append(id)
    while threadDetailCacheOrder.count > Self.threadDetailCacheLimit {
      let evictedID = threadDetailCacheOrder.removeFirst()
      threadDetailCache.removeValue(forKey: evictedID)
    }
  }

  private func pruneThreadDetailCache(keeping threadIDs: Set<UUID>) {
    threadDetailCache = threadDetailCache.filter { threadIDs.contains($0.key) }
    threadDetailCacheOrder.removeAll { !threadIDs.contains($0) }
  }

  private func pairedClient() throws -> MobileRemoteClient {
    guard let accessToken else { throw MobileRemoteClientError.server("Pair this phone with the Mac again.") }
    return try MobileRemoteClient(endpoint: endpointDraft, accessToken: accessToken)
  }

  var pairedEndpoint: String {
    endpointDraft
  }

  private static func saveToken(_ token: String) throws {
    let data = Data(token.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: tokenService,
      kSecAttrAccount as String: tokenAccount
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var addition = query
      attributes.forEach { addition[$0.key] = $0.value }
      let added = SecItemAdd(addition as CFDictionary, nil)
      guard added == errSecSuccess else { throw MobileRemoteKeychainError.status(added) }
    } else if status != errSecSuccess {
      throw MobileRemoteKeychainError.status(status)
    }
  }

  private static func loadToken() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: tokenService,
      kSecAttrAccount as String: tokenAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private static func deleteToken() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: tokenService,
      kSecAttrAccount as String: tokenAccount
    ]
    SecItemDelete(query as CFDictionary)
  }
}

private struct EmptyPayload: Encodable {}

private enum MobileRemoteKeychainError: LocalizedError {
  case status(OSStatus)

  var errorDescription: String? {
    switch self {
    case .status(let status):
      "Could not store the pairing credential in Keychain (\(status))."
    }
  }
}
