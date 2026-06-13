import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct CanonicalDocumentCacheEntry {
  let modifiedAt: Date?
  let document: Org2CanonicalDocument
}

private struct RenderedBlocksCacheEntry {
  let modifiedAt: Date?
  let sourceID: String
  let textByteCount: Int
  let blocks: [OrgEditableBlock]
}

private struct RenderedBlocksMetadata {
  let renderSignature: String
  let structureSignature: String
  let indexes: [OrgEditableBlock.ID: Int]
}

private struct PendingBlockSelection {
  let file: String
  let line: Int
  let mode: PendingBlockSelectionMode
  let beginEditing: Bool

  init(file: String, line: Int, mode: PendingBlockSelectionMode, beginEditing: Bool = false) {
    self.file = file
    self.line = line
    self.mode = mode
    self.beginEditing = beginEditing
  }
}

private enum PendingBlockSelectionMode {
  case containingOrNearest
  case nextOrNearest
}

private struct TransientDraftBlock {
  let file: String
  let insertionLine: Int
  let replacementEndLineExclusive: Int
  let replacementPrefix: String
  let replacementSuffix: String
  let selectionLineOffset: Int
  let block: OrgEditableBlock
  let coveredBlocks: [OrgEditableBlock]
}

private struct DeferredStableAutosave {
  let source: EntrySource
  let block: OrgEditableBlock
}

private struct DetailNavigationSnapshot {
  let location: WorkspaceLocation
  let selectedSurface: WorkspaceSurface
  let selectedEntrySourceMode: EntrySourceMode
}

private struct OrgIDLookupPayload: Decodable {
  let id: String
  let kind: String
  let file: String
  let line: Int
  let headingLine: Int?
}

private struct OrgCryptCLIPayload: Decodable {
  let action: String
  let file: String
  let headingLine: Int
  let applied: Bool
  let changed: Bool
  let gpgProgram: String
  let recipients: [String]
  let recipientFiles: [String]
}

private struct SplitDraftSpec {
  let insertionLineOffset: Int
  let displayLineOffset: Int
  let rawText: String
  let rendered: OrgRenderedBlock
  let replacementPrefix: String
  let replacementSuffix: String
  let selectionLineOffset: Int
}

private struct SplitBlockPlan {
  let replacement: String?
  let newBlockLineOffset: Int?
  let draft: SplitDraftSpec?
}

struct SourceBlockExecutionResult: Equatable, Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
  let timedOut: Bool
  let timeout: TimeInterval
}

@MainActor
public final class WorkspaceStore: ObservableObject {
  nonisolated public static let meetingCaptureSourceSummary = "Captures microphone and system/call audio when Screen Recording permission is granted."

  @Published public var selectedSurface: WorkspaceSurface = .agenda
  @Published public var agendaMode: AgendaMode = .focus {
    didSet {
      defaults.set(agendaMode.rawValue, forKey: agendaModeKey)
    }
  }
  @Published public var agendaFilter = ""
  @Published public var agendaFilterFocusToken = 0
  @Published public var selectedAgendaItemID: String?
  @Published public var corpusRoot: URL?
  @Published public var agenda: AgendaPayload?
  @Published public var corpusFiles: [CorpusFile] = []
  @Published public private(set) var orgRoamLinkResolver = OrgRoamLinkResolver.empty
  @Published public var selectedCorpusFileID: String?
  @Published public var corpusFileFilter = ""
  @Published public var isScanningCorpusFiles = false
  @Published public var isQuickOpenPresented = false
  @Published public var isKeyboardShortcutsPresented = false
  @Published public var detailScrollRequest: DetailScrollRequest?
  @Published public var quickOpenQuery = ""
  @Published public var searchQuery = ""
  @Published public var searchFocusToken = 0
  @Published public var searchResults: [SearchResult] = []
  @Published public var meetings: [MeetingWorkspaceItem] = []
  @Published public var selectedMeetingID: String?
  @Published public var meetingTitleDraft = ""
  @Published public var meetingStatusText = WorkspaceStore.defaultMeetingStatusText()
  @Published public var meetingInputAverageLevel = 0.0
  @Published public var meetingInputPeakLevel = 0.0
  @Published public var meetingSystemAudioAverageLevel = 0.0
  @Published public var meetingSystemAudioPeakLevel = 0.0
  @Published public var isCapturingSystemAudio = false
  @Published public var meetingSystemAudioStatusText = "System audio not recording"
  @Published public var openClawMessages: [OpenClawChatMessage] = [] {
    didSet {
      guard shouldPersistOpenClawMessages else { return }
      persistOpenClawMessages()
    }
  }
  @Published public var openClawDraft = ""
  @Published public var openClawAgentID = "main"
  @Published public var openClawEndpointText = ""
  @Published public var openClawRemoteCorpusPath = ""
  @Published public var openClawHasStoredToken = false
  @Published public var openClawStatusText = WorkspaceStore.defaultOpenClawStatusText()
  @Published public var isOrgCryptConfigurationPresented = false
  @Published public var orgCryptEncryptOnSave = true {
    didSet {
      defaults.set(orgCryptEncryptOnSave, forKey: orgCryptEncryptOnSaveKey)
    }
  }
  @Published public var orgCryptRecipientsText = ""
  @Published public var orgCryptRecipientFilesText = ""
  @Published public var orgCryptUseDefaultGpgKey = false
  @Published public var orgCryptGpgProgram = "gpg"
  @Published public var orgCryptHasStoredPassphrase = false
  @Published public var orgCryptStatusText = "Org crypt encrypts :crypt: subtree bodies with GPG."
  @Published public var isSendingOpenClawMessage = false
  @Published public var openClawRequestStartedAt: Date?
  @Published public var isOpenClawAssistantPresented = false
  public private(set) var openClawChatScrollPosition: Double?
  @Published public var openClawThreads: [OpenClawThread] = []
  @Published public var selectedOpenClawThreadID: String?
  @Published public var selectedLocation: WorkspaceLocation?
  @Published public var selectedEntrySource: EntrySource?
  @Published public var selectedRenderedBlocks: [OrgEditableBlock] = [] {
    didSet {
      defer {
        foldedRenderedBlockIDs = OrgRenderedFoldTree.prunedFoldedIDs(
          foldedRenderedBlockIDs,
          blocks: selectedRenderedBlocks
        )
      }
      if preservesSelectedRenderedBlocksMetadataForNextAssignment {
        selectedRenderedBlocksRenderSignature = Self.renderedBlocksRenderSignature(for: selectedRenderedBlocks)
        preservesSelectedRenderedBlocksMetadataForNextAssignment = false
        return
      }
      let metadata = Self.renderedBlocksMetadata(for: selectedRenderedBlocks)
      selectedRenderedBlocksRenderSignature = metadata.renderSignature
      selectedRenderedBlocksSignature = metadata.structureSignature
      selectedRenderedBlockIndexes = metadata.indexes
    }
  }
  public private(set) var selectedRenderedBlocksRenderSignature = WorkspaceStore.renderedBlocksRenderSignature(for: [])
  public private(set) var selectedRenderedBlocksSignature = WorkspaceStore.renderedBlocksSignature(for: [])
  public private(set) var selectedRenderedBlockIndexes: [OrgEditableBlock.ID: Int] = [:]
  @Published public var selectedEntrySourceMode: EntrySourceMode = .entry
  @Published public var editableEntryText = ""
  @Published public var selectedBlockID: OrgEditableBlock.ID?
  @Published public private(set) var foldedRenderedBlockIDs: Set<OrgEditableBlock.ID> = []
  @Published public var editingBlockID: OrgEditableBlock.ID?
  @Published public var editableBlockText = ""
  @Published public var sourceBlockRuns: [String: SourceBlockRunState] = [:] {
    didSet {
      sourceBlockRunsRenderSignature = Self.sourceBlockRunsRenderSignature(for: sourceBlockRuns)
    }
  }
  public private(set) var sourceBlockRunsRenderSignature = WorkspaceStore.sourceBlockRunsRenderSignature(for: [:])
  @Published public var backlinks: BacklinksPayload?
  @Published public var isLoadingAgenda = false
  @Published public var isSearching = false
  @Published public var isLoadingMeetings = false
  @Published public var isRecordingMeeting = false
  @Published public var isProcessingMeeting = false
  @Published public var isLoadingOpenClawThreads = false
  @Published public var isLoadingEntrySource = false
  @Published public var isRenderingEntrySource = false
  @Published public var isEditingEntry = false
  @Published public var isSavingEntry = false
  @Published public var isSavingBlock = false
  @Published public var isLoadingBacklinks = false
  @Published public var priorityModeActive = false
  @Published public var statusText = ""
  @Published public var errorText: String?
  @Published public private(set) var canNavigateBackInDetail = false

  public var meetingCaptureSourceText: String {
    Self.meetingCaptureSourceSummary
  }

  public let cli: Org2CLI
  private let defaults: UserDefaults
  private let meetingRecorder = MeetingAudioRecorder()
  private let meetingSystemAudioRecorder = MeetingSystemAudioRecorder()
  private let corpusKey = "Org2Workspace.corpusRoot"
  private let agendaModeKey = "Org2Workspace.agendaMode"
  private let openClawEndpointKey = "Org2Workspace.openClawEndpoint"
  private let openClawAgentKey = "Org2Workspace.openClawAgent"
  private let openClawRemoteCorpusPathKey = "Org2Workspace.openClawRemoteCorpusPath"
  private let orgCryptEncryptOnSaveKey = "Org2Workspace.orgCrypt.encryptOnSave"
  private let orgCryptRecipientsKey = "Org2Workspace.orgCrypt.recipients"
  private let orgCryptRecipientFilesKey = "Org2Workspace.orgCrypt.recipientFiles"
  private let orgCryptUseDefaultGpgKeyKey = "Org2Workspace.orgCrypt.useDefaultGpgKey"
  private let orgCryptGpgProgramKey = "Org2Workspace.orgCrypt.gpgProgram"
  private static let canonicalParserLineLimit = 2_000
  private static let renderedBlocksCacheLimit = 12
  private static let detailNavigationHistoryLimit = 100
  private let openClawTranscriptURL: URL
  private var openClawSessionKey = WorkspaceStore.makeOpenClawSessionKey()
  private var shouldPersistOpenClawMessages = false
  private var openClawBearerToken: String?
  private var activeMeetingRecording: PendingMeetingRecording?
  private var meetingMeterTask: Task<Void, Never>?
  private var pendingG = false
  private var orgRoamLinkResolverGeneration = 0
  private var entrySourceLoadGeneration = 0
  private var backlinksLoadGeneration = 0
  private var detailNavigationBackStack: [DetailNavigationSnapshot] = [] {
    didSet {
      canNavigateBackInDetail = !detailNavigationBackStack.isEmpty
    }
  }
  private var canonicalDocumentCache: [String: CanonicalDocumentCacheEntry] = [:]
  private var renderedBlocksCache: [String: RenderedBlocksCacheEntry] = [:]
  private var renderedBlocksCacheOrder: [String] = []
  private var pendingBlockSelection: PendingBlockSelection?
  private var transientDraftBlock: TransientDraftBlock?
  private var activeBlockDrafts: [OrgEditableBlock.ID: String] = [:]
  private var activeBlockOriginals: [OrgEditableBlock.ID: OrgEditableBlock] = [:]
  private var deferredStableAutosaves: [OrgEditableBlock.ID: DeferredStableAutosave] = [:]
  private var preservesSelectedRenderedBlocksMetadataForNextAssignment = false
  private var scheduledAgendaRefreshTask: Task<Void, Never>?
  private var pendingAgendaRefreshAfterBlockEditing = false

  public init(cli: Org2CLI? = nil, defaults: UserDefaults = .standard, openClawTranscriptURL: URL? = nil) {
    self.defaults = defaults
    self.openClawTranscriptURL = openClawTranscriptURL ?? Self.defaultOpenClawTranscriptURL()
    self.cli = cli ?? (try? Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())) ?? Org2CLI(repoRoot: URL(fileURLWithPath: "/Users/avi/dev/org2"))
    agendaMode = Self.restoreAgendaMode(from: defaults, key: agendaModeKey)
    let settings = OpenClawGatewaySettings.resolve()
    openClawEndpointText = defaults.string(forKey: openClawEndpointKey) ?? settings.endpoint.absoluteString
    openClawAgentID = defaults.string(forKey: openClawAgentKey) ?? "main"
    openClawRemoteCorpusPath = defaults.string(forKey: openClawRemoteCorpusPathKey) ?? ""
    orgCryptEncryptOnSave = defaults.object(forKey: orgCryptEncryptOnSaveKey) as? Bool ?? true
    orgCryptRecipientsText = OrgCryptSettings.listText(defaults.stringArray(forKey: orgCryptRecipientsKey) ?? [])
    orgCryptRecipientFilesText = OrgCryptSettings.listText(defaults.stringArray(forKey: orgCryptRecipientFilesKey) ?? [])
    orgCryptUseDefaultGpgKey = defaults.object(forKey: orgCryptUseDefaultGpgKeyKey) as? Bool ?? false
    orgCryptGpgProgram = defaults.string(forKey: orgCryptGpgProgramKey) ?? "gpg"
    openClawMessages = Self.loadOpenClawMessages(from: self.openClawTranscriptURL)
    shouldPersistOpenClawMessages = true
    openClawHasStoredToken = OpenClawKeychain.containsToken()
    orgCryptHasStoredPassphrase = OrgCryptKeychain.containsPassphrase()
    openClawStatusText = Self.openClawStatusText(settings: currentOpenClawSettings())
  }

  public func bootstrap() async {
    if corpusRoot == nil {
      corpusRoot = restoreCorpusRoot()
    }

    if corpusRoot != nil {
      await refreshAgenda()
      await refreshMeetings()
      await refreshCorpusFiles()
      Task { await refreshOpenClawThreads() }
    } else {
      statusText = "No corpus selected"
    }
  }

  public func chooseCorpus() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose an Org2 corpus directory"

    if panel.runModal() == .OK, let url = panel.url {
      setCorpusRoot(url)
      Task { await refreshWorkspace() }
    }
  }

  public func setCorpusRoot(_ url: URL) {
    let standardized = url.standardizedFileURL
    corpusRoot = standardized
    defaults.set(standardized.path, forKey: corpusKey)
    agenda = nil
    corpusFiles = []
    orgRoamLinkResolver = .empty
    orgRoamLinkResolverGeneration += 1
    selectedCorpusFileID = nil
    corpusFileFilter = ""
    quickOpenQuery = ""
    searchResults = []
    meetings = []
    selectedMeetingID = nil
    openClawThreads = []
    selectedOpenClawThreadID = nil
    selectedLocation = nil
    detailNavigationBackStack = []
    selectedEntrySource = nil
    selectedRenderedBlocks = []
    foldedRenderedBlockIDs = []
    sourceBlockRuns = [:]
    editableEntryText = ""
    canonicalDocumentCache = [:]
    renderedBlocksCache = [:]
    renderedBlocksCacheOrder = []
    scheduledAgendaRefreshTask?.cancel()
    scheduledAgendaRefreshTask = nil
    resetBlockState()
    isEditingEntry = false
    isRenderingEntrySource = false
    entrySourceLoadGeneration += 1
    backlinks = nil
    errorText = nil
  }

  public func refreshWorkspace() async {
    await refreshAgenda()
    await refreshMeetings()
    await refreshCorpusFiles()
    Task { await refreshOpenClawThreads() }
  }

  public func refreshCorpusFiles() async {
    guard let corpusRoot else {
      corpusFiles = []
      orgRoamLinkResolver = .empty
      orgRoamLinkResolverGeneration += 1
      return
    }

    isScanningCorpusFiles = true
    defer { isScanningCorpusFiles = false }

    do {
      let files = try await Task.detached(priority: .utility) {
        try Self.scanCorpusFiles(corpusRoot: corpusRoot)
      }.value
      corpusFiles = files
      refreshOrgRoamLinkResolver(files: files)
      if selectedSurface == .files {
        statusText = "\(files.count) corpus file\(files.count == 1 ? "" : "s")"
      }
    } catch {
      orgRoamLinkResolver = .empty
      orgRoamLinkResolverGeneration += 1
      errorText = error.localizedDescription
      statusText = "File scan failed"
    }
  }

  public func refreshAgenda(preserveSelection: Bool = false, updatesStatus: Bool = true) async {
    guard let corpusRoot else {
      if updatesStatus {
        statusText = "No corpus selected"
      }
      return
    }

    isLoadingAgenda = true
    errorText = nil
    defer { isLoadingAgenda = false }

    do {
      let today = Self.formatDate(Date())
      let end = Self.formatDate(Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: Date()) ?? Date())
      let payload: AgendaPayload = try await cli.runJSON([
        "agenda",
        "--dir", corpusRoot.path,
        "--recursive",
        "--from", today,
        "--to", end,
        "--format", "json",
        "--workload"
      ])
      agenda = payload
      syncAgendaSelectionAfterRefresh(preserveSelection: preserveSelection)
      if updatesStatus {
        statusText = "\(payload.totalItemCount) agenda item\(payload.totalItemCount == 1 ? "" : "s")"
      }
    } catch {
      errorText = error.localizedDescription
      if updatesStatus {
        statusText = "Agenda failed"
      }
    }
  }

  public func runSearch() async {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      searchResults = []
      return
    }
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    isSearching = true
    errorText = nil
    statusText = "Searching corpus..."
    defer { isSearching = false }

    do {
      let started = Date()
      let payload: SearchPayload = try await cli.runJSON([
        "search", query,
        "--dir", corpusRoot.path,
        "--limit", "50",
        "--context", "1",
        "--format", "json"
      ])
      searchResults = payload.results
      selectedSurface = .search
      let elapsed = Date().timeIntervalSince(started)
      statusText = "\(payload.results.count) search result\(payload.results.count == 1 ? "" : "s") in \(String(format: "%.1f", elapsed))s"
    } catch {
      errorText = error.localizedDescription
      statusText = "Search failed"
    }
  }

  public func refreshMeetings() async {
    guard let corpusRoot else {
      meetings = []
      return
    }

    isLoadingMeetings = true
    defer { isLoadingMeetings = false }

    do {
      let items = try await Task.detached(priority: .utility) {
        try Self.scanMeetingItems(corpusRoot: corpusRoot)
      }.value
      meetings = items
      if selectedSurface == .meetings {
        statusText = "\(items.count) meeting\(items.count == 1 ? "" : "s")"
      }
      syncMeetingSelectionAfterRefresh()
    } catch {
      errorText = error.localizedDescription
      statusText = "Meeting scan failed"
    }
  }

  public func promptAndStartMeetingRecording() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    guard !isRecordingMeeting && !isProcessingMeeting else { return }

    let alert = NSAlert()
    alert.messageText = "Record Meeting"
    alert.informativeText = "Record local microphone audio into the selected Org2 corpus."
    alert.addButton(withTitle: "Start Recording")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = "Meeting title"
    field.stringValue = meetingTitleDraft
    alert.accessoryView = field

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    meetingTitleDraft = field.stringValue
    Task { await startMeetingRecording(title: field.stringValue) }
  }

  public func startMeetingRecording(title rawTitle: String) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    guard !isRecordingMeeting else {
      meetingStatusText = "A meeting is already recording"
      return
    }
    guard !isProcessingMeeting else {
      meetingStatusText = "Finish the current meeting import first"
      return
    }

    do {
      let startedAt = Date()
      let paths = try MeetingArtifactWriter.preparePaths(
        corpusRoot: corpusRoot,
        title: rawTitle,
        recordedAt: startedAt
      )
      try await meetingRecorder.startRecording(to: paths.audioURL)
      let systemAudioStartError: String?
      do {
        try await meetingSystemAudioRecorder.startRecording(to: paths.systemAudioURL)
        isCapturingSystemAudio = true
        meetingSystemAudioStatusText = "System audio recording"
        systemAudioStartError = nil
      } catch {
        isCapturingSystemAudio = false
        meetingSystemAudioStatusText = "System audio unavailable: \(error.localizedDescription)"
        systemAudioStartError = error.localizedDescription
      }
      activeMeetingRecording = PendingMeetingRecording(
        paths: paths,
        capturesSystemAudio: systemAudioStartError == nil,
        systemAudioStartError: systemAudioStartError
      )
      isRecordingMeeting = true
      startMeetingInputMetering()
      selectedSurface = .meetings
      meetingStatusText = "Recording \(paths.title)"
      statusText = meetingStatusText
    } catch {
      isCapturingSystemAudio = false
      meetingSystemAudioStatusText = "System audio not recording"
      stopMeetingInputMetering()
      errorText = error.localizedDescription
      meetingStatusText = "Recording failed: \(error.localizedDescription)"
      statusText = "Recording failed"
    }
  }

  public func stopMeetingRecording() async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    guard let activeMeetingRecording else {
      meetingStatusText = "No active recording"
      return
    }

    do {
      let duration = try meetingRecorder.stopRecording()
      var systemAudioURL: URL?
      var systemAudioCaptureError = activeMeetingRecording.systemAudioStartError
      if activeMeetingRecording.capturesSystemAudio {
        do {
          if let systemDuration = try await meetingSystemAudioRecorder.stopRecording(), systemDuration > 0 {
            systemAudioURL = activeMeetingRecording.paths.systemAudioURL
          } else {
            try? FileManager.default.removeItem(at: activeMeetingRecording.paths.systemAudioURL)
            systemAudioCaptureError = "No system audio samples were captured."
          }
        } catch {
          try? FileManager.default.removeItem(at: activeMeetingRecording.paths.systemAudioURL)
          systemAudioCaptureError = error.localizedDescription
        }
      }
      self.activeMeetingRecording = nil
      isRecordingMeeting = false
      isCapturingSystemAudio = false
      stopMeetingInputMetering()
      isProcessingMeeting = true
      meetingStatusText = "Transcribing \(activeMeetingRecording.paths.title) locally..."
      defer { isProcessingMeeting = false }

      let transcript = await transcribeRecordedMeetingAudio(
        microphoneAudioURL: activeMeetingRecording.paths.audioURL,
        systemAudioURL: systemAudioURL,
        systemAudioCaptureError: systemAudioCaptureError
      )
      let bundle = try MeetingArtifactWriter.writeArtifacts(
        paths: activeMeetingRecording.paths,
        corpusRoot: corpusRoot,
        duration: duration,
        transcript: transcript,
        systemAudioURL: systemAudioURL
      )
      meetingTitleDraft = ""
      meetingSystemAudioStatusText = systemAudioURL == nil
        ? "System audio not captured"
        : "System audio saved"
      meetingStatusText = transcript.status == .complete
        ? "Saved \(bundle.noteURL.lastPathComponent)"
        : "Saved \(bundle.noteURL.lastPathComponent); transcription \(transcript.status.label)"
      statusText = meetingStatusText
      await refreshAfterMeetingWrite(selecting: bundle.item)
    } catch {
      isRecordingMeeting = false
      if isCapturingSystemAudio {
        _ = try? await meetingSystemAudioRecorder.stopRecording()
      }
      isCapturingSystemAudio = false
      meetingSystemAudioStatusText = "System audio not recording"
      stopMeetingInputMetering()
      isProcessingMeeting = false
      errorText = error.localizedDescription
      meetingStatusText = "Stop failed: \(error.localizedDescription)"
      statusText = "Recording stop failed"
    }
  }

  public func promptAndImportMeetingAudio() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    guard !isRecordingMeeting && !isProcessingMeeting else { return }

    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio, .movie]
    panel.prompt = "Import"
    panel.message = "Choose an audio or video file to transcribe into an Org2 meeting."

    if panel.runModal() == .OK, let url = panel.url {
      let title = meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
        : meetingTitleDraft
      Task { await importMeetingAudio(url: url, title: title) }
    }
  }

  public func importMeetingAudio(url sourceURL: URL, title rawTitle: String) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    guard !isRecordingMeeting else {
      meetingStatusText = "Stop the active recording before importing audio"
      return
    }

    isProcessingMeeting = true
    defer { isProcessingMeeting = false }
    let recordedAt = Date()

    do {
      let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
      let paths = try MeetingArtifactWriter.preparePaths(
        corpusRoot: corpusRoot,
        title: rawTitle,
        recordedAt: recordedAt,
        audioExtension: ext
      )
      try FileManager.default.copyItem(at: sourceURL, to: paths.audioURL)
      meetingStatusText = "Transcribing \(paths.title) locally..."
      let transcript = await transcribeAudioForMeeting(paths.audioURL)
      let bundle = try MeetingArtifactWriter.writeArtifacts(
        paths: paths,
        corpusRoot: corpusRoot,
        duration: nil,
        transcript: transcript,
        captureSources: "imported_audio"
      )
      meetingTitleDraft = ""
      meetingStatusText = transcript.status == .complete
        ? "Imported \(bundle.noteURL.lastPathComponent)"
        : "Imported \(bundle.noteURL.lastPathComponent); transcription \(transcript.status.label)"
      statusText = meetingStatusText
      await refreshAfterMeetingWrite(selecting: bundle.item)
    } catch {
      errorText = error.localizedDescription
      meetingStatusText = "Import failed: \(error.localizedDescription)"
      statusText = "Meeting import failed"
    }
  }

  public func selectMeeting(_ meeting: MeetingWorkspaceItem) {
    selectedSurface = .meetings
    select(.meeting(meeting))
  }

  public func askOpenClawAboutSelectedMeeting() {
    guard case .meeting = selectedLocation else {
      statusText = "Select a meeting first"
      return
    }
    openClawDraft = "Use the selected meeting note and transcript artifact as context. Summarize the meeting, extract decisions, list action items, and cite the org2 file paths you used."
    selectedSurface = .openClaw
  }

  public var meetingDisplaySections: [MeetingSection] {
    let grouped = Dictionary(grouping: meetings) { item -> String in
      guard let recordedAt = item.recordedAt, recordedAt.count >= 10 else {
        return "Unknown date"
      }
      return String(recordedAt.prefix(10))
    }
    return grouped.keys.sorted(by: >).map { key in
      let items = (grouped[key] ?? []).sorted {
        ($0.recordedAt ?? "") > ($1.recordedAt ?? "")
      }
      return MeetingSection(id: key, label: key, meetings: items)
    }
  }

  public func select(_ location: WorkspaceLocation) {
    activateDetailLocation(location, mode: nil, recordsHistory: true)
  }

  public func navigateBackInDetail() {
    guard let snapshot = detailNavigationBackStack.popLast() else { return }
    selectedSurface = snapshot.selectedSurface
    activateDetailLocation(snapshot.location, mode: snapshot.selectedEntrySourceMode, recordsHistory: false)
  }

  private func activateDetailLocation(
    _ location: WorkspaceLocation,
    mode: EntrySourceMode?,
    recordsHistory: Bool
  ) {
    if recordsHistory, let selectedLocation, selectedLocation != location {
      detailNavigationBackStack.append(DetailNavigationSnapshot(
        location: selectedLocation,
        selectedSurface: selectedSurface,
        selectedEntrySourceMode: selectedEntrySourceMode
      ))
      if detailNavigationBackStack.count > Self.detailNavigationHistoryLimit {
        detailNavigationBackStack.removeFirst(detailNavigationBackStack.count - Self.detailNavigationHistoryLimit)
      }
    }

    if case .agenda(let item) = location {
      selectedAgendaItemID = item.id
    }
    if case .openClaw(let thread) = location {
      selectedOpenClawThreadID = thread.id
    }
    if case .meeting(let meeting) = location {
      selectedMeetingID = meeting.id
    }
    selectedLocation = location
    isEditingEntry = false
    editableEntryText = ""
    resetBlockState()
    if let mode {
      selectedEntrySourceMode = mode
    } else if case .meeting = location {
      selectedEntrySourceMode = .page
    } else {
      selectedEntrySourceMode = .entry
    }
    selectedEntrySource = nil
    selectedRenderedBlocks = []
    isRenderingEntrySource = false
    Task { await loadBacklinks(for: location) }
    scheduleEntrySourceLoad(for: location)
  }

  public func loadEntrySource(for location: WorkspaceLocation) async {
    entrySourceLoadGeneration += 1
    let generation = entrySourceLoadGeneration
    await loadEntrySource(for: location, generation: generation)
  }

  private func scheduleEntrySourceLoad(for location: WorkspaceLocation) {
    entrySourceLoadGeneration += 1
    let generation = entrySourceLoadGeneration
    Task { await loadEntrySource(for: location, generation: generation) }
  }

  private func loadEntrySource(for location: WorkspaceLocation, generation: Int) async {
    guard generation == entrySourceLoadGeneration else { return }
    isLoadingEntrySource = true
    isRenderingEntrySource = false
    resetBlockEditing()
    defer {
      if generation == entrySourceLoadGeneration {
        isLoadingEntrySource = false
      }
    }

    do {
      let mode = selectedEntrySourceMode
      let source = try await Task.detached(priority: .userInitiated) {
        switch mode {
        case .entry:
          return try Self.entrySource(file: location.file, line: location.lineForEditor)
        case .page:
          return try Self.pageSource(file: location.file)
        }
      }.value
      guard generation == entrySourceLoadGeneration,
            selectedLocationMatches(location)
      else {
        return
      }
      selectedEntrySource = source
      if isEditingEntry {
        editableEntryText = source.text
      }
      renderEntrySource(source, generation: generation)
    } catch {
      guard generation == entrySourceLoadGeneration,
            selectedLocationMatches(location)
      else {
        return
      }
      selectedEntrySource = nil
      selectedRenderedBlocks = []
      selectedBlockID = nil
      isRenderingEntrySource = false
      errorText = error.localizedDescription
    }
  }

  public func reloadSelectedEntrySource() async {
    isEditingEntry = false
    editableEntryText = ""
    resetBlockState()
    guard let selectedLocation else { return }
    await loadEntrySource(for: selectedLocation)
  }

  public func beginEditingSelectedEntry() {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    editableEntryText = source.text
    resetBlockState()
    isEditingEntry = true
  }

  public func beginEditingCurrentScope() {
    if selectedEntrySourceMode == .page {
      beginEditingSelectedEntry()
    } else {
      beginEditingVisibleBlock()
    }
  }

  public func beginEditingVisibleBlock() {
    guard selectedEntrySource?.isEditable == true else {
      statusText = "No editable source loaded"
      return
    }

    if let selectedBlock {
      beginEditingBlock(selectedBlock)
      return
    }

    guard let firstEditableBlock = selectableBlocks.first else {
      statusText = "No editable block loaded"
      return
    }
    beginEditingBlock(firstEditableBlock)
  }

  public func cancelEditingSelectedEntry() {
    editableEntryText = selectedEntrySource?.text ?? ""
    isEditingEntry = false
  }

  public func beginEditingBlock(_ block: OrgEditableBlock, initialDraft: String? = nil) {
    guard block.isEditable, selectedEntrySource?.isEditable == true else {
      statusText = "Block is read-only"
      return
    }
    if initialDraft == nil,
       !isEditingEntry,
       selectedBlockID == block.id,
       editingBlockID == block.id {
      return
    }
    let draft = initialDraft ?? block.rawText
    isEditingEntry = false
    selectedBlockID = block.id
    editingBlockID = block.id
    editableBlockText = draft
    activeBlockDrafts[block.id] = draft
    activeBlockOriginals[block.id] = block
    deferredStableAutosaves.removeValue(forKey: block.id)
    if draft != block.rawText {
      let updatedBlocks = Self.locallyUpdatingRenderedBlocks(
        selectedRenderedBlocks,
        replacing: block,
        with: draft
      )
      setSelectedRenderedBlocks(updatedBlocks, preservingMetadata: true)
      selectedBlockID = block.id
    }
  }

  public func updateEditingBlockDraft(_ block: OrgEditableBlock, draft: String) {
    guard editingBlockID == block.id else { return }
    activeBlockDrafts[block.id] = draft
  }

  public func cancelEditingBlock() {
    if let draft = transientDraftBlock, editingBlockID == draft.block.id {
      discardTransientDraft(status: "Draft discarded")
      return
    }
    if !applyDeferredStableAutosaveForActiveBlock() {
      restoreActiveBlockOriginal()
    }
    resetBlockEditing()
  }

  public var selectedBlock: OrgEditableBlock? {
    guard let selectedBlockID else { return nil }
    guard let index = selectedRenderedBlockIndexes[selectedBlockID],
          selectedRenderedBlocks.indices.contains(index),
          selectedRenderedBlocks[index].id == selectedBlockID
    else {
      return nil
    }
    return selectedRenderedBlocks[index]
  }

  public var hasSelectedBlock: Bool {
    selectedBlock != nil
  }

  public var canSaveActiveEdit: Bool {
    if isEditingEntry {
      return !isSavingEntry
    }
    if editingBlockID != nil {
      return !isSavingBlock
    }
    return false
  }

  public var canSaveCurrentFile: Bool {
    canSaveActiveEdit || (orgCryptEncryptOnSave && selectedFileForOrgCryptSave != nil)
  }

  public var hasActiveEdit: Bool {
    isEditingEntry || editingBlockID != nil
  }

  public func cancelActiveEdit() {
    if editingBlockID != nil {
      cancelEditingBlock()
    } else {
      cancelEditingSelectedEntry()
    }
  }

  public func selectBlock(_ block: OrgEditableBlock) {
    guard selectedEntrySource?.isEditable == true else { return }
    guard selectedBlockID != block.id else { return }
    selectedBlockID = block.id
  }

  public func clearSelectedBlock() {
    selectedBlockID = nil
  }

  public func canSelectAdjacentBlock(_ direction: OrgBlockMoveDirection) -> Bool {
    guard let selectedBlock else { return false }
    let blocks = selectableBlocks
    guard let index = blocks.firstIndex(where: { $0.id == selectedBlock.id }) else { return false }
    switch direction {
    case .up:
      return index > 0
    case .down:
      return index < blocks.count - 1
    }
  }

  public func selectAdjacentBlock(_ direction: OrgBlockMoveDirection) {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    let blocks = selectableBlocks
    guard let index = blocks.firstIndex(where: { $0.id == selectedBlock.id }) else {
      selectedBlockID = nil
      return
    }

    let nextIndex: Int
    switch direction {
    case .up:
      nextIndex = max(0, index - 1)
    case .down:
      nextIndex = min(blocks.count - 1, index + 1)
    }
    selectedBlockID = blocks[nextIndex].id
  }

  public func toggleRenderedBlockFold(_ block: OrgEditableBlock) {
    setRenderedBlock(block, folded: !foldedRenderedBlockIDs.contains(block.id))
  }

  @discardableResult
  public func collapseSelectedRenderedBlock() -> Bool {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return false
    }
    return setRenderedBlock(selectedBlock, folded: true)
  }

  @discardableResult
  public func expandSelectedRenderedBlock() -> Bool {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return false
    }
    return setRenderedBlock(selectedBlock, folded: false)
  }

  public func collapseAllRenderedBlocks() {
    let foldableIDs = Set(selectedRenderedBlocks.filter {
      OrgRenderedFoldTree.isFoldable($0, in: selectedRenderedBlocks)
    }.map(\.id))
    foldedRenderedBlockIDs = foldableIDs
    if let selectedBlockID,
       let ancestorID = OrgRenderedFoldTree.foldedAncestorID(
        hiding: selectedBlockID,
        foldedBlockIDs: foldableIDs,
        blocks: selectedRenderedBlocks
       ) {
      self.selectedBlockID = ancestorID
    }
    statusText = foldableIDs.isEmpty ? "Nothing to collapse" : "Collapsed rendered blocks"
  }

  public func expandAllRenderedBlocks() {
    foldedRenderedBlockIDs = []
    statusText = "Expanded rendered blocks"
  }

  @discardableResult
  private func setRenderedBlock(_ block: OrgEditableBlock, folded: Bool) -> Bool {
    guard OrgRenderedFoldTree.isFoldable(block, in: selectedRenderedBlocks) else {
      statusText = "Selected block has nothing to \(folded ? "collapse" : "expand")"
      return false
    }

    var nextFoldedIDs = foldedRenderedBlockIDs
    if folded {
      nextFoldedIDs.insert(block.id)
      if let selectedBlockID,
         let range = OrgRenderedFoldTree.childrenRange(for: block, in: selectedRenderedBlocks),
         let selectedIndex = selectedRenderedBlocks.firstIndex(where: { $0.id == selectedBlockID }),
         range.contains(selectedIndex) {
        self.selectedBlockID = block.id
      }
      statusText = "Collapsed block"
    } else {
      nextFoldedIDs.remove(block.id)
      statusText = "Expanded block"
    }
    foldedRenderedBlockIDs = nextFoldedIDs
    return true
  }

  public func beginEditingSelectedBlock() {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    beginEditingBlock(selectedBlock)
  }

  public func beginEditingSelectedBlock(appending text: String) -> Bool {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return false
    }
    guard let draft = Self.editingDraft(selectedBlock, appending: text) else {
      return false
    }
    beginEditingBlock(selectedBlock, initialDraft: draft)
    return true
  }

  public func duplicateSelectedBlock() async {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    await duplicateBlock(selectedBlock)
  }

  public func deleteSelectedBlock() async {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    await deleteBlock(selectedBlock)
  }

  public func moveSelectedBlock(_ direction: OrgBlockMoveDirection) async {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    await moveBlock(selectedBlock, direction: direction)
  }

  public func insertBlockAfterSelected(_ kind: OrgInsertBlockKind, initialText: String? = nil) async {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    await insertBlock(after: selectedBlock, kind: kind, initialText: initialText)
  }

  public func canMoveSelectedBlock(_ direction: OrgBlockMoveDirection) -> Bool {
    guard let selectedBlock else { return false }
    return canMoveBlock(selectedBlock, direction: direction)
  }

  public func saveActiveEdit() async {
    if isEditingEntry {
      await saveEditedEntry()
      return
    }

    guard let block = activeEditingBlock else {
      await encryptSelectedFileAfterSave()
      return
    }
    await saveEditedBlock(block)
  }

  private var selectedFileForOrgCryptSave: String? {
    selectedEntrySource?.file ?? selectedLocation?.file
  }

  private func encryptSelectedFileAfterSave() async {
    guard orgCryptEncryptOnSave else {
      statusText = "No active edit to save"
      return
    }
    guard let file = selectedFileForOrgCryptSave else {
      statusText = "No file selected"
      return
    }

    do {
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: file)
      invalidateCanonicalDocumentCache(for: file)
      if encryptedCount > 0 {
        statusText = "Encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
        if let selectedLocation {
          await loadEntrySource(for: selectedLocation)
        }
        scheduleAgendaRefresh(preserveSelection: true)
      } else {
        statusText = "No plaintext :crypt: subtrees to encrypt"
      }
    } catch {
      recordOrgCryptEncryptionFailure(error, savedPrefix: nil)
    }
  }

  public func saveEditedEntry() async {
    guard let source = selectedEntrySource else {
      statusText = "No source loaded"
      return
    }
    guard source.isEditable else {
      statusText = "Selection is read-only"
      return
    }

    isSavingEntry = true
    defer { isSavingEntry = false }

    let replacement = editableEntryText
    do {
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceEntrySource(source, with: replacement)
      }.value
    } catch {
      errorText = error.localizedDescription
      statusText = "Save failed"
      return
    }

    let savedStatus: String
    do {
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)
      savedStatus = encryptedCount > 0
        ? "Saved and encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
        : "Saved \(relativePath(source.file)):\(source.displayRange)"
    } catch {
      recordOrgCryptEncryptionFailure(error, savedPrefix: "Saved, but")
      await finishSavedEntry(source: source)
      return
    }

    statusText = savedStatus
    await finishSavedEntry(source: source)
  }

  private func finishSavedEntry(source: EntrySource) async {
    invalidateCanonicalDocumentCache(for: source.file)
    isEditingEntry = false
    if let selectedLocation {
      await loadEntrySource(for: selectedLocation)
    }
    scheduleAgendaRefresh(preserveSelection: true)
  }

  private func recordOrgCryptEncryptionFailure(_ error: Error, savedPrefix: String?) {
    let message = error.localizedDescription
    errorText = message
    orgCryptStatusText = message
    if case OrgCryptError.missingEncryptionConfiguration = error {
      statusText = [savedPrefix, "org crypt needs configuration"].compactMap(\.self).joined(separator: " ")
      isOrgCryptConfigurationPresented = true
      return
    }
    statusText = [savedPrefix, "org crypt encryption failed"].compactMap(\.self).joined(separator: " ")
  }

  public func saveEditedBlock(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard editingBlockID == block.id else {
      statusText = "Block edit is no longer active"
      return
    }

    if let draft = transientDraftBlock, draft.block.id == block.id {
      await saveTransientDraftBlock(draft)
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let replacement = Self.normalizeLineEndings(saveReplacementText(for: block))
      let updatedSource = try Self.replacingSourceBlock(
        block,
        in: source,
        with: replacement
      )
      let currentRenderedBlocks = selectedRenderedBlocks
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceSourceRange(
          file: source.file,
          startLine: block.startLine,
          endLineExclusive: block.endLineExclusive,
          replacement: replacement
        )
      }.value
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)

      if encryptedCount > 0 {
        guard selectedEntrySource?.id == source.id else { return }
        deferredStableAutosaves.removeValue(forKey: block.id)
        invalidateCanonicalDocumentCache(for: source.file)
        resetBlockEditing()
        statusText = "Saved and encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
        if let selectedLocation {
          await loadEntrySource(for: selectedLocation)
        }
        scheduleAgendaRefresh(preserveSelection: true)
        return
      }

      let updatedBlocks = await Task.detached(priority: .userInitiated) {
        Self.locallyUpdatingRenderedBlocks(
          currentRenderedBlocks,
          replacing: block,
          with: replacement
        )
      }.value

      guard selectedEntrySource?.id == source.id else {
        return
      }

      deferredStableAutosaves.removeValue(forKey: block.id)
      invalidateCanonicalDocumentCache(for: source.file)
      selectedEntrySource = updatedSource
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: updatedSource)
      selectedRenderedBlocks = updatedVisibleBlocks
      selectedBlockID = blockForSelectionLine(
        block.startLine,
        mode: .containingOrNearest,
        in: updatedVisibleBlocks
      )?.id
      statusText = "Saved block \(relativePath(source.file)):\(block.displayRange)"
      resetBlockEditing()
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Block save failed"
    }
  }

  public func autosaveEditedBlock(_ block: OrgEditableBlock, replacement: String) async {
    guard let source = selectedEntrySource, source.isEditable else { return }
    guard editingBlockID == block.id else { return }
    guard transientDraftBlock?.block.id != block.id else { return }

    let normalizedReplacement = Self.normalizeLineEndings(replacement)
    guard normalizedReplacement != block.rawText else { return }
    guard isCurrentAutosaveDraft(block, in: source, replacement: normalizedReplacement) else {
      return
    }

    let updatedSource: EntrySource
    do {
      updatedSource = try Self.replacingSourceBlock(
        block,
        in: source,
        with: normalizedReplacement
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Autosave failed"
      return
    }

    do {
      let file = source.file
      let startLine = block.startLine
      let endLineExclusive = block.endLineExclusive
      try await Task.detached(priority: .utility) {
        try Self.replaceSourceRange(
          file: file,
          startLine: startLine,
          endLineExclusive: endLineExclusive,
          replacement: normalizedReplacement
        )
      }.value

      guard isCurrentAutosaveDraft(block, in: source, replacement: normalizedReplacement) else {
        return
      }

      let currentRenderedBlocks = selectedRenderedBlocks
      let updatedBlocks = await Task.detached(priority: .utility) {
        Self.locallyUpdatingRenderedBlocks(
          currentRenderedBlocks,
          replacing: block,
          with: normalizedReplacement
        )
      }.value

      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: updatedSource)
      let parsedUpdatedBlock = blockForSelectionLine(
        block.startLine,
        mode: .containingOrNearest,
        in: updatedVisibleBlocks
      )
      let updatedBlock = parsedUpdatedBlock?.preservingID(block.id)
      let renderedBlocks = Self.replacingBlock(
        parsedUpdatedBlock,
        with: updatedBlock,
        in: updatedVisibleBlocks
      )
      if shouldPreserveRenderedBlockMetadata(
        original: block,
        updated: updatedBlock,
        renderedBlocks: renderedBlocks
      ), let updatedBlock {
        invalidateCanonicalDocumentCache(for: source.file)
        deferredStableAutosaves[block.id] = DeferredStableAutosave(
          source: updatedSource,
          block: updatedBlock
        )
        activeBlockDrafts[updatedBlock.id] = normalizedReplacement
        pendingAgendaRefreshAfterBlockEditing = true
        return
      }

      invalidateCanonicalDocumentCache(for: source.file)
      selectedEntrySource = updatedSource
      setSelectedRenderedBlocks(
        renderedBlocks,
        preservingMetadata: shouldPreserveRenderedBlockMetadata(
          original: block,
          updated: updatedBlock,
          renderedBlocks: renderedBlocks
        )
      )
      if selectedBlockID != updatedBlock?.id {
        selectedBlockID = updatedBlock?.id
      }
      if editingBlockID != updatedBlock?.id {
        editingBlockID = updatedBlock?.id
      }
      if editableBlockText != normalizedReplacement {
        editableBlockText = normalizedReplacement
      }
      if let updatedBlock {
        activeBlockDrafts[updatedBlock.id] = normalizedReplacement
      }
      pendingAgendaRefreshAfterBlockEditing = true
    } catch {
      errorText = error.localizedDescription
      statusText = "Autosave failed"
    }
  }

  private func setSelectedRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    preservingMetadata: Bool
  ) {
    if preservingMetadata {
      preservesSelectedRenderedBlocksMetadataForNextAssignment = true
    }
    selectedRenderedBlocks = blocks
    foldedRenderedBlockIDs = OrgRenderedFoldTree.prunedFoldedIDs(foldedRenderedBlockIDs, blocks: blocks)
  }

  private func shouldPreserveRenderedBlockMetadata(
    original: OrgEditableBlock,
    updated: OrgEditableBlock?,
    renderedBlocks: [OrgEditableBlock]
  ) -> Bool {
    guard let updated else { return false }
    return updated.id == original.id
      && updated.startLine == original.startLine
      && updated.endLineExclusive == original.endLineExclusive
      && renderedBlocks.count == selectedRenderedBlocks.count
      && selectedRenderedBlockIndexes[updated.id] != nil
  }

  private func isCurrentAutosaveDraft(
    _ block: OrgEditableBlock,
    in source: EntrySource,
    replacement: String
  ) -> Bool {
    selectedEntrySource?.id == source.id
      && editingBlockID == block.id
      && Self.normalizeLineEndings(activeBlockDrafts[block.id] ?? "") == replacement
  }

  private func saveReplacementText(for block: OrgEditableBlock) -> String {
    editingDraftText(for: block)
  }

  private func editingDraftText(for block: OrgEditableBlock) -> String {
    if let draft = activeBlockDrafts[block.id],
       draft != block.rawText {
      return draft
    }
    if editableBlockText != block.rawText {
      return editableBlockText
    }
    return activeBlockDrafts[block.id] ?? editableBlockText
  }

  public func splitEditingBlock(_ block: OrgEditableBlock, atUTF16Offset offset: Int, draftText: String? = nil) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard editingBlockID == block.id else {
      statusText = "Block edit is no longer active"
      return
    }
    guard block.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block cannot be split"
      return
    }
    let draft = draftText ?? editingDraftText(for: block)
    guard let plan = Self.splitBlockPlan(for: block, draft: draft, utf16Offset: offset) else {
      statusText = "Block cannot be split"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      if let replacement = plan.replacement {
        try await Task.detached(priority: .userInitiated) {
          try Self.replaceSourceRange(
            file: source.file,
            startLine: block.startLine,
            endLineExclusive: block.endLineExclusive,
            replacement: replacement
          )
        }.value
        invalidateCanonicalDocumentCache(for: source.file)
      }
      isEditingEntry = false

      let draftToActivate: TransientDraftBlock?
      if let draftSpec = plan.draft {
        let draft = Self.transientDraftBlock(
          from: draftSpec,
          sourceFile: source.file,
          originalBlock: block
        )
        transientDraftBlock = draft
        draftToActivate = draft
        statusText = "Started draft in \(relativePath(source.file))"
      } else if let newBlockLineOffset = plan.newBlockLineOffset {
        draftToActivate = nil
        transientDraftBlock = nil
        resetBlockEditing()
        pendingBlockSelection = PendingBlockSelection(
          file: source.file,
          line: block.startLine + newBlockLineOffset,
          mode: .containingOrNearest,
          beginEditing: true
        )
        statusText = "Split block in \(relativePath(source.file))"
      } else {
        draftToActivate = nil
      }

      if plan.replacement != nil, let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      if let draftToActivate {
        activateTransientDraft(draftToActivate)
      }
      if plan.replacement != nil {
        scheduleAgendaRefresh(preserveSelection: true)
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Split failed"
    }
  }

  public func convertEditingBlock(_ block: OrgEditableBlock, to kind: OrgInsertBlockKind, draftText: String? = nil) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard editingBlockID == block.id else {
      statusText = "Block edit is no longer active"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }

    let draftText = draftText ?? editingDraftText(for: block)
    let draft = conversionDraftBlock(for: kind, replacing: block, in: source, draft: draftText)
    transientDraftBlock = draft
    pendingBlockSelection = nil
    isEditingEntry = false
    activateTransientDraft(draft)
    statusText = "Converted block to \(kind.title.lowercased()) draft"
  }

  public func insertBlock(after block: OrgEditableBlock, kind: OrgInsertBlockKind, initialText: String? = nil) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }

    let draft = insertionDraftBlock(for: kind, after: block, in: source, initialText: initialText)
    transientDraftBlock = draft
    pendingBlockSelection = nil
    isEditingEntry = false
    activateTransientDraft(draft)
    statusText = "Started \(kind.title.lowercased()) draft in \(relativePath(source.file))"
  }

  public func toggleListItemCheckbox(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .listItem(_, _, let checkbox, _) = block.rendered,
          let checkbox,
          let replacement = Self.toggledListItemCheckboxRawText(block.rawText, current: checkbox)
    else {
      statusText = "List item has no checkbox"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: checkbox == .checked ? "Marked incomplete" : "Marked complete",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Checkbox update failed"
    }
  }

  public func toggleHeadingTodo(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .heading(let heading) = block.rendered,
          let currentStatus = heading.todo,
          let nextStatus = Self.nextHeadingTodoStatus(after: currentStatus),
          let replacement = Self.toggledHeadingTodoRawText(
            block.rawText,
            current: currentStatus,
            next: nextStatus
          )
    else {
      statusText = "Heading has no TODO keyword"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: "\(nextStatus) -> heading",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "TODO update failed"
    }
  }

  public nonisolated static func nextHeadingTodoStatus(after current: String) -> String? {
    let normalized = current.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalized.isEmpty else { return nil }
    if doneHeadingTodoKeywords.contains(normalized) {
      return "TODO"
    }
    if activeHeadingTodoKeywords.contains(normalized) {
      return "DONE"
    }
    return nil
  }

  public func setHeadingPriority(_ block: OrgEditableBlock, priority: String?) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .heading = block.rendered,
          let replacement = Self.headingRawTextSettingPriority(block.rawText, priority: priority)
    else {
      statusText = "Heading priority update failed"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: priority.map { "[#\($0)] -> heading" } ?? "Priority cleared",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Priority update failed"
    }
  }

  public func setHeadingTags(_ block: OrgEditableBlock, tags: [String]) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .heading = block.rendered,
          let replacement = Self.headingRawTextSettingTags(block.rawText, tags: tags)
    else {
      statusText = "Heading tag update failed"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: tags.isEmpty ? "Tags cleared" : "Tags -> \(tags.joined(separator: ", "))",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Tag update failed"
    }
  }

  public func setPlanningBlock(_ block: OrgEditableBlock, kind: String, value: String) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .planning = block.rendered,
          let replacement = Self.planningRawText(kind: kind, value: value)
    else {
      statusText = "Planning update failed"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: "\(replacement) -> planning",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Planning update failed"
    }
  }

  public func setPropertyValue(_ block: OrgEditableBlock, key: String, value: String) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    let normalizedKey = Self.normalizedPropertyKey(key)
    guard normalizedKey != "ID" else {
      statusText = "ID property is read-only"
      return
    }
    guard case .properties = block.rendered,
          let replacement = Self.propertyDrawerRawTextSettingValue(
            block.rawText,
            key: normalizedKey,
            value: value
          )
    else {
      statusText = "Property update failed"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: "\(normalizedKey) -> property",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Property update failed"
    }
  }

  public func duplicateBlock(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block cannot be duplicated"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let replacement = "\n" + block.rawText
      let updatedSource = try Self.replacingSourceRange(
        in: source,
        startLine: block.endLineExclusive,
        endLineExclusive: block.endLineExclusive,
        replacement: replacement
      )
      let currentRenderedBlocks = selectedRenderedBlocks
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceSourceRange(
          file: source.file,
          startLine: block.endLineExclusive,
          endLineExclusive: block.endLineExclusive,
          replacement: replacement
        )
      }.value

      let updatedBlocks = await Task.detached(priority: .userInitiated) {
        Self.locallyInsertingRenderedBlocks(
          currentRenderedBlocks,
          atLine: block.endLineExclusive,
          replacement: replacement
        )
      }.value

      guard selectedEntrySource?.id == source.id else {
        return
      }

      invalidateCanonicalDocumentCache(for: source.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      selectedEntrySource = updatedSource
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: updatedSource)
      selectedRenderedBlocks = updatedVisibleBlocks
      selectedBlockID = blockForSelectionLine(
        block.endLineExclusive + 1,
        mode: .nextOrNearest,
        in: updatedVisibleBlocks
      )?.id
      statusText = "Duplicated block in \(relativePath(source.file))"
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Duplicate failed"
    }
  }

  public func deleteBlock(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block cannot be deleted"
      return
    }
    if source.isSubtree, block.startLine == source.startLine {
      statusText = "Open the page to delete the entry heading"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let deletion = try Self.deletingSourceRangeCleaningAdjacentBlank(
        in: source,
        startLine: block.startLine,
        endLineExclusive: block.endLineExclusive
      )
      let currentRenderedBlocks = selectedRenderedBlocks
      try await Task.detached(priority: .userInitiated) {
        try Self.deleteSourceRangeCleaningAdjacentBlank(
          file: source.file,
          startLine: block.startLine,
          endLineExclusive: block.endLineExclusive
        )
      }.value

      let updatedBlocks = await Task.detached(priority: .userInitiated) {
        Self.locallyDeletingRenderedBlocks(
          currentRenderedBlocks,
          startLine: deletion.startLine,
          endLineExclusive: deletion.endLineExclusive
        )
      }.value

      guard selectedEntrySource?.id == source.id else {
        return
      }

      invalidateCanonicalDocumentCache(for: source.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      selectedEntrySource = deletion.source
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: deletion.source)
      selectedRenderedBlocks = updatedVisibleBlocks
      selectedBlockID = blockForSelectionLine(
        block.startLine,
        mode: .nextOrNearest,
        in: updatedVisibleBlocks
      )?.id
      statusText = "Deleted block in \(relativePath(source.file))"
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Delete failed"
    }
  }

  public func canMoveBlock(_ block: OrgEditableBlock, direction: OrgBlockMoveDirection) -> Bool {
    guard block.isEditable,
          let source = selectedEntrySource,
          source.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      return false
    }
    if source.isSubtree, block.startLine == source.startLine {
      return false
    }

    let blocks = movableBlocks
    guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return false }
    switch direction {
    case .up:
      return index > 0
    case .down:
      return index < blocks.count - 1
    }
  }

  public func moveBlock(_ block: OrgEditableBlock, direction: OrgBlockMoveDirection) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard canMoveBlock(block, direction: direction),
          let target = moveTarget(for: block, direction: direction)
    else {
      statusText = "Block cannot move \(direction == .up ? "up" : "down")"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let sourceSwap: EntrySource
      switch direction {
      case .up:
        sourceSwap = try Self.swappingSourceRanges(
          in: source,
          firstStartLine: target.startLine,
          firstEndLineExclusive: target.endLineExclusive,
          secondStartLine: block.startLine,
          secondEndLineExclusive: block.endLineExclusive
        )
      case .down:
        sourceSwap = try Self.swappingSourceRanges(
          in: source,
          firstStartLine: block.startLine,
          firstEndLineExclusive: block.endLineExclusive,
          secondStartLine: target.startLine,
          secondEndLineExclusive: target.endLineExclusive
        )
      }
      try await Task.detached(priority: .userInitiated) {
        switch direction {
        case .up:
          try Self.swapSourceRanges(
            file: source.file,
            firstStartLine: target.startLine,
            firstEndLineExclusive: target.endLineExclusive,
            secondStartLine: block.startLine,
            secondEndLineExclusive: block.endLineExclusive
          )
        case .down:
          try Self.swapSourceRanges(
            file: source.file,
            firstStartLine: block.startLine,
            firstEndLineExclusive: block.endLineExclusive,
            secondStartLine: target.startLine,
            secondEndLineExclusive: target.endLineExclusive
          )
        }
      }.value
      let selectedLine: Int
      switch direction {
      case .up:
        selectedLine = target.startLine
      case .down:
        selectedLine = block.startLine + (target.endLineExclusive - target.startLine) + max(0, target.startLine - block.endLineExclusive)
      }
      let currentRenderedBlocks = selectedRenderedBlocks
      let updatedBlocks = await Task.detached(priority: .userInitiated) {
        Self.locallyMovingRenderedBlocks(
          currentRenderedBlocks,
          firstStartLine: direction == .up ? target.startLine : block.startLine,
          firstEndLineExclusive: direction == .up ? target.endLineExclusive : block.endLineExclusive,
          secondStartLine: direction == .up ? block.startLine : target.startLine,
          secondEndLineExclusive: direction == .up ? block.endLineExclusive : target.endLineExclusive
        )
      }.value

      guard selectedEntrySource?.id == source.id else {
        return
      }

      invalidateCanonicalDocumentCache(for: source.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      selectedEntrySource = sourceSwap
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: sourceSwap)
      selectedRenderedBlocks = updatedVisibleBlocks
      selectedBlockID = blockForSelectionLine(
        selectedLine,
        mode: .containingOrNearest,
        in: updatedVisibleBlocks
      )?.id
      statusText = "Moved block \(direction == .up ? "up" : "down")"
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Move failed"
    }
  }

  public func sourceBlockRunState(for block: OrgEditableBlock) -> SourceBlockRunState? {
    sourceBlockRuns[sourceBlockRunKey(for: block)]
  }

  public func runSourceBlock(_ block: OrgEditableBlock, rawText: String? = nil) async {
    guard let selectedEntrySource else {
      statusText = "No source loaded"
      return
    }
    guard case .source(let fallbackLanguage, let fallbackLines) = block.rendered else {
      statusText = "Select a source block first"
      return
    }

    let source = OrgEditableSourceBlock(
      rawText: rawText ?? block.rawText,
      fallbackLanguage: fallbackLanguage,
      fallbackLines: fallbackLines
    )
    let language = source.language.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = sourceBlockRunKey(for: block)
    guard let plan = SourceBlockRunPlan.plan(for: language) else {
      sourceBlockRuns[key] = SourceBlockRunState(
        status: .unsupported,
        language: language.isEmpty ? "source" : language,
        commandLabel: "",
        message: language.isEmpty
          ? "Add a supported source language to run this block."
          : "Running \(language) blocks is not supported yet."
      )
      return
    }

    let startedAt = Date()
    sourceBlockRuns[key] = SourceBlockRunState(
      status: .running,
      language: language,
      commandLabel: plan.commandLabel,
      startedAt: startedAt,
      message: "Running..."
    )

    let workingDirectory = URL(fileURLWithPath: selectedEntrySource.file)
      .deletingLastPathComponent()
      .standardizedFileURL

    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try Self.executeSourceBlock(source, plan: plan, workingDirectory: workingDirectory)
      }.value
      guard self.sourceBlockRunKey(for: block) == key else { return }
      let finishedAt = Date()
      let status: SourceBlockRunStatus
      if result.timedOut {
        status = .timedOut
      } else if result.exitCode == 0 {
        status = .succeeded
      } else {
        status = .failed
      }
      sourceBlockRuns[key] = SourceBlockRunState(
        status: status,
        language: language,
        commandLabel: plan.commandLabel,
        startedAt: startedAt,
        finishedAt: finishedAt,
        duration: finishedAt.timeIntervalSince(startedAt),
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
        message: result.timedOut ? "Timed out after \(Int(result.timeout))s" : nil
      )
    } catch {
      sourceBlockRuns[key] = SourceBlockRunState(
        status: .failed,
        language: language,
        commandLabel: plan.commandLabel,
        startedAt: startedAt,
        finishedAt: Date(),
        stderr: error.localizedDescription,
        message: "Run failed"
      )
    }
  }

  public func refreshOpenClawThreads() async {
    guard let corpusRoot else {
      openClawThreads = []
      return
    }

    isLoadingOpenClawThreads = true
    defer { isLoadingOpenClawThreads = false }

    do {
      let threads = try await Task.detached(priority: .utility) {
        try Self.scanOpenClawThreads(corpusRoot: corpusRoot)
      }.value
      openClawThreads = threads
      if selectedSurface == .agentSpace {
        statusText = "\(openClawThreads.count) agent item\(openClawThreads.count == 1 ? "" : "s")"
      }
      syncOpenClawSelectionAfterRefresh()
    } catch {
      errorText = error.localizedDescription
      statusText = "Agent Space scan failed"
    }
  }

  public var openClawDisplaySections: [OpenClawThreadSection] {
    let grouped = Dictionary(grouping: openClawThreads, by: \.zone)
    return grouped.keys.sorted().map { zone in
      OpenClawThreadSection(id: zone, label: zone, threads: grouped[zone] ?? [])
    }
  }

  public func selectOpenClawThread(_ thread: OpenClawThread) {
    selectedSurface = .agentSpace
    select(.openClaw(thread))
  }

  public func selectCorpusFile(_ file: CorpusFile) {
    selectedSurface = .files
    selectedCorpusFileID = file.id
    let thread = OpenClawThread(
      title: file.name,
      file: file.path,
      line: 1,
      zone: file.directory.isEmpty ? "corpus" : file.directory,
      modifiedAt: file.modifiedAt,
      idValue: nil
    )
    activateDetailLocation(.openClaw(thread), mode: .page, recordsHistory: true)
    selectedOpenClawThreadID = nil
    statusText = "Opened \(file.relativePath)"
  }

  public func presentQuickOpen() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    quickOpenQuery = ""
    isQuickOpenPresented = true
    if corpusFiles.isEmpty {
      Task { await refreshCorpusFiles() }
    }
  }

  public func focusSearchSurface() {
    selectedSurface = .search
    searchFocusToken += 1
  }

  public var filteredCorpusFiles: [CorpusFile] {
    filterFiles(corpusFileFilter, limit: 500)
  }

  public var quickOpenFiles: [CorpusFile] {
    filterFiles(quickOpenQuery, limit: 80)
  }

  private func filterFiles(_ rawQuery: String, limit: Int) -> [CorpusFile] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return Array(corpusFiles.prefix(limit))
    }

    return corpusFiles
      .compactMap { file -> (CorpusFile, Int)? in
        guard let score = Self.fuzzyScore(query: query, candidate: file.relativePath) else { return nil }
        return (file, score)
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.relativePath.localizedStandardCompare(rhs.0.relativePath) == .orderedAscending
      }
      .prefix(limit)
      .map(\.0)
  }

  private func selectedLocationMatches(_ location: WorkspaceLocation) -> Bool {
    guard let selectedLocation else { return true }
    return selectedLocation.file == location.file && selectedLocation.lineForEditor == location.lineForEditor
  }

  private func scheduleAgendaRefresh(preserveSelection: Bool = true, updatesStatus: Bool = false) {
    scheduledAgendaRefreshTask?.cancel()
    scheduledAgendaRefreshTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else { return }
      await refreshAgenda(preserveSelection: preserveSelection, updatesStatus: updatesStatus)
    }
  }

  private func applyDeferredStableAutosaveForActiveBlock() -> Bool {
    guard let editingBlockID,
          let deferred = deferredStableAutosaves.removeValue(forKey: editingBlockID)
    else {
      return false
    }

    if selectedEntrySource?.id == deferred.source.id {
      selectedEntrySource = deferred.source
    }

    let updatedBlocks = Self.replacingBlock(
      selectedBlock,
      with: deferred.block,
      in: selectedRenderedBlocks
    )
    setSelectedRenderedBlocks(updatedBlocks, preservingMetadata: true)
    selectedBlockID = deferred.block.id
    return true
  }

  private func restoreActiveBlockOriginal() {
    guard let editingBlockID,
          let original = activeBlockOriginals[editingBlockID]
    else {
      return
    }
    let updatedBlocks = Self.replacingBlock(
      selectedBlock,
      with: original,
      in: selectedRenderedBlocks
    )
    setSelectedRenderedBlocks(updatedBlocks, preservingMetadata: true)
    selectedBlockID = original.id
  }

  private func resetBlockEditing() {
    let wasEditingBlock = editingBlockID != nil
    editingBlockID = nil
    editableBlockText = ""
    activeBlockDrafts.removeAll()
    activeBlockOriginals.removeAll()
    deferredStableAutosaves.removeAll()
    if wasEditingBlock, pendingAgendaRefreshAfterBlockEditing {
      pendingAgendaRefreshAfterBlockEditing = false
      scheduleAgendaRefresh(preserveSelection: true)
    }
  }

  private func resetBlockState() {
    selectedBlockID = nil
    pendingBlockSelection = nil
    transientDraftBlock = nil
    resetBlockEditing()
  }

  private var activeEditingBlock: OrgEditableBlock? {
    guard let editingBlockID else { return nil }
    return selectedRenderedBlocks.first { $0.id == editingBlockID }
  }

  nonisolated static func directTypingInsertionText(from event: NSEvent) -> String? {
    guard let characters = event.characters,
          !characters.isEmpty,
          characters.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control })
    else {
      return nil
    }
    return characters
  }

  nonisolated static func editingDraft(
    _ block: OrgEditableBlock,
    appending text: String
  ) -> String? {
    guard !text.isEmpty else { return nil }
    switch block.rendered {
    case .heading:
      return headingEditingDraft(block.rawText, appending: text)
    case .paragraph, .listItem:
      return block.rawText + text
    default:
      return nil
    }
  }

  nonisolated private static func headingEditingDraft(
    _ rawText: String,
    appending text: String
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first,
          let regex = try? NSRegularExpression(pattern: #"^(\*+\s+)(.*)$"#)
    else {
      return nil
    }

    let nsFirst = first as NSString
    let fullRange = NSRange(location: 0, length: nsFirst.length)
    guard let match = regex.firstMatch(in: first, range: fullRange),
          match.range.location == 0
    else {
      return nil
    }

    let prefix = nsFirst.substring(with: match.range(at: 1))
    var rest = nsFirst.substring(with: match.range(at: 2))
      .trimmingCharacters(in: .whitespaces)
    var tagsSuffix = ""
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      tagsSuffix = String(rest[tagRange])
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var prefixTokens: [String] = []
    if let firstToken = tokens.first,
       allHeadingTodoKeywords.contains(firstToken.uppercased()) {
      prefixTokens.append(firstToken.uppercased())
      tokens.removeFirst()
    }
    if let firstToken = tokens.first,
       firstToken.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      prefixTokens.append(firstToken.uppercased())
      tokens.removeFirst()
    }

    let title = tokens.joined(separator: " ")
    let updatedTitle = title.isEmpty ? text : title + text
    lines[0] = "\(prefix)\((prefixTokens + [updatedTitle]).joined(separator: " "))\(tagsSuffix)"
    return lines.joined(separator: "\n")
  }

  private func discardTransientDraft(status: String? = nil) {
    guard let draft = transientDraftBlock else {
      resetBlockEditing()
      return
    }
    selectedRenderedBlocks.removeAll { $0.id == draft.block.id }
    let existingIDs = Set(selectedRenderedBlocks.map(\.id))
    selectedRenderedBlocks.append(contentsOf: draft.coveredBlocks.filter { !existingIDs.contains($0.id) })
    selectedRenderedBlocks = Self.sortEditableBlocksForDisplay(selectedRenderedBlocks)
    if selectedBlockID == draft.block.id {
      selectedBlockID = nil
    }
    transientDraftBlock = nil
    resetBlockEditing()
    if let status {
      statusText = status
    }
  }

  private func activateTransientDraft(_ draft: TransientDraftBlock) {
    let coveredIDs = Set(draft.coveredBlocks.map(\.id))
    selectedRenderedBlocks.removeAll { $0.id == draft.block.id }
    selectedRenderedBlocks.removeAll { coveredIDs.contains($0.id) }
    selectedRenderedBlocks.append(draft.block)
    selectedRenderedBlocks = Self.sortEditableBlocksForDisplay(selectedRenderedBlocks)
    selectedBlockID = draft.block.id
    editingBlockID = draft.block.id
    editableBlockText = draft.block.rawText
    activeBlockDrafts[draft.block.id] = draft.block.rawText
  }

  private func saveTransientDraftBlock(_ draft: TransientDraftBlock) async {
    guard selectedEntrySource?.isEditable == true else {
      statusText = "No editable source loaded"
      return
    }

    guard let replacementBody = Self.normalizedTransientDraftText(editableBlockText, for: draft.block) else {
      discardTransientDraft(status: "Draft discarded")
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    let replacement = "\(draft.replacementPrefix)\(replacementBody)\(draft.replacementSuffix)"
    do {
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceSourceRange(
          file: draft.file,
          startLine: draft.insertionLine,
          endLineExclusive: draft.replacementEndLineExclusive,
          replacement: replacement
        )
      }.value
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: draft.file)
      transientDraftBlock = nil
      selectedRenderedBlocks.removeAll { $0.id == draft.block.id }
      if selectedBlockID == draft.block.id {
        selectedBlockID = nil
      }
      invalidateCanonicalDocumentCache(for: draft.file)
      resetBlockEditing()
      isEditingEntry = false
      pendingBlockSelection = PendingBlockSelection(
        file: draft.file,
        line: draft.insertionLine + draft.selectionLineOffset,
        mode: .containingOrNearest
      )
      statusText = encryptedCount > 0
        ? "Saved and encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
        : "Saved block \(relativePath(draft.file)):\(draft.insertionLine)"
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Block save failed"
    }
  }

  private func replaceBlockSourceAndFinish(
    source: EntrySource,
    block: OrgEditableBlock,
    replacement: String,
    status: String,
    selectLine: Int? = nil,
    selectionMode: PendingBlockSelectionMode = .containingOrNearest
  ) async throws {
    let normalizedReplacement = Self.normalizeLineEndings(replacement)
    let updatedSource = try Self.replacingSourceBlock(
      block,
      in: source,
      with: normalizedReplacement
    )
    let currentRenderedBlocks = selectedRenderedBlocks
    try await Task.detached(priority: .userInitiated) {
      try Self.replaceSourceRange(
        file: source.file,
        startLine: block.startLine,
        endLineExclusive: block.endLineExclusive,
        replacement: normalizedReplacement
      )
    }.value
    let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)

    if encryptedCount > 0 {
      guard selectedEntrySource?.id == source.id else { return }
      invalidateCanonicalDocumentCache(for: source.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      statusText = "Saved and encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
      return
    }

    let updatedBlocks = await Task.detached(priority: .userInitiated) {
      Self.locallyUpdatingRenderedBlocks(
        currentRenderedBlocks,
        replacing: block,
        with: normalizedReplacement
      )
    }.value

    guard selectedEntrySource?.id == source.id else {
      return
    }

    invalidateCanonicalDocumentCache(for: source.file)
    transientDraftBlock = nil
    resetBlockEditing()
    isEditingEntry = false
    selectedEntrySource = updatedSource
    let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: updatedSource)
    selectedRenderedBlocks = updatedVisibleBlocks
    if let selectLine {
      selectedBlockID = blockForSelectionLine(
        max(1, selectLine),
        mode: selectionMode,
        in: updatedVisibleBlocks
      )?.id
    }
    statusText = status
    scheduleAgendaRefresh(preserveSelection: true)
  }

  private var selectableBlocks: [OrgEditableBlock] {
    guard let source = selectedEntrySource else { return [] }
    return OrgRenderedFoldTree.visibleBlocks(
      selectedRenderedBlocks,
      foldedBlockIDs: foldedRenderedBlockIDs
    ).filter { block in
      block.isEditable
        && block.startLine >= source.startLine
        && block.endLineExclusive <= source.endLineExclusive
    }
  }

  private func blockForSelectionLine(
    _ line: Int,
    mode: PendingBlockSelectionMode,
    in blocks: [OrgEditableBlock]
  ) -> OrgEditableBlock? {
    let editableBlocks = blocks.filter(\.isEditable)
    switch mode {
    case .containingOrNearest:
      if let containing = editableBlocks.first(where: { $0.startLine <= line && line < $0.endLineExclusive }) {
        return containing
      }
      if let next = editableBlocks.first(where: { $0.startLine >= line }) {
        return next
      }
    case .nextOrNearest:
      if let next = editableBlocks.first(where: { $0.startLine >= line }) {
        return next
      }
      if let containing = editableBlocks.first(where: { $0.startLine <= line && line < $0.endLineExclusive }) {
        return containing
      }
    }
    return editableBlocks.last
  }

  private var movableBlocks: [OrgEditableBlock] {
    guard let source = selectedEntrySource else { return [] }
    return selectedRenderedBlocks.filter { block in
      guard block.isEditable,
            block.startLine >= source.startLine,
            block.endLineExclusive <= source.endLineExclusive
      else {
        return false
      }
      return !(source.isSubtree && block.startLine == source.startLine)
    }
  }

  private func moveTarget(for block: OrgEditableBlock, direction: OrgBlockMoveDirection) -> OrgEditableBlock? {
    let blocks = movableBlocks
    guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return nil }
    switch direction {
    case .up:
      guard index > 0 else { return nil }
      return blocks[index - 1]
    case .down:
      guard index < blocks.count - 1 else { return nil }
      return blocks[index + 1]
    }
  }

  private func insertionDraftBlock(
    for kind: OrgInsertBlockKind,
    after previousBlock: OrgEditableBlock,
    in source: EntrySource,
    initialText: String? = nil
  ) -> TransientDraftBlock {
    let rawText = initialText ?? insertionDraftRawText(for: kind, after: previousBlock, in: source)
    let insertionLine = previousBlock.endLineExclusive
    return TransientDraftBlock(
      file: source.file,
      insertionLine: insertionLine,
      replacementEndLineExclusive: insertionLine,
      replacementPrefix: "\n",
      replacementSuffix: "",
      selectionLineOffset: 1,
      block: OrgEditableBlock(
        startLine: insertionLine,
        endLineExclusive: insertionLine,
        rawText: rawText,
        rendered: insertionDraftRenderedBlock(for: kind, rawText: rawText, after: previousBlock, in: source)
      ),
      coveredBlocks: []
    )
  }

  private func insertionDraftRawText(
    for kind: OrgInsertBlockKind,
    after block: OrgEditableBlock,
    in source: EntrySource
  ) -> String {
    let headingLevel = insertionHeadingLevel(after: block, in: source)
    let stars = String(repeating: "*", count: max(1, headingLevel))
    switch kind {
    case .paragraph:
      return ""
    case .heading:
      return "\(stars) "
    case .todo:
      return "\(stars) TODO "
    case .table:
      return """
      | Name | Value |
      |------+-------|
      |      |       |
      """
    case .divider:
      return "-----"
    case .image:
      return mediaDraftRawText(kind: .image, content: "")
    case .video:
      return mediaDraftRawText(kind: .video, content: "")
    case .properties:
      return """
      :PROPERTIES:
      :KEY:
      :END:
      """
    case .quote:
      return """
      #+begin_quote

      #+end_quote
      """
    case .source:
      return """
      #+begin_src sh

      #+end_src
      """
    }
  }

  private func insertionDraftRenderedBlock(
    for kind: OrgInsertBlockKind,
    rawText: String,
    after block: OrgEditableBlock,
    in source: EntrySource
  ) -> OrgRenderedBlock {
    let headingLevel = insertionHeadingLevel(after: block, in: source)
    switch kind {
    case .paragraph:
      return .paragraph("")
    case .heading:
      return .heading(OrgHeadingBlock(level: headingLevel, todo: nil, priority: nil, title: "", tags: []))
    case .todo:
      return .heading(OrgHeadingBlock(level: headingLevel, todo: "TODO", priority: nil, title: "", tags: []))
    case .table:
      return .table(OrgEditableTable(rawText: rawText).renderedBlock)
    case .divider:
      return .horizontalRule
    case .image, .video:
      return .paragraph(rawText)
    case .properties:
      return .properties(OrgEditablePropertyDrawer(rawText: rawText).renderedRows)
    case .quote:
      return .quote([])
    case .source:
      let source = OrgEditableSourceBlock(rawText: rawText)
      return .source(language: source.renderedLanguage, lines: source.renderedLines)
    }
  }

  private func conversionDraftBlock(
    for kind: OrgInsertBlockKind,
    replacing block: OrgEditableBlock,
    in source: EntrySource,
    draft: String
  ) -> TransientDraftBlock {
    let rawText = conversionDraftRawText(for: kind, replacing: block, in: source, draft: draft)
    return TransientDraftBlock(
      file: source.file,
      insertionLine: block.startLine,
      replacementEndLineExclusive: block.endLineExclusive,
      replacementPrefix: "",
      replacementSuffix: "",
      selectionLineOffset: 0,
      block: OrgEditableBlock(
        startLine: block.startLine,
        endLineExclusive: block.endLineExclusive,
        rawText: rawText,
        rendered: draftRenderedBlock(for: kind, rawText: rawText, fallbackLine: block.startLine, fallbackBlock: block, in: source)
      ),
      coveredBlocks: [block]
    )
  }

  private func conversionDraftRawText(
    for kind: OrgInsertBlockKind,
    replacing block: OrgEditableBlock,
    in source: EntrySource,
    draft: String
  ) -> String {
    let content = slashCommandContent(from: draft)
    guard !content.isEmpty else {
      return insertionDraftRawText(for: kind, after: block, in: source)
    }

    let headingLevel = insertionHeadingLevel(after: block, in: source)
    let stars = String(repeating: "*", count: max(1, headingLevel))
    switch kind {
    case .paragraph:
      return content
    case .heading:
      return "\(stars) \(singleLineTitle(content, fallback: ""))"
    case .todo:
      return "\(stars) TODO \(singleLineTitle(content, fallback: ""))"
    case .table:
      if content.contains("|") {
        return content
      }
      return insertionDraftRawText(for: .table, after: block, in: source)
    case .divider:
      return "-----"
    case .image:
      return mediaDraftRawText(kind: .image, content: content)
    case .video:
      return mediaDraftRawText(kind: .video, content: content)
    case .properties:
      return insertionDraftRawText(for: .properties, after: block, in: source)
    case .quote:
      return """
      #+begin_quote
      \(content)
      #+end_quote
      """
    case .source:
      return """
      #+begin_src sh
      \(content)
      #+end_src
      """
    }
  }

  private func mediaDraftRawText(kind: OrgMediaAttachment.Kind, content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[["),
       OrgMediaAttachment.standalone(raw: trimmed) != nil {
      return trimmed
    }

    let placeholderTarget: String
    let placeholderLabel: String
    switch kind {
    case .image:
      placeholderTarget = "images/image.png"
      placeholderLabel = "Image"
    case .video:
      placeholderTarget = "videos/video.mp4"
      placeholderLabel = "Video"
    }

    guard !trimmed.isEmpty else {
      return OrgEditableMediaLink(kind: kind, target: placeholderTarget, label: placeholderLabel).formattedRawText
    }

    if let attachment = OrgMediaAttachment.standalone(raw: trimmed) {
      return OrgEditableMediaLink(kind: kind, target: attachment.target, label: attachment.displayName).formattedRawText
    }

    if trimmed.range(of: #"\.(?:png|jpe?g|gif|tiff?|bmp|heic|heif|webp|mov|mp4|m4v|avi|webm)(?:[#?].*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return OrgEditableMediaLink(kind: kind, target: trimmed).formattedRawText
    }

    return OrgEditableMediaLink(kind: kind, target: placeholderTarget, label: trimmed).formattedRawText
  }

  private func draftRenderedBlock(
    for kind: OrgInsertBlockKind,
    rawText: String,
    fallbackLine: Int,
    fallbackBlock: OrgEditableBlock,
    in source: EntrySource
  ) -> OrgRenderedBlock {
    if let rendered = OrgEntryRenderer.parseEditable(rawText, baseLine: fallbackLine).first?.rendered {
      return rendered
    }
    return insertionDraftRenderedBlock(for: kind, rawText: rawText, after: fallbackBlock, in: source)
  }

  private func slashCommandContent(from draft: String) -> String {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return trimmed }

    let remainder = trimmed.dropFirst()
    guard let contentStart = remainder.firstIndex(where: { $0.isWhitespace }) else {
      return ""
    }

    return String(remainder[contentStart...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func singleLineTitle(_ text: String, fallback: String) -> String {
    let title = text
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? fallback : title
  }

  private func insertionHeadingLevel(after block: OrgEditableBlock, in source: EntrySource) -> Int {
    if source.isSubtree,
       let rootLevel = Self.firstHeadingLevel(in: source.text) {
      return min(6, rootLevel + 1)
    }

    if case .heading(let heading) = block.rendered {
      return heading.level
    }

    if let previousHeading = selectedRenderedBlocks
      .filter({ $0.startLine <= block.startLine })
      .last(where: { candidate in
        if case .heading = candidate.rendered { return true }
        return false
      }),
      case .heading(let heading) = previousHeading.rendered {
      return heading.level
    }

    return 1
  }

  nonisolated private static func firstHeadingLevel(in text: String) -> Int? {
    for line in normalizeLineEndings(text).split(separator: "\n", omittingEmptySubsequences: false) {
      if let level = headingLevel(String(line)) {
        return level
      }
    }
    return nil
  }

  func sourceBlockRunKey(for block: OrgEditableBlock) -> String {
    let file = selectedEntrySource?.file ?? selectedLocation?.file ?? ""
    return "\(file):\(block.id)"
  }

  public func openDailyNote(_ target: DailyNoteTarget) {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    let url = dailyNotePath(corpusRoot: corpusRoot, date: Self.date(for: target))
    do {
      if !FileManager.default.fileExists(atPath: url.path) {
        try createDailyNote(at: url)
      }
      let file = corpusFile(for: url, corpusRoot: corpusRoot)
      upsertCorpusFile(file)
      selectCorpusFile(file)
      statusText = "Opened \(file.relativePath)"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not open \(url.lastPathComponent)"
    }
  }

  public func sendOpenClawMessage() async {
    let text = openClawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    let userMessage = OpenClawChatMessage(role: .user, content: text)
    openClawMessages.append(userMessage)
    openClawDraft = ""
    isSendingOpenClawMessage = true
    openClawRequestStartedAt = Date()
    openClawStatusText = "Sending to OpenClaw..."
    defer {
      isSendingOpenClawMessage = false
      openClawRequestStartedAt = nil
    }

    do {
      let client = OpenClawChatClient(settings: currentOpenClawSettings(allowKeychainRead: true))
      let reply = try await client.send(
        messages: openClawMessages,
        agentID: openClawAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : openClawAgentID,
        sessionKey: openClawSessionKey,
        workspaceContext: currentOpenClawWorkspaceContext()
      )
      openClawMessages.append(OpenClawChatMessage(role: .assistant, content: reply))
      openClawStatusText = "OpenClaw replied"
    } catch {
      openClawStatusText = error.localizedDescription
    }
  }

  public func resetOpenClawChat() {
    openClawSessionKey = Self.makeOpenClawSessionKey()
    openClawMessages = []
    openClawDraft = ""
    openClawChatScrollPosition = nil
    openClawStatusText = Self.openClawStatusText(settings: currentOpenClawSettings())
  }

  public func recordOpenClawChatScrollPosition(_ position: Double) {
    openClawChatScrollPosition = min(1, max(0, position))
  }

  public func openChatFileReference(_ reference: OpenClawFileReference) {
    guard let file = localPathForOpenClawReference(reference.path) else {
      openClawStatusText = "Could not resolve file link: \(reference.path)"
      return
    }

    let url = URL(fileURLWithPath: file)
    let thread = OpenClawThread(
      title: url.deletingPathExtension().lastPathComponent,
      file: file,
      line: reference.line ?? 1,
      zone: "chat link",
      modifiedAt: nil,
      idValue: nil
    )
    activateDetailLocation(.openClaw(thread), mode: .page, recordsHistory: true)
    statusText = "Opened \(relativePath(file))"
  }

  public func saveOpenClawConfiguration(endpoint: String, agent: String, remoteCorpusPath: String, token: String, clearToken: Bool) -> Bool {
    let rawEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let normalizedEndpoint = OpenClawGatewaySettings.normalizedEndpointString(rawEndpoint) else {
      openClawStatusText = "OpenClaw gateway endpoint is invalid"
      return false
    }

    let rawAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
    let agent = rawAgent.isEmpty ? "main" : rawAgent
    let remoteCorpusPath = remoteCorpusPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedToken = OpenClawGatewaySettings.normalizedBearerToken(token)

    do {
      defaults.set(normalizedEndpoint, forKey: openClawEndpointKey)
      defaults.set(agent, forKey: openClawAgentKey)
      defaults.set(remoteCorpusPath, forKey: openClawRemoteCorpusPathKey)
      openClawEndpointText = normalizedEndpoint
      openClawAgentID = agent
      openClawRemoteCorpusPath = remoteCorpusPath

      if clearToken {
        try OpenClawKeychain.deleteToken()
        openClawBearerToken = nil
        openClawHasStoredToken = false
      } else if let token = normalizedToken {
        try OpenClawKeychain.saveToken(token)
        openClawBearerToken = token
        openClawHasStoredToken = true
      } else {
        openClawHasStoredToken = OpenClawKeychain.containsToken()
      }

      openClawStatusText = Self.openClawStatusText(settings: currentOpenClawSettings())
      return true
    } catch {
      openClawStatusText = error.localizedDescription
      return false
    }
  }

  public func saveOrgCryptConfiguration(
    encryptOnSave: Bool,
    recipientsText: String,
    recipientFilesText: String,
    useDefaultGpgKey: Bool,
    gpgProgram: String,
    passphrase: String,
    clearPassphrase: Bool
  ) -> Bool {
    let recipients = OrgCryptSettings.splitListText(recipientsText)
    let recipientFiles = OrgCryptSettings.splitListText(recipientFilesText)
    let normalizedGpgProgram = gpgProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "gpg"
      : gpgProgram.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      defaults.set(encryptOnSave, forKey: orgCryptEncryptOnSaveKey)
      defaults.set(recipients, forKey: orgCryptRecipientsKey)
      defaults.set(recipientFiles, forKey: orgCryptRecipientFilesKey)
      defaults.set(useDefaultGpgKey, forKey: orgCryptUseDefaultGpgKeyKey)
      defaults.set(normalizedGpgProgram, forKey: orgCryptGpgProgramKey)

      orgCryptEncryptOnSave = encryptOnSave
      orgCryptRecipientsText = OrgCryptSettings.listText(recipients)
      orgCryptRecipientFilesText = OrgCryptSettings.listText(recipientFiles)
      orgCryptUseDefaultGpgKey = useDefaultGpgKey
      orgCryptGpgProgram = normalizedGpgProgram

      if clearPassphrase {
        try OrgCryptKeychain.deletePassphrase()
        orgCryptHasStoredPassphrase = false
      } else if !passphrase.isEmpty {
        try OrgCryptKeychain.savePassphrase(passphrase)
        orgCryptHasStoredPassphrase = true
      } else {
        orgCryptHasStoredPassphrase = OrgCryptKeychain.containsPassphrase()
      }

      orgCryptStatusText = orgCryptStatusText(settings: currentOrgCryptSettings())
      statusText = "Org crypt configuration saved"
      return true
    } catch {
      orgCryptStatusText = error.localizedDescription
      errorText = error.localizedDescription
      return false
    }
  }

  public func presentOrgCryptConfiguration() {
    isOrgCryptConfigurationPresented = true
  }

  public func runOrgCrypt(_ action: OrgCryptAction, line explicitLine: Int? = nil) async {
    guard let file = selectedEntrySource?.file ?? selectedLocation?.file else {
      statusText = "Open a file before running org crypt"
      return
    }

    let line = explicitLine ?? selectedBlock?.startLine ?? selectedLocation?.lineForEditor ?? 1
    let settings = currentOrgCryptSettings(allowKeychainRead: true)
    var arguments = [
      "crypt",
      action.rawValue,
      "--file",
      file,
      "--line",
      "\(line)",
      "--gpg-program",
      settings.gpgProgram,
      "--format",
      "json",
      "--apply"
    ]
    if let passphrase = settings.passphrase {
      arguments += ["--passphrase", passphrase]
    }
    if settings.useDefaultGpgKey {
      arguments += ["--default-recipient-self"]
    }
    for recipient in settings.recipients {
      arguments += ["--recipient", recipient]
    }
    for recipientFile in settings.recipientFiles {
      arguments += ["--recipient-file", recipientFile]
    }

    do {
      let result = try await cli.runJSON(arguments, as: OrgCryptCLIPayload.self)
      invalidateCanonicalDocumentCache(for: file)
      resetBlockEditing()
      isEditingEntry = false
      orgCryptStatusText = "\(action.title) \(result.changed ? "updated" : "made no changes") \(relativePath(file)):\(result.headingLine)"
      statusText = orgCryptStatusText
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      orgCryptStatusText = error.localizedDescription
      statusText = "Org crypt \(action.rawValue) failed"
    }
  }

  public var agendaDisplaySections: [AgendaDisplaySection] {
    guard let agenda else { return [] }
    let overdue = agenda.overdue.flatMap(\.items).filter { $0.matchesAgendaFilter(agendaFilter) }
    let today = agenda.days.filter { $0.date == agenda.range.start }.flatMap(\.items).filter { $0.matchesAgendaFilter(agendaFilter) }
    let next7End = Self.isoDate(Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: Self.dateFromISO(agenda.range.start) ?? Date()) ?? Date())
    let next7 = agenda.days
      .filter { $0.date > agenda.range.start && $0.date <= next7End }
      .flatMap(\.items)
      .filter { $0.matchesAgendaFilter(agendaFilter) }
    let later = agenda.days
      .filter { $0.date > next7End }
      .flatMap(\.items)
      .filter { $0.matchesAgendaFilter(agendaFilter) }

    switch agendaMode {
    case .focus:
      let todayActionable = today.filter(\.isActionable)
      let overdueActionable = overdue.filter(\.isActionable)
      let doneToday = today.filter { !$0.isActionable }
      return [
        AgendaDisplaySection(id: "focus-today", label: "Today", items: todayActionable, hint: "today"),
        AgendaDisplaySection(id: "focus-overdue", label: "Overdue", items: overdueActionable, hint: "overdue"),
        AgendaDisplaySection(id: "focus-closed", label: "Done or canceled", items: doneToday, hint: "today")
      ].filter { !$0.items.isEmpty }
    case .today:
      return [
        AgendaDisplaySection(id: "today", label: "Today", items: today, hint: "today"),
        AgendaDisplaySection(id: "overdue", label: "Overdue", items: overdue, hint: "overdue")
      ].filter { !$0.items.isEmpty }
    case .range:
      return [
        AgendaDisplaySection(id: "overdue", label: "Overdue", items: overdue, hint: "overdue"),
        AgendaDisplaySection(id: "today", label: "Today", items: today, hint: "today"),
        AgendaDisplaySection(id: "next-7-days", label: "Next 7 days", items: next7, hint: "upcoming"),
        AgendaDisplaySection(id: "later", label: "Later", items: later, hint: "upcoming")
      ].filter { !$0.items.isEmpty }
    }
  }

  public var visibleAgendaItems: [AgendaItem] {
    agendaDisplaySections.flatMap(\.items)
  }

  public func selectAgendaItem(_ item: AgendaItem) {
    selectedSurface = .agenda
    select(.agenda(item))
  }

  public func moveAgendaSelection(by delta: Int) {
    let items = visibleAgendaItems
    guard !items.isEmpty else { return }

    let currentIndex = selectedAgendaItemID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
    let nextIndex: Int
    if let currentIndex {
      nextIndex = max(0, min(items.count - 1, currentIndex + delta))
    } else {
      nextIndex = delta < 0 ? items.count - 1 : 0
    }
    selectAgendaItem(items[nextIndex])
  }

  public func requestDetailScroll(_ direction: DetailScrollDirection) {
    detailScrollRequest = DetailScrollRequest(
      id: (detailScrollRequest?.id ?? 0) + 1,
      direction: direction
    )
  }

  public func selectFirstAgendaItem() {
    if let first = visibleAgendaItems.first {
      selectAgendaItem(first)
    }
  }

  public func selectLastAgendaItem() {
    if let last = visibleAgendaItems.last {
      selectAgendaItem(last)
    }
  }

  public func setAgendaModeFromKey(_ key: String) {
    if key == "1" { agendaMode = .focus }
    if key == "2" { agendaMode = .today }
    if key == "3" { agendaMode = .range }
    syncAgendaSelectionAfterRefresh()
  }

  public func focusAgendaFilter() {
    selectedSurface = .agenda
    agendaFilter = ""
    agendaFilterFocusToken += 1
  }

  public func clearAgendaFilter() {
    agendaFilter = ""
    syncAgendaSelectionAfterRefresh()
  }

  public func applyTodoShortcut(_ status: TodoEditStatus?) async {
    guard let item = selectedAgendaItemForMutation() else {
      statusText = "Select an agenda item first"
      return
    }
    let originalVisibleIndex = visibleAgendaItems.firstIndex(where: { $0.id == item.id })
    var shouldAdvanceSelection = status.map { Self.isTerminalTodoStatus($0.rawValue) } ?? false

    do {
      if let status {
        let _: TodoMutationPayload = try await cli.runJSON([
          "todo", "set",
          "--file", item.file,
          "--line", "\(item.lineForEditor)",
          "--status", status.rawValue,
          "--format", "json",
          "--apply"
        ])
        statusText = "\(status.label) -> \(item.headline)"
      } else {
        let payload: TodoMutationPayload = try await cli.runJSON([
          "todo", "toggle",
          "--file", item.file,
          "--line", "\(item.lineForEditor)",
          "--format", "json",
          "--apply"
        ])
        statusText = "\(payload.newStatus) -> \(item.headline)"
        shouldAdvanceSelection = Self.isTerminalTodoStatus(payload.newStatus)
      }
      invalidateCanonicalDocumentCache(for: item.file)
      await refreshAgenda()
      if shouldAdvanceSelection {
        selectNextActionableAgendaItem(afterMutating: item.id, originalVisibleIndex: originalVisibleIndex)
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "TODO update failed"
    }
  }

  public func applyPlanningShortcut(kind: PlanningEditKind, target: PlanningDateTarget) async {
    guard let item = selectedAgendaItemForMutation() else {
      statusText = "Select an agenda item first"
      return
    }

    let date = Self.dateString(for: target)
    do {
      let _: PlanMutationPayload = try await cli.runJSON([
        "plan", "set",
        "--file", item.file,
        "--line", "\(item.lineForEditor)",
        "--kind", kind.rawValue,
        "--date", date,
        "--format", "json",
        "--apply"
      ])
      statusText = "\(kind.rawValue.uppercased()) \(date) -> \(item.headline)"
      invalidateCanonicalDocumentCache(for: item.file)
      await refreshAgenda()
    } catch {
      errorText = error.localizedDescription
      statusText = "Planning update failed"
    }
  }

  public func applyAgentHandoffShortcut() async {
    guard let item = selectedAgendaItemForMutation() else {
      statusText = "Select an agenda item first"
      return
    }

    do {
      let _: TodoMutationPayload = try await cli.runJSON([
        "todo", "set",
        "--file", item.file,
        "--line", "\(item.lineForEditor)",
        "--status", TodoEditStatus.done.rawValue,
        "--format", "json",
        "--apply"
      ])
      try upsertHeadlineProperties(
        file: item.file,
        line: item.lineForEditor,
        properties: [
          "STATUS": "ready-for-agent",
          "ORG2_AGENT_HANDOFF_AT": Self.orgTimestamp(Date())
        ]
      )
      statusText = "Ready for agent -> \(Org2Display.cleanInline(item.headline))"
      invalidateCanonicalDocumentCache(for: item.file)
      await refreshAgenda()
    } catch {
      errorText = error.localizedDescription
      statusText = "Agent handoff failed"
    }
  }

  public func applyPriorityShortcut(_ priority: String?) async {
    guard let item = selectedAgendaItemForMutation() else {
      statusText = "Select an agenda item first"
      return
    }

    do {
      try updateHeadlinePriority(file: item.file, line: item.lineForEditor, priority: priority)
      statusText = priority.map { "Priority [#\($0)] -> \(Org2Display.cleanInline(item.headline))" }
        ?? "Priority cleared -> \(Org2Display.cleanInline(item.headline))"
      invalidateCanonicalDocumentCache(for: item.file)
      await refreshAgenda()
    } catch {
      errorText = error.localizedDescription
      statusText = "Priority update failed"
    }
  }

  public func promptAndApplyPropertyShortcut() {
    guard selectedAgendaItemForMutation() != nil else {
      statusText = "Select an agenda item first"
      return
    }

    let alert = NSAlert()
    alert.messageText = "Set Property"
    alert.informativeText = "Use KEY=VALUE on the selected headline."
    alert.addButton(withTitle: "Set")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "STATUS=ready-for-agent"
    alert.accessoryView = field

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    guard let assignment = Self.parsePropertyAssignment(field.stringValue) else {
      statusText = "Property edit canceled; use KEY=VALUE"
      return
    }

    Task { await applyPropertyShortcut(key: assignment.key, value: assignment.value) }
  }

  public func promptAndCaptureTodoShortcut() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }

    let alert = NSAlert()
    alert.messageText = "Capture TODO"
    alert.informativeText = "Append a scheduled TODO to today's daily note."
    alert.addButton(withTitle: "Capture")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = "Follow up"
    alert.accessoryView = field

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      statusText = "Capture canceled"
      return
    }

    Task { await captureTodo(title: title) }
  }

  public func captureTodo(title: String) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    do {
      let target = todayDailyNotePath(corpusRoot: corpusRoot)
      try appendScheduledTodo(title: title, to: target)
      statusText = "Captured TODO -> \(target.lastPathComponent)"
      invalidateCanonicalDocumentCache(for: target.path)
      await refreshAgenda()
    } catch {
      errorText = error.localizedDescription
      statusText = "Capture failed"
    }
  }

  public func applyPropertyShortcut(key: String, value: String) async {
    guard let item = selectedAgendaItemForMutation() else {
      statusText = "Select an agenda item first"
      return
    }

    do {
      try upsertHeadlineProperties(file: item.file, line: item.lineForEditor, properties: [key: value])
      statusText = "\(key)=\(value) -> \(Org2Display.cleanInline(item.headline))"
      invalidateCanonicalDocumentCache(for: item.file)
      await refreshAgenda()
    } catch {
      errorText = error.localizedDescription
      statusText = "Property update failed"
    }
  }

  public func handleWorkspaceKeyDown(_ event: NSEvent) -> Bool {
    if handleGlobalKeyDown(event) {
      return true
    }
    if handleDocumentKeyDown(event) {
      return true
    }
    return handleAgendaKeyDown(event)
  }

  public func handleGlobalKeyDown(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard modifiers == [.command] || modifiers == [.command, .shift] else {
      return false
    }

    let key = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()
    if modifiers == [.command] {
      switch key {
      case "0":
        isOpenClawAssistantPresented.toggle()
      case "1":
        selectedSurface = .agenda
      case "2":
        selectedSurface = .files
      case "3":
        focusSearchSurface()
      case "4":
        selectedSurface = .meetings
      case "5":
        selectedSurface = .openClaw
      case "6":
        selectedSurface = .agentSpace
      case "7":
        openDailyNote(.today)
      case "8":
        openDailyNote(.yesterday)
      case "9":
        openDailyNote(.tomorrow)
      case "f":
        focusSearchSurface()
      case "k", "p":
        presentQuickOpen()
      case "/":
        isKeyboardShortcutsPresented = true
      default:
        return false
      }
      return true
    }

    if modifiers == [.command, .shift],
       key == "/" || event.characters == "?" {
      isKeyboardShortcutsPresented = true
      return true
    }

    return false
  }

  public func handleDocumentKeyDown(_ event: NSEvent) -> Bool {
    guard selectedEntrySource?.isEditable == true,
          selectedBlock != nil,
          editingBlockID == nil,
          !isEditingEntry
    else {
      return false
    }

    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let key = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()

    if event.keyCode == 53, modifiers.isEmpty {
      clearSelectedBlock()
      return true
    }

    if event.keyCode == 36, modifiers.isEmpty {
      beginEditingSelectedBlock()
      return true
    }

    if event.keyCode == 36, modifiers == [.command] {
      Task { await insertBlockAfterSelected(.paragraph) }
      return true
    }

    if modifiers.isEmpty, key == "/" {
      Task { await insertBlockAfterSelected(.paragraph, initialText: "/") }
      return true
    }

    if modifiers.isEmpty {
      if event.keyCode == 126 || key == "k" {
        selectAdjacentBlock(.up)
        return true
      }
      if event.keyCode == 125 || key == "j" {
        selectAdjacentBlock(.down)
        return true
      }
      if event.keyCode == 123 {
        _ = collapseSelectedRenderedBlock()
        return true
      }
      if event.keyCode == 124 {
        _ = expandSelectedRenderedBlock()
        return true
      }
    }

    if modifiers == [.command] {
      if event.keyCode == 123 {
        collapseAllRenderedBlocks()
        return true
      }
      if event.keyCode == 124 {
        expandAllRenderedBlocks()
        return true
      }
    }

    if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty {
      Task { await deleteSelectedBlock() }
      return true
    }

    if modifiers == [.command], key == "d" {
      Task { await duplicateSelectedBlock() }
      return true
    }

    if modifiers == [.command, .shift] {
      if event.keyCode == 126 {
        Task { await moveSelectedBlock(.up) }
        return true
      }
      if event.keyCode == 125 {
        Task { await moveSelectedBlock(.down) }
        return true
      }
    }

    if modifiers.isEmpty,
       let insertionText = Self.directTypingInsertionText(from: event),
       beginEditingSelectedBlock(appending: insertionText) {
      return true
    }

    return false
  }

  public func handleAgendaKeyDown(_ event: NSEvent) -> Bool {
    guard selectedSurface == .agenda else { return false }

    let disallowedModifiers = event.modifierFlags.intersection([.command, .option])
    guard disallowedModifiers.isEmpty else { return false }

    if event.modifierFlags.contains(.control) {
      if event.charactersIgnoringModifiers == "d" {
        moveAgendaSelection(by: 8)
        return true
      }
      if event.charactersIgnoringModifiers == "u" {
        moveAgendaSelection(by: -8)
        return true
      }
      return false
    }

    let key = event.characters ?? event.charactersIgnoringModifiers ?? ""

    if priorityModeActive {
      if event.keyCode == 53 {
        priorityModeActive = false
        statusText = "Priority change canceled"
        return true
      }

      switch key.lowercased() {
      case "a", "b", "c":
        priorityModeActive = false
        Task { await applyPriorityShortcut(key.uppercased()) }
      case "0":
        priorityModeActive = false
        Task { await applyPriorityShortcut(nil) }
      default:
        statusText = "Priority mode: press a, b, c, or 0 to clear"
      }
      return true
    }

    switch event.keyCode {
    case 36:
      openSelectedLocation()
      return true
    case 49:
      Task { await applyTodoShortcut(nil) }
      return true
    case 53:
      clearAgendaFilter()
      return true
    case 125:
      moveAgendaSelection(by: 1)
      return true
    case 126:
      moveAgendaSelection(by: -1)
      return true
    default:
      break
    }

    if pendingG {
      pendingG = false
      if key == "g" {
        selectFirstAgendaItem()
        return true
      }
    }

    switch key {
    case "J":
      requestDetailScroll(.down)
    case "K":
      requestDetailScroll(.up)
    case "j":
      moveAgendaSelection(by: 1)
    case "k":
      moveAgendaSelection(by: -1)
    case "g":
      pendingG = true
    case "G":
      selectLastAgendaItem()
    case "1", "2", "3":
      setAgendaModeFromKey(key)
    case "/":
      focusAgendaFilter()
    case "r":
      Task { await refreshAgenda() }
    case "o":
      openSelectedLocation()
    case "e":
      beginEditingVisibleBlock()
    case "p":
      priorityModeActive = true
      statusText = "Priority mode: press a, b, c, or 0 to clear"
    case "P":
      promptAndApplyPropertyShortcut()
    case "c":
      promptAndCaptureTodoShortcut()
    case "t":
      Task { await applyTodoShortcut(.todo) }
    case "i":
      Task { await applyTodoShortcut(.inProgress) }
    case "d":
      Task { await applyTodoShortcut(.done) }
    case "x":
      Task { await applyTodoShortcut(.canceled) }
    case "A":
      Task { await applyAgentHandoffShortcut() }
    case "s":
      Task { await applyPlanningShortcut(kind: .scheduled, target: .today) }
    case "n":
      Task { await applyPlanningShortcut(kind: .scheduled, target: .tomorrow) }
    case "w":
      Task { await applyPlanningShortcut(kind: .scheduled, target: .upcomingMonday) }
    case "m":
      Task { await applyPlanningShortcut(kind: .scheduled, target: .nextMonth) }
    case "S":
      Task { await applyPlanningShortcut(kind: .deadline, target: .today) }
    case "N":
      Task { await applyPlanningShortcut(kind: .deadline, target: .tomorrow) }
    case "W":
      Task { await applyPlanningShortcut(kind: .deadline, target: .upcomingMonday) }
    case "M":
      Task { await applyPlanningShortcut(kind: .deadline, target: .nextMonth) }
    case "q":
      NSApplication.shared.terminate(nil)
    default:
      return false
    }
    return true
  }

  public func loadBacklinks(for location: WorkspaceLocation) async {
    backlinksLoadGeneration += 1
    let generation = backlinksLoadGeneration

    guard let corpusRoot else {
      backlinks = nil
      return
    }

    isLoadingBacklinks = true
    defer {
      if generation == backlinksLoadGeneration {
        isLoadingBacklinks = false
      }
    }

    do {
      guard let id = try await backlinkTargetID(for: location), !id.isEmpty else {
        guard generation == backlinksLoadGeneration, selectedLocationMatches(location) else { return }
        backlinks = nil
        return
      }

      let payload: BacklinksPayload = try await cli.runJSON([
        "backlinks",
        "--id", id,
        "--dir", corpusRoot.path,
        "--recursive",
        "--format", "json"
      ])
      guard generation == backlinksLoadGeneration, selectedLocationMatches(location) else { return }
      backlinks = payload
    } catch {
      guard generation == backlinksLoadGeneration, selectedLocationMatches(location) else { return }
      backlinks = nil
      errorText = error.localizedDescription
    }
  }

  private func backlinkTargetID(for location: WorkspaceLocation) async throws -> String? {
    if let id = location.idValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
      return id
    }

    do {
      let payload: OrgIDLookupPayload = try await cli.runJSON([
        "id", "get",
        "--file", location.file,
        "--line", "\(location.lineForEditor)",
        "--format", "json"
      ])
      applyResolvedID(payload.id, to: location)
      return payload.id
    } catch {
      return nil
    }
  }

  private func applyResolvedID(_ id: String, to location: WorkspaceLocation) {
    guard selectedLocationMatches(location) else { return }
    switch selectedLocation {
    case .openClaw(let thread):
      selectedLocation = .openClaw(OpenClawThread(
        title: thread.title,
        file: thread.file,
        line: thread.lineForEditor,
        zone: thread.zone,
        modifiedAt: thread.modifiedAt,
        idValue: id
      ))
    default:
      break
    }
  }

  public func openSelectedLocation() {
    guard let selectedLocation else { return }
    open(selectedLocation)
  }

  public func open(_ location: WorkspaceLocation) {
    openFile(path: location.file, line: location.lineForEditor)
  }

  public func revealSelectedLocation() {
    guard let selectedLocation else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedLocation.file)])
  }

  public func relativePath(_ path: String) -> String {
    guard let corpusRoot else { return path }
    let root = corpusRoot.standardizedFileURL.path
    if path == root { return "." }
    if path.hasPrefix(root + "/") {
      return String(path.dropFirst(root.count + 1))
    }
    return path
  }

  public var openClawContextRootText: String {
    effectiveOpenClawRemoteCorpusPath() ?? "Remote org2 root not configured"
  }

  private static func restoreAgendaMode(from defaults: UserDefaults, key: String) -> AgendaMode {
    guard let rawValue = defaults.string(forKey: key),
          let mode = AgendaMode(rawValue: rawValue)
    else {
      return .focus
    }
    return mode
  }

  private func restoreCorpusRoot() -> URL? {
    if let saved = defaults.string(forKey: corpusKey), isDirectory(saved) {
      return URL(fileURLWithPath: saved).standardizedFileURL
    }

    let candidates = [
      "/Users/avi/avi.org2",
      "/Users/avi/openclaw/aviaviavi-org2",
      "/Users/avi/clawd/aviaviavi-org2",
      "/Users/avi/dev/org2"
    ]

    return candidates.first(where: isDirectory).map {
      URL(fileURLWithPath: $0).standardizedFileURL
    }
  }

  private func currentOpenClawSettings(allowKeychainRead: Bool = false) -> OpenClawGatewaySettings {
    if allowKeychainRead,
       openClawBearerToken == nil,
       openClawHasStoredToken {
      openClawBearerToken = OpenClawKeychain.readToken(allowUserInteraction: true)
      openClawHasStoredToken = openClawBearerToken != nil || OpenClawKeychain.containsToken()
    }

    return OpenClawGatewaySettings.resolve(
      userEndpoint: openClawEndpointText,
      userBearerToken: openClawBearerToken
    )
  }

  private func currentOrgCryptSettings(allowKeychainRead: Bool = false) -> OrgCryptSettings {
    let passphrase = allowKeychainRead
      ? OrgCryptKeychain.readPassphrase(allowUserInteraction: true)
      : nil
    if allowKeychainRead {
      orgCryptHasStoredPassphrase = passphrase != nil || OrgCryptKeychain.containsPassphrase()
    }

    return OrgCryptSettings(
      encryptOnSave: orgCryptEncryptOnSave,
      recipients: OrgCryptSettings.splitListText(orgCryptRecipientsText),
      recipientFiles: OrgCryptSettings.splitListText(orgCryptRecipientFilesText),
      gpgProgram: orgCryptGpgProgram,
      passphrase: passphrase,
      useDefaultGpgKey: orgCryptUseDefaultGpgKey
    )
  }

  private func encryptOrgCryptSubtreesAfterExplicitSave(file: String) async throws -> Int {
    let settings = currentOrgCryptSettings(allowKeychainRead: true)
    guard settings.encryptOnSave else { return 0 }

    return try await Task.detached(priority: .userInitiated) {
      let url = URL(fileURLWithPath: file)
      let raw = try String(contentsOf: url, encoding: .utf8)
      let result = try OrgCrypt.encryptPlaintextCryptSubtrees(in: raw, file: file, settings: settings)
      guard result.encryptedCount > 0, result.text != raw else { return 0 }
      try result.text.write(to: url, atomically: true, encoding: .utf8)
      return result.encryptedCount
    }.value
  }

  private func persistOpenClawMessages() {
    do {
      try Self.saveOpenClawMessages(openClawMessages, to: openClawTranscriptURL)
    } catch {
      errorText = "OpenClaw transcript save failed: \(error.localizedDescription)"
    }
  }

  private func renderEntrySource(_ source: EntrySource, generation: Int) {
    isRenderingEntrySource = true
    let modifiedAt = Self.modificationDate(for: URL(fileURLWithPath: source.file).standardizedFileURL)
    if let blocks = cachedRenderedBlocks(for: source, modifiedAt: modifiedAt) {
      applyRenderedBlocks(blocks, for: source)
      isRenderingEntrySource = false
      return
    }

    Task { @MainActor in
      let blocks: [OrgEditableBlock]
      if source.endLineExclusive - source.startLine > Self.canonicalParserLineLimit {
        blocks = await Task.detached(priority: .userInitiated) {
          OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)
        }.value
      } else {
        do {
          let document = try await canonicalDocument(for: source)
          blocks = await Task.detached(priority: .userInitiated) {
            OrgEntryRenderer.parseEditable(
              source.text,
              baseLine: source.startLine,
              canonicalDocument: document
            )
          }.value
        } catch {
          blocks = await Task.detached(priority: .userInitiated) {
            OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)
          }.value
        }
      }
      guard generation == self.entrySourceLoadGeneration,
            self.selectedEntrySource?.id == source.id
      else {
        return
      }
      self.cacheRenderedBlocks(blocks, for: source, modifiedAt: modifiedAt)
      self.applyRenderedBlocks(blocks, for: source)
      self.isRenderingEntrySource = false
    }
  }

  private func applyRenderedBlocks(_ blocks: [OrgEditableBlock], for source: EntrySource) {
    let visibleBlocks = blocksWithTransientDraft(blocks, for: source)
    selectedRenderedBlocks = visibleBlocks
    if let pending = pendingBlockSelection,
       pending.file == source.file {
      let pendingBlock = blockForSelectionLine(pending.line, mode: pending.mode, in: visibleBlocks)
      selectedBlockID = pendingBlock?.id
      pendingBlockSelection = nil
      if pending.beginEditing,
         let pendingBlock,
         pendingBlock.isEditable,
         source.isEditable {
        editingBlockID = pendingBlock.id
        editableBlockText = pendingBlock.rawText
        activeBlockDrafts[pendingBlock.id] = pendingBlock.rawText
      }
    } else if let selectedBlockID,
       !visibleBlocks.contains(where: { $0.id == selectedBlockID }) {
      self.selectedBlockID = nil
    }
  }

  private func blocksWithTransientDraft(_ blocks: [OrgEditableBlock], for source: EntrySource) -> [OrgEditableBlock] {
    guard let draft = transientDraftBlock, draft.file == source.file else {
      return blocks
    }
    let coveredIDs = Set(draft.coveredBlocks.map(\.id))
    var visibleBlocks = blocks.filter { $0.id != draft.block.id && !coveredIDs.contains($0.id) }
    visibleBlocks.append(draft.block)
    return Self.sortEditableBlocksForDisplay(visibleBlocks)
  }

  private func canonicalDocument(for source: EntrySource) async throws -> Org2CanonicalDocument {
    if source.isSubtree || source.startLine != 1 {
      return try await cli.parseTextJSON(
        source.text,
        sourceRanges: true,
        sourceLineOffset: max(0, source.startLine - 1)
      )
    }

    return try await canonicalDocument(for: source.file)
  }

  private func canonicalDocument(for file: String) async throws -> Org2CanonicalDocument {
    let url = URL(fileURLWithPath: file).standardizedFileURL
    let modifiedAt = Self.modificationDate(for: url)
    let cacheKey = url.path
    if let cached = canonicalDocumentCache[cacheKey], cached.modifiedAt == modifiedAt {
      return cached.document
    }

    let document: Org2CanonicalDocument = try await cli.parseFileJSON(url, sourceRanges: true)
    canonicalDocumentCache[cacheKey] = CanonicalDocumentCacheEntry(
      modifiedAt: Self.modificationDate(for: url),
      document: document
    )
    return document
  }

  private func invalidateCanonicalDocumentCache(for file: String) {
    canonicalDocumentCache.removeValue(forKey: URL(fileURLWithPath: file).standardizedFileURL.path)
    invalidateRenderedBlocksCache(for: file)
  }

  private func renderedBlocksCacheKey(for source: EntrySource) -> String {
    let path = URL(fileURLWithPath: source.file).standardizedFileURL.path
    return "\(path)|\(source.startLine)|\(source.endLineExclusive)"
  }

  private func cacheRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    for source: EntrySource,
    modifiedAt: Date?
  ) {
    let key = renderedBlocksCacheKey(for: source)
    renderedBlocksCache[key] = RenderedBlocksCacheEntry(
      modifiedAt: modifiedAt,
      sourceID: source.id,
      textByteCount: source.text.utf8.count,
      blocks: blocks
    )
    renderedBlocksCacheOrder.removeAll { $0 == key }
    renderedBlocksCacheOrder.append(key)

    while renderedBlocksCacheOrder.count > Self.renderedBlocksCacheLimit {
      let evicted = renderedBlocksCacheOrder.removeFirst()
      renderedBlocksCache.removeValue(forKey: evicted)
    }
  }

  private func cachedRenderedBlocks(for source: EntrySource, modifiedAt: Date?) -> [OrgEditableBlock]? {
    let key = renderedBlocksCacheKey(for: source)
    guard let cached = renderedBlocksCache[key],
          cached.modifiedAt == modifiedAt,
          cached.sourceID == source.id,
          cached.textByteCount == source.text.utf8.count
    else {
      return nil
    }
    renderedBlocksCacheOrder.removeAll { $0 == key }
    renderedBlocksCacheOrder.append(key)
    return cached.blocks
  }

  private static func renderedBlocksSignature(for blocks: [OrgEditableBlock]) -> String {
    guard !blocks.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(blocks.count)
    for block in blocks {
      hasher.combine(block.id)
      hasher.combine(block.startLine)
      hasher.combine(block.endLineExclusive)
      hasher.combine(block.isEditable)
    }
    return "\(blocks.count):\(hasher.finalize())"
  }

  private static func renderedBlocksMetadata(for blocks: [OrgEditableBlock]) -> RenderedBlocksMetadata {
    guard !blocks.isEmpty else {
      return RenderedBlocksMetadata(renderSignature: "empty", structureSignature: "empty", indexes: [:])
    }

    var renderHasher = Hasher()
    var structureHasher = Hasher()
    renderHasher.combine(blocks.count)
    structureHasher.combine(blocks.count)

    var indexes: [OrgEditableBlock.ID: Int] = [:]
    indexes.reserveCapacity(blocks.count)

    for (index, block) in blocks.enumerated() {
      renderHasher.combine(block.renderIdentity.id)
      renderHasher.combine(block.renderIdentity.startLine)
      renderHasher.combine(block.renderIdentity.endLineExclusive)
      renderHasher.combine(block.renderIdentity.rawUTF8Count)
      renderHasher.combine(block.renderIdentity.rawHash)
      renderHasher.combine(block.renderIdentity.renderedKind)
      renderHasher.combine(block.isEditable)

      structureHasher.combine(block.id)
      structureHasher.combine(block.startLine)
      structureHasher.combine(block.endLineExclusive)
      structureHasher.combine(block.isEditable)

      indexes[block.id] = index
    }

    return RenderedBlocksMetadata(
      renderSignature: "\(blocks.count):\(renderHasher.finalize())",
      structureSignature: "\(blocks.count):\(structureHasher.finalize())",
      indexes: indexes
    )
  }

  nonisolated static func renderedBlocksRenderSignature(for blocks: [OrgEditableBlock]) -> String {
    guard !blocks.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(blocks.count)
    for block in blocks {
      hasher.combine(block.renderIdentity.id)
      hasher.combine(block.renderIdentity.startLine)
      hasher.combine(block.renderIdentity.endLineExclusive)
      hasher.combine(block.renderIdentity.rawUTF8Count)
      hasher.combine(block.renderIdentity.rawHash)
      hasher.combine(block.renderIdentity.renderedKind)
      hasher.combine(block.isEditable)
    }
    return "\(blocks.count):\(hasher.finalize())"
  }

  nonisolated static func sourceBlockRunsRenderSignature(for runs: [String: SourceBlockRunState]) -> String {
    guard !runs.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(runs.count)
    for key in runs.keys.sorted() {
      guard let state = runs[key] else { continue }
      hasher.combine(key)
      combineSourceBlockRunSignature(state, into: &hasher)
    }
    return "\(runs.count):\(hasher.finalize())"
  }

  nonisolated static func sourceBlockRunRenderSignature(for state: SourceBlockRunState?) -> String? {
    guard let state else { return nil }
    var hasher = Hasher()
    combineSourceBlockRunSignature(state, into: &hasher)
    return hasher.finalize().description
  }

  nonisolated private static func combineSourceBlockRunSignature(
    _ state: SourceBlockRunState,
    into hasher: inout Hasher
  ) {
    hasher.combine(sourceBlockRunStatusSignature(state.status))
    hasher.combine(state.language)
    hasher.combine(state.commandLabel)
    hasher.combine(state.startedAt)
    hasher.combine(state.finishedAt)
    hasher.combine(state.duration)
    hasher.combine(state.exitCode)
    hasher.combine(state.stdout.utf8.count)
    hasher.combine(state.stdout.hashValue)
    hasher.combine(state.stderr.utf8.count)
    hasher.combine(state.stderr.hashValue)
    hasher.combine(state.message)
  }

  nonisolated private static func sourceBlockRunStatusSignature(_ status: SourceBlockRunStatus) -> String {
    switch status {
    case .running: "running"
    case .succeeded: "succeeded"
    case .failed: "failed"
    case .timedOut: "timed-out"
    case .unsupported: "unsupported"
    }
  }

  private static func renderedBlockIndexes(for blocks: [OrgEditableBlock]) -> [OrgEditableBlock.ID: Int] {
    guard !blocks.isEmpty else { return [:] }

    var indexes: [OrgEditableBlock.ID: Int] = [:]
    indexes.reserveCapacity(blocks.count)
    for (index, block) in blocks.enumerated() {
      indexes[block.id] = index
    }
    return indexes
  }

  private func invalidateRenderedBlocksCache(for file: String) {
    let path = URL(fileURLWithPath: file).standardizedFileURL.path + "|"
    let keys = renderedBlocksCache.keys.filter { $0.hasPrefix(path) }
    for key in keys {
      renderedBlocksCache.removeValue(forKey: key)
    }
    renderedBlocksCacheOrder.removeAll { key in
      key.hasPrefix(path)
    }
  }

  private func currentOpenClawWorkspaceContext() -> OpenClawWorkspaceContext {
    let source: EntrySource?
    if isEditingEntry, let selectedEntrySource {
      source = EntrySource(
        file: selectedEntrySource.file,
        startLine: selectedEntrySource.startLine,
        endLineExclusive: selectedEntrySource.endLineExclusive,
        text: editableEntryText,
        isSubtree: selectedEntrySource.isSubtree,
        isEditable: selectedEntrySource.isEditable
      )
    } else {
      source = selectedEntrySource
    }

    return OpenClawWorkspaceContext(
      localCorpusRoot: corpusRoot?.standardizedFileURL.path,
      remoteCorpusRoot: effectiveOpenClawRemoteCorpusPath(),
      selectedSurface: selectedSurface.title,
      selectedLocation: selectedLocation,
      selectedEntrySource: source,
      backlinks: backlinks,
      agenda: agenda,
      searchQuery: searchQuery,
      searchResults: searchResults
    )
  }

  private func effectiveOpenClawRemoteCorpusPath() -> String? {
    let configured = openClawRemoteCorpusPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !configured.isEmpty { return configured }
    if openClawEndpointLooksLocal() {
      return corpusRoot?.standardizedFileURL.path
    }
    return nil
  }

  private func openClawEndpointLooksLocal() -> Bool {
    guard let normalized = OpenClawGatewaySettings.normalizedEndpointString(openClawEndpointText),
          let url = URL(string: normalized),
          let host = url.host?.lowercased()
    else {
      return false
    }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  private func localPathForOpenClawReference(_ rawPath: String) -> String? {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }

    var candidates: [String] = []
    if let corpusRoot,
       let remoteRoot = effectiveOpenClawRemoteCorpusPath().map(Self.trimTrailingSlashes) {
      let localRoot = Self.trimTrailingSlashes(corpusRoot.standardizedFileURL.path)
      let normalizedPath = Self.trimTrailingSlashes(path)
      if normalizedPath == remoteRoot {
        candidates.append(localRoot)
      } else if path.hasPrefix(remoteRoot + "/") {
        candidates.append(localRoot + "/" + String(path.dropFirst(remoteRoot.count + 1)))
      }
    }

    if path.hasPrefix("~/") {
      candidates.append(NSHomeDirectory() + "/" + String(path.dropFirst(2)))
    } else if NSString(string: path).isAbsolutePath {
      candidates.append(path)
    } else if let corpusRoot {
      candidates.append(corpusRoot.appendingPathComponent(path).standardizedFileURL.path)
    }

    for candidate in candidates {
      let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
      if FileManager.default.fileExists(atPath: standardized) {
        return standardized
      }
    }
    return nil
  }

  private static func trimTrailingSlashes(_ raw: String) -> String {
    var value = raw
    while value.count > 1 && value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }

  private static func defaultOpenClawStatusText() -> String {
    openClawStatusText(settings: OpenClawGatewaySettings.resolve())
  }

  private static func defaultMeetingStatusText() -> String {
    "Local transcription: \(LocalWhisperTranscriber.resolvedBackendDescription())"
  }

  private static func makeOpenClawSessionKey() -> String {
    "org2-workspace:\(UUID().uuidString)"
  }

  nonisolated private static func defaultOpenClawTranscriptURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base
      .appendingPathComponent("Org2Workspace", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
  }

  nonisolated private static func loadOpenClawMessages(from url: URL) -> [OpenClawChatMessage] {
    guard let data = try? Data(contentsOf: url),
          let payload = try? JSONDecoder().decode(OpenClawTranscriptPayload.self, from: data)
    else {
      return []
    }
    return payload.messages
  }

  nonisolated private static func saveOpenClawMessages(_ messages: [OpenClawChatMessage], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload = OpenClawTranscriptPayload(version: 1, messages: messages)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    try data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  nonisolated private static func modificationDate(for url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  nonisolated static func executeSourceBlock(
    _ source: OrgEditableSourceBlock,
    plan: SourceBlockRunPlan,
    workingDirectory: URL?,
    timeout: TimeInterval = 12,
    maxOutputCharacters: Int = 20_000
  ) throws -> SourceBlockExecutionResult {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("org2-source-run-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: tempDirectory)
    }

    let scriptURL = tempDirectory.appendingPathComponent("block.\(plan.scriptExtension)")
    try source.body.write(to: scriptURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: plan.executable)
    process.arguments = plan.arguments + [scriptURL.path]
    if let workingDirectory {
      process.currentDirectoryURL = workingDirectory
    }
    process.environment = ProcessInfo.processInfo.environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let stdoutCollector = SourceRunOutputCollector()
    let stderrCollector = SourceRunOutputCollector()
    let readGroup = DispatchGroup()

    try process.run()

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stdoutCollector.set(stdout.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }
    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stderrCollector.set(stderr.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }

    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false
    while process.isRunning {
      if Date() >= deadline {
        timedOut = true
        process.terminate()
        break
      }
      Thread.sleep(forTimeInterval: 0.03)
    }

    if timedOut {
      let terminationDeadline = Date().addingTimeInterval(1)
      while process.isRunning && Date() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.03)
      }
    }

    if process.isRunning {
      process.interrupt()
    }
    process.waitUntilExit()
    readGroup.wait()

    return SourceBlockExecutionResult(
      exitCode: process.terminationStatus,
      stdout: truncateOutput(String(data: stdoutCollector.data, encoding: .utf8) ?? "", maxCharacters: maxOutputCharacters),
      stderr: truncateOutput(String(data: stderrCollector.data, encoding: .utf8) ?? "", maxCharacters: maxOutputCharacters),
      timedOut: timedOut,
      timeout: timeout
    )
  }

  nonisolated private static func truncateOutput(_ text: String, maxCharacters: Int) -> String {
    guard text.count > maxCharacters else { return text }
    let prefix = text.prefix(maxCharacters)
    return "\(prefix)\n...[truncated \(text.count - maxCharacters) characters]"
  }

  private static func openClawStatusText(settings: OpenClawGatewaySettings) -> String {
    if settings.chatCompletionsEnabled != true {
      return "OpenClaw chat endpoint may need enabling in the local gateway config"
    }
    return "OpenClaw gateway: \(settings.endpoint.host ?? settings.endpoint.absoluteString)"
  }

  private func orgCryptStatusText(settings: OrgCryptSettings) -> String {
    var parts = [settings.encryptOnSave ? "Encrypt on save" : "Manual encryption"]
    if settings.passphrase != nil || orgCryptHasStoredPassphrase {
      parts.append("passphrase configured")
    }
    if settings.useDefaultGpgKey {
      parts.append("default GPG key")
    }
    if !settings.recipients.isEmpty {
      parts.append("\(settings.recipients.count) recipient\(settings.recipients.count == 1 ? "" : "s")")
    }
    if !settings.recipientFiles.isEmpty {
      parts.append("\(settings.recipientFiles.count) recipient file\(settings.recipientFiles.count == 1 ? "" : "s")")
    }
    parts.append("GPG: \(settings.gpgProgram)")
    return parts.joined(separator: " • ")
  }

  private func syncAgendaSelectionAfterRefresh(preserveSelection: Bool = false) {
    let items = visibleAgendaItems
    guard !items.isEmpty else {
      selectedAgendaItemID = nil
      if !preserveSelection, case .agenda = selectedLocation {
        selectedLocation = nil
        backlinks = nil
      }
      return
    }

    if let selectedAgendaItemID, let item = items.first(where: { $0.id == selectedAgendaItemID }) {
      if case .agenda = selectedLocation {
        if preserveSelection {
          selectedLocation = .agenda(item)
        } else {
          select(.agenda(item))
        }
      }
      return
    }

    if preserveSelection, case .agenda = selectedLocation {
      return
    }

    if selectedSurface == .agenda {
      selectAgendaItem(items[0])
    }
  }

  private func selectedAgendaItemForMutation() -> AgendaItem? {
    if case .agenda(let item) = selectedLocation {
      return item
    }
    if let selectedAgendaItemID {
      return visibleAgendaItems.first(where: { $0.id == selectedAgendaItemID })
    }
    return visibleAgendaItems.first
  }

  private func selectNextActionableAgendaItem(afterMutating mutatedID: String, originalVisibleIndex: Int?) {
    let items = visibleAgendaItems
    guard !items.isEmpty else { return }

    let actionableItems = items.enumerated().filter { offset, item in
      item.id != mutatedID && item.isActionable
    }
    guard !actionableItems.isEmpty else { return }

    let anchor = originalVisibleIndex ?? 0
    let selection = actionableItems.first { offset, _ in
      offset >= anchor
    } ?? actionableItems.last

    if let item = selection?.element {
      selectAgendaItem(item)
    }
  }

  private static func isTerminalTodoStatus(_ status: String) -> Bool {
    let normalized = status.uppercased()
    return normalized == "DONE" || normalized == "CANCELED" || normalized == "CANCELLED"
  }

  private func syncOpenClawSelectionAfterRefresh() {
    guard selectedSurface == .agentSpace, !openClawThreads.isEmpty else { return }
    if let selectedOpenClawThreadID,
       let thread = openClawThreads.first(where: { $0.id == selectedOpenClawThreadID }) {
      select(.openClaw(thread))
      return
    }
    selectOpenClawThread(openClawThreads[0])
  }

  nonisolated private static func entrySource(file: String, line: Int) throws -> EntrySource {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let normalized = normalizeLineEndings(raw)
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else {
      return EntrySource(file: file, startLine: 1, endLineExclusive: 1, text: "", isSubtree: false, isEditable: false)
    }

    let targetIndex = max(0, min(lines.count - 1, line - 1))
    if let headingIndex = headingIndex(in: lines, atOrBefore: targetIndex),
       let level = headingLevel(lines[headingIndex]) {
      let endIndex = subtreeEndIndex(lines: lines, headingIndex: headingIndex, level: level)
      let text = lines[headingIndex..<endIndex].joined(separator: "\n")
      return EntrySource(
        file: file,
        startLine: headingIndex + 1,
        endLineExclusive: endIndex + 1,
        text: text,
        isSubtree: true
      )
    }

    let text = lines[targetIndex]
    return EntrySource(
      file: file,
      startLine: targetIndex + 1,
      endLineExclusive: targetIndex + 2,
      text: text,
      isSubtree: false,
      isEditable: true
    )
  }

  nonisolated private static func pageSource(file: String) throws -> EntrySource {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let normalized = normalizeLineEndings(raw)
    let endLineExclusive = max(2, lineCount(in: normalized) + 1)
    return EntrySource(
      file: file,
      startLine: 1,
      endLineExclusive: endLineExclusive,
      text: normalized,
      isSubtree: false,
      isEditable: true
    )
  }

  nonisolated private static func lineCount(in text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return text.reduce(1) { count, character in
      character == "\n" ? count + 1 : count
    }
  }

  nonisolated private static func replaceEntrySource(_ source: EntrySource, with replacement: String) throws {
    try replaceSourceRange(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.endLineExclusive,
      replacement: replacement
    )
  }

  nonisolated private static func replacingSourceBlock(
    _ block: OrgEditableBlock,
    in source: EntrySource,
    with replacement: String
  ) throws -> EntrySource {
    try replacingSourceRange(
      in: source,
      startLine: block.startLine,
      endLineExclusive: block.endLineExclusive,
      replacement: replacement
    )
  }

  nonisolated private static func replacingSourceRange(
    in source: EntrySource,
    startLine: Int,
    endLineExclusive: Int,
    replacement: String
  ) throws -> EntrySource {
    var lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let startIndex = startLine - source.startLine
    let endIndex = endLineExclusive - source.startLine
    guard startIndex >= 0,
          startIndex <= lines.count,
          endIndex >= startIndex,
          endIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: startLine)
    }

    let normalizedReplacement = normalizeLineEndings(replacement)
    let replacementLines = normalizedReplacement.isEmpty
      ? []
      : normalizedReplacement
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    lines.replaceSubrange(startIndex..<endIndex, with: replacementLines)

    return EntrySource(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.startLine + lines.count,
      text: lines.joined(separator: "\n"),
      isSubtree: source.isSubtree,
      isEditable: source.isEditable
    )
  }

  nonisolated private static func deletingSourceRangeCleaningAdjacentBlank(
    in source: EntrySource,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> (source: EntrySource, startLine: Int, endLineExclusive: Int) {
    var lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let range = try adjustedDeletionRangeCleaningAdjacentBlank(
      in: lines,
      baseLine: source.startLine,
      file: source.file,
      startLine: startLine,
      endLineExclusive: endLineExclusive
    )
    lines.replaceSubrange(range.startIndex..<range.endIndex, with: [])

    return (
      source: EntrySource(
        file: source.file,
        startLine: source.startLine,
        endLineExclusive: source.startLine + lines.count,
        text: lines.joined(separator: "\n"),
        isSubtree: source.isSubtree,
        isEditable: source.isEditable
      ),
      startLine: range.startLine,
      endLineExclusive: range.endLineExclusive
    )
  }

  nonisolated private static func swappingSourceRanges(
    in source: EntrySource,
    firstStartLine: Int,
    firstEndLineExclusive: Int,
    secondStartLine: Int,
    secondEndLineExclusive: Int
  ) throws -> EntrySource {
    var lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let firstStartIndex = firstStartLine - source.startLine
    let firstEndIndex = firstEndLineExclusive - source.startLine
    let secondStartIndex = secondStartLine - source.startLine
    let secondEndIndex = secondEndLineExclusive - source.startLine
    guard firstStartIndex >= 0,
          firstStartIndex < firstEndIndex,
          firstEndIndex <= secondStartIndex,
          secondStartIndex < secondEndIndex,
          secondEndIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: firstStartLine)
    }

    let first = Array(lines[firstStartIndex..<firstEndIndex])
    let between = Array(lines[firstEndIndex..<secondStartIndex])
    let second = Array(lines[secondStartIndex..<secondEndIndex])
    lines.replaceSubrange(firstStartIndex..<secondEndIndex, with: second + between + first)

    return EntrySource(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.startLine + lines.count,
      text: lines.joined(separator: "\n"),
      isSubtree: source.isSubtree,
      isEditable: source.isEditable
    )
  }

  nonisolated private static func replaceSourceRange(file: String, startLine: Int, endLineExclusive: Int, replacement: String) throws {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    var lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let startIndex = startLine - 1
    let endIndex = endLineExclusive - 1
    guard startIndex >= 0, startIndex <= lines.count, endIndex >= startIndex, endIndex <= lines.count else {
      throw WorkspaceEditError.invalidRange(file: file, line: startLine)
    }

    let normalizedReplacement = normalizeLineEndings(replacement)
    let replacementLines = normalizedReplacement.isEmpty
      ? []
      : normalizedReplacement
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    lines.replaceSubrange(startIndex..<endIndex, with: replacementLines)

    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.hasSuffix("\n") {
      output += "\n"
    }
    try output.write(to: url, atomically: true, encoding: .utf8)
  }

  nonisolated private static func splitBlockPlan(
    for block: OrgEditableBlock,
    draft: String,
    utf16Offset: Int
  ) -> SplitBlockPlan? {
    switch block.rendered {
    case .paragraph:
      let normalizedDraft = normalizeLineEndings(draft)
      let split = splitText(normalizedDraft, atUTF16Offset: utf16Offset)
      let currentText = split.before.trimmingCharacters(in: .whitespacesAndNewlines)
      let nextText = split.after.trimmingCharacters(in: .whitespacesAndNewlines)

      if nextText.isEmpty {
        return SplitBlockPlan(
          replacement: currentText.isEmpty ? nil : currentText,
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: block.endLineExclusive - block.startLine,
            displayLineOffset: block.endLineExclusive - block.startLine,
            rawText: "",
            rendered: .paragraph(""),
            replacementPrefix: "\n",
            replacementSuffix: "",
            selectionLineOffset: 1
          )
        )
      }

      if currentText.isEmpty {
        return SplitBlockPlan(
          replacement: nextText,
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: 0,
            displayLineOffset: 0,
            rawText: "",
            rendered: .paragraph(""),
            replacementPrefix: "",
            replacementSuffix: "\n",
            selectionLineOffset: 0
          )
        )
      }

      return SplitBlockPlan(
        replacement: "\(currentText)\n\n\(nextText)",
        newBlockLineOffset: lineCount(in: currentText) + 1,
        draft: nil
      )
    case .listItem(let indent, let marker, let checkbox, _):
      let normalizedDraft = normalizeLineEndings(draft)
      let split = splitText(normalizedDraft, atUTF16Offset: utf16Offset)
      let firstBlock = split.before.trimmingCharacters(in: .newlines)
      let nextText = split.after.trimmingCharacters(in: .whitespacesAndNewlines)
      let prefix = continuedListPrefix(
        draft: normalizedDraft,
        fallbackMarker: marker,
        checkbox: checkbox
      )

      if nextText.isEmpty {
        return SplitBlockPlan(
          replacement: firstBlock.isEmpty ? nil : firstBlock,
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: block.endLineExclusive - block.startLine,
            displayLineOffset: block.endLineExclusive - block.startLine,
            rawText: prefix,
            rendered: .listItem(
              indent: indent,
              marker: marker,
              checkbox: checkbox == nil ? nil : .unchecked,
              text: ""
            ),
            replacementPrefix: "",
            replacementSuffix: "",
            selectionLineOffset: 0
          )
        )
      }

      if firstBlock.isEmpty {
        return SplitBlockPlan(
          replacement: "\(prefix)\(nextText)",
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: 0,
            displayLineOffset: 0,
            rawText: prefix,
            rendered: .listItem(
              indent: indent,
              marker: marker,
              checkbox: checkbox == nil ? nil : .unchecked,
              text: ""
            ),
            replacementPrefix: "",
            replacementSuffix: "",
            selectionLineOffset: 0
          )
        )
      }

      return SplitBlockPlan(
        replacement: "\(firstBlock)\n\(prefix)\(nextText)",
        newBlockLineOffset: lineCount(in: firstBlock),
        draft: nil
      )
    default:
      return nil
    }
  }

  nonisolated private static func transientDraftBlock(
    from spec: SplitDraftSpec,
    sourceFile: String,
    originalBlock: OrgEditableBlock
  ) -> TransientDraftBlock {
    let insertionLine = originalBlock.startLine + spec.insertionLineOffset
    let displayLine = originalBlock.startLine + spec.displayLineOffset
    return TransientDraftBlock(
      file: sourceFile,
      insertionLine: insertionLine,
      replacementEndLineExclusive: insertionLine,
      replacementPrefix: spec.replacementPrefix,
      replacementSuffix: spec.replacementSuffix,
      selectionLineOffset: spec.selectionLineOffset,
      block: OrgEditableBlock(
        startLine: displayLine,
        endLineExclusive: displayLine,
        rawText: spec.rawText,
        rendered: spec.rendered
      ),
      coveredBlocks: []
    )
  }

  nonisolated private static func normalizedTransientDraftText(
    _ raw: String,
    for block: OrgEditableBlock
  ) -> String? {
    let normalized = normalizeLineEndings(raw)
    switch block.rendered {
    case .paragraph:
      let text = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    case .heading:
      let text = normalized.trimmingCharacters(in: .newlines)
      guard headingDraftHasTitle(text) else { return nil }
      return text
    case .listItem:
      let text = normalized.trimmingCharacters(in: .newlines)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      guard let regex = try? NSRegularExpression(
        pattern: #"^\s*(?:[-+]|[0-9]+[.)])\s+(?:\[(?: |X|x|-)\]\s*)?"#
      ) else {
        return text
      }
      let nsText = text as NSString
      let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length))
      if let match,
         match.range.location == 0,
         match.range.length == nsText.length {
        return nil
      }
      return text
    default:
      let text = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }
  }

  nonisolated private static func headingDraftHasTitle(_ raw: String) -> Bool {
    let line = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else {
      return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var rest = String(line.dropFirst(stars.count)).trimmingCharacters(in: .whitespaces)
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    let todoKeywords = Set(["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"])
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if let first = tokens.first, todoKeywords.contains(first.uppercased()) {
      tokens.removeFirst()
    }
    if let first = tokens.first,
       first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }
    return !tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  nonisolated private static func sortEditableBlocksForDisplay(_ blocks: [OrgEditableBlock]) -> [OrgEditableBlock] {
    blocks.sorted { lhs, rhs in
      if lhs.startLine != rhs.startLine {
        return lhs.startLine < rhs.startLine
      }
      if lhs.endLineExclusive != rhs.endLineExclusive {
        return lhs.endLineExclusive < rhs.endLineExclusive
      }
      return lhs.id < rhs.id
    }
  }

  nonisolated private static func replacingBlock(
    _ original: OrgEditableBlock?,
    with replacement: OrgEditableBlock?,
    in blocks: [OrgEditableBlock]
  ) -> [OrgEditableBlock] {
    guard let original, let replacement else { return blocks }
    return blocks.map { block in
      block.id == original.id ? replacement : block
    }
  }

  nonisolated private static func locallyUpdatingRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    replacing original: OrgEditableBlock,
    with replacement: String
  ) -> [OrgEditableBlock] {
    let normalizedReplacement = normalizeLineEndings(replacement)
    let replacementBlocks = OrgEntryRenderer.parseEditable(
      normalizedReplacement,
      baseLine: original.startLine
    )
    let oldLineCount = original.endLineExclusive - original.startLine
    let newLineCount = normalizedReplacement.isEmpty ? 0 : lineCount(in: normalizedReplacement)
    let lineDelta = newLineCount - oldLineCount

    if lineDelta == 0,
       replacementBlocks.count == 1,
       let originalIndex = blocks.firstIndex(where: { $0.id == original.id }) {
      var updated = blocks
      updated[originalIndex] = replacementBlocks[0]
      return updated
    }

    var updated: [OrgEditableBlock] = []
    updated.reserveCapacity(blocks.count + max(0, replacementBlocks.count - 1))
    var insertedReplacement = false

    for block in blocks {
      if block.id == original.id {
        updated.append(contentsOf: replacementBlocks)
        insertedReplacement = true
        continue
      }

      if block.startLine >= original.endLineExclusive {
        updated.append(shiftedBlock(block, by: lineDelta))
      } else if block.endLineExclusive <= original.startLine {
        updated.append(block)
      } else {
        continue
      }
    }

    if !insertedReplacement {
      updated.append(contentsOf: replacementBlocks)
    }

    return sortEditableBlocksForDisplay(updated)
  }

  nonisolated private static func locallyInsertingRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    atLine insertionLine: Int,
    replacement: String
  ) -> [OrgEditableBlock] {
    let normalizedReplacement = normalizeLineEndings(replacement)
    let insertedBlocks = OrgEntryRenderer.parseEditable(
      normalizedReplacement,
      baseLine: insertionLine
    )
    let lineDelta = normalizedReplacement.isEmpty ? 0 : lineCount(in: normalizedReplacement)

    var updated: [OrgEditableBlock] = []
    updated.reserveCapacity(blocks.count + insertedBlocks.count)
    for block in blocks {
      if block.startLine >= insertionLine {
        updated.append(shiftedBlock(block, by: lineDelta))
      } else {
        updated.append(block)
      }
    }
    updated.append(contentsOf: insertedBlocks)
    return sortEditableBlocksForDisplay(updated)
  }

  nonisolated private static func locallyMovingRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    firstStartLine: Int,
    firstEndLineExclusive: Int,
    secondStartLine: Int,
    secondEndLineExclusive: Int
  ) -> [OrgEditableBlock] {
    let firstLineCount = firstEndLineExclusive - firstStartLine
    let secondLineCount = secondEndLineExclusive - secondStartLine
    let betweenLineCount = secondStartLine - firstEndLineExclusive
    let firstShift = secondLineCount + betweenLineCount
    let betweenShift = secondLineCount
    let secondShift = -(firstLineCount + betweenLineCount)

    var updated: [OrgEditableBlock] = []
    updated.reserveCapacity(blocks.count)

    for block in blocks {
      if block.endLineExclusive <= firstStartLine || block.startLine >= secondEndLineExclusive {
        updated.append(block)
      } else if block.startLine >= firstStartLine && block.endLineExclusive <= firstEndLineExclusive {
        updated.append(shiftedBlock(block, by: firstShift))
      } else if block.startLine >= firstEndLineExclusive && block.endLineExclusive <= secondStartLine {
        updated.append(shiftedBlock(block, by: betweenShift))
      } else if block.startLine >= secondStartLine && block.endLineExclusive <= secondEndLineExclusive {
        updated.append(shiftedBlock(block, by: secondShift))
      }
    }

    return sortEditableBlocksForDisplay(updated)
  }

  nonisolated private static func locallyDeletingRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    startLine: Int,
    endLineExclusive: Int
  ) -> [OrgEditableBlock] {
    let lineDelta = startLine - endLineExclusive
    var updated: [OrgEditableBlock] = []
    updated.reserveCapacity(blocks.count)

    for block in blocks {
      if block.endLineExclusive <= startLine {
        updated.append(block)
      } else if block.startLine >= endLineExclusive {
        updated.append(shiftedBlock(block, by: lineDelta))
      }
    }

    return sortEditableBlocksForDisplay(updated)
  }

  nonisolated private static func shiftedBlock(_ block: OrgEditableBlock, by lineDelta: Int) -> OrgEditableBlock {
    guard lineDelta != 0 else { return block }
    return OrgEditableBlock(
      id: "\(block.startLine + lineDelta):\(block.endLineExclusive + lineDelta):\(renderedBlockKindName(block.rendered))",
      startLine: block.startLine + lineDelta,
      endLineExclusive: block.endLineExclusive + lineDelta,
      rawText: block.rawText,
      rendered: block.rendered
    )
  }

  nonisolated private static func renderedBlockKindName(_ block: OrgRenderedBlock) -> String {
    switch block {
    case .heading: "heading"
    case .planning: "planning"
    case .properties: "properties"
    case .quote: "quote"
    case .source: "source"
    case .table: "table"
    case .horizontalRule: "horizontal-rule"
    case .listItem: "list"
    case .paragraph: "paragraph"
    case .keyword: "keyword"
    case .blank: "blank"
    }
  }

  nonisolated private static func continuedListPrefix(
    draft: String,
    fallbackMarker: String,
    checkbox: OrgListCheckbox?
  ) -> String {
    let firstLine = draft.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let leadingWhitespace = String(firstLine.prefix { $0 == " " || $0 == "\t" })
    let withoutLeading = firstLine.dropFirst(leadingWhitespace.count)
    let marker = String(withoutLeading.prefix { !$0.isWhitespace })
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let markerText = marker.isEmpty ? fallbackMarker : String(marker)
    let checkboxText = checkbox == nil ? "" : "[ ] "
    return "\(leadingWhitespace)\(markerText) \(checkboxText)"
  }

  nonisolated private static func splitText(_ text: String, atUTF16Offset offset: Int) -> (before: String, after: String) {
    let ns = text as NSString
    let clampedOffset = max(0, min(offset, ns.length))
    return (
      ns.substring(to: clampedOffset),
      ns.substring(from: clampedOffset)
    )
  }

  nonisolated private static func toggledListItemCheckboxRawText(
    _ rawText: String,
    current: OrgListCheckbox
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"^(\s*(?:[-+]|[0-9]+[.)])\s+)\[( |X|x|-)\](\s+)"#) else {
      return nil
    }

    let range = NSRange(location: 0, length: (first as NSString).length)
    guard let match = regex.firstMatch(in: first, range: range),
          match.range.location == 0
    else {
      return nil
    }

    let prefix = (first as NSString).substring(with: match.range(at: 1))
    let suffix = (first as NSString).substring(with: match.range(at: 3))
    let restLocation = match.range.location + match.range.length
    let restLength = max(0, (first as NSString).length - restLocation)
    let rest = (first as NSString).substring(with: NSRange(location: restLocation, length: restLength))
    lines[0] = "\(prefix)\(current.toggled.rawMarker)\(suffix)\(rest)"
    return lines.joined(separator: "\n")
  }

  nonisolated private static func toggledHeadingTodoRawText(
    _ rawText: String,
    current: String,
    next: String
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"^(\*+\s+)(\S+)(.*)$"#) else {
      return nil
    }

    let nsFirst = first as NSString
    let range = NSRange(location: 0, length: nsFirst.length)
    guard let match = regex.firstMatch(in: first, range: range),
          match.range.location == 0
    else {
      return nil
    }

    let keyword = nsFirst.substring(with: match.range(at: 2)).uppercased()
    guard keyword == current.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
      return nil
    }

    let prefix = nsFirst.substring(with: match.range(at: 1))
    let suffix = nsFirst.substring(with: match.range(at: 3))
    lines[0] = "\(prefix)\(next)\(suffix)"
    return lines.joined(separator: "\n")
  }

  nonisolated private static func headingRawTextSettingPriority(
    _ rawText: String,
    priority: String?
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"^(\*+\s+)(.*)$"#) else {
      return nil
    }

    let nsFirst = first as NSString
    let range = NSRange(location: 0, length: nsFirst.length)
    guard let match = regex.firstMatch(in: first, range: range),
          match.range.location == 0
    else {
      return nil
    }

    let prefix = nsFirst.substring(with: match.range(at: 1))
    let rest = nsFirst.substring(with: match.range(at: 2))
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var outputTokens: [String] = []

    if let firstToken = tokens.first,
       allHeadingTodoKeywords.contains(firstToken.uppercased()) {
      outputTokens.append(firstToken.uppercased())
      tokens.removeFirst()
    }

    if let firstToken = tokens.first,
       firstToken.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }

    if let priority = normalizedHeadingPriority(priority) {
      outputTokens.append("[#\(priority)]")
    }
    outputTokens.append(contentsOf: tokens)

    lines[0] = "\(prefix)\(outputTokens.joined(separator: " "))"
    return lines.joined(separator: "\n")
  }

  nonisolated private static func normalizedHeadingPriority(_ priority: String?) -> String? {
    guard var priority = priority?.trimmingCharacters(in: .whitespacesAndNewlines),
          !priority.isEmpty
    else {
      return nil
    }
    priority = priority
      .replacingOccurrences(of: "[#", with: "")
      .replacingOccurrences(of: "]", with: "")
      .uppercased()
    guard priority.range(of: #"^[A-Z0-9]$"#, options: .regularExpression) != nil else {
      return nil
    }
    return priority
  }

  nonisolated private static func headingRawTextSettingTags(
    _ rawText: String,
    tags: [String]
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"^(\*+\s+)(.*)$"#) else {
      return nil
    }

    let nsFirst = first as NSString
    let range = NSRange(location: 0, length: nsFirst.length)
    guard let match = regex.firstMatch(in: first, range: range),
          match.range.location == 0
    else {
      return nil
    }

    let prefix = nsFirst.substring(with: match.range(at: 1))
    var rest = nsFirst.substring(with: match.range(at: 2))
      .trimmingCharacters(in: .whitespaces)
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    let normalizedTags = normalizedHeadingTags(tags)
    let tagSuffix = normalizedTags.isEmpty ? "" : " :\(normalizedTags.joined(separator: ":")):"
    lines[0] = "\(prefix)\(rest)\(tagSuffix)"
    return lines.joined(separator: "\n")
  }

  private func syncMeetingSelectionAfterRefresh() {
    guard selectedSurface == .meetings, !meetings.isEmpty else { return }
    if let selectedMeetingID,
       let meeting = meetings.first(where: { $0.id == selectedMeetingID }) {
      select(.meeting(meeting))
      return
    }
    selectMeeting(meetings[0])
  }

  private func startMeetingInputMetering() {
    meetingMeterTask?.cancel()
    updateMeetingInputMeter()
    meetingMeterTask = Task { [weak self] in
      while !Task.isCancelled {
        let shouldContinue = await MainActor.run { () -> Bool in
          guard let self, self.isRecordingMeeting else { return false }
          self.updateMeetingInputMeter()
          return true
        }
        guard shouldContinue else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  private func stopMeetingInputMetering() {
    meetingMeterTask?.cancel()
    meetingMeterTask = nil
    meetingInputAverageLevel = 0
    meetingInputPeakLevel = 0
    meetingSystemAudioAverageLevel = 0
    meetingSystemAudioPeakLevel = 0
  }

  private func updateMeetingInputMeter() {
    let snapshot = meetingRecorder.inputMeterSnapshot
    meetingInputAverageLevel = snapshot.averageLevel
    meetingInputPeakLevel = snapshot.peakLevel
    let systemSnapshot = meetingSystemAudioRecorder.inputMeterSnapshot
    meetingSystemAudioAverageLevel = systemSnapshot.averageLevel
    meetingSystemAudioPeakLevel = systemSnapshot.peakLevel
  }

  private func transcribeRecordedMeetingAudio(
    microphoneAudioURL: URL,
    systemAudioURL: URL?,
    systemAudioCaptureError: String?
  ) async -> MeetingTranscriptResult {
    guard let systemAudioURL else {
      let microphone = await transcribeAudioForMeeting(microphoneAudioURL)
      return MeetingTranscriptResult.combined(
        microphone: microphone,
        systemAudio: nil,
        systemAudioCaptureError: systemAudioCaptureError
      )
    }

    async let microphone = transcribeAudioForMeeting(microphoneAudioURL)
    async let systemAudio = transcribeAudioForMeeting(systemAudioURL)
    return await MeetingTranscriptResult.combined(
      microphone: microphone,
      systemAudio: systemAudio,
      systemAudioCaptureError: systemAudioCaptureError
    )
  }

  private func transcribeAudioForMeeting(_ audioURL: URL) async -> MeetingTranscriptResult {
    do {
      return try await LocalWhisperTranscriber().transcribe(audioURL: audioURL)
    } catch {
      let localError = error as? LocalWhisperError
      let status: MeetingTranscriptionStatus = localError == .notConfigured
        ? .unavailable
        : .failed
      return MeetingTranscriptResult(
        text: "",
        status: status,
        engine: LocalWhisperTranscriber.resolvedBackendDescription(),
        errorMessage: error.localizedDescription
      )
    }
  }

  private func refreshAfterMeetingWrite(selecting item: MeetingWorkspaceItem) async {
    await refreshMeetings()
    if let refreshed = meetings.first(where: { $0.file == item.file }) {
      selectMeeting(refreshed)
    } else {
      meetings.insert(item, at: 0)
      selectMeeting(item)
    }
    await refreshAgenda()
    Task { await refreshOpenClawThreads() }
  }

  nonisolated private static func normalizedHeadingTags(_ tags: [String]) -> [String] {
    var seen: Set<String> = []
    var output: [String] = []
    for tag in tags {
      let normalized = tag
        .trimmingCharacters(in: CharacterSet(charactersIn: "#: \n\t"))
      guard !normalized.isEmpty,
            normalized.range(of: #"^[A-Za-z0-9_@#%.-]+$"#, options: .regularExpression) != nil,
            !seen.contains(normalized)
      else {
        continue
      }
      seen.insert(normalized)
      output.append(normalized)
    }
    return output
  }

  nonisolated private static func propertyDrawerRawTextSettingValue(
    _ rawText: String,
    key: String,
    value: String
  ) -> String? {
    let normalizedKey = normalizedPropertyKey(key)
    guard !normalizedKey.isEmpty, normalizedKey != "PROPERTIES", normalizedKey != "END" else {
      return nil
    }

    var drawer = OrgEditablePropertyDrawer(rawText: rawText)
    guard let index = drawer.rows.firstIndex(where: { $0.normalizedKey == normalizedKey }) else {
      return nil
    }
    drawer.setValue(at: index, value: value)
    return drawer.formattedRawText
  }

  nonisolated private static func normalizedPropertyKey(_ key: String) -> String {
    key
      .trimmingCharacters(in: CharacterSet(charactersIn: ": \t\r\n"))
      .uppercased()
  }

  nonisolated private static func planningRawText(kind: String, value: String) -> String? {
    let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard planningKinds.contains(normalizedKind) else { return nil }
    let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedValue.isEmpty else { return nil }
    return "\(normalizedKind): \(normalizedValue)"
  }

  nonisolated private static let activeHeadingTodoKeywords = Set([
    "TODO",
    "IN_PROGRESS",
    "PROG",
    "WAIT",
    "HOLD",
    "PAUSED"
  ])

  nonisolated private static let doneHeadingTodoKeywords = Set([
    "DONE",
    "CANCELED",
    "CANCELLED"
  ])

  nonisolated private static let allHeadingTodoKeywords = activeHeadingTodoKeywords.union(doneHeadingTodoKeywords)
  nonisolated private static let planningKinds = Set(["SCHEDULED", "DEADLINE", "CLOSED"])

  nonisolated private static func deleteSourceRangeCleaningAdjacentBlank(
    file: String,
    startLine: Int,
    endLineExclusive: Int
  ) throws {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    var lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let range = try adjustedDeletionRangeCleaningAdjacentBlank(
      in: lines,
      baseLine: 1,
      file: file,
      startLine: startLine,
      endLineExclusive: endLineExclusive
    )

    lines.replaceSubrange(range.startIndex..<range.endIndex, with: [])
    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.hasSuffix("\n") {
      output += "\n"
    }
    try output.write(to: url, atomically: true, encoding: .utf8)
  }

  nonisolated private static func adjustedDeletionRangeCleaningAdjacentBlank(
    in lines: [String],
    baseLine: Int,
    file: String,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> (startIndex: Int, endIndex: Int, startLine: Int, endLineExclusive: Int) {
    var startIndex = startLine - baseLine
    var endIndex = endLineExclusive - baseLine
    guard startIndex >= 0,
          startIndex <= lines.count,
          endIndex >= startIndex,
          endIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: file, line: startLine)
    }

    if startIndex > 0,
       lines[startIndex - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      startIndex -= 1
    } else if endIndex < lines.count,
              lines[endIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      endIndex += 1
    }

    return (
      startIndex: startIndex,
      endIndex: endIndex,
      startLine: baseLine + startIndex,
      endLineExclusive: baseLine + endIndex
    )
  }

  nonisolated private static func swapSourceRanges(
    file: String,
    firstStartLine: Int,
    firstEndLineExclusive: Int,
    secondStartLine: Int,
    secondEndLineExclusive: Int
  ) throws {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    var lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let firstStartIndex = firstStartLine - 1
    let firstEndIndex = firstEndLineExclusive - 1
    let secondStartIndex = secondStartLine - 1
    let secondEndIndex = secondEndLineExclusive - 1
    guard firstStartIndex >= 0,
          firstStartIndex < firstEndIndex,
          firstEndIndex <= secondStartIndex,
          secondStartIndex < secondEndIndex,
          secondEndIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: file, line: firstStartLine)
    }

    let first = Array(lines[firstStartIndex..<firstEndIndex])
    let between = Array(lines[firstEndIndex..<secondStartIndex])
    let second = Array(lines[secondStartIndex..<secondEndIndex])
    lines.replaceSubrange(firstStartIndex..<secondEndIndex, with: second + between + first)

    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.hasSuffix("\n") {
      output += "\n"
    }
    try output.write(to: url, atomically: true, encoding: .utf8)
  }

  nonisolated private static func scanOpenClawThreads(corpusRoot: URL) throws -> [OpenClawThread] {
    let fileManager = FileManager.default
    let directories = openClawThreadDirectories(corpusRoot: corpusRoot)
    var threads: [OpenClawThread] = []
    let allowedExtensions = Set(["org", "org2", "md", "txt", "log", "json", "jsonl"])

    for directory in directories where isDirectoryURL(directory) {
      guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) else {
        continue
      }

      for case let fileURL as URL in enumerator {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { continue }

        let ext = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { continue }
        if fileURL.lastPathComponent.hasSuffix(".transcript.org2") { continue }

        let prefix = (try? readPrefix(fileURL, maxBytes: 48 * 1024)) ?? ""
        let titleInfo = openClawTitle(from: prefix, fallback: fileURL.deletingPathExtension().lastPathComponent)
        let zone = openClawZone(fileURL: fileURL, corpusRoot: corpusRoot, directory: directory)
        threads.append(OpenClawThread(
          title: titleInfo.title,
          file: fileURL.path,
          line: titleInfo.line,
          zone: zone,
          modifiedAt: values?.contentModificationDate,
          idValue: firstOrgID(in: prefix)
        ))
      }
    }

    return threads
      .sorted {
        let left = $0.modifiedAt ?? .distantPast
        let right = $1.modifiedAt ?? .distantPast
        if left != right { return left > right }
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
      .prefix(250)
      .map { $0 }
  }

  nonisolated private static func scanMeetingItems(corpusRoot: URL) throws -> [MeetingWorkspaceItem] {
    let fileManager = FileManager.default
    let meetingsDirectory = corpusRoot.appendingPathComponent("meetings", isDirectory: true)
    guard isDirectoryURL(meetingsDirectory),
          let enumerator = fileManager.enumerator(
            at: meetingsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
          )
    else {
      return []
    }

    var items: [MeetingWorkspaceItem] = []
    for case let fileURL as URL in enumerator {
      let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      guard values?.isRegularFile == true,
            fileURL.pathExtension.lowercased() == "org2",
            !fileURL.lastPathComponent.hasSuffix(".transcript.org2")
      else {
        continue
      }

      let prefix = (try? readPrefix(fileURL, maxBytes: 96 * 1024)) ?? ""
      guard meetingProperty("kind", in: prefix)?.lowercased() == "meeting"
        || prefix.contains("#+ORG2_KIND: meeting")
      else {
        continue
      }

      let titleInfo = openClawTitle(from: prefix, fallback: fileURL.deletingPathExtension().lastPathComponent)
      items.append(MeetingWorkspaceItem(
        title: titleInfo.title.replacingOccurrences(of: #"^Meeting:\s*"#, with: "", options: .regularExpression),
        file: fileURL.path,
        line: titleInfo.line,
        recordedAt: meetingProperty("recorded_at", in: prefix),
        modifiedAt: values?.contentModificationDate,
        audioArtifact: meetingProperty("audio_artifact", in: prefix),
        systemAudioArtifact: meetingProperty("system_audio_artifact", in: prefix),
        transcriptArtifact: meetingProperty("transcript_artifact", in: prefix),
        transcriptionStatus: meetingProperty("transcription_status", in: prefix),
        idValue: firstOrgID(in: prefix)
      ))
    }

    return items.sorted {
      let leftRecorded = $0.recordedAt ?? ""
      let rightRecorded = $1.recordedAt ?? ""
      if leftRecorded != rightRecorded { return leftRecorded > rightRecorded }
      let leftModified = $0.modifiedAt ?? .distantPast
      let rightModified = $1.modifiedAt ?? .distantPast
      if leftModified != rightModified { return leftModified > rightModified }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  private func refreshOrgRoamLinkResolver(files: [CorpusFile]) {
    orgRoamLinkResolverGeneration += 1
    let generation = orgRoamLinkResolverGeneration
    Task {
      let resolver = await Task.detached(priority: .utility) {
        Self.buildOrgRoamLinkResolver(files: files)
      }.value
      guard generation == orgRoamLinkResolverGeneration else { return }
      orgRoamLinkResolver = resolver
    }
  }

  nonisolated static func buildOrgRoamLinkResolver(files: [CorpusFile]) -> OrgRoamLinkResolver {
    OrgRoamLinkResolver(nodes: files.flatMap(scanRoamNodes))
  }

  nonisolated private static func scanRoamNodes(file: CorpusFile) -> [OrgRoamNodeReference] {
    guard let raw = try? String(contentsOf: URL(fileURLWithPath: file.path), encoding: .utf8) else {
      return []
    }

    let lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var nodes: [OrgRoamNodeReference] = []
    var fileTitle: (value: String, line: Int)?
    var fileAliases: [String] = []
    var fileID: String?
    var currentHeading: RoamHeadingDraft?

    func flushCurrentHeading() {
      guard let heading = currentHeading else { return }
      nodes.append(OrgRoamNodeReference(
        idValue: heading.idValue,
        title: heading.title,
        aliases: heading.aliases,
        file: file.path,
        line: heading.line
      ))
      currentHeading = nil
    }

    for (index, line) in lines.enumerated() {
      let lineNumber = index + 1

      if let headingTitle = roamHeadingTitle(line) {
        flushCurrentHeading()
        currentHeading = RoamHeadingDraft(title: headingTitle, line: lineNumber)
        continue
      }

      if let keyword = roamKeyword(line) {
        switch keyword.key {
        case "TITLE":
          if fileTitle == nil {
            fileTitle = (Org2Display.cleanInline(keyword.value), lineNumber)
          }
        case "ID":
          if currentHeading == nil, fileID == nil {
            fileID = keyword.value
          }
        case "ROAM_ALIASES", "ROAM_ALIAS":
          if currentHeading == nil {
            fileAliases.append(contentsOf: parseRoamAliases(keyword.value))
          } else {
            currentHeading?.aliases.append(contentsOf: parseRoamAliases(keyword.value))
          }
        default:
          break
        }
        continue
      }

      if let property = roamProperty(line) {
        switch property.key {
        case "ID":
          if currentHeading == nil {
            fileID = fileID ?? property.value
          } else if currentHeading?.idValue == nil {
            currentHeading?.idValue = property.value
          }
        case "ROAM_ALIASES", "ROAM_ALIAS":
          if currentHeading == nil {
            fileAliases.append(contentsOf: parseRoamAliases(property.value))
          } else {
            currentHeading?.aliases.append(contentsOf: parseRoamAliases(property.value))
          }
        default:
          break
        }
      }
    }

    flushCurrentHeading()
    let fallbackFileTitle = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
    let resolvedFileTitle = fileTitle?.value ?? fallbackFileTitle
    if fileTitle != nil || fileID != nil || !fileAliases.isEmpty {
      nodes.append(OrgRoamNodeReference(
        idValue: fileID,
        title: resolvedFileTitle,
        aliases: fileAliases,
        file: file.path,
        line: fileTitle?.line ?? 1
      ))
    }
    return nodes
  }

  private struct RoamHeadingDraft {
    var title: String
    var line: Int
    var idValue: String?
    var aliases: [String] = []
  }

  nonisolated private static func roamKeyword(_ line: String) -> (key: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#+"), let colon = trimmed.firstIndex(of: ":") else { return nil }
    let keyStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
    let key = String(trimmed[keyStart..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let valueStart = trimmed.index(after: colon)
    let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !value.isEmpty else { return nil }
    return (key, value)
  }

  nonisolated private static func roamProperty(_ line: String) -> (key: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(":"),
          let keyEnd = trimmed.dropFirst().firstIndex(of: ":")
    else {
      return nil
    }
    let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<keyEnd]).uppercased()
    let valueStart = trimmed.index(after: keyEnd)
    let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !value.isEmpty else { return nil }
    return (key, value)
  }

  nonisolated private static func roamHeadingTitle(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, first == "*" else { return nil }
    let starCount = trimmed.prefix { $0 == "*" }.count
    guard trimmed.count > starCount else { return nil }
    let afterStars = trimmed.dropFirst(starCount)
    guard afterStars.first?.isWhitespace == true else { return nil }

    var tokens = afterStars
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !tokens.isEmpty else { return nil }

    if let last = tokens.last, isTagSuffix(last) {
      tokens.removeLast()
    }
    if let first = tokens.first, roamTodoKeywords.contains(first.uppercased()) {
      tokens.removeFirst()
    }
    if let first = tokens.first, first.range(of: #"^\[#.\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }

    let title = Org2Display.cleanInline(tokens.joined(separator: " "))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }

  nonisolated private static func parseRoamAliases(_ raw: String) -> [String] {
    var aliases: [String] = []
    var current = ""
    var isQuoted = false
    var iterator = raw.makeIterator()

    while let character = iterator.next() {
      if character == "\"" {
        if isQuoted {
          let alias = current.trimmingCharacters(in: .whitespacesAndNewlines)
          if !alias.isEmpty { aliases.append(alias) }
          current = ""
          isQuoted = false
        } else {
          if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aliases.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
          }
          isQuoted = true
        }
        continue
      }

      if character.isWhitespace && !isQuoted {
        let alias = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alias.isEmpty { aliases.append(alias) }
        current = ""
      } else {
        current.append(character)
      }
    }

    let alias = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !alias.isEmpty { aliases.append(alias) }
    return aliases
  }

  nonisolated private static func isTagSuffix(_ raw: String) -> Bool {
    raw.count > 2
      && raw.first == ":"
      && raw.last == ":"
      && raw.dropFirst().dropLast().allSatisfy { character in
        character.isLetter || character.isNumber || character == "_" || character == "@" || character == "#"
      }
  }

  nonisolated private static let roamTodoKeywords = Set([
    "TODO", "OPEN", "BACKLOG", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"
  ])

  nonisolated private static func scanCorpusFiles(corpusRoot: URL) throws -> [CorpusFile] {
    let root = corpusRoot.standardizedFileURL
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
    let skippedDirectories = Set([".git", ".hg", ".svn", ".trash", "node_modules", "dist", "build", ".build", "DerivedData"])
    let allowedExtensions = Set(["org", "org2", "md"])
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    var files: [CorpusFile] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: resourceKeys)
      if values.isDirectory == true {
        if skippedDirectories.contains(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }

      guard values.isRegularFile == true,
            allowedExtensions.contains(url.pathExtension.lowercased())
      else {
        continue
      }

      let path = url.standardizedFileURL.path
      let relativePath = path.hasPrefix(root.path + "/")
        ? String(path.dropFirst(root.path.count + 1))
        : url.lastPathComponent
      files.append(CorpusFile(
        path: path,
        relativePath: relativePath,
        modifiedAt: values.contentModificationDate,
        byteCount: values.fileSize.map(Int64.init)
      ))
    }

    return files.sorted {
      $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
  }

  nonisolated private static func fuzzyScore(query: String, candidate: String) -> Int? {
    let query = query.lowercased().filter { !$0.isWhitespace }
    guard !query.isEmpty else { return 0 }

    let candidate = candidate.lowercased()
    var score = 0
    var queryIndex = query.startIndex
    var previousMatch: String.Index?

    for candidateIndex in candidate.indices {
      guard queryIndex < query.endIndex else { break }
      if candidate[candidateIndex] != query[queryIndex] { continue }

      score += 10
      if let previousMatch, candidate.index(after: previousMatch) == candidateIndex {
        score += 8
      }
      if candidateIndex == candidate.startIndex {
        score += 6
      } else {
        let previous = candidate[candidate.index(before: candidateIndex)]
        if ["/", "-", "_", ".", " "].contains(previous) {
          score += 6
        }
      }
      previousMatch = candidateIndex
      queryIndex = query.index(after: queryIndex)
    }

    guard queryIndex == query.endIndex else { return nil }
    if candidate.contains(query) { score += 30 }
    if candidate.hasSuffix(query) { score += 20 }
    score -= max(0, candidate.count - query.count) / 8
    return score
  }

  nonisolated private static func normalizeLineEndings(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }

  nonisolated private static func headingIndex(in lines: [String], atOrBefore targetIndex: Int) -> Int? {
    var cursor = targetIndex
    while cursor >= 0 {
      if headingLevel(lines[cursor]) != nil {
        return cursor
      }
      cursor -= 1
    }
    return nil
  }

  nonisolated private static func headingLevel(_ line: String) -> Int? {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return nil }
    let afterStars = line.dropFirst(stars.count)
    guard afterStars.first?.isWhitespace == true else { return nil }
    return stars.count
  }

  nonisolated private static func subtreeEndIndex(lines: [String], headingIndex: Int, level: Int) -> Int {
    guard headingIndex + 1 < lines.count else { return lines.count }
    for index in (headingIndex + 1)..<lines.count {
      guard let candidateLevel = headingLevel(lines[index]) else { continue }
      if candidateLevel <= level {
        return index
      }
    }
    return lines.count
  }

  nonisolated private static func openClawThreadDirectories(corpusRoot: URL) -> [URL] {
    let configured = workspaceConfig(corpusRoot: corpusRoot)?.openClaw?.threadDirs ?? []
    let rawDirectories = configured.isEmpty
      ? ["agents", "meetings", "notes/openclaw", "raw/openclaw", "views/openclaw"]
      : configured

    return rawDirectories.map { raw in
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if NSString(string: trimmed).isAbsolutePath {
        return URL(fileURLWithPath: trimmed).standardizedFileURL
      }
      return corpusRoot.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
    }
  }

  nonisolated private static func workspaceConfig(corpusRoot: URL) -> WorkspaceOrg2Config? {
    let configURL = corpusRoot.appendingPathComponent("org2.json")
    guard let data = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONDecoder().decode(WorkspaceOrg2Config.self, from: data)
  }

  nonisolated private static func isDirectoryURL(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  nonisolated private static func readPrefix(_ url: URL, maxBytes: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
  }

  nonisolated private static func openClawTitle(from prefix: String, fallback: String) -> (title: String, line: Int) {
    let lines = normalizeLineEndings(prefix)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.uppercased().hasPrefix("#+TITLE:") {
        let title = String(trimmed.dropFirst("#+TITLE:".count)).trimmingCharacters(in: .whitespaces)
        if !title.isEmpty {
          return (Org2Display.cleanInline(title), index + 1)
        }
      }
      if let heading = OrgEntryRenderer.parse(line).compactMap({ block -> OrgHeadingBlock? in
        if case .heading(let heading) = block { return heading }
        return nil
      }).first, !heading.title.isEmpty {
        return (heading.title, index + 1)
      }
    }

    return (fallback.replacingOccurrences(of: "-", with: " "), 1)
  }

  nonisolated private static func openClawZone(fileURL: URL, corpusRoot: URL, directory: URL) -> String {
    let rootPath = corpusRoot.standardizedFileURL.path
    let directoryPath = directory.standardizedFileURL.path
    if directoryPath.hasPrefix(rootPath + "/") {
      return String(directoryPath.dropFirst(rootPath.count + 1))
    }
    return directory.lastPathComponent
  }

  nonisolated private static func firstOrgID(in prefix: String) -> String? {
    let pattern = #"(?m)^\s*:ID:\s*([0-9a-fA-F-]{36})\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = prefix as NSString
    guard let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: nsText.length)),
          match.numberOfRanges >= 2
    else {
      return nil
    }
    return nsText.substring(with: match.range(at: 1))
  }

  nonisolated private static func meetingProperty(_ key: String, in prefix: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: key)
    let pattern = "(?im)^\\s*:" + escaped + ":\\s*(.*?)\\s*$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = prefix as NSString
    guard let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: nsText.length)),
          match.numberOfRanges >= 2
    else {
      return nil
    }
    let value = nsText.substring(with: match.range(at: 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private func upsertHeadlineProperties(file: String, line: Int, properties: [String: String]) throws {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
    var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let headingIndex = max(0, min(lines.count - 1, line - 1))

    guard headingIndex < lines.count, lines[headingIndex].range(of: #"^\*+\s+"#, options: .regularExpression) != nil else {
      throw WorkspaceEditError.noHeadline(file: file, line: line)
    }

    let headingLevel = lines[headingIndex].prefix { $0 == "*" }.count
    var subtreeEnd = lines.count
    if headingIndex + 1 < lines.count {
      for index in (headingIndex + 1)..<lines.count {
        let candidate = lines[index]
        guard candidate.range(of: #"^\*+\s+"#, options: .regularExpression) != nil else { continue }
        let level = candidate.prefix { $0 == "*" }.count
        if level <= headingLevel {
          subtreeEnd = index
          break
        }
      }
    }

    var insertAt = headingIndex + 1
    while insertAt < subtreeEnd {
      let trimmed = lines[insertAt].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      if trimmed.hasPrefix("SCHEDULED:") || trimmed.hasPrefix("DEADLINE:") || trimmed.hasPrefix("CLOSED:") {
        insertAt += 1
      } else {
        break
      }
    }

    var drawerStart: Int?
    var drawerEnd: Int?
    if insertAt < subtreeEnd,
       lines[insertAt].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == ":PROPERTIES:" {
      drawerStart = insertAt
      for index in (insertAt + 1)..<subtreeEnd {
        if lines[index].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == ":END:" {
          drawerEnd = index
          break
        }
      }
    }

    if let drawerStart, let drawerEnd {
      var end = drawerEnd
      for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
        let prefix = ":\(key):"
        var replaced = false
        if drawerStart + 1 < end {
          for index in (drawerStart + 1)..<end {
            if lines[index].uppercased().hasPrefix(prefix.uppercased()) {
              lines[index] = "\(prefix) \(value)"
              replaced = true
              break
            }
          }
        }
        if !replaced {
          lines.insert("\(prefix) \(value)", at: end)
          end += 1
        }
      }
    } else {
      let drawerLines = [":PROPERTIES:"]
        + properties.sorted(by: { $0.key < $1.key }).map { ":\($0.key): \($0.value)" }
        + [":END:"]
      lines.insert(contentsOf: drawerLines, at: insertAt)
    }

    let output = lines.joined(separator: "\n")
    try output.write(to: url, atomically: true, encoding: .utf8)
  }

  private func updateHeadlinePriority(file: String, line: Int, priority: String?) throws {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
    var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let index = max(0, min(lines.count - 1, line - 1))

    guard index < lines.count else {
      throw WorkspaceEditError.noHeadline(file: file, line: line)
    }

    let original = lines[index]
    guard let match = original.range(of: #"^(\*+)\s+(.*)$"#, options: .regularExpression) else {
      throw WorkspaceEditError.noHeadline(file: file, line: line)
    }

    let matched = String(original[match])
    guard let separator = matched.firstIndex(of: " ") else {
      throw WorkspaceEditError.noHeadline(file: file, line: line)
    }

    let stars = String(matched[..<separator])
    var rest = String(matched[matched.index(after: separator)...])
    var tagsSuffix = ""

    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      tagsSuffix = String(rest[tagRange])
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    let todoKeywords = Set(["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"])
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var todoPrefix = ""
    if let first = tokens.first, todoKeywords.contains(first.uppercased()) {
      todoPrefix = first.uppercased()
      tokens.removeFirst()
    }
    if let first = tokens.first, first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }

    let title = tokens.joined(separator: " ")
    let normalizedPriority = priority.flatMap(Self.normalizePriority)
    let todoPart = todoPrefix.isEmpty ? "" : "\(todoPrefix) "
    let priorityPart = normalizedPriority.map { "[#\($0)] " } ?? ""
    lines[index] = "\(stars) \(todoPart)\(priorityPart)\(title)\(tagsSuffix)"

    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  private func todayDailyNotePath(corpusRoot: URL) -> URL {
    dailyNotePath(corpusRoot: corpusRoot, date: Date())
  }

  private func dailyNotePath(corpusRoot: URL, date: Date) -> URL {
    let configURL = corpusRoot.appendingPathComponent("org2.json")
    let basePath: String
    if let data = try? Data(contentsOf: configURL),
       let config = try? JSONDecoder().decode(WorkspaceOrg2Config.self, from: data) {
      let configured = config.roam?.dailiesDir?.trimmingCharacters(in: .whitespacesAndNewlines)
      let indexDir = config.roam?.indexDir?.trimmingCharacters(in: .whitespacesAndNewlines)
      let rawBase = configured?.isEmpty == false ? configured! : (indexDir?.isEmpty == false ? indexDir! : "")
      if !rawBase.isEmpty {
        basePath = NSString(string: rawBase).isAbsolutePath
          ? rawBase
          : corpusRoot.appendingPathComponent(rawBase).path
      } else {
        basePath = corpusRoot.path
      }
    } else {
      basePath = corpusRoot.path
    }

    return URL(fileURLWithPath: basePath).appendingPathComponent("\(Self.formatDate(date)).org2")
  }

  private func createDailyNote(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let title = url.deletingPathExtension().lastPathComponent
    try "#+TITLE: \(title)\n\n".write(to: url, atomically: true, encoding: .utf8)
  }

  private func corpusFile(for url: URL, corpusRoot: URL) -> CorpusFile {
    let standardizedURL = url.standardizedFileURL
    let relativePath = self.relativePath(standardizedURL.path)
    let values = try? standardizedURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return CorpusFile(
      path: standardizedURL.path,
      relativePath: relativePath,
      modifiedAt: values?.contentModificationDate,
      byteCount: values?.fileSize.map(Int64.init)
    )
  }

  private func upsertCorpusFile(_ file: CorpusFile) {
    corpusFiles.removeAll { $0.id == file.id }
    corpusFiles.append(file)
    corpusFiles.sort {
      $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
  }

  private func appendScheduledTodo(title: String, to target: URL) throws {
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let safeTitle = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let entry = "* TODO \(safeTitle)\nSCHEDULED: \(Self.orgDateTimestamp(Date()))\n"
    let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
    let prefix = existing.isEmpty || existing.hasSuffix("\n") ? existing : "\(existing)\n"
    try "\(prefix)\(entry)".write(to: target, atomically: true, encoding: .utf8)
  }

  private func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  private func openFile(path: String, line: Int) {
    let fileURL = URL(fileURLWithPath: path)

    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil {
      var allowed = CharacterSet.urlPathAllowed
      allowed.insert(":")
      let encodedPath = fileURL.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? fileURL.path
      if let url = URL(string: "vscode://file\(encodedPath):\(line):1") {
        NSWorkspace.shared.open(url)
        return
      }
    }

    NSWorkspace.shared.open(fileURL)
  }

  private static func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private static func isoDate(_ date: Date) -> String {
    formatDate(date)
  }

  private static func dateFromISO(_ raw: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: raw)
  }

  private static func dateString(for target: PlanningDateTarget) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let today = Date()
    switch target {
    case .today:
      return formatDate(today)
    case .tomorrow:
      return formatDate(calendar.date(byAdding: .day, value: 1, to: today) ?? today)
    case .upcomingMonday:
      let weekday = calendar.component(.weekday, from: today)
      let delta = weekday == 2 ? 7 : ((9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7)
      return formatDate(calendar.date(byAdding: .day, value: delta, to: today) ?? today)
    case .nextMonth:
      let components = calendar.dateComponents([.year, .month], from: today)
      var next = DateComponents()
      next.year = components.year
      next.month = (components.month ?? 1) + 1
      next.day = 1
      return formatDate(calendar.date(from: next) ?? today)
    }
  }

  private static func date(for target: DailyNoteTarget) -> Date {
    let calendar = Calendar(identifier: .gregorian)
    let today = Date()
    switch target {
    case .yesterday:
      return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    case .today:
      return today
    case .tomorrow:
      return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
  }

  private static func orgTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
    return "<\(formatter.string(from: date))>"
  }

  private static func orgDateTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd EEE"
    return "<\(formatter.string(from: date))>"
  }

  private static func normalizePriority(_ raw: String) -> String? {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return token.range(of: #"^[A-Z0-9]$"#, options: .regularExpression) == nil ? nil : token
  }

  private static func parsePropertyAssignment(_ raw: String) -> (key: String, value: String)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = trimmed.firstIndex(of: "="), separator != trimmed.startIndex else {
      return nil
    }

    let key = String(trimmed[..<separator])
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
    let value = String(trimmed[trimmed.index(after: separator)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard key.range(of: #"^[A-Z0-9_@#%+.-]+$"#, options: .regularExpression) != nil else {
      return nil
    }

    return (key, value)
  }
}

private struct PendingMeetingRecording {
  let paths: MeetingArtifactPaths
  let capturesSystemAudio: Bool
  let systemAudioStartError: String?
}

private struct WorkspaceOrg2Config: Decodable {
  let roam: Roam?
  let openClaw: OpenClaw?

  enum CodingKeys: String, CodingKey {
    case roam
    case openClaw
    case openclaw
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    roam = try container.decodeIfPresent(Roam.self, forKey: .roam)
    openClaw = try container.decodeIfPresent(OpenClaw.self, forKey: .openClaw)
      ?? container.decodeIfPresent(OpenClaw.self, forKey: .openclaw)
  }

  struct Roam: Decodable {
    let indexDir: String?
    let dailiesDir: String?
  }

  struct OpenClaw: Decodable {
    let threadDirs: [String]?
  }
}

private struct OpenClawTranscriptPayload: Codable {
  let version: Int
  let messages: [OpenClawChatMessage]
}

private enum WorkspaceEditError: LocalizedError {
  case noHeadline(file: String, line: Int)
  case invalidRange(file: String, line: Int)

  var errorDescription: String? {
    switch self {
    case .noHeadline(let file, let line):
      "No headline found at \(file):\(line)"
    case .invalidRange(let file, let line):
      "Invalid edit range at \(file):\(line)"
    }
  }
}

private final class SourceRunOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func set(_ data: Data) {
    lock.lock()
    storage = data
    lock.unlock()
  }

  var data: Data {
    lock.lock()
    let data = storage
    lock.unlock()
    return data
  }
}

public enum WorkspaceSurface: String, CaseIterable, Identifiable, Sendable {
  case agenda
  case files
  case search
  case meetings
  case openClaw
  case agentSpace

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .agenda: "Agenda"
    case .files: "Files"
    case .search: "Search"
    case .meetings: "Meetings"
    case .openClaw: "OpenClaw Chat"
    case .agentSpace: "Agent Space"
    }
  }

  public var systemImage: String {
    switch self {
    case .agenda: "calendar"
    case .files: "doc.text"
    case .search: "magnifyingglass"
    case .meetings: "mic"
    case .openClaw: "sparkles"
    case .agentSpace: "bubble.left.and.bubble.right"
    }
  }

  public var commandShortcutTitle: String {
    switch self {
    case .agenda: "⌘1"
    case .files: "⌘2"
    case .search: "⌘3"
    case .meetings: "⌘4"
    case .openClaw: "⌘5"
    case .agentSpace: "⌘6"
    }
  }
}
