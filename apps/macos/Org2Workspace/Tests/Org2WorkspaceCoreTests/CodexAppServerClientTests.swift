import Darwin
import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class CodexAppServerClientTests: XCTestCase {
  func testLegacyChatThreadDefaultsToOpenClawRuntime() throws {
    let id = UUID()
    let json = """
    {
      "id": "\(id.uuidString)",
      "title": "Legacy",
      "createdAt": 0,
      "updatedAt": 0,
      "sessionKey": "agent:main:org2-workspace:legacy",
      "messages": []
    }
    """

    let thread = try JSONDecoder().decode(
      OpenClawChatThread.self,
      from: Data(json.utf8)
    )

    XCTAssertEqual(thread.runtime, .openClaw)
    XCTAssertNil(thread.runtimeThreadID)
    XCTAssertNil(thread.model)
    XCTAssertNil(thread.reasoningEffort)
  }

  func testCodexChatThreadRuntimeRoundTrips() throws {
    let thread = OpenClawChatThread(
      title: "Local Codex",
      runtime: .codex,
      sessionKey: "unused-for-codex",
      runtimeThreadID: "thr_codex",
      model: "gpt-test",
      reasoningEffort: "high"
    )

    let data = try JSONEncoder().encode(thread)
    let restored = try JSONDecoder().decode(OpenClawChatThread.self, from: data)

    XCTAssertEqual(restored.runtime, .codex)
    XCTAssertEqual(restored.runtimeThreadID, "thr_codex")
    XCTAssertEqual(restored.model, "gpt-test")
    XCTAssertEqual(restored.reasoningEffort, "high")
  }

  func testChatRuntimeLocksAfterFirstMessage() {
    let thread = OpenClawChatThread(
      title: "Runtime picker",
      runtime: .openClaw,
      sessionKey: "agent:main:runtime-picker"
    )

    XCTAssertTrue(thread.canChangeAIRuntime)
    XCTAssertFalse(
      thread.replacingMessages([
        OpenClawChatMessage(role: .user, content: "Hello")
      ]).canChangeAIRuntime
    )
  }

  func testReplacingThreadMessagesPreservesNamedDestinationRouting() {
    let destinationID = "managed-remote-codex"
    let thread = OpenClawChatThread(
      title: "Remote Codex",
      runtime: .codex,
      destinationID: destinationID,
      sessionKey: "unused-for-codex",
      runtimeThreadID: "thr-remote",
      runtimeThreadIDsByDestination: [destinationID: "thr-remote"],
      model: "gpt-remote",
      messages: [OpenClawChatMessage(role: .user, content: "Work remotely")]
    )
    let messages = thread.messages + [
      OpenClawChatMessage(role: .assistant, content: "Remote work completed")
    ]

    let updated = WorkspaceStore.updatedOpenClawChatThread(
      thread,
      messages: messages,
      newAssistantMessageCount: 1,
      isThreadOpen: true,
      pendingTurnUpdate: .preserve
    )

    XCTAssertEqual(updated.destinationID, destinationID)
    XCTAssertEqual(updated.runtimeThreadID, "thr-remote")
    XCTAssertEqual(updated.runtimeThreadIDsByDestination, [destinationID: "thr-remote"])
    XCTAssertEqual(updated.model, "gpt-remote")
    XCTAssertEqual(updated.messages, messages)
  }

  func testRepairsThreadsWhoseNamedRemoteDestinationWasResetToLocal() {
    let destination = AIChatDestinationConfiguration(
      id: "managed-remote-codex",
      name: "Remote Codex",
      mention: "codex-remote",
      adapter: .codexManagedRemote,
      endpoint: "remote-mac"
    )
    let damagedThread = OpenClawChatThread(
      title: "Remote work",
      runtime: .codex,
      destinationID: AIChatDestinationConfiguration.localCodexID,
      sessionKey: "unused-for-codex",
      runtimeThreadID: "thr-remote",
      messages: [
        OpenClawChatMessage(
          role: .user,
          content: "Run this remotely",
          targetRuntime: .codex,
          targetDestinationID: destination.id
        ),
        OpenClawChatMessage(role: .assistant, content: "Done remotely")
      ]
    )

    XCTAssertEqual(
      WorkspaceStore.recoveredNamedCodexDestinationID(
        for: damagedThread,
        destinations: AIChatDestinationConfiguration.defaults + [destination]
      ),
      destination.id
    )
  }

  func testCodexStreamingTextPreservesAgentMessageBoundaries() {
    var text = CodexStreamingText.appending(
      "I’ll inspect the current delivery model.",
      itemID: "commentary-1",
      after: nil,
      to: ""
    )
    text = CodexStreamingText.appending(
      " I found the relevant package.",
      itemID: "commentary-1",
      after: "commentary-1",
      to: text
    )
    text = CodexStreamingText.appending(
      "The implementation is now taking shape.",
      itemID: "commentary-2",
      after: "commentary-1",
      to: text
    )

    XCTAssertEqual(
      text,
      "I’ll inspect the current delivery model. I found the relevant package.\n\n"
        + "The implementation is now taking shape."
    )
  }

  func testCodexWorkspaceSnapshotIncludesUnsavedSelectedSource() {
    let context = OpenClawWorkspaceContext(
      localCorpusRoot: "/tmp/example-corpus",
      remoteCorpusRoot: nil,
      selectedSurface: "Files",
      selectedLocation: nil,
      selectedEntrySource: EntrySource(
        file: "/tmp/example-corpus/notes/draft.org2",
        startLine: 1,
        endLineExclusive: 3,
        text: "* Draft\nUnsaved editor text",
        isSubtree: false
      ),
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )

    let snapshot = context.codexSystemPrompt()

    XCTAssertTrue(snapshot.contains("may include unsaved editor changes"))
    XCTAssertTrue(snapshot.contains("notes/draft.org2"))
    XCTAssertTrue(snapshot.contains("Unsaved editor text"))
  }

  func testWorkspacePromptsDistinguishRuntimeFromPortableAgentIdentity() {
    let context = OpenClawWorkspaceContext(
      localCorpusRoot: "/tmp/example-corpus",
      remoteCorpusRoot: "/srv/example-corpus",
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: EntrySource(
        file: "/tmp/example-corpus/notes/support.org2",
        startLine: 4,
        endLineExclusive: 10,
        text: """
        * TODO Resolve customer issue
        :PROPERTIES:
        :AGENT_REF: scarf-support
        :GOAL_REF: customer-trust
        :END:
        """,
        isSubtree: true
      ),
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )

    let openClaw = context.systemPrompt(runtime: "openclaw", runtimeAgentID: "scarf-support")
    XCTAssertTrue(openClaw.contains("Execution runtime: openclaw"))
    XCTAssertTrue(openClaw.contains("Runtime agent ID: scarf-support"))
    XCTAssertTrue(openClaw.contains("ORG2_SELECTED_AGENT_REF: scarf-support"))
    XCTAssertTrue(openClaw.contains("ORG2_SELECTED_GOAL_REF: customer-trust"))
    XCTAssertTrue(openClaw.contains("org2 agent-profile resolve --runtime openclaw --runtime-agent-id scarf-support --dir /srv/example-corpus --json"))
    XCTAssertTrue(openClaw.contains("Never use =openclaw=, =codex=, =claude=, a model name, or a session ID as =AGENT_REF:="))

    let codex = context.codexSystemPrompt()
    XCTAssertTrue(codex.contains("Execution runtime: codex"))
    XCTAssertTrue(codex.contains("org2 agent-profile resolve --runtime codex --runtime-agent-id default --dir /tmp/example-corpus --json"))

    let claude = context.localAgentSystemPrompt(runtime: "claude", runtimeTitle: "Claude Code")
    XCTAssertTrue(claude.contains("Execution runtime: claude"))
    XCTAssertTrue(claude.contains("running locally through the installed Claude Code CLI"))
    XCTAssertFalse(claude.contains("Use the client-provided Org2 workspace tools for any other corpus reads or writes."))
  }

  func testWorkspaceSnapshotIncludesAuthorizedCorporaAndCustomInstructions() {
    let context = OpenClawWorkspaceContext(
      localCorpusRoot: "/tmp/personal",
      remoteCorpusRoot: "/srv/personal",
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: [],
      authorizedCorpora: [
        AIChatCorpusContext(
          name: "Personal",
          kind: "personal",
          localRoot: "/tmp/personal",
          remoteRoot: "/srv/personal",
          isActive: true
        ),
        AIChatCorpusContext(
          name: "Team",
          kind: "shared",
          localRoot: "/tmp/team",
          remoteRoot: "/srv/team",
          isActive: false
        )
      ],
      customInstructions: "Prefer concise answers and surface open TODOs."
    )

    for prompt in [context.systemPrompt(), context.codexSystemPrompt()] {
      XCTAssertTrue(prompt.contains("Authorized Org2 corpora"))
      XCTAssertTrue(prompt.contains("Personal (active; reads and reviewed writes; kind: personal)"))
      XCTAssertTrue(prompt.contains("Team (additional; read-only; kind: shared)"))
      XCTAssertTrue(prompt.contains("/tmp/team"))
      XCTAssertTrue(prompt.contains("/srv/team"))
      XCTAssertTrue(prompt.contains("User-configured AI chat instructions"))
      XCTAssertTrue(prompt.contains("Prefer concise answers and surface open TODOs."))
      XCTAssertTrue(prompt.contains("Org2 response formatting contract"))
      XCTAssertTrue(prompt.contains("Inline emphasis does not nest in Org2 v0."))
      XCTAssertTrue(prompt.contains("*no duplicate in* =recipes.org2="))
      XCTAssertTrue(prompt.contains("|-------+--------------|"))
      XCTAssertTrue(prompt.contains("Never use a Markdown table delimiter such as |---|---|."))
      XCTAssertTrue(prompt.contains("exactly one fewer + join than the number of columns"))
      XCTAssertTrue(prompt.contains("#+begin_src sh"))
      XCTAssertTrue(prompt.contains("Never write ##+begin_src or ##+end_src."))
      XCTAssertTrue(prompt.contains("clickable file-and-line citations is a deliberate OpenOrg chat transport exception"))
    }
  }

  func testThreadContinuationTeachesExplicitAsynchronousReporting() {
    let threadID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let context = OpenClawWorkspaceContext(
      localCorpusRoot: "/tmp/personal",
      remoteCorpusRoot: "/srv/personal",
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: [],
      threadContinuation: AIChatThreadContinuation(
        id: threadID,
        title: "Async reporting",
        messages: [],
        org2References: []
      )
    )

    for prompt in [context.systemPrompt(), context.codexSystemPrompt()] {
      XCTAssertTrue(prompt.contains("ORG2_AI_CHAT_THREAD_ID: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
      XCTAssertTrue(prompt.contains("org2_thread_post"))
      XCTAssertTrue(prompt.contains("Do not post a duplicate background message"))
    }
  }

  @MainActor
  func testAIChatContextSettingsPersist() throws {
    let suiteName = "AIChatContextSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    XCTAssertEqual(store.aiChatCorpusAccessScope, .activeCorpus)
    XCTAssertEqual(store.aiChatCustomInstructions, "")
    XCTAssertEqual(store.codexSandboxAccess, .workspaceWrite)
    XCTAssertEqual(store.aiChatMessageSound, .org2)

    store.aiChatCorpusAccessScope = .allCorpora
    store.aiChatCustomInstructions = "Always identify the source corpus."
    store.codexSandboxAccess = .fullAccess
    store.aiChatMessageSound = .purr

    let restored = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    XCTAssertEqual(restored.aiChatCorpusAccessScope, .allCorpora)
    XCTAssertEqual(restored.aiChatCustomInstructions, "Always identify the source corpus.")
    XCTAssertEqual(restored.codexSandboxAccess, .fullAccess)
    XCTAssertEqual(restored.aiChatMessageSound, .purr)
  }

  @MainActor
  func testNamedAIDestinationsPersistIndependently() throws {
    let suiteName = "AIChatDestinationSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-destination-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let id = store.addAIChatDestination()
    var destination = try XCTUnwrap(store.aiChatDestination(id: id))
    destination.name = "Codex on Press"
    destination.mention = "codex-remote"
    destination.endpoint = "wss://press.example.test/codex"
    destination.workspaceRoot = "~/dev/org2"
    store.updateAIChatDestination(destination)

    let restored = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let restoredDestination = try XCTUnwrap(restored.aiChatDestination(id: id))
    XCTAssertEqual(restoredDestination.name, "Codex on Press")
    XCTAssertEqual(restoredDestination.mention, "codex-remote")
    XCTAssertEqual(restoredDestination.adapter, .codexRemote)
    XCTAssertEqual(restoredDestination.endpoint, "wss://press.example.test/codex")
    XCTAssertEqual(restoredDestination.workspaceRoot, "~/dev/org2")
    XCTAssertTrue(restored.enabledAIChatDestinations.contains(where: { $0.id == id }))

    restored.createAIChatThread(destinationID: AIChatDestinationConfiguration.localCodexID)
    restored.setSelectedAIChatModel("local-model")
    restored.createAIChatThread(destinationID: id)
    XCTAssertNil(restored.selectedOpenClawChatThread?.model)
    restored.setSelectedAIChatModel("remote-model")
    restored.createAIChatThread(destinationID: id)
    XCTAssertEqual(restored.selectedOpenClawChatThread?.model, "remote-model")
  }

  @MainActor
  func testManagedRemoteCodexDestinationPersistsSSHHostAndWorkspace() throws {
    let suiteName = "AIChatManagedRemoteDestination.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let id = store.addAIChatDestination(adapter: .codexManagedRemote)
    var destination = try XCTUnwrap(store.aiChatDestination(id: id))
    destination.name = "Codex on Scarf"
    destination.endpoint = "scarfs-macbook-air"
    destination.workspaceRoot = "/Users/avi/avi.org2"
    store.updateAIChatDestination(destination)

    let restored = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let restoredDestination = try XCTUnwrap(restored.aiChatDestination(id: id))
    XCTAssertEqual(restoredDestination.adapter, .codexManagedRemote)
    XCTAssertEqual(restoredDestination.endpoint, "scarfs-macbook-air")
    XCTAssertEqual(restoredDestination.workspaceRoot, "/Users/avi/avi.org2")
    XCTAssertFalse(restoredDestination.acceptsBearerToken)
  }

  @MainActor
  func testNewAIChatThreadPreservesSelectedManagedRemoteDestination() throws {
    let suiteName = "AIChatManagedRemoteNewThread.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-new-thread-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let destinationID = store.addAIChatDestination(adapter: .codexManagedRemote)
    var destination = try XCTUnwrap(store.aiChatDestination(id: destinationID))
    destination.name = "Codex on Scarf"
    destination.endpoint = "scarfs-macbook-air"
    destination.workspaceRoot = "/Users/avi/avi.org2"
    store.updateAIChatDestination(destination)

    store.createAIChatThread(destinationID: destinationID)
    store.createAIChatThread()

    XCTAssertEqual(store.selectedOpenClawChatThread?.destinationID, destinationID)
    XCTAssertEqual(store.selectedAIChatDestination.adapter, .codexManagedRemote)
  }

  @MainActor
  func testDirectProviderDestinationPersistsEndpointAndModel() throws {
    let suiteName = "AIChatDirectProviderSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-direct-provider-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let id = store.addAIChatDestination(adapter: .openRouter)
    var destination = try XCTUnwrap(store.aiChatDestination(id: id))
    XCTAssertFalse(destination.isEnabled)
    XCTAssertEqual(destination.endpoint, "https://openrouter.ai/api/v1")
    destination.model = "anthropic/claude-test"
    destination.isEnabled = true
    store.updateAIChatDestination(destination)

    let restored = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let restoredDestination = try XCTUnwrap(restored.aiChatDestination(id: id))
    XCTAssertEqual(restoredDestination.adapter, .openRouter)
    XCTAssertEqual(restoredDestination.model, "anthropic/claude-test")
    XCTAssertTrue(restoredDestination.isEnabled)

    restored.createAIChatThread(destinationID: id)
    XCTAssertEqual(restored.selectedOpenClawChatThread?.model, "anthropic/claude-test")
  }

  @MainActor
  func testBuiltInOpenClawDestinationInheritsConfiguredAgentAfterMigration() async throws {
    let suiteName = "AIChatDestinationAgentMigration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-destination-agent-migration-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    defaults.set("openclaw/org2", forKey: "Org2Workspace.openClawAgent")
    let buggyDestinations = [
      AIChatDestinationConfiguration(
        id: AIChatDestinationConfiguration.localCodexID,
        name: "Codex",
        mention: "codex",
        adapter: .codexLocal
      ),
      AIChatDestinationConfiguration(
        id: AIChatDestinationConfiguration.openClawID,
        name: "OpenClaw",
        mention: "openclaw",
        adapter: .openClaw,
        agentID: "main"
      )
    ]
    defaults.set(
      try JSONEncoder().encode(buggyDestinations),
      forKey: "Org2Workspace.aiChat.destinations.v1"
    )
    let recorder = OpenClawDestinationRoutingRecorder()
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      openClawSendHandler: { _, agentID, sessionKey, _ in
        await recorder.record(agentID: agentID, sessionKey: sessionKey)
        return "Routed reply"
      },
      legacyDefaultsDomains: []
    )

    XCTAssertEqual(store.openClawAgentID, "openclaw/org2")
    XCTAssertEqual(
      store.aiChatDestination(id: AIChatDestinationConfiguration.openClawID)?.agentID,
      ""
    )

    store.createAIChatThread(destinationID: AIChatDestinationConfiguration.openClawID)
    await store.sendOpenClawMessage(text: "Use the configured Org2 agent")

    let routing = await recorder.value()
    XCTAssertEqual(routing?.agentID, "org2")
    XCTAssertTrue(routing?.sessionKey.hasPrefix("agent:org2:") == true)
  }

  func testCodexRemoteTransportDescribesItsWebSocketEndpoint() throws {
    let endpoint = try XCTUnwrap(URL(string: "wss://press.example.test/codex"))
    XCTAssertEqual(
      CodexAppServerTransport.remote(endpoint: endpoint, bearerToken: "secret")
        .connectionDescription,
      endpoint.absoluteString
    )
    XCTAssertEqual(CodexAppServerTransport.local.connectionDescription, "Local Codex App Server")
    XCTAssertEqual(
      CodexAppServerTransport.managedRemote(sshHost: "scarfs-macbook-air")
        .connectionDescription,
      "Managed remote Codex via scarfs-macbook-air"
    )
  }

  func testManagedRemoteCodexBuildsSafeKeepaliveSSHArguments() throws {
    let arguments = try CodexAppServerClient.managedRemoteSSHArguments(
      sshHost: " avi@scarfs-macbook-air "
    )

    XCTAssertEqual(arguments.prefix(2), ["-T", "-o"])
    XCTAssertTrue(arguments.contains("BatchMode=yes"))
    XCTAssertTrue(arguments.contains("ServerAliveInterval=15"))
    XCTAssertTrue(arguments.contains("ServerAliveCountMax=12"))
    XCTAssertEqual(arguments[arguments.count - 2], "avi@scarfs-macbook-air")
    XCTAssertTrue(arguments.last?.contains("codex app-server --listen stdio://") == true)
    XCTAssertFalse(arguments.last?.contains("codex app-server proxy") == true)
    XCTAssertThrowsError(
      try CodexAppServerClient.managedRemoteSSHArguments(
        sshHost: "-oProxyCommand=touch /tmp/unsafe"
      )
    )
  }

  func testCodexSandboxAccessBuildsAppServerPolicies() {
    let cwd = URL(fileURLWithPath: "/tmp/example-corpus", isDirectory: true)

    XCTAssertEqual(CodexSandboxAccess.readOnly.threadSandboxValue, "read-only")
    XCTAssertEqual(CodexSandboxAccess.workspaceWrite.threadSandboxValue, "workspace-write")
    XCTAssertEqual(CodexSandboxAccess.fullAccess.threadSandboxValue, "danger-full-access")
    XCTAssertEqual(
      CodexSandboxAccess.readOnly.turnSandboxPolicy(cwd: cwd),
      .object(["type": .string("readOnly")])
    )
    XCTAssertEqual(
      CodexSandboxAccess.workspaceWrite.turnSandboxPolicy(cwd: cwd),
      .object([
        "type": .string("workspaceWrite"),
        "writableRoots": .array([.string("/tmp/example-corpus")]),
        "networkAccess": .bool(false)
      ])
    )
    XCTAssertEqual(
      CodexSandboxAccess.fullAccess.turnSandboxPolicy(cwd: cwd),
      .object(["type": .string("dangerFullAccess")])
    )
  }

  @MainActor
  func testAllCorporaSettingIsCapturedInTheSentTurnContext() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("ai-chat-all-corpora-\(UUID().uuidString)", isDirectory: true)
    let personal = container.appendingPathComponent("personal", isDirectory: true)
    let team = container.appendingPathComponent("team", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    _ = try WorkspaceStore.initializeStarterCorpus(at: personal, kind: "personal")
    _ = try WorkspaceStore.initializeStarterCorpus(at: team, kind: "shared")
    let suiteName = "AIChatAllCorpora.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let recorder = AIChatContextRecorder()
    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: container.appendingPathComponent("chat.json"),
      openClawSendHandler: { _, _, _, context in
        await recorder.record(context)
        return "Both corpora are available."
      },
      legacyDefaultsDomains: []
    )

    store.setCorpusRoot(personal)
    await store.refreshActiveCorpusIdentity()
    store.setCorpusRoot(team)
    await store.refreshActiveCorpusIdentity()
    store.setCorpusRoot(personal)
    store.aiChatCorpusAccessScope = .allCorpora
    store.aiChatCustomInstructions = "Name the corpus for every citation."

    await store.sendOpenClawMessage(text: "What can you see?")

    let recordedContext = await recorder.value()
    let context = try XCTUnwrap(recordedContext)
    XCTAssertEqual(Set(context.authorizedCorpora.map(\.localRoot)), Set([personal.path, team.path]))
    XCTAssertEqual(context.authorizedCorpora.filter(\.isActive).map(\.localRoot), [personal.path])
    XCTAssertEqual(context.customInstructions, "Name the corpus for every citation.")
  }

  @MainActor
  func testWorkspaceCreatesAndRestoresCodexThread() throws {
    let suiteName = "CodexAppServerClientTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.createOpenClawChatThread()
    XCTAssertTrue(store.canChangeSelectedAIChatRuntime)
    store.setSelectedAIChatRuntime(.codex)
    store.setSelectedAIChatModel("gpt-test")
    store.setSelectedAIChatReasoningEffort("high")
    XCTAssertEqual(store.selectedOpenClawChatThread?.runtime, .codex)
    XCTAssertEqual(store.selectedOpenClawChatThread?.model, "gpt-test")
    XCTAssertEqual(store.selectedOpenClawChatThread?.reasoningEffort, "high")
    XCTAssertEqual(
      store.visibleOpenClawChatThreads.first(where: {
        $0.id == store.selectedOpenClawChatThreadID
      })?.runtime,
      .codex
    )

    let restored = WorkspaceStore(
      defaults: defaults,
      openClawTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    XCTAssertEqual(restored.selectedOpenClawChatThread?.runtime, .codex)
    XCTAssertEqual(restored.selectedOpenClawChatThread?.model, "gpt-test")
    XCTAssertEqual(restored.selectedOpenClawChatThread?.reasoningEffort, "high")
  }

  func testClientRunsCodexTurnAndAnswersDynamicToolCall() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-app-server-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex")
    try Self.fakeAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )

    let recorder = CodexTestRecorder()
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { event in
        await recorder.record(event)
      },
      dynamicToolHandler: { call in
        await recorder.record(call)
        return CodexDynamicToolResult(
          success: true,
          text: #"{"path":"notes/example.org2","text":"effective local text"}"#
        )
      }
    )

    let account = try await client.accountState()
    XCTAssertEqual(account, .chatGPT(email: "test@example.com", plan: "plus"))

    let threadID = try await client.ensureThread(
      existingThreadID: nil,
      cwd: temporaryDirectory,
      model: "gpt-test",
      sandboxAccess: .fullAccess
    )
    XCTAssertEqual(threadID, "thr-test")

    let result = try await client.runTurn(
      threadID: threadID,
      turnID: "local-turn",
      message: "Read the note.",
      workspaceContext: "Selected source includes an unsaved draft.",
      attachments: [],
      cwd: temporaryDirectory,
      clientUserMessageID: UUID(),
      model: "gpt-test",
      reasoningEffort: "high",
      sandboxAccess: .fullAccess
    )
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Final reply")

    var toolCall = await recorder.toolCall
    for _ in 0..<50 where toolCall == nil {
      try await Task.sleep(for: .milliseconds(10))
      toolCall = await recorder.toolCall
    }
    XCTAssertEqual(toolCall?.tool, "org2_workspace_read")
    XCTAssertEqual(toolCall?.arguments["turnId"]?.stringValue, "local-turn")
    let streamedText = await recorder.streamedText
    XCTAssertEqual(streamedText, "Working…")

    let models = try await client.listModels()
    XCTAssertEqual(models.map(\.id), ["gpt-test"])
    XCTAssertEqual(models.first?.label, "GPT Test")
    XCTAssertEqual(models.first?.reasoningOptions.map(\.id), ["low", "high"])
    XCTAssertEqual(models.first?.defaultReasoningEffort, "low")
    XCTAssertTrue(models.first?.isDefault == true)

    await client.shutdown()
  }

  func testSlowThreadResumeUsesDedicatedRecoveryTimeout() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-slow-resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-slow-resume")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/resume"'*)
          sleep 1.2
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr-slow"}}}'
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      requestTimeoutNanoseconds: 1_000_000_000,
      threadResumeRequestTimeoutNanoseconds: 3_000_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let threadID = try await client.ensureThread(
      existingThreadID: "thr-slow",
      cwd: temporaryDirectory
    )

    XCTAssertEqual(threadID, "thr-slow")
    await client.shutdown()
  }

  func testTimedOutThreadResumeResetsTransportForRetry() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-resume-reset-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let marker = temporaryDirectory.appendingPathComponent("first-resume-started")
    let firstProcessID = temporaryDirectory.appendingPathComponent("first-process-id")
    let executable = temporaryDirectory.appendingPathComponent("fake-codex-resume-reset")
    let script = #"""
    #!/bin/sh
    marker='\#(marker.path)'
    first_process_id='\#(firstProcessID.path)'
    trap '' TERM
    if [ ! -f "$first_process_id" ]; then
      printf '%s\n' "$$" > "$first_process_id"
    fi
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/resume"'*)
          if [ ! -f "$marker" ]; then
            : > "$marker"
            sleep 1
          fi
          printf '{"id":%s,"result":{"thread":{"id":"thr-retry"}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      requestTimeoutNanoseconds: 5_000_000_000,
      threadResumeRequestTimeoutNanoseconds: 100_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    do {
      _ = try await client.ensureThread(
        existingThreadID: "thr-retry",
        cwd: temporaryDirectory
      )
      XCTFail("The first slow resume should time out")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Codex took too long to reopen this task. Its connection was reset; retry once to reconnect."
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    let abandonedProcessID = try XCTUnwrap(
      Int(String(contentsOf: firstProcessID, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines))
    )
    for _ in 0..<50 where Darwin.kill(Int32(abandonedProcessID), 0) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotEqual(
      Darwin.kill(Int32(abandonedProcessID), 0),
      0,
      "A timed-out app-server must not retain its task-writer lock"
    )

    let threadID = try await client.ensureThread(
      existingThreadID: "thr-retry",
      cwd: temporaryDirectory
    )

    XCTAssertEqual(threadID, "thr-retry")
    await client.shutdown()
  }

  func testTimedOutThreadResumeAutomaticallyStartsAReplacementTask() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-auto-rebind-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let marker = temporaryDirectory.appendingPathComponent("resume-started")
    let executable = temporaryDirectory.appendingPathComponent("fake-codex-auto-rebind")
    let script = #"""
    #!/bin/sh
    marker='\#(marker.path)'
    trap '' TERM
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/resume"'*)
          : > "$marker"
          sleep 1
          ;;
        *'"method":"thread/start"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-replacement"}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      requestTimeoutNanoseconds: 5_000_000_000,
      threadResumeRequestTimeoutNanoseconds: 100_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let resolution = try await client.ensureThreadRecoveringStaleSession(
      existingThreadID: "thr-stale",
      cwd: temporaryDirectory
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(
      resolution,
      CodexThreadResolution(threadID: "thr-replacement", replacedStaleThread: true)
    )
    await client.shutdown()
  }

  func testManagedRemoteClientUsesSSHStdioJSONLTransport() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    try Self.fakeAppServerScript.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: fakeSSH.path
    )
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "scarfs-macbook-air"),
      eventHandler: { _ in },
      dynamicToolHandler: { _ in
        CodexDynamicToolResult(success: false, text: "unused")
      }
    )

    let account = try await client.accountState()

    XCTAssertEqual(account, .chatGPT(email: "test@example.com", plan: "plus"))
    await client.shutdown()
  }

  func testClientSteersTheExpectedActiveTurn() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-steer-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-steer")
    try Self.fakeSteerAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    try await client.steer(
      threadID: "thr-steer",
      expectedTurnID: "turn-steer",
      message: "Focus on the failing test first.",
      attachments: [
        OpenClawChatAttachment(fileName: "example.png", mimeType: "image/png", data: Data([1, 2, 3]))
      ]
    )

    await client.shutdown()
  }

  func testExternalCodexThreadParsesAsHarnessNeutralSummaryAndTranscript() throws {
    let raw: JSONValue = .object([
      "id": .string("019f-thread"),
      "name": .string("Inspect release state"),
      "preview": .string("Check the release artifacts"),
      "cwd": .string("/tmp/org2"),
      "source": .string("vscode"),
      "modelProvider": .string("openai"),
      "createdAt": .integer(100),
      "updatedAt": .integer(120),
      "status": .object(["type": .string("notLoaded")]),
      "turns": .array([
        .object([
          "startedAt": .integer(101),
          "items": .array([
            .object([
              "type": .string("userMessage"),
              "id": .string("user-1"),
              "content": .array([
                .object(["type": .string("text"), "text": .string("What shipped?")])
              ])
            ]),
            .object([
              "type": .string("commandExecution"),
              "id": .string("tool-1")
            ]),
            .object([
              "type": .string("agentMessage"),
              "id": .string("agent-1"),
              "text": .string("Version 0.4.1 shipped.")
            ])
          ])
        ])
      ])
    ])

    let summary = try XCTUnwrap(CodexAppServerClient.externalThreadSummary(raw))
    XCTAssertEqual(summary.harness, .codex)
    XCTAssertEqual(summary.externalID, "019f-thread")
    XCTAssertEqual(summary.title, "Inspect release state")
    XCTAssertEqual(summary.workspacePath, "/tmp/org2")
    XCTAssertEqual(summary.source, "vscode")
    XCTAssertEqual(summary.status, "notLoaded")

    let messages = CodexAppServerClient.externalThreadMessages(raw)
    XCTAssertEqual(messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(messages.map(\.content), ["What shipped?", "Version 0.4.1 shipped."])
  }

  func testCodexRolloutTranscriptReaderStreamsOnlyVisibleMessages() throws {
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-rollout-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: transcript) }
    let ignoredPayload = String(repeating: "internal tool output ", count: 100_000)
    let contents = [
      #"{"timestamp":"2026-08-15T12:00:00.100Z","type":"session_meta","payload":{"id":"thread"}}"#,
      #"{"timestamp":"2026-08-15T12:00:01.100Z","type":"event_msg","payload":{"type":"user_message","client_id":"user-visible","message":"What shipped?","images":[]}}"#,
      #"{"timestamp":"2026-08-15T12:00:02.200Z","type":"response_item","payload":{"type":"function_call_output","output":"\#(ignoredPayload)"}}"#,
      #"{"timestamp":"2026-08-15T12:00:03.300Z","type":"event_msg","payload":{"type":"agent_message","message":"I’m checking now.","phase":"commentary"}}"#,
      #"{"timestamp":"2026-08-15T12:00:04.400Z","type":"event_msg","payload":{"type":"agent_message","message":"Version 0.4.1 shipped.","phase":"final_answer"}}"#,
      #"{"timestamp":"2026-08-15T12:00:05.500Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Version 0.4.1 shipped."}}"#
    ].joined(separator: "\n")
    try contents.write(to: transcript, atomically: true, encoding: .utf8)

    let messages = try CodexRolloutTranscriptReader.readMessages(at: transcript)

    XCTAssertEqual(messages.map(\.role), [.user, .assistant, .assistant])
    XCTAssertEqual(
      messages.map(\.content),
      ["What shipped?", "I’m checking now.", "Version 0.4.1 shipped."]
    )
    XCTAssertEqual(messages.map(\.id), ["user-visible", "rollout-line-4", "rollout-line-5"])
    XCTAssertEqual(messages[0].createdAt.timeIntervalSince1970, 1_786_795_201.1, accuracy: 0.001)
    XCTAssertEqual(messages[1].createdAt.timeIntervalSince1970, 1_786_795_203.3, accuracy: 0.001)
    XCTAssertEqual(messages[2].createdAt.timeIntervalSince1970, 1_786_795_204.4, accuracy: 0.001)
  }

  func testExternalThreadReadUsesTheRolloutInsteadOfMaterializingTurns() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-external-read-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let transcript = temporaryDirectory.appendingPathComponent("rollout-thr-readable.jsonl")
    try [
      #"{"timestamp":"2026-08-15T12:00:01.100Z","type":"event_msg","payload":{"type":"user_message","message":"Load this without tool history."}}"#,
      #"{"timestamp":"2026-08-15T12:00:02.200Z","type":"event_msg","payload":{"type":"agent_message","message":"Loaded.","phase":"final_answer"}}"#
    ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-external-read")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/read"'*)
          case "$line" in
            *'"includeTurns":false'*) ;;
            *) printf '%s\n' '{"id":2,"error":{"message":"turn history must stay excluded"}}'; continue ;;
          esac
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr-readable","name":"Readable thread","source":"cli","createdAt":100,"updatedAt":120,"path":"\#(transcript.path)","turns":[]}}}'
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let detail = try await client.readExternalThread("thr-readable")

    XCTAssertEqual(detail.thread.title, "Readable thread")
    XCTAssertEqual(detail.messages.map(\.content), ["Load this without tool history.", "Loaded."])
    await client.shutdown()
  }

  func testExternalCodexThreadListingUsesRecencyAndPaginates() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-external-list-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-external-list")
    try Self.fakeExternalThreadListAppServerScript.write(
      to: executable,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let threads = try await client.listExternalThreads(limit: 3)

    XCTAssertEqual(threads.map(\.externalID), ["thr-current", "thr-recent", "thr-older"])
    await client.shutdown()
  }

  func testExternalCodexThreadSearchUsesFullHistorySearchAndSnippet() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-external-search-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-external-search")
    try Self.fakeExternalThreadListAppServerScript.write(
      to: executable,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let threads = try await client.searchExternalThreads("meeting automation", limit: 5)

    XCTAssertEqual(threads.map(\.externalID), ["thr-search-result"])
    XCTAssertEqual(threads.first?.preview, "Matched text from an older transcript")
    await client.shutdown()
  }

  func testExternalThreadSnapshotUsesOrg2StructureAndReadOnlyProvenance() {
    let summary = ExternalThreadSummary(
      harness: .codex,
      externalID: "019f-thread",
      title: "Inspect release state",
      preview: nil,
      workspacePath: "/tmp/org2",
      source: "vscode",
      modelProvider: "openai",
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 120),
      status: "notLoaded",
      isPinned: false
    )
    let detail = ExternalThreadDetail(
      thread: summary,
      messages: [
        ExternalThreadMessage(
          id: "user-1",
          role: .user,
          content: "A line\n* that must stay quoted",
          createdAt: Date(timeIntervalSince1970: 101)
        )
      ]
    )

    let snapshot = WorkspaceStore.externalThreadSnapshotText(detail)
    XCTAssertTrue(snapshot.contains("* External thread: Inspect release state"))
    XCTAssertTrue(snapshot.contains(":EXTERNAL_HARNESS: codex"))
    XCTAssertTrue(snapshot.contains("read-only snapshot imported from Codex"))
    XCTAssertTrue(snapshot.contains("*** You"))
    XCTAssertTrue(snapshot.contains(": * that must stay quoted"))
    XCTAssertEqual(
      WorkspaceStore.externalThreadSnapshotRelativePath(summary),
      "views/external-threads/inspect-release-state-019f-thread.org2"
    )
  }

  private static let fakeAppServerScript = #"""
  #!/bin/sh
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*)
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
        ;;
      *'"method":"initialized"'*)
        ;;
      *'"method":"account/read"'*)
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"test@example.com","planType":"plus"},"requiresOpenaiAuth":true}}'
        ;;
      *'"method":"thread/start"'*)
        case "$line" in
          *'"name":"org2_thread_post"'*) ;;
          *) printf '%s\n' '{"id":3,"error":{"message":"background thread-post tool missing"}}'; continue ;;
        esac
        case "$line" in
          *'"sandbox":"danger-full-access"'*) ;;
          *) printf '%s\n' '{"id":3,"error":{"message":"thread sandbox missing"}}'; continue ;;
        esac
        case "$line" in
          *'"model":"gpt-test"'*) ;;
          *) printf '%s\n' '{"id":3,"error":{"message":"thread model missing"}}'; continue ;;
        esac
        printf '%s\n' '{"id":3,"result":{"thread":{"id":"thr-test"}}}'
        ;;
      *'"method":"turn/start"'*)
        case "$line" in
          *'"type":"dangerFullAccess"'*) ;;
          *) printf '%s\n' '{"id":4,"error":{"message":"turn sandbox missing"}}'; continue ;;
        esac
        case "$line" in
          *'"model":"gpt-test"'*) ;;
          *) printf '%s\n' '{"id":4,"error":{"message":"turn model missing"}}'; continue ;;
        esac
        case "$line" in
          *'"effort":"high"'*) ;;
          *) printf '%s\n' '{"id":4,"error":{"message":"turn effort missing"}}'; continue ;;
        esac
        printf '%s\n' '{"id":4,"result":{"turn":{"id":"turn-test","status":"inProgress","items":[],"error":null}}}'
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-test","turn":{"id":"turn-test","status":"inProgress","items":[],"error":null}}}'
        printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thr-test","turnId":"turn-test","itemId":"msg-test","delta":"Working…"}}'
        printf '%s\n' '{"id":"tool-request","method":"item/tool/call","params":{"callId":"call-test","threadId":"thr-test","turnId":"turn-test","tool":"org2_workspace_read","arguments":{"turnId":"local-turn","path":"notes/example.org2"}}}'
        printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr-test","turnId":"turn-test","completedAtMs":1,"item":{"type":"agentMessage","id":"msg-test","text":"Final reply","phase":"final_answer"}}}'
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-test","turn":{"id":"turn-test","status":"completed","items":[],"error":null}}}'
        ;;
      *'"method":"model/list"'*)
        printf '%s\n' '{"id":5,"result":{"data":[{"id":"gpt-test","model":"gpt-test","upgrade":null,"upgradeInfo":null,"availabilityNux":null,"displayName":"GPT Test","description":"Test model","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"high","description":"Thorough"}],"defaultReasoningEffort":"low","inputModalities":["text"],"supportsPersonality":false,"additionalSpeedTiers":[],"serviceTiers":[],"defaultServiceTier":null,"isDefault":true}],"nextCursor":null}}'
        ;;
    esac
  done
  """#

  private static let fakeSteerAppServerScript = #"""
  #!/bin/sh
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*)
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
        ;;
      *'"method":"initialized"'*)
        ;;
      *'"method":"turn/steer"'*)
        case "$line" in
          *'"threadId":"thr-steer"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"wrong steer target"}}'; continue ;;
        esac
        case "$line" in
          *'"expectedTurnId":"turn-steer"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"wrong expected turn"}}'; continue ;;
        esac
        case "$line" in
          *'Focus on the failing test first.'*'"type":"image"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"steer input missing"}}'; continue ;;
        esac
        printf '%s\n' '{"id":2,"result":{"turnId":"turn-steer"}}'
        ;;
    esac
  done
  """#

  private static let fakeExternalThreadListAppServerScript = #"""
  #!/bin/sh
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*)
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
        ;;
      *'"method":"initialized"'*)
        ;;
      *'"method":"thread/list"'*)
        case "$line" in
          *'"sortKey":"recency_at"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"recency sort missing"}}'; continue ;;
        esac
        case "$line" in
          *'"sortDirection":"desc"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"sort direction missing"}}'; continue ;;
        esac
        case "$line" in
          *'"useStateDbOnly":true'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"state database mode missing"}}'; continue ;;
        esac
        case "$line" in
          *'"cursor":"page-2"'*)
            printf '%s\n' '{"id":3,"result":{"data":[{"id":"thr-older","name":"Older task","source":"vscode","createdAt":50,"updatedAt":100}],"nextCursor":null}}'
            ;;
          *)
            printf '%s\n' '{"id":2,"result":{"data":[{"id":"thr-current","name":"Long-running current task","source":"appServer","createdAt":1,"updatedAt":300},{"id":"thr-recent","name":"Recent task","source":"cli","createdAt":200,"updatedAt":250}],"nextCursor":"page-2"}}'
            ;;
        esac
        ;;
      *'"method":"thread/search"'*)
        case "$line" in
          *'"searchTerm":"meeting automation"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"search term missing"}}'; continue ;;
        esac
        printf '%s\n' '{"id":2,"result":{"data":[{"snippet":"Matched text from an older transcript","thread":{"id":"thr-search-result","name":"Older matching task","source":"cli","createdAt":10,"updatedAt":20}}],"nextCursor":null}}'
        ;;
    esac
  done
  """#
}

private actor AIChatContextRecorder {
  private var context: OpenClawWorkspaceContext?

  func record(_ context: OpenClawWorkspaceContext?) {
    self.context = context
  }

  func value() -> OpenClawWorkspaceContext? {
    context
  }
}

private actor OpenClawDestinationRoutingRecorder {
  private var routing: (agentID: String, sessionKey: String)?

  func record(agentID: String, sessionKey: String) {
    routing = (agentID, sessionKey)
  }

  func value() -> (agentID: String, sessionKey: String)? {
    routing
  }
}

private actor CodexTestRecorder {
  private(set) var toolCall: CodexDynamicToolCall?
  private(set) var streamedText = ""

  func record(_ event: CodexAppServerEvent) {
    if case .agentMessageDelta(_, _, _, let delta) = event {
      streamedText += delta
    }
  }

  func record(_ call: CodexDynamicToolCall) {
    toolCall = call
  }
}
