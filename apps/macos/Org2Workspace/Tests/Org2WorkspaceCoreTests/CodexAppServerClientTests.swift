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
    XCTAssertTrue(openClaw.contains("Never use =openclaw=, =codex=, a model name, or a session ID as =AGENT_REF:="))

    let codex = context.codexSystemPrompt()
    XCTAssertTrue(codex.contains("Execution runtime: codex"))
    XCTAssertTrue(codex.contains("org2 agent-profile resolve --runtime codex --runtime-agent-id default --dir /tmp/example-corpus --json"))
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
      XCTAssertTrue(prompt.contains("clickable file-and-line citations is a deliberate Org2 Workspace chat transport exception"))
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
    XCTAssertEqual(store.aiChatMessageSound, .glass)

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

  func testCodexSandboxAccessBuildsAppServerPolicies() {
    let cwd = URL(fileURLWithPath: "/tmp/example-corpus", isDirectory: true)

    XCTAssertEqual(CodexSandboxAccess.readOnly.threadSandboxValue, "readOnly")
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
          *'"sandbox":"dangerFullAccess"'*) ;;
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

private actor CodexTestRecorder {
  private(set) var toolCall: CodexDynamicToolCall?
  private(set) var streamedText = ""

  func record(_ event: CodexAppServerEvent) {
    if case .agentMessageDelta(_, _, let delta) = event {
      streamedText += delta
    }
  }

  func record(_ call: CodexDynamicToolCall) {
    toolCall = call
  }
}
