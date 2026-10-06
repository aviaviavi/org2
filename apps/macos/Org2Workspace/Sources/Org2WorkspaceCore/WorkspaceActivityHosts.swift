import Foundation
import SwiftUI

/// One OpenOrg host or remote agent harness in Activity's Hosts section: the
/// local Mac, headless servers and other desktops sharing the corpus, and
/// SSH/endpoint harnesses that execute turns elsewhere.
public struct WorkspaceActivityHost: Identifiable, Equatable, Sendable {
  public enum Kind: String, Sendable {
    case desktop
    case server
    case harness
  }

  public enum State: String, Sendable {
    case online
    case reconnecting
    case authenticationNeeded = "authentication-needed"
    case stale
    case offline
    /// A harness is reached on demand; there is no presence to report.
    case onDemand = "on-demand"

    public var label: String {
      switch self {
      case .online: "Online"
      case .reconnecting: "Reconnecting"
      case .authenticationNeeded: "Sign-in needed"
      case .stale: "Stale"
      case .offline: "Offline"
      case .onDemand: "On demand"
      }
    }

    /// Whether the host's reported work is current rather than last-known.
    public var isLive: Bool { self == .online || self == .authenticationNeeded }
  }

  public struct Turn: Identifiable, Equatable, Sendable {
    public let threadID: UUID
    public let title: String
    public let destination: String?
    public let activity: String?
    public var id: UUID { threadID }
  }

  public let id: String
  public let name: String
  public let kind: Kind
  public let state: State
  public let stateReason: String
  public let lastSeen: Date?
  public let isThisMac: Bool
  public let isAutomationHost: Bool
  /// Where turns for this host execute ("This Mac", "press over SSH").
  public let executionLocation: String
  public let turns: [Turn]
  public let needsYouCount: Int
  /// Online hosts that share one of this host's destinations and could take
  /// over its conversations.
  public let failoverHostNames: [String]
  public let authenticationNeededDestinations: [String]

  /// Disconnected hosts show their last-known work dimmed.
  public var isCached: Bool { !state.isLive && state != .onDemand }
}

public enum WorkspaceActivityHostPolicy {
  /// Matches `AIChatLiveHostRecord` freshness and `org2 activity hosts`.
  public static let freshness: TimeInterval = 150
  public static let staleAfter: TimeInterval = 15 * 60

  public static func classify(
    isOnline: Bool,
    updatedAt: Date,
    authenticationNeeded: Bool,
    now: Date
  ) -> (WorkspaceActivityHost.State, String) {
    let age = max(0, now.timeIntervalSince(updatedAt))
    if !isOnline { return (.offline, "Signed off \(relative(age))") }
    if updatedAt > now.addingTimeInterval(300) { return (.stale, "Presence timestamp is in the future; clocks disagree") }
    if age <= freshness {
      return authenticationNeeded
        ? (.authenticationNeeded, "Online, but a destination needs sign-in")
        : (.online, "Heartbeat \(relative(age))")
    }
    if age <= staleAfter { return (.reconnecting, "Missed heartbeats; last seen \(relative(age))") }
    return (.stale, "No heartbeat since \(relative(age)); asleep, stopped, or not syncing")
  }

  static func relative(_ seconds: TimeInterval) -> String {
    let value = Int(seconds.rounded())
    if value < 60 { return "\(value)s ago" }
    if value < 3600 { return "\(value / 60) min ago" }
    if value < 48 * 3600 { return "\(value / 3600) h ago" }
    return "\(value / 86_400) d ago"
  }

  /// Whether a stored delivery failure is an authentication problem rather
  /// than a transient or content error.
  public static func isAuthenticationFailure(_ text: String) -> Bool {
    let normalized = text.lowercased()
    return [
      "401", "unauthorized", "not signed in", "not logged in", "sign in again", "signing in again",
      "log in again", "re-authenticate", "reauthenticate", "token refresh failed", "invalid api key",
      "authentication failed", "authentication required", "login required", "expired token", "token expired",
    ].contains { normalized.contains($0) }
  }
}

extension WorkspaceStore {
  /// Destinations whose most recent delivery on this host failed because
  /// the runtime needs sign-in. Published in this host's presence record.
  func aiChatAuthenticationNeededDestinationIDs() -> [String] {
    var latestByDestination: [String: (date: Date, failed: Bool)] = [:]
    let here = aiChatHostIdentity.ref
    for thread in aiChatThreads where !thread.isArchived {
      guard let message = thread.messages.last(where: { $0.role == .user || $0.role == .assistant }) else { continue }
      if let executionRef = message.provenance?.executionHostRef, executionRef != here { continue }
      let failed = message.deliveryStatus == .failed
        && WorkspaceActivityHostPolicy.isAuthenticationFailure(message.sendFailure ?? "")
      let destination = thread.destinationID
      if let existing = latestByDestination[destination], existing.date >= message.createdAt { continue }
      latestByDestination[destination] = (message.createdAt, failed)
    }
    let enabled = Set(enabledAIChatDestinations.map(\.id))
    return latestByDestination.filter { $0.value.failed && enabled.contains($0.key) }.map(\.key).sorted()
  }

  /// Reads the corpus scheduler owner from `org2.json`.
  func refreshCorpusAutomationHostRef() {
    guard let corpusRoot else {
      corpusAutomationHostRef = nil
      return
    }
    let url = corpusRoot.appendingPathComponent("org2.json")
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      corpusAutomationHostRef = "desktop"
      return
    }
    corpusAutomationHostRef = (object["automationHostRef"] as? String) ?? "desktop"
  }

  private func activityHostMatchesAutomation(ref: String, kind: AIChatHostIdentity.Kind) -> Bool {
    let owner = corpusAutomationHostRef ?? automationHostRef
    return owner == ref || (owner == "desktop" && kind == .desktop)
  }

  /// Every host that runs or recently ran work for this corpus, live hosts first.
  public func activityHosts(now: Date = Date()) -> [WorkspaceActivityHost] {
    let threadsByID = Dictionary(aiChatThreads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var needsYouByHost: [String: Int] = [:]
    for thread in aiChatThreads where !thread.isArchived && thread.latestDeliveryNeedsAttention {
      let ref = aiChatExecutionHostRef(for: thread.messages) ?? aiChatHostIdentity.ref
      needsYouByHost[ref, default: 0] += 1
    }
    func title(_ id: UUID) -> String { threadsByID[id]?.title ?? "Chat" }

    // Newest record per host reference.
    var remote: [String: AIChatLiveHostRecord] = [:]
    for record in aiChatRemoteLiveHosts where record.hostRef != aiChatHostIdentity.ref {
      if let existing = remote[record.hostRef], existing.updatedAt >= record.updatedAt { continue }
      remote[record.hostRef] = record
    }
    let liveRemote = remote.values.filter { $0.isRoutable(now: now, within: WorkspaceActivityHostPolicy.freshness) }
    let localDestinations = enabledAIChatDestinations.map(\.id)
    func failover(for destinations: [String], excluding ref: String) -> [String] {
      var names: [String] = []
      if ref != aiChatHostIdentity.ref, destinations.contains(where: localDestinations.contains) {
        names.append(aiChatHostIdentity.name)
      }
      for record in liveRemote where record.hostRef != ref
        && destinations.contains(where: record.enabledDestinationIDs.contains) {
        names.append(record.hostName)
      }
      return names.sorted()
    }

    var hosts: [WorkspaceActivityHost] = []
    // This Mac.
    let localTurns = aiChatThreads.filter { isAIChatThreadRunningOnCurrentHost($0.id) }.map { thread in
      WorkspaceActivityHost.Turn(
        threadID: thread.id,
        title: thread.title,
        destination: aiChatActiveDestinationID(for: thread.id).map(aiChatDestinationTitle),
        activity: aiChatRunActivities(for: thread.id).last?.title
      )
    }
    let localAuth = aiChatAuthenticationNeededDestinationIDs()
    hosts.append(WorkspaceActivityHost(
      id: aiChatHostIdentity.ref,
      name: aiChatHostIdentity.name,
      kind: aiChatHostIdentity.kind == .server ? .server : .desktop,
      state: localAuth.isEmpty ? .online : .authenticationNeeded,
      stateReason: isAIChatDraining
        ? "This Mac is finishing running turns before quitting"
        : localAuth.isEmpty
          ? (aiChatPreferredExecutionHostRef.map { "This Mac; new turns run on \(remote[$0]?.hostName ?? $0)" } ?? "This Mac")
          : "This Mac; a destination needs sign-in",
      lastSeen: now,
      isThisMac: true,
      isAutomationHost: activityHostMatchesAutomation(ref: aiChatHostIdentity.ref, kind: aiChatHostIdentity.kind),
      executionLocation: "This Mac",
      turns: localTurns,
      needsYouCount: needsYouByHost[aiChatHostIdentity.ref] ?? 0,
      failoverHostNames: failover(for: localDestinations, excluding: aiChatHostIdentity.ref),
      authenticationNeededDestinations: localAuth.map(aiChatDestinationTitle)
    ))

    // Other desktops and headless servers sharing the corpus.
    let pairing = openOrgServer.pairing
    for record in remote.values {
      let auth = record.authenticationNeededDestinationIDs ?? []
      var (state, reason) = WorkspaceActivityHostPolicy.classify(
        isOnline: record.isOnline,
        updatedAt: record.updatedAt,
        authenticationNeeded: !auth.isEmpty,
        now: now
      )
      if record.isDraining == true, state.isLive {
        reason = "Restarting: finishing \(record.turns.count) running turn\(record.turns.count == 1 ? "" : "s"); new turns go to other hosts"
      }
      // The paired server's API refusing this Mac's credential means the
      // pairing needs to be renewed, even while presence is fresh.
      if let pairing, pairing.hostRef == record.hostRef, case .offline(let detail) = openOrgServer.reachability,
         WorkspaceActivityHostPolicy.isAuthenticationFailure(detail) {
        state = .authenticationNeeded
        reason = "Pairing credential was rejected; pair this Mac again in Settings → Sharing"
      }
      hosts.append(WorkspaceActivityHost(
        id: record.hostRef,
        name: record.hostName,
        kind: record.hostKind == .server ? .server : .desktop,
        state: state,
        stateReason: reason,
        lastSeen: record.updatedAt,
        isThisMac: false,
        isAutomationHost: activityHostMatchesAutomation(ref: record.hostRef, kind: record.hostKind),
        executionLocation: record.hostKind == .server ? "Headless server" : "Another Mac",
        turns: (record.isOnline ? record.turns : []).map { turn in
          WorkspaceActivityHost.Turn(
            threadID: turn.threadID,
            title: title(turn.threadID),
            destination: turn.destinationName,
            activity: turn.activities.last?.title ?? turn.statusText
          )
        },
        needsYouCount: needsYouByHost[record.hostRef] ?? 0,
        failoverHostNames: failover(for: record.enabledDestinationIDs, excluding: record.hostRef),
        authenticationNeededDestinations: auth.map(aiChatDestinationTitle)
      ))
    }

    // A paired server without a presence record yet.
    if let pairing, !hosts.contains(where: { $0.id == pairing.hostRef && pairing.hostRef != nil }) {
      let state: WorkspaceActivityHost.State
      let reason: String
      switch openOrgServer.reachability {
      case .online: (state, reason) = (.online, "Reachable; no presence record has synced yet")
      case .checking, .unknown: (state, reason) = (.reconnecting, "Checking the paired server")
      case .offline(let detail):
        (state, reason) = WorkspaceActivityHostPolicy.isAuthenticationFailure(detail)
          ? (.authenticationNeeded, "Pairing credential was rejected; pair again in Settings → Sharing")
          : (.stale, detail)
      }
      hosts.append(WorkspaceActivityHost(
        id: pairing.hostRef ?? "paired-server",
        name: openOrgServer.serverName,
        kind: .server,
        state: state,
        stateReason: reason,
        lastSeen: nil,
        isThisMac: false,
        isAutomationHost: pairing.hostRef.map { activityHostMatchesAutomation(ref: $0, kind: .server) } ?? false,
        executionLocation: "Headless server",
        turns: [],
        needsYouCount: 0,
        failoverHostNames: [],
        authenticationNeededDestinations: []
      ))
    }

    // Remote harnesses reached over SSH or an endpoint.
    var harnessTurns: [String: [WorkspaceActivityHost.Turn]] = [:]
    for thread in aiChatThreads where isAIChatThreadRunning(thread.id) {
      let destinationID = aiChatRemoteLiveTurn(for: thread.id)?.turn.destinationID ?? aiChatActiveDestinationID(for: thread.id)
      guard let destinationID else { continue }
      harnessTurns[destinationID, default: []].append(WorkspaceActivityHost.Turn(
        threadID: thread.id,
        title: thread.title,
        destination: aiChatDestinationTitle(destinationID),
        activity: aiChatRunActivities(for: thread.id).last?.title
      ))
    }
    for destination in enabledAIChatDestinations {
      guard let harnessHost = destination.harnessHostName else { continue }
      let turns = harnessTurns[destination.id] ?? []
      hosts.append(WorkspaceActivityHost(
        id: "harness:\(destination.id)",
        name: "\(destination.title) on \(harnessHost)",
        kind: .harness,
        state: turns.isEmpty ? .onDemand : .online,
        stateReason: turns.isEmpty ? "Reached when a turn starts" : "Running \(turns.count) turn\(turns.count == 1 ? "" : "s")",
        lastSeen: nil,
        isThisMac: false,
        isAutomationHost: false,
        executionLocation: "\(harnessHost) via \(destination.adapter.title)",
        turns: turns,
        needsYouCount: 0,
        failoverHostNames: [],
        authenticationNeededDestinations: []
      ))
    }

    let rank: (WorkspaceActivityHost) -> Int = { host in
      if host.isThisMac { return 0 }
      switch host.state {
      case .online, .authenticationNeeded: return 1
      case .reconnecting: return 2
      case .onDemand: return 3
      case .stale: return 4
      case .offline: return 5
      }
    }
    return hosts.sorted { lhs, rhs in
      rank(lhs) != rank(rhs) ? rank(lhs) < rank(rhs) : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }
}

// MARK: - View

struct ActivityHostsSection: View {
  @Environment(WorkspaceStore.self) private var store
  let hosts: [WorkspaceActivityHost]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(hosts) { host in
        ActivityHostRow(host: host)
      }
    }
  }
}

private struct ActivityHostRow: View {
  @Environment(WorkspaceStore.self) private var store
  let host: WorkspaceActivityHost

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: icon)
          .foregroundStyle(.secondary)
          .frame(width: 18)
        Text(host.name)
          .font(.body.weight(.medium))
          .lineLimit(1)
        if host.isThisMac {
          tag("This Mac")
        }
        if host.isAutomationHost {
          tag("Automations")
            .help("This host owns the corpus's scheduled automations")
        }
        Spacer(minLength: 8)
        stateBadge
      }
      HStack(spacing: 6) {
        Text(host.executionLocation)
        if !host.turns.isEmpty {
          Text("·")
          Text("\(host.turns.count) active\(host.isCached ? " (last known)" : "")")
        }
        if host.needsYouCount > 0 {
          Text("·")
          Text("\(host.needsYouCount) need\(host.needsYouCount == 1 ? "s" : "") you")
            .foregroundStyle(.orange)
        }
        if let lastSeen = host.lastSeen, !host.isThisMac {
          Text("·")
          Text("seen ") + Text(lastSeen, style: .relative) + Text(" ago")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.leading, 26)
      .lineLimit(1)
      HStack(spacing: 6) {
        Text(host.stateReason)
        if !host.authenticationNeededDestinations.isEmpty {
          Text("· Sign in: \(host.authenticationNeededDestinations.joined(separator: ", "))")
            .foregroundStyle(.orange)
        }
        if host.kind != .harness {
          Text("·")
          Text(host.failoverHostNames.isEmpty ? "No failover" : "Failover: \(host.failoverHostNames.joined(separator: ", "))")
            .help(host.failoverHostNames.isEmpty
              ? "No other online host has this host's destinations enabled"
              : "If this host goes away, these online hosts can continue its conversations")
        }
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .padding(.leading, 26)
      .lineLimit(1)
      ForEach(host.turns.prefix(4)) { turn in
        Button {
          store.openHeadingWork(threadID: turn.threadID, runID: nil)
        } label: {
          HStack(spacing: 6) {
            if host.isCached {
              Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
            } else {
              CoreAnimationActivityDot(animates: true)
                .frame(width: 6, height: 6)
            }
            Text(turn.title)
              .lineLimit(1)
            if let detail = turn.activity ?? turn.destination {
              Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .font(.caption)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 26)
        .help(host.isCached ? "Last reported before \(host.name) disconnected; may no longer be running" : "Open this conversation")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
        .fill(WorkspaceDesign.panelFill)
    )
    .opacity(host.isCached ? 0.6 : 1)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(host.name), \(host.state.label)")
  }

  private var icon: String {
    switch host.kind {
    case .desktop: "laptopcomputer"
    case .server: "server.rack"
    case .harness: "terminal"
    }
  }

  private func tag(_ text: String) -> some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(WorkspaceDesign.subtleFill, in: Capsule())
  }

  private var stateBadge: some View {
    let tint: Color = switch host.state {
    case .online: .green
    case .authenticationNeeded: .orange
    case .reconnecting: .yellow
    case .stale, .offline: .secondary
    case .onDemand: .secondary
    }
    return HStack(spacing: 4) {
      Circle().fill(tint).frame(width: 6, height: 6)
      Text(host.state.label)
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(tint)
    .padding(.horizontal, 7)
    .padding(.vertical, 2)
    .background(tint.opacity(0.12), in: Capsule())
    .help(host.stateReason)
  }
}
