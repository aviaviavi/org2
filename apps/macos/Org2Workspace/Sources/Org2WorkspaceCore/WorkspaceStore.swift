import AppKit
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public enum WorkspaceKeyboardShortcutScope: Equatable, Sendable {
  case all
  case globalOnly
}

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

private struct EntrySourceCacheEntry {
  let modifiedAt: Date?
  let source: EntrySource
}

private struct RenderedHTMLCacheEntry {
  let html: String
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
  let initialSourceUTF16Offset: Int?

  init(
    file: String,
    line: Int,
    mode: PendingBlockSelectionMode,
    beginEditing: Bool = false,
    initialSourceUTF16Offset: Int? = nil
  ) {
    self.file = file
    self.line = line
    self.mode = mode
    self.beginEditing = beginEditing
    self.initialSourceUTF16Offset = initialSourceUTF16Offset
  }
}

private struct RenderedTextSelectionWrite {
  let file: String
  let startLine: Int
  let endLineExclusive: Int
  let replacement: String
  let expectedOriginal: String
  let allowDestructiveReplacement: Bool
  let failureStatus: String
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

private struct PendingFileUndoSnapshot {
  let file: String
  let previous: String
}

private struct DetailNavigationSnapshot {
  let location: WorkspaceLocation
  let selectedSurface: WorkspaceSurface
  let selectedEntrySourceMode: EntrySourceMode
}

private struct OpenClawContextPointer: Equatable, Sendable {
  let kind: String
  let reference: String
  let displayReference: String
  let threadTitle: String
}

public enum OpenClawThreadMode: String, CaseIterable, Identifiable, Sendable {
  case newThread
  case currentThread

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .newThread: "New thread"
    case .currentThread: "Current thread"
    }
  }
}

private struct OpenClawBlockContextPointer: Equatable, Sendable {
  let file: String
  let startLine: Int
  let endLineExclusive: Int

  init?(source: EntrySource?, block: OrgEditableBlock) {
    guard let source else { return nil }
    file = source.file
    startLine = block.startLine
    endLineExclusive = block.endLineExclusive
  }
}

private struct OpenClawCorpusSnapshot: Sendable {
  let rootPath: String
  let files: [String: OpenClawSnapshotFile]

  func filtered(to relativePaths: Set<String>) -> OpenClawCorpusSnapshot {
    guard !relativePaths.isEmpty else { return self }
    return OpenClawCorpusSnapshot(
      rootPath: rootPath,
      files: files.filter { relativePaths.contains($0.key) }
    )
  }
}

private struct OpenClawSnapshotFile: Sendable {
  let text: String
}

private enum WorkspaceUndoAction: Equatable, Sendable {
  case openClawDraft(previous: String, next: String)
  case fileSnapshot(file: String, previous: String, next: String)
}

public enum QuickOpenSelectionDirection: Equatable, Sendable {
  case up
  case down
}

private struct QuickOpenIndexedFile: Sendable {
  let file: CorpusFile
  let normalizedRelativePath: String
}

private struct AssignedWorkSearchRow: Sendable {
  let item: AssignedWorkItem
  let searchText: String
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

private struct RoamLinkifyPayload: Decodable {
  let changedFileCount: Int
  let replacementCount: Int
  let ambiguousSkipCount: Int
  let representedSuggestionCount: Int
  let applied: Bool
}

private struct SearchIndexBuildPayload: Decodable {
  let fileCount: Int
  let lineCount: Int
  let skippedFiles: Int
}

private struct ApprovalPayload: Decodable {
  let count: Int
  let items: [ApprovalItem]
}

private struct WorkspaceSearchIndex: Decodable {
  let schema: String
  let version: Int
  let rootDir: String
  let recursive: Bool
  let includeArchives: Bool
  let files: [WorkspaceSearchIndexFile]

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case version
    case rootDir
    case recursive
    case includeArchives
    case files
  }
}

private struct WorkspaceSearchIndexFile: Decodable {
  let path: String
  let relativePath: String
  let modifiedMs: Int64
  let byteCount: Int64
  let lines: [String]
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

private struct PageSearchRenderedMatch: Equatable, Sendable {
  let blockID: OrgEditableBlock.ID
  let blockIndex: Int
  let occurrenceOffsetInBlock: Int
}

struct SourceBlockExecutionResult: Equatable, Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
  let timedOut: Bool
  let timeout: TimeInterval
}

public struct CreatedKnowledgeNode: Equatable, Sendable {
  public let title: String
  public let file: String
  public let id: String

  public init(title: String, file: String, id: String) {
    self.title = title
    self.file = file
    self.id = id
  }
}

public struct InlineSelectionReplacement: Equatable, Sendable {
  public let text: String
  public let selectedRange: NSRange

  public init(text: String, selectedRange: NSRange) {
    self.text = text
    self.selectedRange = selectedRange
  }
}

public enum WorkspaceCaptureKind: String, CaseIterable, Identifiable, Sendable {
  case task
  case note

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .task: "Task"
    case .note: "Note"
    }
  }
}

public enum WorkspaceCaptureAttachmentKind: String, Sendable {
  case file
  case image
  case video
  case link
}

public struct WorkspaceCaptureAttachmentDraft: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var kind: WorkspaceCaptureAttachmentKind
  public var name: String
  public var sourceURL: URL?
  public var data: Data?
  public var suggestedExtension: String

  public init(
    id: UUID = UUID(),
    kind: WorkspaceCaptureAttachmentKind,
    name: String,
    sourceURL: URL? = nil,
    data: Data? = nil,
    suggestedExtension: String = ""
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.sourceURL = sourceURL
    self.data = data
    self.suggestedExtension = suggestedExtension
  }
}

public struct WorkspaceCaptureDraft: Equatable, Sendable {
  public var kind: WorkspaceCaptureKind
  public var title: String
  public var body: String
  public var todoStatus: TodoEditStatus
  public var includeScheduled: Bool
  public var scheduledDate: Date
  public var includeDeadline: Bool
  public var deadlineDate: Date
  public var priority: String
  public var tagsText: String
  public var assignToAgent: Bool
  public var attachments: [WorkspaceCaptureAttachmentDraft]

  public init(
    kind: WorkspaceCaptureKind = .task,
    title: String = "",
    body: String = "",
    todoStatus: TodoEditStatus = .todo,
    includeScheduled: Bool = true,
    scheduledDate: Date = Date(),
    includeDeadline: Bool = false,
    deadlineDate: Date = Date(),
    priority: String = "",
    tagsText: String = "",
    assignToAgent: Bool = false,
    attachments: [WorkspaceCaptureAttachmentDraft] = []
  ) {
    self.kind = kind
    self.title = title
    self.body = body
    self.todoStatus = todoStatus
    self.includeScheduled = includeScheduled
    self.scheduledDate = scheduledDate
    self.includeDeadline = includeDeadline
    self.deadlineDate = deadlineDate
    self.priority = priority
    self.tagsText = tagsText
    self.assignToAgent = assignToAgent
    self.attachments = attachments
  }
}

public struct SimilarTodoCandidate: Identifiable, Hashable, Sendable {
  public let file: String
  public let line: Int
  public let headline: String
  public let todo: String?
  public let tags: [String]
  public let properties: [String: String]
  public let score: Double

  public init(
    file: String,
    line: Int,
    headline: String,
    todo: String?,
    tags: [String] = [],
    properties: [String: String] = [:],
    score: Double = 1
  ) {
    self.file = file
    self.line = line
    self.headline = headline
    self.todo = todo
    self.tags = tags
    self.properties = properties
    self.score = score
  }

  public var id: String {
    "\(file):\(line):\(headline)"
  }
}

private struct WorkspaceCapturePasteboardContent {
  var text: String = ""
  var attachments: [WorkspaceCaptureAttachmentDraft] = []
}

private struct HeadlineMutationTarget: Sendable {
  let file: String
  let line: Int
  let title: String
  let agendaItemID: String?
  let idValue: String?

  init(file: String, line: Int, title: String, agendaItemID: String? = nil, idValue: String? = nil) {
    self.file = file
    self.line = line
    self.title = title
    self.agendaItemID = agendaItemID
    self.idValue = idValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
  }

  init(item: AgendaItem) {
    self.init(
      file: item.file,
      line: item.lineForEditor,
      title: Org2Display.cleanInline(item.headline),
      agendaItemID: item.id,
      idValue: item.properties["ID"]
    )
  }
}

private struct ApprovalMutationIdentity: Sendable {
  let title: String
  let idValue: String?
}

private struct ApprovalCandidateSource: Sendable {
  let file: CorpusFile
  let sourceText: String
  let parseText: String
  let sourceLineOffset: Int
}

private struct AgendaTodoShortcutMutation: Sendable {
  let status: TodoEditStatus
  let target: HeadlineMutationTarget
}

private struct ApprovedAgentActionResult {
  let title: String
  let file: String
  let line: Int
  let created: Bool
}

private struct ApprovalRejectionChoice {
  let endStatus: TodoEditStatus
  let reason: String
}

private enum ApprovalActionKind {
  case approve
  case reject
}

struct RecoverableMeetingRecording: Sendable {
  let paths: MeetingArtifactPaths
  let duration: TimeInterval?
  let systemAudioURL: URL?
  let systemAudioCaptureError: String?
  let captureSources: String
}

public struct WorkspaceRuntimeIdentity: Equatable, Sendable {
  public let executablePath: String
  public let bundlePath: String
  public let bundleIdentifier: String?
  public let isAppBundle: Bool

  public var audioPermissionStatusLabel: String {
    isAppBundle ? "Stable app bundle" : "Debug executable"
  }

  public var audioPermissionDetailText: String {
    if isAppBundle {
      return "Screen/System Audio permission should apply to this app bundle after relaunch."
    }
    return "Screen/System Audio permission may not apply reliably to a rebuilt SwiftPM debug executable. Launch an installed Org2Workspace.app bundle for stable TCC permissions."
  }

  public static func current(
    bundle: Bundle = .main
  ) -> WorkspaceRuntimeIdentity {
    WorkspaceRuntimeIdentity(
      executablePath: bundle.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? "",
      bundlePath: bundle.bundleURL.path,
      bundleIdentifier: bundle.bundleIdentifier,
      isAppBundle: bundle.bundleURL.pathExtension.lowercased() == "app"
    )
  }
}

@MainActor
public final class WorkspaceStore: ObservableObject {
  nonisolated public static let meetingCaptureSourceSummary = "Captures microphone and system/call audio. System audio uses macOS ScreenCaptureKit permission; Org2 records audio only."
  nonisolated public static let defaultAgentHandoffAssignee = "OpenClaw"

  @Published public var selectedSurface: WorkspaceSurface = .home {
    didSet {
      guard oldValue != selectedSurface else { return }
      isWorkspaceSurfacePaneClosed = false
      expandedWorkspaceSurface = nil
      isWorkspaceDetailPaneExpanded = false
    }
  }
  @Published public var expandedWorkspaceSurface: WorkspaceSurface?
  @Published public var isWorkspaceSurfacePaneClosed = false
  @Published public var isWorkspaceDetailPaneClosed = false
  @Published public var isWorkspaceDetailPaneExpanded = false
  @Published public var agendaMode: AgendaMode = .focus {
    didSet {
      defaults.set(agendaMode.rawValue, forKey: agendaModeKey)
      rebuildAgendaDisplayCache()
    }
  }
  @Published public var agendaFilter = "" {
    didSet {
      guard oldValue != agendaFilter else { return }
      rebuildAgendaDisplayCache()
      rebuildAssignedWorkDisplayCache()
    }
  }
  @Published public var agendaFilterFocusToken = 0
  @Published public var isAgendaFilterFocused = false
  @Published public var selectedAgendaItemID: String?
  @Published public var bulkSelectedAgendaItemIDs: Set<String> = []
  private var suppressNextAgendaSelectionActivation = false
  @Published public var corpusRoot: URL?
  @Published public var agenda: AgendaPayload? {
    didSet {
      rebuildAgendaDisplayCache()
    }
  }
  public private(set) var agendaDisplaySections: [AgendaDisplaySection] = []
  public private(set) var visibleAgendaItems: [AgendaItem] = []
  @Published public private(set) var approvalItems: [ApprovalItem] = [] {
    didSet {
      rebuildApprovalDisplayCache()
    }
  }
  @Published public var approvalFilter = "" {
    didSet {
      guard oldValue != approvalFilter else { return }
      rebuildApprovalDisplayCache()
    }
  }
  @Published public var approvalFilterFocusToken = 0
  public private(set) var visibleApprovalItems: [ApprovalItem] = []
  @Published public var selectedApprovalItemID: ApprovalItem.ID?
  @Published public var isLoadingApprovals = false
  @Published public private(set) var approvingApprovalItemIDs: Set<ApprovalItem.ID> = []
  @Published public private(set) var rejectingApprovalItemIDs: Set<ApprovalItem.ID> = []
  @Published public var corpusFiles: [CorpusFile] = [] {
    didSet {
      rebuildQuickOpenIndex()
      scheduleQuickOpenSearch(debounce: false)
    }
  }
  @Published public private(set) var orgRoamLinkResolver = OrgRoamLinkResolver.empty
  @Published public var selectedCorpusFileID: String?
  @Published public var corpusFileFilter = ""
  @Published public var corpusFileFilterFocusToken = 0
  @Published public var isScanningCorpusFiles = false
  @Published public var isQuickOpenPresented = false
  @Published public var isKeyboardShortcutsPresented = false
  @Published public var isCapturePanelPresented = false
  @Published public var captureDraft = WorkspaceCaptureDraft()
  @Published public var isSimilarTodoAssignmentPresented = false
  @Published public var similarTodoCandidates: [SimilarTodoCandidate] = []
  @Published public var selectedSimilarTodoCandidateIDs: Set<SimilarTodoCandidate.ID> = []
  @Published public var similarTodoPattern = ""
  @Published public var similarTodoAssignee = ""
  @Published public var similarTodoStatus = "ready"
  @Published public var assignedWorkItems: [AssignedWorkItem] = [] {
    didSet {
      assignedWorkSearchRows = assignedWorkItems.map { item in
        AssignedWorkSearchRow(item: item, searchText: Self.assignedWorkFilterText(for: item))
      }
      rebuildAssignedWorkDisplayCache()
    }
  }
  public private(set) var visibleAssignedWorkItems: [AssignedWorkItem] = []
  public private(set) var assignedWorkSections: [AssignedWorkSection] = []
  @Published public var selectedAssignedWorkItemID: AssignedWorkItem.ID?
  @Published public var isLoadingAssignedWork = false
  @Published public var detailScrollRequest: DetailScrollRequest?
  @Published public var quickOpenQuery = "" {
    didSet {
      selectedQuickOpenFileID = nil
      scheduleQuickOpenSearch()
    }
  }
  @Published public var selectedQuickOpenFileID: String?
  @Published public private(set) var quickOpenFiles: [CorpusFile] = []
  @Published public private(set) var isFilteringQuickOpenFiles = false
  @Published public var searchMode: WorkspaceSearchMode = .text
  @Published public var searchQuery = ""
  @Published public var searchFocusToken = 0
  @Published public var searchResults: [SearchResult] = []
  @Published public var openClawChatSearchResults: [OpenClawChatSearchResult] = []
  @Published public var renderedSearchHighlightQuery: String?
  @Published public var isPageSearchPresented = false
  @Published public var pageSearchQuery = "" {
    didSet {
      guard isPageSearchPresented else { return }
      renderedSearchHighlightQuery = Self.normalizedRenderedSearchHighlightQuery(pageSearchQuery)
      refreshPageSearchMatches(selectFirst: true)
    }
  }
  @Published public var pageSearchFocusToken = 0
  @Published public private(set) var pageSearchOccurrenceCount = 0
  @Published public private(set) var pageSearchSelectedOccurrenceIndex: Int?
  private var pageSearchRenderedMatches: [PageSearchRenderedMatch] = []
  @Published public var meetings: [MeetingWorkspaceItem] = []
  @Published public private(set) var processingMeetings: [MeetingProcessingItem] = []
  @Published public var selectedMeetingID: String?
  @Published public var meetingTitleDraft = ""
  @Published public var meetingStatusText = WorkspaceStore.defaultMeetingStatusText()
  @Published public var meetingInputAverageLevel = 0.0
  @Published public var meetingInputPeakLevel = 0.0
  @Published public var meetingSystemAudioAverageLevel = 0.0
  @Published public var meetingSystemAudioPeakLevel = 0.0
  @Published public var meetingTranscriptionProgress = 0.0
  @Published public var meetingTranscriptionElapsedText = ""
  @Published public var audioSettingsStatus = LocalWhisperTranscriber.installationStatus()
  @Published public var isAudioSettingsExpanded = false
  @Published public var isInstallingFastTranscriber = false
  @Published public var audioSettingsStatusText = ""
  @Published public var workspaceRuntimeIdentity = WorkspaceRuntimeIdentity.current()
  @Published public var isCapturingSystemAudio = false
  @Published public var meetingSystemAudioStatusText = "System audio not recording"
  @Published public var openClawMessages: [OpenClawChatMessage] = [] {
    didSet {
      guard !isApplyingOpenClawThreadMessages else { return }
      updateSelectedOpenClawChatThread(messages: openClawMessages)
      guard shouldPersistOpenClawMessages else { return }
      persistOpenClawTranscript()
    }
  }
  @Published public private(set) var openClawChatThreads: [OpenClawChatThread] = []
  @Published public private(set) var selectedOpenClawChatThreadID: UUID?
  public var openClawIncomingMessageSoundPlayer: @MainActor () -> Void = {
    NSSound(named: NSSound.Name("Glass"))?.play()
  }
  @Published public var openClawDraft = ""
  @Published public var openClawPendingAttachments: [OpenClawChatAttachment] = []
  @Published public var openClawAgentID = "main"
  @Published public var openClawEndpointText = ""
  @Published public var agentHandoffAssignee = WorkspaceStore.defaultAgentHandoffAssignee
  @Published public var personalAssigneeNamesText = ""
  @Published public var openClawRemoteCorpusPath = ""
  @Published public var openClawBriefsStartNewThread = true {
    didSet {
      defaults.set(openClawBriefsStartNewThread, forKey: openClawBriefsStartNewThreadKey)
    }
  }
  @Published public var openClawHasStoredToken = false
  @Published public var openClawStatusText = WorkspaceStore.defaultOpenClawStatusText()
  @Published public var isRecordingOpenClawVoiceNote = false
  @Published public var isTranscribingOpenClawVoiceNote = false
  @Published public var openClawVoiceAverageLevel = 0.0
  @Published public var openClawVoicePeakLevel = 0.0
  @Published public var openClawVoiceTranscriptionProgress = 0.0
  @Published public var openClawVoiceTranscriptionElapsedText = ""
  @Published public var openClawVoiceStatusText = "Dictate with local transcription."
  @Published public var isOrgCryptConfigurationPresented = false
  @Published public var orgCryptEncryptOnSave = true {
    didSet {
      defaults.set(orgCryptEncryptOnSave, forKey: orgCryptEncryptOnSaveKey)
    }
  }
  @Published public var orgCryptRecipientsText = ""
  @Published public var orgCryptRecipientFilesText = ""
  @Published public private(set) var orgCryptManagedRecipientFiles: [OrgCryptRecipientFile] = []
  @Published public var orgCryptUseDefaultGpgKey = true
  @Published public var orgCryptGpgProgram = "gpg"
  @Published public var orgCryptHasStoredPassphrase = false
  @Published public var orgCryptStatusText = "Encrypt :crypt: subtrees with GPG."
  @Published public var isSendingOpenClawMessage = false
  @Published public private(set) var openClawQueuedMessageCount = 0
  @Published public private(set) var openClawSendingThreadIDs: Set<UUID> = []
  @Published public var openClawRequestStartedAt: Date?
  @Published public var isOpenClawAssistantPresented = false
  public private(set) var openClawChatScrollPosition: Double?
  public private(set) var openClawAssistantChatScrollPosition: Double?
  @Published public var openClawThreads: [OpenClawThread] = []
  @Published public var selectedOpenClawThreadID: String?
  @Published public var workspaceHealthChecks: [WorkspaceHealthCheck] = []
  @Published public var isCheckingWorkspaceHealth = false
  @Published public var selectedLocation: WorkspaceLocation?
  @Published public var selectedEntrySource: EntrySource?
  @Published public private(set) var selectedEntryHTML: String?
  @Published public private(set) var selectedEntryRenderError: String?
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
        if isPageSearchPresented {
          refreshPageSearchMatches(selectFirst: false)
        }
        return
      }
      let metadata = Self.renderedBlocksMetadata(for: selectedRenderedBlocks)
      selectedRenderedBlocksRenderSignature = metadata.renderSignature
      selectedRenderedBlocksSignature = metadata.structureSignature
      selectedRenderedBlockIndexes = metadata.indexes
      if isPageSearchPresented {
        refreshPageSearchMatches(selectFirst: false)
      }
    }
  }
  public private(set) var selectedRenderedBlocksRenderSignature = WorkspaceStore.renderedBlocksRenderSignature(for: [])
  public private(set) var selectedRenderedBlocksSignature = WorkspaceStore.renderedBlocksSignature(for: [])
  public private(set) var selectedRenderedBlockIndexes: [OrgEditableBlock.ID: Int] = [:]
  @Published public var selectedEntrySourceMode: EntrySourceMode = .entry
  @Published public var editableEntryText = ""
  @Published public var sourceEditorSelection = NSRange(location: 0, length: 0)
  @Published public var sourceEditorCommandRequest: OrgSourceEditorCommandRequest?
  @Published public var sourceEditorDiagnostics: [Org2EditorDiagnostic] = []
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
  @Published public var isNodeContextPanePresented = false
  @Published public var nodeContextTab: NodeContextTab = .overview
  @Published public var expandedBacklinkFileIDs: Set<String> = []
  @Published public var isBuildingNodeBrief = false
  @Published public var isLoadingAgenda = false
  @Published public var isSearching = false
  @Published public private(set) var isBuildingSearchIndex = false
  @Published public private(set) var searchIndexStatusText = ""
  @Published public var isLoadingMeetings = false
  @Published public var isRecordingMeeting = false
  @Published public var isMeetingRecordingPaused = false
  @Published public var isProcessingMeeting = false
  @Published public var isLoadingOpenClawThreads = false
  @Published public var isLoadingEntrySource = false
  @Published public var isRenderingEntrySource = false
  @Published public var isEditingEntry = false
  @Published public var isSavingEntry = false
  @Published public var isSavingBlock = false
  @Published public private(set) var isLiveFileEditorAutosaving = false
  @Published public private(set) var liveFileEditorStatusText = ""
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
  private let openClawVoiceRecorder = MeetingAudioRecorder()
  private let meetingSystemAudioRecorder = MeetingSystemAudioRecorder()
  private let corpusKey = "Org2Workspace.corpusRoot"
  private let agendaModeKey = "Org2Workspace.agendaMode"
  private let openClawEndpointKey = "Org2Workspace.openClawEndpoint"
  private let openClawAgentKey = "Org2Workspace.openClawAgent"
  private let agentHandoffAssigneeKey = "Org2Workspace.agentHandoffAssignee"
  private let personalAssigneeNamesKey = "Org2Workspace.personalAssigneeNames"
  private let openClawRemoteCorpusPathKey = "Org2Workspace.openClawRemoteCorpusPath"
  private let openClawBriefsStartNewThreadKey = "Org2Workspace.openClawBriefsStartNewThread"
  private let orgCryptEncryptOnSaveKey = "Org2Workspace.orgCrypt.encryptOnSave"
  private let orgCryptRecipientsKey = "Org2Workspace.orgCrypt.recipients"
  private let orgCryptRecipientFilesKey = "Org2Workspace.orgCrypt.recipientFiles"
  private let orgCryptUseDefaultGpgKeyKey = "Org2Workspace.orgCrypt.useDefaultGpgKey"
  private let orgCryptUseDefaultGpgKeyMigrationKey = "Org2Workspace.orgCrypt.useDefaultGpgKeyDefaulted.v2"
  private let orgCryptGpgProgramKey = "Org2Workspace.orgCrypt.gpgProgram"
  private let legacyDefaultsMigrationKey = "Org2Workspace.legacyDefaultsMigrated.v1"
  private static let legacyDefaultsDomains = [
    "Org2Workspace",
    "press.avi.org2.workspace"
  ]
  private static let orgCryptPublicKeysDirectoryName = "public-keys"
  private static let canonicalParserLineLimit = 2_000
  private static let renderedBlocksCacheLimit = 12
  private static let renderedHTMLCacheLimit = 24
  private static let entrySourceCacheLimit = 24
  private static let detailNavigationHistoryLimit = 100
  private static let workspaceUndoStackLimit = 100
  private static let workspaceUndoSnapshotMaxBytes = 2_000_000
  nonisolated private static let liveFileEditorAutosaveDelayNanoseconds: UInt64 = 850_000_000
  nonisolated private static let openClawChangeSnapshotMaxFileBytes = 2_000_000
  nonisolated private static let openClawChangeSnapshotAllowedExtensions = Set([
    "org", "org2", "md", "markdown", "txt",
    "json", "jsonl", "yaml", "yml", "toml",
    "csv", "tsv"
  ])
  nonisolated private static let openClawChangeSnapshotRetryDelays: [UInt64] = [
    0,
    150_000_000,
    350_000_000
  ]
  nonisolated private static let nodeBriefArtifactRetryDelays: [UInt64] = [
    0,
    150_000_000,
    350_000_000,
    700_000_000,
    1_200_000_000
  ]
  nonisolated private static let openClawInterruptedSendFailureText =
    "Org2 Workspace restarted before this OpenClaw response was saved. The response may have completed outside the app, but this chat cannot recover it. Retry to send again."
  private var openClawTranscriptURL: URL
  private let appOpenClawTranscriptURL: URL
  private let usesFixedOpenClawTranscriptURL: Bool
  private let openClawSendHandler: (@Sendable ([OpenClawChatMessage], String, String, OpenClawWorkspaceContext?) async throws -> String)?
  private var openClawSessionKey = WorkspaceStore.makeOpenClawSessionKey()
  private var shouldPersistOpenClawMessages = false
  private var isApplyingOpenClawThreadMessages = false
  private var openClawBearerToken: String?
  private var openClawDraftsByThreadID: [UUID: String] = [:]
  private var openClawComposerCachedThreadIDs: Set<UUID> = []
  private var openClawPendingUserMessageIDsByThreadID: [UUID: [UUID]] = [:]
  private var drainingOpenClawThreadIDs: Set<UUID> = []
  private var openClawRequestStartedAtByThreadID: [UUID: Date] = [:]
  private var activeMeetingRecording: PendingMeetingRecording?
  private var activeMeetingProcessingCount = 0 {
    didSet {
      isProcessingMeeting = activeMeetingProcessingCount > 0
    }
  }
  private var activeMeetingProcessingIDs: Set<String> = []
  private var activeMeetingProcessingItems: [String: MeetingProcessingItem] = [:]
  private var activeOpenClawVoiceNoteURL: URL?
  private var meetingMeterTask: Task<Void, Never>?
  nonisolated static let meetingMeterPublishIntervalNanoseconds: UInt64 = 250_000_000
  nonisolated static let meetingMeterPublishThreshold = 0.03
  private var meetingTranscriptionProgressTask: Task<Void, Never>?
  private var meetingTranscriptionProgressID: UUID?
  private var meetingTranscriptionProgressTitle = ""
  private var meetingTranscriptionStartedAt: Date?
  private var meetingTranscriptionEstimatedDuration: TimeInterval = 120
  private var openClawVoiceMeterTask: Task<Void, Never>?
  private var openClawVoiceTranscriptionProgressTask: Task<Void, Never>?
  private var openClawVoiceTranscriptionStartedAt: Date?
  private var openClawVoiceTranscriptionEstimatedDuration: TimeInterval = 8
  private var pendingNodeBriefArtifactRelativePath: String?
  private var pendingNodeBriefTitle: String?
  private var postOpenClawWorkspaceRefreshTask: Task<Void, Never>?
  private var pendingG = false
  private var orgRoamLinkResolverGeneration = 0
  private var quickOpenIndexedFiles: [QuickOpenIndexedFile] = []
  private var quickOpenSearchTask: Task<Void, Never>?
  private var quickOpenSearchGeneration = 0
  private var searchIndexTask: Task<Void, Never>?
  private var searchIndexGeneration = 0
  private var entrySourceLoadGeneration = 0
  private var entryHTMLRenderGeneration = 0
  private var activeEntrySourceLoadingGeneration: Int?
  private var liveFileEditorAutosaveTask: Task<Void, Never>?
  private var liveFileEditorAutosaveGeneration = 0
  private var sourceEditorCommandGeneration = 0
  private var backlinksLoadGeneration = 0
  private var detailNavigationBackStack: [DetailNavigationSnapshot] = [] {
    didSet {
      canNavigateBackInDetail = !detailNavigationBackStack.isEmpty
    }
  }
  private var workspaceUndoStack: [WorkspaceUndoAction] = []
  private var workspaceRedoStack: [WorkspaceUndoAction] = []
  private var canonicalDocumentCache: [String: CanonicalDocumentCacheEntry] = [:]
  private var entrySourceCache: [String: EntrySourceCacheEntry] = [:]
  private var entrySourceCacheOrder: [String] = []
  private var renderedBlocksCache: [String: RenderedBlocksCacheEntry] = [:]
  private var renderedBlocksCacheOrder: [String] = []
  private var renderedHTMLCache: [String: RenderedHTMLCacheEntry] = [:]
  private var renderedHTMLCacheOrder: [String] = []
  private var selectedEntryHTMLRenderKey: String?
  private var pendingBlockSelection: PendingBlockSelection?
  private var transientDraftBlock: TransientDraftBlock?
  private var transientDraftIDCounter = 0
  private var activeBlockDrafts: [OrgEditableBlock.ID: String] = [:]
  private var activeBlockOriginals: [OrgEditableBlock.ID: OrgEditableBlock] = [:]
  private var activeBlockInitialSelections: [OrgEditableBlock.ID: NSRange] = [:]
  private var deferredStableAutosaves: [OrgEditableBlock.ID: DeferredStableAutosave] = [:]
  private var preservesSelectedRenderedBlocksMetadataForNextAssignment = false
  private var isRefreshingAgenda = false
  private var isRefreshingApprovals = false
  private var isRefreshingAssignedWork = false
  private var isRefreshingOpenClawThreads = false
  private var scheduledAgendaRefreshTask: Task<Void, Never>?
  private var scheduledApprovalsRefreshTask: Task<Void, Never>?
  private var agendaTodoShortcutMutationTask: Task<Void, Never>?
  private var pendingAgendaTodoShortcutMutations: [AgendaTodoShortcutMutation] = []
  private var pendingAgendaRefreshAfterBlockEditing = false
  private var assignedWorkSearchRows: [AssignedWorkSearchRow] = []

  public init(
    cli: Org2CLI? = nil,
    defaults: UserDefaults = .standard,
    openClawTranscriptURL: URL? = nil,
    openClawFallbackTranscriptURL: URL? = nil,
    openClawSendHandler: (@Sendable ([OpenClawChatMessage], String, String, OpenClawWorkspaceContext?) async throws -> String)? = nil,
    legacyDefaultsDomains: [String]? = nil
  ) {
    self.defaults = defaults
    let fallbackTranscriptURL = openClawFallbackTranscriptURL ?? Self.defaultOpenClawTranscriptURL()
    usesFixedOpenClawTranscriptURL = openClawTranscriptURL != nil
    appOpenClawTranscriptURL = fallbackTranscriptURL
    self.openClawTranscriptURL = openClawTranscriptURL ?? fallbackTranscriptURL
    self.openClawSendHandler = openClawSendHandler
    self.cli = cli ?? (try? Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())) ?? Org2CLI(repoRoot: URL(fileURLWithPath: "/Users/avi/dev/org2"))
    let settings = OpenClawGatewaySettings.resolve()
    let migrationDomains = legacyDefaultsDomains
      ?? (
        defaults === UserDefaults.standard
          && !Self.shouldIgnoreStandardDefaultsForTests(defaults)
          && Self.shouldMigrateLegacyDefaultsForCurrentBundle()
          ? Self.legacyDefaultsDomains
          : []
      )
    migrateLegacyDefaultsIfNeeded(
      legacyDomains: migrationDomains,
      defaultOpenClawEndpoint: settings.endpoint.absoluteString
    )
    agendaMode = Self.shouldIgnoreStandardDefaultsForTests(defaults)
      ? .focus
      : Self.restoreAgendaMode(from: defaults, key: agendaModeKey)
    openClawEndpointText = defaults.string(forKey: openClawEndpointKey) ?? settings.endpoint.absoluteString
    openClawAgentID = defaults.string(forKey: openClawAgentKey) ?? "main"
    agentHandoffAssignee = defaults.string(forKey: agentHandoffAssigneeKey) ?? Self.defaultAgentHandoffAssignee
    personalAssigneeNamesText = defaults.string(forKey: personalAssigneeNamesKey) ?? ""
    openClawRemoteCorpusPath = defaults.string(forKey: openClawRemoteCorpusPathKey) ?? ""
    openClawBriefsStartNewThread = defaults.object(forKey: openClawBriefsStartNewThreadKey) as? Bool ?? true
    orgCryptEncryptOnSave = defaults.object(forKey: orgCryptEncryptOnSaveKey) as? Bool ?? true
    orgCryptRecipientsText = OrgCryptSettings.listText(defaults.stringArray(forKey: orgCryptRecipientsKey) ?? [])
    orgCryptRecipientFilesText = OrgCryptSettings.listText(defaults.stringArray(forKey: orgCryptRecipientFilesKey) ?? [])
    orgCryptUseDefaultGpgKey = defaults.object(forKey: orgCryptUseDefaultGpgKeyKey) as? Bool ?? true
    if defaults.object(forKey: orgCryptUseDefaultGpgKeyMigrationKey) == nil {
      orgCryptUseDefaultGpgKey = true
      defaults.set(true, forKey: orgCryptUseDefaultGpgKeyKey)
      defaults.set(true, forKey: orgCryptUseDefaultGpgKeyMigrationKey)
    }
    orgCryptGpgProgram = defaults.string(forKey: orgCryptGpgProgramKey) ?? "gpg"
    if usesFixedOpenClawTranscriptURL {
      applyOpenClawTranscript(Self.loadOpenClawTranscript(from: self.openClawTranscriptURL), shouldPersist: false)
    }
    shouldPersistOpenClawMessages = true
    openClawHasStoredToken = OpenClawKeychain.containsToken()
    orgCryptHasStoredPassphrase = OrgCryptKeychain.containsPassphrase()
    openClawStatusText = Self.openClawStatusText(settings: currentOpenClawSettings())
    restoreInterruptedOpenClawSendStatusIfNeeded()
    refreshAudioSettingsStatus()
    restoreStartupHomeDetailIfPossible()
  }

  public func bootstrap() async {
    refreshAudioSettingsStatus()
    if corpusRoot == nil {
      if let screenshotCorpusRoot = screenshotCorpusRootFromEnvironment() {
        setCorpusRoot(screenshotCorpusRoot, persistsDefault: false)
      } else {
        corpusRoot = restoreCorpusRoot()
        if let corpusRoot {
          switchOpenClawTranscript(to: Self.openClawTranscriptURL(corpusRoot: corpusRoot), migrationSource: appOpenClawTranscriptURL)
        }
      }
    }

    if corpusRoot != nil {
      if selectedSurface == .home {
        ensureHomeDetailReady()
      }
      await refreshAgenda()
      await refreshMeetings()
      await refreshCorpusFiles()
      await refreshAssignedWork()
      await refreshApprovals()
      refreshOrgCryptManagedRecipientFiles()
      if screenshotModeFromEnvironment() == nil {
        Task { await refreshOpenClawThreads() }
      } else {
        await refreshOpenClawThreads()
        await applyScreenshotModeFromEnvironment()
      }
    } else {
      statusText = "No corpus selected"
    }
  }

  private func restoreStartupHomeDetailIfPossible() {
    guard corpusRoot == nil,
          selectedSurface == .home,
          !Self.shouldIgnoreStandardDefaultsForTests(defaults),
          let restoredRoot = restoreSavedCorpusRoot()
    else {
      return
    }

    corpusRoot = restoredRoot
    switchOpenClawTranscript(to: Self.openClawTranscriptURL(corpusRoot: restoredRoot), migrationSource: appOpenClawTranscriptURL)
    openHome()
  }

  private func screenshotCorpusRootFromEnvironment() -> URL? {
    guard let raw = ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_CORPUS"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      return nil
    }
    let url = URL(fileURLWithPath: raw).standardizedFileURL
    return isDirectory(url.path) ? url : nil
  }

  private func screenshotModeFromEnvironment() -> String? {
    let raw = ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_MODE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return raw?.isEmpty == false ? raw : nil
  }

  private func applyScreenshotModeFromEnvironment() async {
    guard let mode = screenshotModeFromEnvironment() else { return }
    let target = ProcessInfo.processInfo.environment["ORG2_WORKSPACE_SCREENSHOT_TARGET"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    switch mode {
    case "home":
      openHome()
    case "agenda":
      selectedSurface = .agenda
      agendaMode = .focus
      if let item = visibleAgendaItems.first(where: { item in
        guard let target, !target.isEmpty else { return false }
        return item.headline.lowercased().contains(target)
      }) ?? visibleAgendaItems.first {
        selectAgendaItem(item)
      }
    case "approvals":
      selectedSurface = .approvals
      if let item = visibleApprovalItems.first(where: { item in
        guard let target, !target.isEmpty else { return true }
        return item.title.lowercased().contains(target)
          || item.status.lowercased().contains(target)
          || item.file.lowercased().contains(target)
      }) ?? visibleApprovalItems.first {
        selectApprovalItem(item)
      }
    case "openclaw", "chat":
      selectedSurface = .openClaw
      publishOpenClawComposerDraft("Summarize the current launch plan and call out open risks.")
    case "brief":
      selectedSurface = .files
      if let thread = openClawThreads.first(where: { thread in
        guard let target, !target.isEmpty else {
          return thread.title.lowercased().contains("brief")
        }
        return thread.title.lowercased().contains(target)
      }) ?? openClawThreads.first {
        openOpenClawThread(thread, surface: .files, mode: .page)
      }
    case "meetings":
      selectedSurface = .meetings
      if let meeting = meetings.first(where: { meeting in
        guard let target, !target.isEmpty else { return true }
        return meeting.title.lowercased().contains(target)
      }) {
        selectMeeting(meeting)
      }
    case "files":
      selectedSurface = .files
      if let file = filteredCorpusFiles.first(where: { file in
        guard let target, !target.isEmpty else { return true }
        return file.relativePath.lowercased().contains(target)
          || file.name.lowercased().contains(target)
      }) {
        selectCorpusFile(file)
      }
    default:
      openHome()
    }

    if let selectedLocation {
      await loadEntrySource(for: selectedLocation)
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

  public func setCorpusRoot(_ url: URL, persistsDefault: Bool = true) {
    let standardized = url.standardizedFileURL
    corpusRoot = standardized
    if persistsDefault {
      defaults.set(standardized.path, forKey: corpusKey)
    }
    switchOpenClawTranscript(to: Self.openClawTranscriptURL(corpusRoot: standardized))
    agenda = nil
    approvalItems = []
    selectedApprovalItemID = nil
    approvalFilter = ""
    corpusFiles = []
    orgRoamLinkResolver = .empty
    orgRoamLinkResolverGeneration += 1
    selectedCorpusFileID = nil
    corpusFileFilter = ""
    quickOpenQuery = ""
    searchResults = []
    bulkSelectedAgendaItemIDs = []
    assignedWorkItems = []
    selectedAssignedWorkItemID = nil
    meetings = []
    selectedMeetingID = nil
    openClawThreads = []
    selectedOpenClawThreadID = nil
    refreshOrgCryptManagedRecipientFiles()
    selectedLocation = nil
    detailNavigationBackStack = []
    selectedEntrySource = nil
    selectedEntryHTML = nil
    selectedEntryRenderError = nil
    selectedEntryHTMLRenderKey = nil
    selectedRenderedBlocks = []
    foldedRenderedBlockIDs = []
    sourceBlockRuns = [:]
    editableEntryText = ""
    sourceEditorSelection = NSRange(location: 0, length: 0)
    canonicalDocumentCache = [:]
    entrySourceCache = [:]
    entrySourceCacheOrder = []
    renderedBlocksCache = [:]
    renderedBlocksCacheOrder = []
    renderedHTMLCache = [:]
    renderedHTMLCacheOrder = []
    isRefreshingAgenda = false
    isRefreshingApprovals = false
    isRefreshingAssignedWork = false
    isRefreshingOpenClawThreads = false
    isLoadingAgenda = false
    isLoadingApprovals = false
    isLoadingAssignedWork = false
    isLoadingOpenClawThreads = false
    scheduledAgendaRefreshTask?.cancel()
    scheduledAgendaRefreshTask = nil
    scheduledApprovalsRefreshTask?.cancel()
    scheduledApprovalsRefreshTask = nil
    postOpenClawWorkspaceRefreshTask?.cancel()
    postOpenClawWorkspaceRefreshTask = nil
    agendaTodoShortcutMutationTask?.cancel()
    agendaTodoShortcutMutationTask = nil
    pendingAgendaTodoShortcutMutations = []
    searchIndexTask?.cancel()
    searchIndexTask = nil
    searchIndexGeneration += 1
    isBuildingSearchIndex = false
    searchIndexStatusText = ""
    resetBlockState()
    isEditingEntry = false
    isLoadingEntrySource = false
    isRenderingEntrySource = false
    entrySourceLoadGeneration += 1
    entryHTMLRenderGeneration += 1
    activeEntrySourceLoadingGeneration = nil
    backlinks = nil
    errorText = nil
  }

  public func refreshWorkspace() async {
    refreshAudioSettingsStatus(preserveStatusText: true)
    await refreshAgenda()
    await refreshMeetings()
    await refreshCorpusFiles()
    await refreshAssignedWork()
    await refreshApprovals()
    refreshWorkspaceHealth()
    refreshOrgCryptManagedRecipientFiles()
    Task { await refreshOpenClawThreads() }
  }

  public func refreshAudioSettingsStatus(preserveStatusText: Bool = false) {
    audioSettingsStatus = LocalWhisperTranscriber.installationStatus()
    workspaceRuntimeIdentity = WorkspaceRuntimeIdentity.current()
    if !preserveStatusText && (audioSettingsStatusText.isEmpty || !isInstallingFastTranscriber) {
      audioSettingsStatusText = audioSettingsStatus.detailText
    }
  }

  public func installFastMeetingTranscriber() async {
    guard !isInstallingFastTranscriber else { return }
    isInstallingFastTranscriber = true
    audioSettingsStatusText = "Installing whisper.cpp and base English model..."
    defer {
      isInstallingFastTranscriber = false
      refreshAudioSettingsStatus(preserveStatusText: true)
    }

    do {
      try await Task.detached(priority: .userInitiated) {
        try Self.installWhisperCppAndDefaultModel()
      }.value
      audioSettingsStatusText = "Installed whisper.cpp and base English model"
      statusText = "Audio transcription fast path installed"
    } catch {
      audioSettingsStatusText = error.localizedDescription
      errorText = error.localizedDescription
      statusText = "Audio transcription install failed"
    }
  }

  public func refreshWorkspaceHealth() {
    isCheckingWorkspaceHealth = true
    defer { isCheckingWorkspaceHealth = false }
    workspaceHealthChecks = Self.workspaceHealthChecks(cli: cli, corpusRoot: corpusRoot)
    let blockingCount = workspaceHealthChecks.filter { $0.status == .blocking }.count
    let warningCount = workspaceHealthChecks.filter { $0.status == .warning }.count
    if blockingCount > 0 {
      statusText = "\(blockingCount) setup blocker\(blockingCount == 1 ? "" : "s")"
    } else if warningCount > 0 {
      statusText = "\(warningCount) setup warning\(warningCount == 1 ? "" : "s")"
    } else {
      statusText = "Workspace setup looks ready"
    }
  }

  public func refreshCorpusFiles() async {
    guard let corpusRoot else {
      corpusFiles = []
      orgRoamLinkResolver = .empty
      orgRoamLinkResolverGeneration += 1
      searchIndexTask?.cancel()
      searchIndexTask = nil
      searchIndexGeneration += 1
      isBuildingSearchIndex = false
      searchIndexStatusText = ""
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
      scheduleSearchIndexBuild(corpusRoot: corpusRoot)
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
    guard !isRefreshingAgenda else {
      if updatesStatus {
        statusText = "Agenda already refreshing"
      }
      return
    }

    guard let corpusRoot else {
      if updatesStatus {
        statusText = "No corpus selected"
      }
      return
    }

    isRefreshingAgenda = true
    let showsLoading = updatesStatus || agenda == nil
    if showsLoading {
      isLoadingAgenda = true
    }
    errorText = nil
    defer {
      isRefreshingAgenda = false
      if showsLoading {
        isLoadingAgenda = false
      }
    }

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

  public func refreshApprovals(updatesStatus: Bool = false) async {
    guard !isRefreshingApprovals else {
      if updatesStatus {
        statusText = "Approvals already refreshing"
      }
      return
    }

    guard let corpusRoot else {
      if updatesStatus {
        statusText = "No corpus selected"
      }
      return
    }

    isRefreshingApprovals = true
    let showsLoading = updatesStatus || approvalItems.isEmpty
    if showsLoading {
      isLoadingApprovals = true
    }
    errorText = nil
    defer {
      isRefreshingApprovals = false
      if showsLoading {
        isLoadingApprovals = false
      }
    }
    if updatesStatus {
      statusText = "Scanning approvals..."
    }

    do {
      do {
        let payload: ApprovalPayload = try await cli.runJSON([
          "approvals",
          "--dir", corpusRoot.path,
          "--recursive",
          "--format", "json"
        ])
        approvalItems = Self.sortedApprovalItems(payload.items)
        syncApprovalSelectionAfterRefresh()
        if updatesStatus {
          statusText = "\(payload.count) approval\(payload.count == 1 ? "" : "s")"
        }
        return
      } catch {
        if updatesStatus {
          statusText = "Falling back to local approval scan..."
        }
      }

      let candidateSources: [ApprovalCandidateSource]
      if corpusFiles.isEmpty {
        if let indexedCandidates = Self.approvalCandidateSourcesFromStoredIndex(corpusRoot: corpusRoot) {
          candidateSources = indexedCandidates
        } else {
          if updatesStatus {
            statusText = "Scanning approval candidates..."
          }
          let files = try Self.scanCorpusFiles(corpusRoot: corpusRoot)
          corpusFiles = files
          candidateSources = await approvalCandidateSources(
            files: files,
            corpusRoot: corpusRoot,
            updatesStatus: updatesStatus
          )
        }
      } else {
        candidateSources = await approvalCandidateSources(
          files: corpusFiles,
          corpusRoot: corpusRoot,
          updatesStatus: updatesStatus
        )
      }
      if updatesStatus {
        statusText = candidateSources.isEmpty
          ? "0 approval candidates"
          : "Checking \(candidateSources.count) approval candidate file\(candidateSources.count == 1 ? "" : "s")"
      }
      var items: [ApprovalItem] = []
      for candidate in candidateSources {
        guard FileManager.default.fileExists(atPath: candidate.file.path) else {
          continue
        }
        let document: Org2CanonicalDocument = try await cli.parseTextJSON(
          candidate.parseText,
          sourceRanges: true,
          sourceLineOffset: candidate.sourceLineOffset
        )
        items.append(contentsOf: Self.approvalItems(
          in: document,
          file: candidate.file.path,
          sourceText: candidate.sourceText
        ))
      }
      approvalItems = Self.sortedApprovalItems(items)
      syncApprovalSelectionAfterRefresh()
      if updatesStatus {
        statusText = "\(approvalItems.count) approval\(approvalItems.count == 1 ? "" : "s")"
      }
    } catch {
      errorText = error.localizedDescription
      if updatesStatus {
        statusText = "Approvals failed"
      }
    }
  }

  private func approvalCandidateSources(
    files: [CorpusFile],
    corpusRoot: URL,
    updatesStatus: Bool
  ) async -> [ApprovalCandidateSource] {
    if let indexedCandidates = Self.approvalCandidateSourcesFromFreshIndex(files: files, corpusRoot: corpusRoot) {
      return indexedCandidates
    }

    if searchIndexTask != nil {
      if updatesStatus {
        statusText = "Scanning approvals while search index updates..."
      }
      return Self.approvalCandidateSourcesByScanningFiles(files: files)
    }

    if updatesStatus {
      statusText = "Scanning approval candidates..."
    }

    return Self.approvalCandidateSourcesByScanningFiles(files: files)
  }

  nonisolated private static func approvalCandidateSourcesFromFreshIndex(
    files: [CorpusFile],
    corpusRoot: URL
  ) -> [ApprovalCandidateSource]? {
    guard let index = freshWorkspaceSearchIndex(files: files, corpusRoot: corpusRoot) else {
      return nil
    }
    let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    var candidates: [ApprovalCandidateSource] = []
    for indexedFile in index.files {
      guard let file = filesByPath[indexedFile.path],
            isApprovalIndexableFile(file)
      else {
        continue
      }
      candidates.append(contentsOf: approvalCandidateSources(
        file: file,
        sourceLines: indexedFile.lines
      ))
    }
    return candidates
  }

  nonisolated private static func approvalCandidateSourcesFromStoredIndex(corpusRoot: URL) -> [ApprovalCandidateSource]? {
    guard let index = storedWorkspaceSearchIndex(corpusRoot: corpusRoot) else {
      return nil
    }
    var candidates: [ApprovalCandidateSource] = []
    for indexedFile in index.files {
      let file = CorpusFile(
        path: indexedFile.path,
        relativePath: indexedFile.relativePath,
        modifiedAt: Date(timeIntervalSince1970: Double(indexedFile.modifiedMs) / 1000),
        byteCount: indexedFile.byteCount
      )
      guard isApprovalIndexableFile(file) else { continue }
      candidates.append(contentsOf: approvalCandidateSources(
        file: file,
        sourceLines: indexedFile.lines
      ))
    }
    return candidates
  }

  nonisolated private static func approvalCandidateSourcesByScanningFiles(files: [CorpusFile]) -> [ApprovalCandidateSource] {
    var candidates: [ApprovalCandidateSource] = []
    for file in files {
      guard isApprovalIndexableFile(file),
            let raw = try? String(contentsOfFile: file.path, encoding: .utf8)
      else {
        continue
      }
      let lines = normalizeLineEndings(raw)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      candidates.append(contentsOf: approvalCandidateSources(file: file, sourceLines: lines))
    }
    return candidates
  }

  nonisolated private static func approvalCandidateSources(
    file: CorpusFile,
    sourceLines: [String]
  ) -> [ApprovalCandidateSource] {
    let sourceText = sourceLines.joined(separator: "\n")
    var ranges: [Range<Int>] = []
    for index in sourceLines.indices {
      guard let level = approvalHeadingLevel(sourceLines[index]) else { continue }

      let directEnd = firstHeadingIndex(in: sourceLines, after: index) ?? sourceLines.count
      let directText = sourceLines[index..<directEnd].joined(separator: "\n")
      guard approvalCandidateTextMayContainItem(directText) else { continue }

      let subtreeEnd = firstHeadingIndex(in: sourceLines, after: index, maxLevel: level) ?? sourceLines.count
      ranges.append(index..<subtreeEnd)
    }
    guard !ranges.isEmpty else { return [] }

    var parseLines = sourceLines.map { line in
      approvalHeadingLevel(line) == nil ? "" : line
    }
    for range in mergedApprovalCandidateRanges(ranges) {
      for index in range {
        parseLines[index] = sourceLines[index]
      }
    }
    return [
      ApprovalCandidateSource(
        file: file,
        sourceText: sourceText,
        parseText: parseLines.joined(separator: "\n"),
        sourceLineOffset: 0
      )
    ]
  }

  nonisolated private static func mergedApprovalCandidateRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
    let sorted = ranges.sorted { lhs, rhs in
      lhs.lowerBound == rhs.lowerBound
        ? lhs.upperBound < rhs.upperBound
        : lhs.lowerBound < rhs.lowerBound
    }
    var merged: [Range<Int>] = []
    for range in sorted {
      guard let last = merged.last else {
        merged.append(range)
        continue
      }
      if range.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  nonisolated private static func firstHeadingIndex(
    in lines: [String],
    after index: Int,
    maxLevel: Int? = nil
  ) -> Int? {
    guard index + 1 < lines.count else { return nil }
    for candidateIndex in (index + 1)..<lines.count {
      guard let level = approvalHeadingLevel(lines[candidateIndex]) else { continue }
      if let maxLevel {
        if level <= maxLevel {
          return candidateIndex
        }
      } else {
        return candidateIndex
      }
    }
    return nil
  }

  nonisolated private static func approvalHeadingLevel(_ line: String) -> Int? {
    var count = 0
    for character in line {
      if character == "*" {
        count += 1
      } else {
        break
      }
    }
    guard count > 0,
          line.dropFirst(count).first?.isWhitespace == true
    else {
      return nil
    }
    return count
  }

  nonisolated private static func freshWorkspaceSearchIndex(files: [CorpusFile], corpusRoot: URL) -> WorkspaceSearchIndex? {
    let root = corpusRoot.standardizedFileURL
    let indexableFiles = files.filter { isApprovalIndexableFile($0) }
    let indexURL = searchIndexURL(corpusRoot: root)
    guard let data = try? Data(contentsOf: indexURL),
          let index = try? JSONDecoder().decode(WorkspaceSearchIndex.self, from: data),
          index.schema == "org2:search-index:v1",
          index.version == 1,
          URL(fileURLWithPath: index.rootDir).standardizedFileURL.path == root.path,
          index.recursive,
          !index.includeArchives,
          index.files.count == indexableFiles.count
    else {
      return nil
    }

    let expected = Dictionary(uniqueKeysWithValues: indexableFiles.map { ($0.path, $0) })
    for indexedFile in index.files {
      guard let file = expected[indexedFile.path],
            freshSearchIndexMetadataMatches(file: file, indexedFile: indexedFile)
      else {
        return nil
      }
    }
    return index
  }

  nonisolated private static func storedWorkspaceSearchIndex(corpusRoot: URL) -> WorkspaceSearchIndex? {
    let root = corpusRoot.standardizedFileURL
    let indexURL = searchIndexURL(corpusRoot: root)
    guard let data = try? Data(contentsOf: indexURL),
          let index = try? JSONDecoder().decode(WorkspaceSearchIndex.self, from: data),
          index.schema == "org2:search-index:v1",
          index.version == 1,
          URL(fileURLWithPath: index.rootDir).standardizedFileURL.path == root.path,
          index.recursive,
          !index.includeArchives
    else {
      return nil
    }
    return index
  }

  nonisolated private static func isApprovalIndexableFile(_ file: CorpusFile) -> Bool {
    guard !isDefaultIgnoredSyncArtifactPath(file.path) else { return false }
    let pathExtension = URL(fileURLWithPath: file.path).pathExtension.lowercased()
    return pathExtension == "org" || pathExtension == "org2"
  }

  nonisolated private static func freshSearchIndexMetadataMatches(
    file: CorpusFile,
    indexedFile: WorkspaceSearchIndexFile
  ) -> Bool {
    if let modifiedAt = file.modifiedAt,
       let byteCount = file.byteCount {
      return Int64(modifiedAt.timeIntervalSince1970 * 1000) == indexedFile.modifiedMs
        && byteCount == indexedFile.byteCount
    }

    guard let values = try? URL(fileURLWithPath: file.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modifiedAt = values.contentModificationDate,
          let byteCount = values.fileSize
    else {
      return false
    }
    return Int64(modifiedAt.timeIntervalSince1970 * 1000) == indexedFile.modifiedMs
      && Int64(byteCount) == indexedFile.byteCount
  }

  nonisolated private static func searchIndexURL(corpusRoot: URL) -> URL {
    let configuredIndexHome = ProcessInfo.processInfo.environment["ORG2_INDEX_HOME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let indexHome: URL
    if let configuredIndexHome, !configuredIndexHome.isEmpty {
      let expanded = expandHomePath(configuredIndexHome)
      indexHome = URL(fileURLWithPath: expanded).standardizedFileURL
    } else {
      indexHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".org2", isDirectory: true)
        .appendingPathComponent("index", isDirectory: true)
    }

    return indexHome
      .appendingPathComponent(corpusIndexDirectoryName(corpusRoot: corpusRoot), isDirectory: true)
      .appendingPathComponent("search-v1.json")
  }

  nonisolated private static func corpusIndexDirectoryName(corpusRoot: URL) -> String {
    let resolvedPath = corpusRoot.standardizedFileURL.path
    let base = corpusRoot.lastPathComponent
    let slug = base
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let digest = SHA256.hash(data: Data(resolvedPath.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
      .prefix(12)
    return "\((slug.isEmpty ? "corpus" : slug))-\(digest)"
  }

  nonisolated private static func expandHomePath(_ path: String) -> String {
    if path == "~" {
      return FileManager.default.homeDirectoryForCurrentUser.path
    }
    if path.hasPrefix("~/") {
      return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(String(path.dropFirst(2)))
        .path
    }
    return path
  }

  nonisolated static func approvalCandidateTextMayContainItem(_ raw: String) -> Bool {
    let normalized = raw.lowercased()
    guard normalized.contains(":") else { return false }

    let hasHumanApprovalTitle = approvalTextHasHumanApprovalTitle(normalized)
    let hasPendingStatus = approvalStatusNeedles.contains { normalized.contains($0) }
    let hasSpecificReviewStatusKey = [
      ":org2_review_status:",
      ":review_status:",
      ":review:",
      ":followup_status:",
      ":reply_status:"
    ].contains { normalized.contains($0) }
    if hasSpecificReviewStatusKey && hasPendingStatus && hasHumanApprovalTitle {
      return true
    }

    if normalized.contains(":status:"),
       hasPendingStatus,
       hasHumanApprovalTitle {
      return true
    }

    let hasGateKey = [
      ":waiting_on:",
      ":blocked_by:",
      ":org2_waiting_on:",
      ":next_action:",
      ":action_required:",
      ":org2_next_action:",
      ":handoff_summary:",
      ":org2_handoff_summary:"
    ].contains { normalized.contains($0) }
    if hasGateKey && containsApprovalSignal(normalized) {
      return true
    }

    let hasAccessPolicyKey = [
      ":access_policy:",
      ":review_policy:"
    ].contains { normalized.contains($0) }
    return hasAccessPolicyKey && (hasPendingStatus || containsApprovalSignal(normalized))
  }

  nonisolated private static let approvalStatusNeedles = [
    "review-required",
    "requires-review",
    "approval-required",
    "needs-approval",
    "need-approval",
    "needs-review",
    "need-review",
    "pending-review",
    "pending-approval",
    "require-approval",
    "waiting-on-approval",
    "draft-needs-review",
    "draft-needs-approval",
    "reply-review",
    "needs-avi",
    "avi-approval",
    "needs-human",
    "human-review",
    "generated",
    "draft"
  ]

  nonisolated private static func approvalTextHasHumanApprovalTitle(_ normalizedText: String) -> Bool {
    normalizedText.range(
      of: #"(?m)^\*+\s+(?:(?:todo|in_progress|prog|wait|hold|paused)\s+)?(?:approve|review|review/|review-send|review and approve|review/approve)\b"#,
      options: .regularExpression
    ) != nil
  }

  public func clearApprovalFilter() {
    approvalFilter = ""
  }

  public func selectApprovalItem(_ item: ApprovalItem) {
    selectedApprovalItemID = item.id
    select(.agenda(item.agendaItem()))
    statusText = item.sourceLabel
  }

  public func approve(_ item: ApprovalItem) async {
    guard !isApprovalActionInProgress(item) else { return }
    let originalVisibleIndex = visibleApprovalItems.firstIndex(where: { $0.id == item.id })
    beginApprovalAction(item, kind: .approve)
    defer { endApprovalAction(item, kind: .approve) }

    do {
      try await approveAndAgentHandoff(HeadlineMutationTarget(
        file: item.file,
        line: item.line,
        title: Org2Display.cleanInline(item.title),
        agendaItemID: nil,
        idValue: item.idValue
      ))
      removeApprovalItemOptimistically(item.id, originalVisibleIndex: originalVisibleIndex)
      scheduleApprovalsRefresh()
    } catch {
      errorText = error.localizedDescription
      statusText = "Approve handoff failed"
    }
  }

  public func promptAndRejectApproval(_ item: ApprovalItem) {
    guard !isApprovalActionInProgress(item) else { return }
    selectedApprovalItemID = item.id
    guard let rejection = Self.promptForApprovalRejection() else { return }
    Task {
      await rejectApproval(
        item,
        endStatus: rejection.endStatus,
        reason: rejection.reason
      )
    }
  }

  public func rejectApproval(_ item: ApprovalItem, endStatus: TodoEditStatus, reason: String) async {
    guard !isApprovalActionInProgress(item) else { return }
    let originalVisibleIndex = visibleApprovalItems.firstIndex(where: { $0.id == item.id })
    beginApprovalAction(item, kind: .reject)
    defer { endApprovalAction(item, kind: .reject) }

    do {
      try await rejectApproval(
        HeadlineMutationTarget(
          file: item.file,
          line: item.line,
          title: Org2Display.cleanInline(item.title),
          agendaItemID: nil,
          idValue: item.idValue
        ),
        endStatus: endStatus,
        reason: reason
      )
      removeApprovalItemOptimistically(item.id, originalVisibleIndex: originalVisibleIndex)
      scheduleApprovalsRefresh()
    } catch {
      errorText = error.localizedDescription
      statusText = "Reject approval failed"
    }
  }

  public func isApprovingApproval(_ item: ApprovalItem) -> Bool {
    approvingApprovalItemIDs.contains(item.id)
  }

  public func isRejectingApproval(_ item: ApprovalItem) -> Bool {
    rejectingApprovalItemIDs.contains(item.id)
  }

  public func isApprovalActionInProgress(_ item: ApprovalItem) -> Bool {
    isApprovingApproval(item) || isRejectingApproval(item)
  }

  public func discussApprovalInOpenClaw(
    _ item: ApprovalItem,
    message: String? = nil,
    threadMode: OpenClawThreadMode = .newThread
  ) async {
    let text = Self.openClawApprovalDiscussionPrompt(item: item, message: message)
    selectedSurface = .openClaw
    prepareOpenClawThread(
      mode: threadMode,
      title: "Discuss: \(Org2Display.cleanInline(item.title))",
      statusText: "New OpenClaw approval chat"
    )
    await sendOpenClawMessage(text: text)
  }

  public func copyApprovalDiscussionText(_ item: ApprovalItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.discussionText, forType: .string)
    statusText = "Copied approval discussion text"
  }

  private func syncApprovalSelectionAfterRefresh() {
    guard !visibleApprovalItems.isEmpty else {
      selectedApprovalItemID = nil
      return
    }
    if let selectedApprovalItemID,
       visibleApprovalItems.contains(where: { $0.id == selectedApprovalItemID }) {
      return
    }
    if selectedSurface == .approvals {
      selectApprovalItem(visibleApprovalItems[0])
    }
  }

  private func rebuildApprovalDisplayCache() {
    visibleApprovalItems = approvalItems.filter { $0.matchesApprovalFilter(approvalFilter) }
    if let selectedApprovalItemID,
       !visibleApprovalItems.contains(where: { $0.id == selectedApprovalItemID }) {
      self.selectedApprovalItemID = nil
    }
    pruneApprovalActionState()
  }

  private func beginApprovalAction(_ item: ApprovalItem, kind: ApprovalActionKind) {
    switch kind {
    case .approve:
      var ids = approvingApprovalItemIDs
      ids.insert(item.id)
      approvingApprovalItemIDs = ids
    case .reject:
      var ids = rejectingApprovalItemIDs
      ids.insert(item.id)
      rejectingApprovalItemIDs = ids
    }
  }

  private func endApprovalAction(_ item: ApprovalItem, kind: ApprovalActionKind) {
    switch kind {
    case .approve:
      var ids = approvingApprovalItemIDs
      ids.remove(item.id)
      approvingApprovalItemIDs = ids
    case .reject:
      var ids = rejectingApprovalItemIDs
      ids.remove(item.id)
      rejectingApprovalItemIDs = ids
    }
  }

  private func pruneApprovalActionState() {
    let itemIDs = Set(approvalItems.map(\.id))
    let nextApprovingIDs = approvingApprovalItemIDs.intersection(itemIDs)
    if nextApprovingIDs != approvingApprovalItemIDs {
      approvingApprovalItemIDs = nextApprovingIDs
    }
    let nextRejectingIDs = rejectingApprovalItemIDs.intersection(itemIDs)
    if nextRejectingIDs != rejectingApprovalItemIDs {
      rejectingApprovalItemIDs = nextRejectingIDs
    }
  }

  private func preserveApprovalSelectionAfterMutation(mutatedID: ApprovalItem.ID, originalVisibleIndex: Int?) {
    selectedSurface = .approvals

    if let item = nextApprovalItem(afterMutating: mutatedID, originalVisibleIndex: originalVisibleIndex) {
      selectApprovalItem(item)
      selectedSurface = .approvals
    } else {
      selectedApprovalItemID = nil
    }
  }

  private func removeApprovalItemOptimistically(_ id: ApprovalItem.ID, originalVisibleIndex: Int?) {
    approvalItems.removeAll { $0.id == id }
    preserveApprovalSelectionAfterMutation(mutatedID: id, originalVisibleIndex: originalVisibleIndex)
  }

  private func scheduleApprovalsRefresh(updatesStatus: Bool = false) {
    scheduledApprovalsRefreshTask?.cancel()
    scheduledApprovalsRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      await self.refreshApprovals(updatesStatus: updatesStatus)
      if !Task.isCancelled {
        self.scheduledApprovalsRefreshTask = nil
      }
    }
  }

  private func nextApprovalItem(afterMutating mutatedID: ApprovalItem.ID, originalVisibleIndex: Int?) -> ApprovalItem? {
    if let current = visibleApprovalItems.first(where: { $0.id == mutatedID }) {
      return current
    }

    guard !visibleApprovalItems.isEmpty else { return nil }
    let fallbackIndex = originalVisibleIndex ?? 0
    let boundedIndex = min(max(fallbackIndex, 0), visibleApprovalItems.count - 1)
    return visibleApprovalItems[boundedIndex]
  }

  nonisolated static func approvalItems(
    in document: Org2CanonicalDocument,
    file: String,
    sourceText: String
  ) -> [ApprovalItem] {
    let lines = normalizeLineEndings(sourceText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var items: [ApprovalItem] = []
    appendApprovalItems(from: document.children, file: file, sourceLines: lines, into: &items)
    return sortedApprovalItems(items)
  }

  nonisolated private static func appendApprovalItems(
    from nodes: [Org2CanonicalNode],
    file: String,
    sourceLines: [String],
    into items: inout [ApprovalItem]
  ) {
    for node in nodes {
      guard case .headline(let headline) = node else { continue }
      appendApprovalItem(from: headline, file: file, sourceLines: sourceLines, into: &items)
      appendApprovalItems(from: headline.children, file: file, sourceLines: sourceLines, into: &items)
    }
  }

  nonisolated private static func appendApprovalItem(
    from headline: Org2CanonicalHeadline,
    file: String,
    sourceLines: [String],
    into items: inout [ApprovalItem]
  ) {
    let todo = headline.todo?.uppercased()
    guard !isTerminalTodo(todo),
          let sourceRange = headline.sourceRange
    else {
      return
    }

    let properties = canonicalHeadlineProperties(headline)
    let title = canonicalInlineText(headline.title)
    guard let status = approvalStatus(title: title, properties: properties) else { return }

    items.append(ApprovalItem(
      title: title,
      status: status,
      todo: todo,
      level: headline.level,
      file: file,
      line: sourceRange.startLine,
      idValue: properties["ID"],
      properties: properties,
      body: approvalBody(
        sourceLines: sourceLines,
        sourceRange: sourceRange,
        children: headline.children
      ),
      tags: headline.tags ?? []
    ))
  }

  nonisolated private static func canonicalHeadlineProperties(_ headline: Org2CanonicalHeadline) -> [String: String] {
    for child in headline.children {
      guard case .propertyDrawer(let drawer) = child else { continue }
      return Dictionary(uniqueKeysWithValues: drawer.properties.map { ($0.key.uppercased(), $0.value) })
    }
    return [:]
  }

  nonisolated private static func approvalBody(
    sourceLines: [String],
    sourceRange: Org2CanonicalSourceRange,
    children: [Org2CanonicalNode]
  ) -> String {
    let startLine = max(1, sourceRange.startLine + 1)
    let endLine = max(startLine, sourceRange.endLine)
    guard startLine <= endLine, !sourceLines.isEmpty else { return "" }

    let hiddenRanges = children.compactMap { child -> ClosedRange<Int>? in
      switch child {
      case .propertyDrawer(let drawer):
        guard let range = drawer.sourceRange else { return nil }
        return range.startLine...range.endLine
      case .planning(let planning):
        guard let range = planning.sourceRange else { return nil }
        return range.startLine...range.endLine
      default:
        return nil
      }
    }

    var bodyLines: [String] = []
    for lineNumber in startLine...endLine {
      guard sourceLines.indices.contains(lineNumber - 1),
            !hiddenRanges.contains(where: { $0.contains(lineNumber) })
      else {
        continue
      }
      bodyLines.append(sourceLines[lineNumber - 1])
    }
    return bodyLines
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func approvalStatus(title: String, properties: [String: String]) -> String? {
    let status = firstPropertyText(
      in: properties,
      keys: [
        "ORG2_REVIEW_STATUS",
        "REVIEW_STATUS",
        "REVIEW",
        "STATUS",
        "FOLLOWUP_STATUS",
        "REPLY_STATUS"
      ]
    )
    if let status, isPendingApprovalStatus(status), titleNeedsHumanApproval(title) {
      return status
    }

    let waitingOn = firstPropertyText(in: properties, keys: ["WAITING_ON", "BLOCKED_BY", "ORG2_WAITING_ON"]) ?? ""
    if containsApprovalSignal(waitingOn) {
      return waitingOn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "approval-required" : waitingOn
    }

    let nextAction = firstPropertyText(in: properties, keys: ["NEXT_ACTION", "ACTION_REQUIRED", "ORG2_NEXT_ACTION"]) ?? ""
    if containsApprovalSignal(nextAction) {
      return "approval-required"
    }

    let handoff = firstPropertyText(in: properties, keys: ["HANDOFF_SUMMARY", "ORG2_HANDOFF_SUMMARY"]) ?? ""
    if containsApprovalSignal(handoff) {
      return "approval-required"
    }

    let accessPolicy = firstPropertyText(in: properties, keys: ["ACCESS_POLICY", "REVIEW_POLICY"]) ?? ""
    if isPendingApprovalStatus(accessPolicy) || containsApprovalSignal(accessPolicy) {
      return accessPolicy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "approval-required" : accessPolicy
    }

    return nil
  }

  nonisolated private static func firstPropertyText(in properties: [String: String], keys: [String]) -> String? {
    for key in keys {
      let value = properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      if value?.isEmpty == false {
        return value
      }
    }
    return nil
  }

  nonisolated private static func isPendingApprovalStatus(_ raw: String) -> Bool {
    let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if [
      "review-required",
      "requires-review",
      "approval-required",
      "needs-approval",
      "needs-review",
      "pending-review",
      "pending-approval",
      "require-approval",
      "generated",
      "draft"
    ].contains(normalized) {
      return true
    }

    return normalized.contains("needs-review")
      || normalized.contains("need-review")
      || normalized.contains("needs-approval")
      || normalized.contains("need-approval")
      || normalized.contains("waiting-on-approval")
      || normalized.contains("pending-review")
      || normalized.contains("pending-approval")
      || normalized.contains("draft-needs-review")
      || normalized.contains("draft-needs-approval")
      || normalized.contains("reply-review")
      || normalized.contains("needs-avi")
      || normalized.contains("avi-approval")
      || normalized.contains("needs-human")
      || normalized.contains("human-review")
  }

  nonisolated private static func titleNeedsHumanApproval(_ title: String) -> Bool {
    let normalized = Org2Display.cleanInline(title).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.hasPrefix("approve ")
      || normalized.hasPrefix("review ")
      || normalized.hasPrefix("review/")
      || normalized.hasPrefix("review-send ")
      || normalized.hasPrefix("review and approve ")
      || normalized.hasPrefix("review/approve ")
  }

  nonisolated private static func containsApprovalSignal(_ raw: String) -> Bool {
    let normalized = raw.lowercased()
    return normalized.contains("approval")
      || normalized.contains("approve")
      || normalized.contains("review")
      || normalized.contains("avi")
  }

  nonisolated private static func isTerminalTodo(_ todo: String?) -> Bool {
    guard let todo else { return false }
    return todo == "DONE" || todo == "CANCELED" || todo == "CANCELLED"
  }

  nonisolated private static func canonicalInlineText(_ inlines: [Org2CanonicalInline]) -> String {
    inlines.map(canonicalInlineText).joined()
  }

  nonisolated private static func canonicalInlineText(_ inline: Org2CanonicalInline) -> String {
    switch inline {
    case .text(let text):
      return text.value
    case .timestamp(let timestamp):
      return timestamp.raw
    case .timestampRange(let range):
      return "\(range.start.raw)\(range.separatorRaw)\(range.end.raw)"
    case .emphasis(let emphasis):
      return "\(emphasis.marker)\(emphasis.content)\(emphasis.marker)"
    case .link(let link):
      return link.descriptionRaw ?? link.targetRaw
    case .progressCookie(let raw):
      return raw
    case .unsupported(let type):
      return type
    }
  }

  nonisolated private static func sortedApprovalItems(_ items: [ApprovalItem]) -> [ApprovalItem] {
    items.sorted { lhs, rhs in
      let statusOrder = lhs.status.localizedCaseInsensitiveCompare(rhs.status)
      if statusOrder != .orderedSame { return statusOrder == .orderedAscending }
      let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
      if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
      if lhs.file != rhs.file { return lhs.file.localizedStandardCompare(rhs.file) == .orderedAscending }
      return lhs.line < rhs.line
    }
  }

  nonisolated private static func openClawApprovalDiscussionPrompt(item: ApprovalItem, message: String?) -> String {
    let intro = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
      ?? "I need to discuss this approval item before deciding."
    return """
    \(intro)

    \(item.discussionText)
    """
  }

  private func scheduleSearchIndexBuild(corpusRoot: URL) {
    searchIndexGeneration += 1
    let generation = searchIndexGeneration
    searchIndexTask?.cancel()
    isBuildingSearchIndex = true
    searchIndexStatusText = "Indexing search..."

    searchIndexTask = Task { [cli] in
      do {
        let payload: SearchIndexBuildPayload = try await cli.runJSON([
          "index",
          "--dir", corpusRoot.path,
          "--recursive",
          "--format", "json"
        ])
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard self.searchIndexGeneration == generation else { return }
          self.isBuildingSearchIndex = false
          let skipped = payload.skippedFiles > 0 ? ", \(payload.skippedFiles) skipped" : ""
          self.searchIndexStatusText = "\(payload.fileCount) files, \(payload.lineCount) lines indexed\(skipped)"
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard self.searchIndexGeneration == generation else { return }
          self.isBuildingSearchIndex = false
          self.searchIndexStatusText = "Search index unavailable"
        }
      }
    }
  }

  public func runSearch() async {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      searchResults = []
      openClawChatSearchResults = []
      return
    }
    isSearching = true
    errorText = nil
    statusText = "Searching workspace..."
    defer { isSearching = false }

    let started = Date()
    let chatResults = Self.searchOpenClawChatThreads(openClawChatThreads, query: query, limit: 25)
    guard let corpusRoot else {
      searchResults = []
      openClawChatSearchResults = chatResults
      selectedSurface = .search
      let elapsed = Date().timeIntervalSince(started)
      statusText = chatResults.isEmpty
        ? "No corpus selected"
        : "\(chatResults.count) chat result\(chatResults.count == 1 ? "" : "s") in \(String(format: "%.1f", elapsed))s"
      return
    }

    do {
      let payload: SearchPayload = try await cli.runJSON([
        "search", query,
        "--dir", corpusRoot.path,
        "--recursive",
        "--limit", "50",
        "--context", "1",
        "--index", "auto",
        "--format", "json"
      ])
      searchResults = Self.prioritizedSearchResultsForDisplay(payload.results)
      openClawChatSearchResults = chatResults
      selectedSurface = .search
      let elapsed = Date().timeIntervalSince(started)
      let totalCount = payload.results.count + chatResults.count
      statusText = "\(totalCount) search result\(totalCount == 1 ? "" : "s") in \(String(format: "%.1f", elapsed))s"
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
      reconcileMeetingProcessingState(with: items)
      syncMeetingSelectionAfterRefresh()
      recoverInterruptedMeetingTranscriptions(knownItems: items)
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
    guard !isRecordingMeeting else { return }

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
      isMeetingRecordingPaused = false
      startMeetingInputMetering()
      selectedSurface = .meetings
      meetingStatusText = "Recording \(paths.title)"
      statusText = meetingStatusText
    } catch {
      isCapturingSystemAudio = false
      isMeetingRecordingPaused = false
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
    guard let recording = activeMeetingRecording else {
      meetingStatusText = "No active recording"
      return
    }

    do {
      let duration = try meetingRecorder.stopRecording()
      var systemAudioURL: URL?
      var systemAudioCaptureError = recording.systemAudioStartError
      if recording.capturesSystemAudio {
        do {
          if let systemDuration = try await meetingSystemAudioRecorder.stopRecording(), systemDuration > 0 {
            systemAudioURL = recording.paths.systemAudioURL
          } else {
            try? FileManager.default.removeItem(at: recording.paths.systemAudioURL)
            systemAudioCaptureError = "No system audio samples were captured."
          }
        } catch {
          try? FileManager.default.removeItem(at: recording.paths.systemAudioURL)
          systemAudioCaptureError = error.localizedDescription
        }
      }
      self.activeMeetingRecording = nil
      isRecordingMeeting = false
      isMeetingRecordingPaused = false
      isCapturingSystemAudio = false
      stopMeetingInputMetering()
      beginMeetingProcessing(paths: recording.paths, status: "Transcribing \(recording.paths.title) locally...")
      let progressID = startMeetingTranscriptionProgress(
        title: recording.paths.title,
        audioDuration: duration
      )
      Task { [weak self] in
        await self?.finishStoppedMeetingRecording(
          recording,
          corpusRoot: corpusRoot,
          duration: duration,
          systemAudioURL: systemAudioURL,
          systemAudioCaptureError: systemAudioCaptureError,
          progressID: progressID
        )
      }
    } catch {
      isRecordingMeeting = false
      isMeetingRecordingPaused = false
      if isCapturingSystemAudio {
        _ = try? await meetingSystemAudioRecorder.stopRecording()
      }
      isCapturingSystemAudio = false
      meetingSystemAudioStatusText = "System audio not recording"
      stopMeetingInputMetering()
      errorText = error.localizedDescription
      meetingStatusText = "Stop failed: \(error.localizedDescription)"
      statusText = "Recording stop failed"
    }
  }

  public func pauseMeetingRecording() async {
    guard isRecordingMeeting, !isMeetingRecordingPaused else { return }
    guard let activeMeetingRecording else {
      meetingStatusText = "No active recording"
      return
    }

    do {
      try meetingRecorder.pauseRecording()
      if activeMeetingRecording.capturesSystemAudio {
        try await meetingSystemAudioRecorder.pauseRecording()
      }
      isMeetingRecordingPaused = true
      stopMeetingInputMetering()
      meetingStatusText = "Paused \(activeMeetingRecording.paths.title)"
      statusText = meetingStatusText
    } catch {
      errorText = error.localizedDescription
      meetingStatusText = "Pause failed: \(error.localizedDescription)"
      statusText = "Recording pause failed"
    }
  }

  public func resumeMeetingRecording() async {
    guard isRecordingMeeting, isMeetingRecordingPaused else { return }
    guard let activeMeetingRecording else {
      meetingStatusText = "No active recording"
      return
    }

    do {
      try meetingRecorder.resumeRecording()
      if activeMeetingRecording.capturesSystemAudio {
        try await meetingSystemAudioRecorder.resumeRecording()
      }
      isMeetingRecordingPaused = false
      startMeetingInputMetering()
      meetingStatusText = "Recording \(activeMeetingRecording.paths.title)"
      statusText = meetingStatusText
    } catch {
      errorText = error.localizedDescription
      meetingStatusText = "Resume failed: \(error.localizedDescription)"
      statusText = "Recording resume failed"
    }
  }

  private func finishStoppedMeetingRecording(
    _ recording: PendingMeetingRecording,
    corpusRoot: URL,
    duration: TimeInterval,
    systemAudioURL: URL?,
    systemAudioCaptureError: String?,
    progressID: UUID
  ) async {
    defer {
      endMeetingProcessing(paths: recording.paths)
      stopMeetingTranscriptionProgress(id: progressID)
    }

    do {
      let transcript = await transcribeRecordedMeetingAudio(
        microphoneAudioURL: recording.paths.audioURL,
        systemAudioURL: systemAudioURL,
        systemAudioCaptureError: systemAudioCaptureError
      )
      let bundle = try MeetingArtifactWriter.writeArtifacts(
        paths: recording.paths,
        corpusRoot: corpusRoot,
        duration: duration,
        transcript: transcript,
        systemAudioURL: systemAudioURL
      )
      meetingTitleDraft = ""
      meetingSystemAudioStatusText = systemAudioURL == nil
        ? "System audio not captured"
        : "System audio saved"
      let completionText = transcript.status == .complete
        ? "Saved \(bundle.noteURL.lastPathComponent)"
        : "Saved \(bundle.noteURL.lastPathComponent); transcription \(transcript.status.label)"
      if !isRecordingMeeting {
        meetingStatusText = completionText
      }
      statusText = completionText
      await refreshAfterMeetingWrite(selecting: bundle.item)
    } catch {
      errorText = error.localizedDescription
      let failureText = "Meeting save failed: \(error.localizedDescription)"
      if !isRecordingMeeting {
        meetingStatusText = failureText
      }
      statusText = "Meeting save failed"
    }
  }

  private func recoverInterruptedMeetingTranscriptions(knownItems: [MeetingWorkspaceItem]) {
    guard let corpusRoot else { return }
    Task { [weak self] in
      guard let self else { return }
      let recoverable: [RecoverableMeetingRecording]
      do {
        recoverable = try await Task.detached(priority: .utility) {
          try Self.scanRecoverableMeetingRecordings(corpusRoot: corpusRoot)
        }.value
      } catch {
        await MainActor.run {
          self.errorText = error.localizedDescription
          self.statusText = "Meeting recovery scan failed"
        }
        return
      }

      await MainActor.run {
        self.startRecoveringInterruptedMeetings(recoverable, knownItems: knownItems, corpusRoot: corpusRoot)
      }
    }
  }

  private func startRecoveringInterruptedMeetings(
    _ recoverable: [RecoverableMeetingRecording],
    knownItems: [MeetingWorkspaceItem],
    corpusRoot: URL
  ) {
    guard !recoverable.isEmpty else { return }
    let knownAudioArtifacts = Set(knownItems.compactMap(\.audioArtifact))

    for recording in recoverable {
      let processingID = Self.meetingProcessingID(for: recording.paths)
      guard !activeMeetingProcessingIDs.contains(processingID) else { continue }
      let relativeAudio = MeetingArtifactWriter.relativePath(from: corpusRoot, to: recording.paths.audioURL)
      guard !knownAudioArtifacts.contains(relativeAudio) else { continue }

      beginMeetingProcessing(
        paths: recording.paths,
        status: "Resuming transcription for \(recording.paths.title)..."
      )
      let progressID = startMeetingTranscriptionProgress(
        title: recording.paths.title,
        audioDuration: recording.duration
      )
      Task { [weak self] in
        await self?.finishRecoveredMeetingRecording(
          recording,
          corpusRoot: corpusRoot,
          progressID: progressID
        )
      }
    }
  }

  private func finishRecoveredMeetingRecording(
    _ recording: RecoverableMeetingRecording,
    corpusRoot: URL,
    progressID: UUID
  ) async {
    defer {
      endMeetingProcessing(paths: recording.paths)
      stopMeetingTranscriptionProgress(id: progressID)
    }

    let transcript = await transcribeRecordedMeetingAudio(
      microphoneAudioURL: recording.paths.audioURL,
      systemAudioURL: recording.systemAudioURL,
      systemAudioCaptureError: recording.systemAudioCaptureError
    )

    do {
      let bundle = try MeetingArtifactWriter.writeArtifacts(
        paths: recording.paths,
        corpusRoot: corpusRoot,
        duration: recording.duration,
        transcript: transcript,
        systemAudioURL: recording.systemAudioURL,
        captureSources: recording.captureSources
      )
      let completionText = transcript.status == .complete
        ? "Recovered \(bundle.noteURL.lastPathComponent)"
        : "Recovered \(bundle.noteURL.lastPathComponent); transcription \(transcript.status.label)"
      if !isRecordingMeeting {
        meetingStatusText = completionText
      }
      statusText = completionText
      await refreshAfterMeetingWrite(selecting: bundle.item)
    } catch {
      errorText = error.localizedDescription
      let failureText = "Meeting recovery failed: \(error.localizedDescription)"
      if !isRecordingMeeting {
        meetingStatusText = failureText
      }
      statusText = "Meeting recovery failed"
    }
  }

  public func promptAndImportMeetingAudio() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    guard !isRecordingMeeting else { return }

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

    var processingPaths: MeetingArtifactPaths?
    var progressID: UUID?
    defer {
      if let processingPaths {
        endMeetingProcessing(paths: processingPaths)
      }
      if let progressID {
        stopMeetingTranscriptionProgress(id: progressID)
      }
    }
    let recordedAt = Date()

    do {
      let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
      let paths = try MeetingArtifactWriter.preparePaths(
        corpusRoot: corpusRoot,
        title: rawTitle,
        recordedAt: recordedAt,
        audioExtension: ext
      )
      processingPaths = paths
      beginMeetingProcessing(paths: paths, status: "Importing \(paths.title)...")
      try FileManager.default.copyItem(at: sourceURL, to: paths.audioURL)
      meetingStatusText = "Transcribing \(paths.title) locally..."
      progressID = startMeetingTranscriptionProgress(title: paths.title, audioDuration: nil)
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

  public func askOpenClawAboutSelectedMeeting(threadMode: OpenClawThreadMode = .newThread) {
    guard case .meeting(let meeting) = selectedLocation else {
      statusText = "Select a meeting first"
      return
    }
    prepareOpenClawThread(
      mode: threadMode,
      title: "Meeting: \(Org2Display.cleanInline(meeting.title))",
      statusText: "New OpenClaw meeting chat"
    )
    publishOpenClawComposerDraft("Use the selected meeting note and transcript artifact as context. Summarize the meeting, extract decisions, list action items, and cite the org2 file paths you used.")
    selectedSurface = .openClaw
  }

  public func confirmAndDeleteMeeting(_ meeting: MeetingWorkspaceItem) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Delete Meeting?"
    alert.informativeText = "This deletes the meeting note and any linked audio/transcript artifacts from the corpus."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task { await deleteMeeting(meeting) }
  }

  public func deleteMeeting(_ meeting: MeetingWorkspaceItem) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    let urls = meetingArtifactURLs(for: meeting, corpusRoot: corpusRoot)
    do {
      for url in urls {
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
      }
      meetings.removeAll { $0.id == meeting.id }
      if selectedMeetingID == meeting.id {
        selectedMeetingID = nil
      }
      if selectedLocation?.file == meeting.file {
        selectedLocation = nil
        selectedEntrySource = nil
      }
      statusText = "Deleted \(Org2Display.cleanInline(meeting.title))"
      meetingStatusText = statusText
      await refreshMeetings()
      await refreshAgenda()
      Task { await refreshOpenClawThreads(showsLoading: false) }
    } catch {
      errorText = error.localizedDescription
      statusText = "Meeting delete failed"
      meetingStatusText = "Delete failed: \(error.localizedDescription)"
    }
  }

  public var canAskOpenClawAboutCurrentSelection: Bool {
    selectedEntrySource != nil || selectedLocation != nil
  }

  public var hasWorkspaceDetailContent: Bool {
    selectedLocation != nil || selectedEntrySource != nil
  }

  public var canBriefCurrentNodeInOpenClaw: Bool {
    selectedLocation != nil
      && corpusRoot != nil
      && !isBuildingNodeBrief
      && (openClawBriefsStartNewThread || !isSendingOpenClawMessage)
  }

  public var canLinkifyCurrentFile: Bool {
    corpusRoot != nil && (selectedEntrySource?.file != nil || selectedLocation?.file != nil)
  }

  public func askOpenClawAboutCurrentSelection(threadMode: OpenClawThreadMode = .newThread) {
    guard let pointer = openClawContextPointerForCurrentSelection() else {
      statusText = "Select a page or entry first"
      return
    }

    addOpenClawContext(pointer, threadMode: threadMode)
  }

  public func askOpenClawAboutBlock(_ block: OrgEditableBlock, threadMode: OpenClawThreadMode = .newThread) {
    if selectedRenderedBlockIndexes[block.id] != nil {
      selectedBlockID = block.id
    }

    guard let pointer = openClawContextPointer(for: OpenClawBlockContextPointer(source: selectedEntrySource, block: block)) else {
      askOpenClawAboutCurrentSelection(threadMode: threadMode)
      return
    }

    addOpenClawContext(pointer, threadMode: threadMode)
  }

  public func briefCurrentNodeInOpenClaw() async {
    guard let location = selectedLocation else {
      statusText = "Select a node first"
      return
    }
    guard let corpusRoot else {
      statusText = "Open a corpus first"
      return
    }

    let existingID = location.idValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    let initialArtifactRelativePath = Self.nodeBriefArtifactRelativePath(
      title: location.title,
      id: existingID?.isEmpty == false ? existingID : nil,
      file: relativePath(location.file),
      line: location.lineForEditor
    )
    let initialArtifactURL = corpusRoot.appendingPathComponent(initialArtifactRelativePath).standardizedFileURL
    if Self.hasUsableNodeBriefArtifact(at: initialArtifactURL) {
      openNodeBriefArtifact(url: initialArtifactURL, relativePath: initialArtifactRelativePath, title: location.title)
      return
    }

    isBuildingNodeBrief = true
    openClawStatusText = "Sending node brief request..."
    statusText = "Sending node brief request..."
    defer { isBuildingNodeBrief = false }

    do {
      let id = try await backlinkTargetID(for: location)
      let artifactRelativePath = Self.nodeBriefArtifactRelativePath(
        title: location.title,
        id: id,
        file: relativePath(location.file),
        line: location.lineForEditor
      )
      let artifactURL = corpusRoot.appendingPathComponent(artifactRelativePath).standardizedFileURL
      if Self.hasUsableNodeBriefArtifact(at: artifactURL) {
        openNodeBriefArtifact(url: artifactURL, relativePath: artifactRelativePath, title: location.title)
        return
      }

      let prompt = Self.nodeBriefPrompt(
        title: location.title,
        reference: "\(relativePath(location.file)):\(location.lineForEditor)",
        artifactRelativePath: artifactRelativePath,
        artifactLocalPath: artifactURL.path,
        artifactOpenClawPath: mappedPathForOpenClaw(artifactURL.path),
        sourceID: id
      )
      pendingNodeBriefArtifactRelativePath = artifactRelativePath
      pendingNodeBriefTitle = location.title
      setOpenClawAssistantPanelPresented(true)
      prepareOpenClawThreadForNodeBrief(title: location.title)
      await sendOpenClawMessage(text: prompt)
      if await openNodeBriefArtifactWhenAvailable(url: artifactURL, relativePath: artifactRelativePath, title: location.title) {
        return
      }
      if openClawStatusText == "OpenClaw replied" || openClawStatusText.hasPrefix("Edited ") {
        pendingNodeBriefArtifactRelativePath = nil
        pendingNodeBriefTitle = nil
        openClawStatusText = "OpenClaw replied without writing the node brief artifact"
        statusText = "Node brief artifact was not written"
      }
    } catch {
      errorText = error.localizedDescription
      openClawStatusText = "Node brief failed"
      statusText = "Node brief failed"
    }
  }

  private func openNodeBriefArtifactWhenAvailable(url: URL, relativePath: String, title: String) async -> Bool {
    let expectedPath = url.standardizedFileURL.path
    for delay in Self.nodeBriefArtifactRetryDelays {
      if delay > 0 {
        try? await Task.sleep(nanoseconds: delay)
      }
      if case .openClaw(let thread) = selectedLocation,
         URL(fileURLWithPath: thread.file).standardizedFileURL.path == expectedPath {
        return true
      }
      guard Self.hasUsableNodeBriefArtifact(at: url) else { continue }
      await refreshCorpusFiles()
      Task { await refreshOpenClawThreads(showsLoading: false) }
      openNodeBriefArtifact(url: url, relativePath: relativePath, title: title)
      return true
    }
    return false
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

  public var pendingMeetingProcessingItems: [MeetingProcessingItem] {
    let existingMeetingIDs = Set(meetings.map(Self.meetingProcessingID(for:)))
    return processingMeetings.filter { !existingMeetingIDs.contains($0.id) }
  }

  public func isMeetingProcessing(_ meeting: MeetingWorkspaceItem) -> Bool {
    activeMeetingProcessingIDs.contains(Self.meetingProcessingID(for: meeting))
  }

  public func select(_ location: WorkspaceLocation) {
    if case .search = location {
      isPageSearchPresented = false
      pageSearchQuery = ""
      renderedSearchHighlightQuery = Self.normalizedRenderedSearchHighlightQuery(searchQuery)
      resetPageSearchMatches()
    } else {
      isPageSearchPresented = false
      pageSearchQuery = ""
      renderedSearchHighlightQuery = nil
      resetPageSearchMatches()
    }
    activateDetailLocation(location, mode: nil, recordsHistory: true)
  }

  public var hasRenderedSearchHighlight: Bool {
    renderedSearchHighlightQuery?.isEmpty == false
  }

  public func clearRenderedSearchHighlight() {
    renderedSearchHighlightQuery = nil
    pageSearchQuery = ""
    isPageSearchPresented = false
    resetPageSearchMatches()
  }

  @discardableResult
  public func focusPageSearch() -> Bool {
    guard selectedLocation != nil else { return false }
    isPageSearchPresented = true
    pageSearchQuery = renderedSearchHighlightQuery ?? ""
    renderedSearchHighlightQuery = Self.normalizedRenderedSearchHighlightQuery(pageSearchQuery)
    refreshPageSearchMatches(selectFirst: true)
    pageSearchFocusToken += 1
    return true
  }

  public var pageSearchOccurrenceSummary: String {
    guard renderedSearchHighlightQuery?.isEmpty == false else { return "" }
    let total = max(pageSearchOccurrenceCount, pageSearchRenderedMatches.count)
    guard total > 0 else { return "0 matches" }
    if let pageSearchSelectedOccurrenceIndex {
      return "\(min(pageSearchSelectedOccurrenceIndex + 1, total)) of \(total)"
    }
    return "\(total) matches"
  }

  public var canNavigatePageSearchOccurrences: Bool {
    pageSearchRenderedMatches.count > 1
  }

  public func selectNextPageSearchOccurrence() {
    selectAdjacentPageSearchOccurrence(delta: 1)
  }

  public func selectPreviousPageSearchOccurrence() {
    selectAdjacentPageSearchOccurrence(delta: -1)
  }

  private func selectAdjacentPageSearchOccurrence(delta: Int) {
    refreshPageSearchMatches(selectFirst: false)
    guard !pageSearchRenderedMatches.isEmpty else { return }
    let current = pageSearchSelectedOccurrenceIndex ?? 0
    let count = pageSearchRenderedMatches.count
    let next = (current + delta + count) % count
    selectPageSearchOccurrence(at: next)
  }

  private func refreshPageSearchMatches(selectFirst: Bool) {
    guard let query = renderedSearchHighlightQuery else {
      resetPageSearchMatches()
      return
    }

    let matches = Self.renderedPageSearchMatches(in: selectedRenderedBlocks, query: query)
    pageSearchRenderedMatches = matches
    pageSearchOccurrenceCount = Self.countSearchOccurrences(
      in: pageSearchFullFileText() ?? selectedEntrySource?.text ?? "",
      query: query
    )

    guard !matches.isEmpty else {
      pageSearchSelectedOccurrenceIndex = nil
      return
    }

    let selectedIndex = pageSearchSelectedOccurrenceIndex
    let nextIndex: Int
    if selectFirst || selectedIndex == nil {
      nextIndex = 0
    } else {
      nextIndex = min(selectedIndex ?? 0, matches.count - 1)
    }
    selectPageSearchOccurrence(at: nextIndex)
  }

  private func resetPageSearchMatches() {
    pageSearchRenderedMatches = []
    pageSearchOccurrenceCount = 0
    pageSearchSelectedOccurrenceIndex = nil
  }

  private func selectPageSearchOccurrence(at index: Int) {
    guard pageSearchRenderedMatches.indices.contains(index) else { return }
    let match = pageSearchRenderedMatches[index]
    pageSearchSelectedOccurrenceIndex = index
    selectedBlockID = match.blockID
    requestDetailScroll(toBlock: match.blockID)
  }

  private func pageSearchFullFileText() -> String? {
    if isLiveFileEditorSelected {
      return editableEntryText
    }
    guard let file = selectedEntrySource?.file else { return nil }
    return try? String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
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
    let nextMode = resolvedEntrySourceMode(for: location, requestedMode: mode)
    if canReuseActiveDetail(for: location, mode: nextMode) {
      applyDetailSelectionMetadata(for: location)
      selectedLocation = location
      return
    }

    persistLiveFileEditorDraftBeforeNavigation()
    cancelLiveFileEditorAutosave(resetStatus: false)
    isWorkspaceDetailPaneClosed = false
    isWorkspaceDetailPaneExpanded = false
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

    switch location {
    case .search:
      break
    default:
      isPageSearchPresented = false
      pageSearchQuery = ""
      renderedSearchHighlightQuery = nil
      resetPageSearchMatches()
    }

    applyDetailSelectionMetadata(for: location)
    selectedLocation = location
    isEditingEntry = false
    editableEntryText = ""
    sourceEditorSelection = NSRange(location: 0, length: 0)
    resetBlockState()
    selectedEntrySourceMode = nextMode
    selectedEntrySource = nil
    selectedEntryHTML = nil
    selectedEntryRenderError = nil
    selectedEntryHTMLRenderKey = nil
    selectedRenderedBlocks = []
    isRenderingEntrySource = false
    entryHTMLRenderGeneration += 1
    Task { await loadBacklinks(for: location) }
    scheduleEntrySourceLoad(for: location)
  }

  private func resolvedEntrySourceMode(
    for location: WorkspaceLocation,
    requestedMode: EntrySourceMode?
  ) -> EntrySourceMode {
    if let requestedMode {
      return requestedMode
    }
    if case .meeting = location {
      return .page
    }
    return .entry
  }

  private func canReuseActiveDetail(for location: WorkspaceLocation, mode: EntrySourceMode) -> Bool {
    guard let selectedLocation,
          Self.selectionIdentity(for: selectedLocation) == Self.selectionIdentity(for: location),
          selectedEntrySourceMode == mode
    else {
      return false
    }
    return selectedEntrySource != nil || isRenderingEntrySource
  }

  private func applyDetailSelectionMetadata(for location: WorkspaceLocation) {
    if case .agenda(let item) = location {
      selectedAgendaItemID = item.id
    }
    if case .assigned(let item) = location {
      selectedAssignedWorkItemID = item.id
    }
    if case .openClaw(let thread) = location {
      selectedOpenClawThreadID = thread.id
    }
    if case .meeting(let meeting) = location {
      selectedMeetingID = meeting.id
    }
  }

  public func loadEntrySource(for location: WorkspaceLocation) async {
    entrySourceLoadGeneration += 1
    let generation = entrySourceLoadGeneration
    await loadEntrySource(for: location, generation: generation)
  }

  private func scheduleEntrySourceLoad(for location: WorkspaceLocation) {
    entrySourceLoadGeneration += 1
    let generation = entrySourceLoadGeneration
    applyCachedEntrySourceIfAvailable(for: location, generation: generation)
    Task { await loadEntrySource(for: location, generation: generation) }
  }

  private func loadEntrySource(for location: WorkspaceLocation, generation: Int) async {
    guard generation == entrySourceLoadGeneration else { return }
    activeEntrySourceLoadingGeneration = generation
    isLoadingEntrySource = true
    isRenderingEntrySource = false
    defer {
      if activeEntrySourceLoadingGeneration == generation {
        activeEntrySourceLoadingGeneration = nil
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
      cacheEntrySource(source, for: location, mode: mode, modifiedAt: Self.modificationDate(for: URL(fileURLWithPath: source.file).standardizedFileURL))
      guard !shouldDeferEntrySourceApplicationDuringActiveEdit(for: location) else {
        return
      }
      let previousSource = selectedEntrySource
      prepareEntryHTML(for: source)
      selectedEntrySource = source
      updateEditableEntryTextFromLoadedSourceIfSafe(source, previousSource: previousSource)
      renderEntrySource(source, generation: generation)
    } catch {
      guard generation == entrySourceLoadGeneration,
            selectedLocationMatches(location)
      else {
        return
      }
      selectedEntrySource = nil
      selectedEntryHTML = nil
      selectedEntryRenderError = error.localizedDescription
      selectedEntryHTMLRenderKey = nil
      selectedRenderedBlocks = []
      selectedBlockID = nil
      isRenderingEntrySource = false
      errorText = error.localizedDescription
    }
  }

  private func applyCachedEntrySourceIfAvailable(for location: WorkspaceLocation, generation: Int) {
    let mode = selectedEntrySourceMode
    guard let source = cachedEntrySource(for: location, mode: mode) else { return }
    guard !shouldDeferEntrySourceApplicationDuringActiveEdit(for: location) else {
      return
    }
    let previousSource = selectedEntrySource
    prepareEntryHTML(for: source)
    selectedEntrySource = source
    updateEditableEntryTextFromLoadedSourceIfSafe(source, previousSource: previousSource)
    renderEntrySource(source, generation: generation)
  }

  private func shouldDeferEntrySourceApplicationDuringActiveEdit(for location: WorkspaceLocation) -> Bool {
    guard selectedLocationMatches(location), selectedEntrySource != nil else { return false }
    if editingBlockID != nil { return true }
    if isEditingEntry { return true }
    if isLiveFileEditorSelected && liveFileEditorHasUnsavedChanges {
      return true
    }
    return false
  }

  private func updateEditableEntryTextFromLoadedSourceIfSafe(_ source: EntrySource, previousSource: EntrySource?) {
    if isEditingEntry {
      let hadUnsavedChanges = Self.normalizeLineEndings(editableEntryText)
        != Self.normalizeLineEndings(previousSource?.text ?? "")
      if !hadUnsavedChanges {
        editableEntryText = source.text
      }
    } else if isLiveFileEditorSelected {
      let hadUnsavedChanges = Self.normalizeLineEndings(editableEntryText)
        != Self.normalizeLineEndings(previousSource?.text ?? "")
      guard !hadUnsavedChanges else { return }
      editableEntryText = source.text
    }
  }

  public func reloadSelectedEntrySource() async {
    isEditingEntry = false
    editableEntryText = ""
    resetBlockState()
    guard let selectedLocation else { return }
    await loadEntrySource(for: selectedLocation)
  }

  public func linkifyCurrentFile() async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    guard let file = selectedEntrySource?.file ?? selectedLocation?.file else {
      statusText = "Open a file first"
      return
    }

    do {
      let payload: RoamLinkifyPayload = try await cli.runJSON([
        "roam", "linkify",
        "--dir", corpusRoot.path,
        "--recursive",
        "--file", file,
        "--apply",
        "--format", "json"
      ])
      invalidateCanonicalDocumentCache(for: file)
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      await refreshCorpusFiles()
      let relative = relativePath(file)
      statusText = payload.replacementCount > 0
        ? "Linkified \(relative): \(payload.replacementCount) link\(payload.replacementCount == 1 ? "" : "s")"
        : "No linkify changes in \(relative)"
      if payload.ambiguousSkipCount > 0 || payload.representedSuggestionCount > 0 {
        statusText += " (\(payload.ambiguousSkipCount) ambiguous, \(payload.representedSuggestionCount) suggestions)"
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Linkify failed"
    }
  }

  public func beginEditingSelectedEntry(initialSelection: NSRange? = nil) {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    editableEntryText = source.text
    sourceEditorSelection = Self.clampedSourceEditorSelection(
      initialSelection ?? NSRange(location: 0, length: 0),
      in: source.text
    )
    resetBlockState()
    sourceEditorDiagnostics = []
    isEditingEntry = true
  }

  public func requestSourceEditorCommand(_ command: OrgSourceEditorCommand) {
    guard isEditingEntry else {
      statusText = "Open source editing first"
      return
    }
    sourceEditorCommandGeneration += 1
    sourceEditorCommandRequest = OrgSourceEditorCommandRequest(
      id: sourceEditorCommandGeneration,
      command: command
    )
  }

  public func analyzeSourceEditorText(_ text: String) async -> OrgSourceEditorSemanticSnapshot? {
    do {
      return try await cli.analyzeEditorText(text)
    } catch {
      return nil
    }
  }

  public func beginEditingCurrentScope() {
    if let selectedBlock {
      beginEditingSource(for: selectedBlock)
      return
    }
    beginEditingSelectedEntry()
  }

  public func beginEditingVisibleBlock() {
    guard selectedEntrySource?.isEditable == true else {
      statusText = "No editable source loaded"
      return
    }

    if let selectedBlock {
      beginEditingSource(for: selectedBlock)
      return
    }

    guard let firstEditableBlock = selectableBlocks.first else {
      beginEditingSelectedEntry()
      return
    }
    beginEditingSource(for: firstEditableBlock)
  }

  public func cancelEditingSelectedEntry() {
    editableEntryText = selectedEntrySource?.text ?? ""
    sourceEditorSelection = NSRange(location: 0, length: 0)
    sourceEditorDiagnostics = []
    sourceEditorCommandRequest = nil
    isEditingEntry = false
  }

  public func beginEditingSource(for block: OrgEditableBlock, selection: NSRange? = nil) {
    guard block.isEditable,
          let source = selectedEntrySource,
          source.isEditable
    else {
      statusText = "Block is read-only"
      return
    }
    let sourceSelection = Self.sourceEditorSelectionRange(
      for: block,
      in: source,
      selection: selection
    )
    beginEditingSelectedEntry(initialSelection: sourceSelection)
  }

  nonisolated static func sourceEditorSelectionRange(
    for block: OrgEditableBlock,
    in source: EntrySource,
    selection: NSRange? = nil
  ) -> NSRange {
    let blockStartOffset = sourceEditorUTF16Offset(forAbsoluteLine: block.startLine, in: source)
    let sourceLength = source.text.utf16.count
    let blockLength = block.rawText.utf16.count
    let localSelection = selection ?? NSRange(location: 0, length: 0)
    let localLocation = min(max(0, localSelection.location), blockLength)
    let localLength = min(max(0, localSelection.length), max(0, blockLength - localLocation))
    let sourceLocation = min(sourceLength, blockStartOffset + localLocation)
    let sourceLengthRemaining = max(0, sourceLength - sourceLocation)
    return NSRange(
      location: sourceLocation,
      length: min(localLength, sourceLengthRemaining)
    )
  }

  nonisolated private static func clampedSourceEditorSelection(
    _ selection: NSRange,
    in text: String
  ) -> NSRange {
    let textLength = text.utf16.count
    let location = min(max(0, selection.location), textLength)
    return NSRange(
      location: location,
      length: min(max(0, selection.length), max(0, textLength - location))
    )
  }

  nonisolated private static func sourceEditorUTF16Offset(
    forAbsoluteLine line: Int,
    in source: EntrySource
  ) -> Int {
    let lineOffset = max(0, line - source.startLine)
    guard lineOffset > 0 else { return 0 }

    var currentLineOffset = 0
    var utf16Offset = 0
    var index = source.text.utf16.startIndex
    while index < source.text.utf16.endIndex {
      let codeUnit = source.text.utf16[index]
      utf16Offset += 1
      index = source.text.utf16.index(after: index)
      if codeUnit == 10 {
        currentLineOffset += 1
        if currentLineOffset >= lineOffset {
          return utf16Offset
        }
      }
    }
    return utf16Offset
  }

  public func beginEditingBlock(
    _ block: OrgEditableBlock,
    initialDraft: String? = nil,
    initialSelection: NSRange? = nil
  ) {
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
    if let initialSelection {
      activeBlockInitialSelections[block.id] = initialSelection
    } else {
      activeBlockInitialSelections.removeValue(forKey: block.id)
    }
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

  public func initialSelectionForEditingBlock(_ block: OrgEditableBlock) -> NSRange? {
    guard editingBlockID == block.id else { return nil }
    return activeBlockInitialSelections[block.id]
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
      return entryEditorHasUnsavedChanges && !isSavingEntry
    }
    if editingBlockID != nil {
      return !isSavingBlock
    }
    return false
  }

  public var canSaveCurrentFile: Bool {
    (isEditingEntry && !isSavingEntry)
      || canSaveActiveEdit
      || canSaveLiveFileEditor
      || (orgCryptEncryptOnSave && selectedFileForOrgCryptSave != nil)
  }

  public var hasActiveEdit: Bool {
    isEditingEntry || editingBlockID != nil
  }

  public var isLiveFileEditorSelected: Bool {
    selectedSurface == .files
      && selectedEntrySourceMode == .page
      && selectedLocation != nil
  }

  public var isLiveFileEditorAvailable: Bool {
    isLiveFileEditorSelected && selectedEntrySource?.isEditable == true
  }

  public var canSaveLiveFileEditor: Bool {
    isLiveFileEditorAvailable && liveFileEditorHasUnsavedChanges && !isSavingEntry
  }

  public var liveFileEditorHasUnsavedChanges: Bool {
    guard let source = selectedEntrySource, isLiveFileEditorSelected else { return false }
    return Self.normalizeLineEndings(editableEntryText) != Self.normalizeLineEndings(source.text)
  }

  public var entryEditorHasUnsavedChanges: Bool {
    guard isEditingEntry, let source = selectedEntrySource else { return false }
    return Self.normalizeLineEndings(editableEntryText) != Self.normalizeLineEndings(source.text)
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
    beginEditingSource(for: selectedBlock)
  }

  public func beginEditingSelectedBlock(appending text: String) -> Bool {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return false
    }
    beginEditingSource(
      for: selectedBlock,
      selection: NSRange(location: selectedBlock.rawText.utf16.count, length: 0)
    )
    insertTextInSourceEditor(text)
    return true
  }

  private func insertTextInSourceEditor(_ text: String) {
    guard isEditingEntry, !text.isEmpty else { return }
    let range = Self.clampedSourceEditorSelection(sourceEditorSelection, in: editableEntryText)
    editableEntryText = (editableEntryText as NSString).replacingCharacters(in: range, with: text)
    sourceEditorSelection = NSRange(location: range.location + text.utf16.count, length: 0)
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

  public func beginAppendingSectionAtEnd() async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }

    if let lastBlock = selectedRenderedBlocks
      .filter({ block in
        block.isEditable
          && block.startLine >= source.startLine
          && block.endLineExclusive <= source.endLineExclusive
      })
      .max(by: { lhs, rhs in
        if lhs.endLineExclusive != rhs.endLineExclusive {
          return lhs.endLineExclusive < rhs.endLineExclusive
        }
        return lhs.startLine < rhs.startLine
      }) {
      await insertBlock(after: lastBlock, kind: .paragraph)
      return
    }

    let draft = appendDraftBlock(kind: .paragraph, in: source)
    transientDraftBlock = draft
    pendingBlockSelection = nil
    isEditingEntry = false
    activateTransientDraft(draft)
    statusText = "Started paragraph draft in \(relativePath(source.file))"
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

    if let draft = transientDraftBlock, editingBlockID == draft.block.id {
      await saveTransientDraftBlock(draft)
      return
    }

    guard let block = activeEditingBlock else {
      if isLiveFileEditorAvailable && liveFileEditorHasUnsavedChanges {
        await saveLiveFileEditor(explicit: true)
        return
      }
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
    guard entryEditorHasUnsavedChanges else {
      statusText = "No source changes to save"
      return
    }

    isSavingEntry = true
    defer { isSavingEntry = false }

    let replacement = editableEntryText
    let undoSnapshot = fileUndoSnapshot(for: source.file)
    do {
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceEntrySource(source, with: replacement)
      }.value
    } catch {
      errorText = error.localizedDescription
      if case WorkspaceEditError.fileChanged = error {
        statusText = "Save conflict: file changed on disk"
      } else {
        statusText = "Save failed"
      }
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
      recordFileUndo(from: undoSnapshot)
      await finishSavedEntry(source: source, savedText: replacement, keepEditing: true)
      return
    }

    recordFileUndo(from: undoSnapshot)
    statusText = savedStatus
    await finishSavedEntry(
      source: source,
      savedText: replacement,
      keepEditing: !savedStatus.contains("encrypted")
    )
  }

  public func noteLiveFileEditorTextChanged(_ text: String) {
    guard isLiveFileEditorSelected else { return }
    if editableEntryText != text {
      editableEntryText = text
    }
    liveFileEditorStatusText = liveFileEditorHasUnsavedChanges ? "Unsaved" : "Saved"
    scheduleLiveFileEditorAutosave()
  }

  public func revertLiveFileEditor() {
    cancelLiveFileEditorAutosave(resetStatus: true)
    editableEntryText = selectedEntrySource?.text ?? ""
    liveFileEditorStatusText = "Reverted"
  }

  public func saveLiveFileEditor(explicit: Bool) async {
    if explicit {
      cancelLiveFileEditorAutosave(resetStatus: false)
    }

    guard let source = selectedEntrySource, source.isEditable, isLiveFileEditorSelected else {
      if explicit {
        statusText = "No editable file loaded"
      }
      return
    }

    let replacement = editableEntryText
    let hasTextChanges = Self.normalizeLineEndings(replacement) != Self.normalizeLineEndings(source.text)
    guard hasTextChanges else {
      liveFileEditorStatusText = "Saved"
      if explicit {
        await encryptSelectedFileAfterSave()
      }
      return
    }

    let undoSnapshot = fileUndoSnapshot(for: source.file)
    if explicit {
      isSavingEntry = true
    } else {
      isLiveFileEditorAutosaving = true
    }
    defer {
      if explicit {
        isSavingEntry = false
      } else {
        isLiveFileEditorAutosaving = false
      }
    }

    do {
      if explicit {
        try await Task.detached(priority: .userInitiated) {
          try Self.replaceEntrySource(source, with: replacement)
        }.value
      } else {
        guard selectedEntrySource?.id == source.id,
              Self.normalizeLineEndings(editableEntryText) == Self.normalizeLineEndings(replacement)
        else {
          return
        }
        try Self.replaceEntrySource(source, with: replacement)
      }
    } catch {
      errorText = error.localizedDescription
      if case WorkspaceEditError.fileChanged = error {
        liveFileEditorStatusText = "Conflict"
        statusText = "Save conflict: file changed on disk"
      } else {
        liveFileEditorStatusText = explicit ? "Save failed" : "Autosave failed"
      }
      if explicit {
        if !statusText.hasPrefix("Save conflict") {
          statusText = "Save failed"
        }
      }
      return
    }

    guard selectedEntrySource?.id == source.id else {
      recordFileUndo(from: undoSnapshot)
      return
    }
    if !explicit {
      guard Self.normalizeLineEndings(editableEntryText) == Self.normalizeLineEndings(replacement) else {
        return
      }
    }

    selectedEntrySource = Self.entrySource(source, replacingText: replacement)
    invalidateCanonicalDocumentCache(for: source.file)
    if let corpusRoot {
      upsertCorpusFile(corpusFile(for: URL(fileURLWithPath: source.file), corpusRoot: corpusRoot))
    }

    if explicit {
      let savedStatus: String
      do {
        let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)
        savedStatus = encryptedCount > 0
          ? "Saved and encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
          : "Saved \(relativePath(source.file))"
      } catch {
        recordOrgCryptEncryptionFailure(error, savedPrefix: "Saved, but")
        recordFileUndo(from: undoSnapshot)
        liveFileEditorStatusText = "Saved"
        scheduleAgendaRefresh(preserveSelection: true)
        return
      }

      recordFileUndo(from: undoSnapshot)
      statusText = savedStatus
      liveFileEditorStatusText = "Saved"
      if savedStatus.contains("encrypted"), let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
    } else {
      recordFileUndo(from: undoSnapshot)
      liveFileEditorStatusText = "Autosaved"
      scheduleAgendaRefresh(preserveSelection: true)
    }
  }

  private func finishSavedEntry(
    source: EntrySource,
    savedText: String,
    keepEditing: Bool
  ) async {
    invalidateCanonicalDocumentCache(for: source.file)
    let savedSource = Self.entrySource(source, replacingText: savedText)
    selectedEntrySource = savedSource
    editableEntryText = savedSource.text
    isEditingEntry = keepEditing
    if !keepEditing, let selectedLocation {
      await loadEntrySource(for: selectedLocation)
    } else {
      renderEntrySource(savedSource, generation: entrySourceLoadGeneration)
    }
    scheduleAgendaRefresh(preserveSelection: true)
  }

  private func scheduleLiveFileEditorAutosave() {
    guard isLiveFileEditorAvailable else { return }
    guard liveFileEditorHasUnsavedChanges else {
      cancelLiveFileEditorAutosave(resetStatus: false)
      liveFileEditorStatusText = "Saved"
      return
    }

    liveFileEditorAutosaveTask?.cancel()
    liveFileEditorAutosaveGeneration += 1
    let generation = liveFileEditorAutosaveGeneration
    liveFileEditorAutosaveTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.liveFileEditorAutosaveDelayNanoseconds)
      } catch {
        return
      }
      guard let self,
            !Task.isCancelled,
            self.liveFileEditorAutosaveGeneration == generation
      else {
        return
      }
      await self.saveLiveFileEditor(explicit: false)
    }
  }

  private func cancelLiveFileEditorAutosave(resetStatus: Bool) {
    liveFileEditorAutosaveTask?.cancel()
    liveFileEditorAutosaveTask = nil
    liveFileEditorAutosaveGeneration += 1
    if resetStatus {
      liveFileEditorStatusText = ""
    }
  }

  private func persistLiveFileEditorDraftBeforeNavigation() {
    guard isLiveFileEditorAvailable,
          liveFileEditorHasUnsavedChanges,
          let source = selectedEntrySource
    else {
      return
    }

    let replacement = editableEntryText
    Task { @MainActor [weak self, source, replacement] in
      guard let self else { return }
      do {
        let undoSnapshot = self.fileUndoSnapshot(for: source.file)
        try await Task.detached(priority: .utility) {
          try Self.replaceEntrySource(source, with: replacement)
        }.value
        self.recordFileUndo(from: undoSnapshot)
      } catch {
        self.errorText = error.localizedDescription
        self.liveFileEditorStatusText = "Autosave failed"
      }
    }
  }

  private func recordOrgCryptEncryptionFailure(_ error: Error, savedPrefix: String?) {
    let message = error.localizedDescription
    errorText = message
    orgCryptStatusText = message
    if case OrgCryptError.missingEncryptionConfiguration = error {
      statusText = [savedPrefix, "encryption needs configuration"].compactMap(\.self).joined(separator: " ")
      isOrgCryptConfigurationPresented = true
      return
    }
    statusText = [savedPrefix, "encryption failed"].compactMap(\.self).joined(separator: " ")
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
      let sourceBlock = activeBlockOriginals[block.id] ?? block
      if finalizeDeferredStableAutosaveIfCurrent(
        block,
        source: source,
        sourceBlock: sourceBlock,
        replacement: replacement
      ) {
        return
      }

      let undoSnapshot = fileUndoSnapshot(for: source.file)
      let updatedSource = try Self.replacingSourceBlock(
        sourceBlock,
        in: source,
        with: replacement
      )
      let currentRenderedBlocks = selectedRenderedBlocks
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceSourceRange(
          file: source.file,
          startLine: sourceBlock.startLine,
          endLineExclusive: sourceBlock.endLineExclusive,
          replacement: replacement,
          expectedOriginal: sourceBlock.rawText
        )
      }.value
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)

      if encryptedCount > 0 {
        recordFileUndo(from: undoSnapshot)
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
        recordFileUndo(from: undoSnapshot)
        return
      }

      recordFileUndo(from: undoSnapshot)
      deferredStableAutosaves.removeValue(forKey: block.id)
      invalidateCanonicalDocumentCache(for: source.file)
      selectedEntrySource = updatedSource
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: updatedSource)
      selectedRenderedBlocks = updatedVisibleBlocks
      selectedBlockID = blockForSelectionLine(
        sourceBlock.startLine,
        mode: .containingOrNearest,
        in: updatedVisibleBlocks
      )?.id
      statusText = "Saved block \(relativePath(source.file)):\(sourceBlock.displayRange)"
      resetBlockEditing()
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Block save failed"
    }
  }

  private func finalizeDeferredStableAutosaveIfCurrent(
    _ block: OrgEditableBlock,
    source: EntrySource,
    sourceBlock: OrgEditableBlock,
    replacement: String
  ) -> Bool {
    guard let deferred = deferredStableAutosaves[block.id],
          Self.normalizeLineEndings(deferred.block.rawText) == replacement,
          let fileText = try? Self.sourceText(
            file: source.file,
            startLine: deferred.block.startLine,
            endLineExclusive: deferred.block.endLineExclusive
          ),
          Self.normalizeLineEndings(fileText) == replacement
    else {
      return false
    }

    deferredStableAutosaves.removeValue(forKey: block.id)
    if selectedEntrySource?.id == source.id {
      selectedEntrySource = deferred.source
    }
    let updatedBlocks = Self.replacingBlock(
      selectedBlock,
      with: deferred.block,
      in: selectedRenderedBlocks
    )
    setSelectedRenderedBlocks(updatedBlocks, preservingMetadata: true)
    selectedBlockID = deferred.block.id
    invalidateCanonicalDocumentCache(for: source.file)
    statusText = "Saved block \(relativePath(source.file)):\(sourceBlock.displayRange)"
    resetBlockEditing()
    return true
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
      let undoSnapshot = fileUndoSnapshot(for: source.file)
      let file = source.file
      let startLine = block.startLine
      let endLineExclusive = block.endLineExclusive
      try Self.replaceSourceRange(
        file: file,
        startLine: startLine,
        endLineExclusive: endLineExclusive,
        replacement: normalizedReplacement,
        expectedOriginal: block.rawText
      )

      recordFileUndo(from: undoSnapshot)
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
      guard isCurrentAutosaveDraft(block, in: source, replacement: normalizedReplacement) else {
        return
      }

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
    let activeTransientDraft = transientDraftBlock?.block.id == block.id ? transientDraftBlock : nil
    let sourceBlock = activeTransientDraft == nil ? activeBlockOriginals[block.id] ?? block : block
    guard block.isEditable,
          sourceBlock.startLine >= source.startLine,
          sourceBlock.endLineExclusive <= source.endLineExclusive || activeTransientDraft != nil
    else {
      statusText = "Block cannot be split"
      return
    }
    let draft = draftText ?? editingDraftText(for: block)
    guard let plan = Self.splitBlockPlan(for: block, draft: draft, utf16Offset: offset) else {
      statusText = "Block cannot be split"
      return
    }
    if let activeTransientDraft {
      await splitTransientDraftBlock(activeTransientDraft, originalBlock: block, plan: plan)
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = fileUndoSnapshot(for: source.file)
      if let replacement = plan.replacement {
        try await Task.detached(priority: .userInitiated) {
          try Self.replaceSourceRange(
            file: source.file,
            startLine: sourceBlock.startLine,
            endLineExclusive: sourceBlock.endLineExclusive,
            replacement: replacement,
            expectedOriginal: sourceBlock.rawText
          )
        }.value
        recordFileUndo(from: undoSnapshot)
        invalidateCanonicalDocumentCache(for: source.file)
      }
      isEditingEntry = false

      let draftToActivate: TransientDraftBlock?
      if let draftSpec = plan.draft {
        let draft = transientDraftBlock(
          from: draftSpec,
          sourceFile: source.file,
          originalBlock: sourceBlock
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
          line: sourceBlock.startLine + newBlockLineOffset,
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

  private func splitTransientDraftBlock(
    _ activeDraft: TransientDraftBlock,
    originalBlock block: OrgEditableBlock,
    plan: SplitBlockPlan
  ) async {
    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = fileUndoSnapshot(for: activeDraft.file)
      if let replacementBody = plan.replacement {
        let replacement = "\(activeDraft.replacementPrefix)\(replacementBody)\(activeDraft.replacementSuffix)"
        try await Task.detached(priority: .userInitiated) {
          try Self.replaceSourceRange(
            file: activeDraft.file,
            startLine: activeDraft.insertionLine,
            endLineExclusive: activeDraft.replacementEndLineExclusive,
            replacement: replacement
          )
        }.value
        recordFileUndo(from: undoSnapshot)
        invalidateCanonicalDocumentCache(for: activeDraft.file)
      }

      selectedRenderedBlocks.removeAll { $0.id == activeDraft.block.id }
      activeBlockDrafts.removeValue(forKey: activeDraft.block.id)
      activeBlockOriginals.removeValue(forKey: activeDraft.block.id)
      isEditingEntry = false
      let bodyLineOffset = Self.lineBreakCount(in: activeDraft.replacementPrefix)

      let draftToActivate: TransientDraftBlock?
      if let draftSpec = plan.draft {
        let draftBaseBlock = bodyLineOffset == 0
          ? block
          : Self.shiftedBlock(block, by: bodyLineOffset)
        let nextDraft = transientDraftBlock(
          from: draftSpec,
          sourceFile: activeDraft.file,
          originalBlock: draftBaseBlock
        )
        transientDraftBlock = nextDraft
        draftToActivate = nextDraft
        statusText = "Started draft in \(relativePath(activeDraft.file))"
      } else if let newBlockLineOffset = plan.newBlockLineOffset {
        draftToActivate = nil
        transientDraftBlock = nil
        resetBlockEditing()
        pendingBlockSelection = PendingBlockSelection(
          file: activeDraft.file,
          line: block.startLine + bodyLineOffset + newBlockLineOffset,
          mode: .containingOrNearest,
          beginEditing: true
        )
        statusText = "Split block in \(relativePath(activeDraft.file))"
      } else {
        draftToActivate = nil
        transientDraftBlock = nil
        resetBlockEditing()
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

  public func deleteBackwardFromStartOfEditingBlock(_ block: OrgEditableBlock, draftText: String? = nil) async {
    let draft = Self.normalizeLineEndings(draftText ?? editingDraftText(for: block))
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if transientDraftBlock?.block.id == block.id {
        let fallbackSelection = previousMergeTarget(before: block)
        discardTransientDraft(status: "Draft discarded")
        selectedBlockID = fallbackSelection?.id
        return
      }
      await deleteBlock(block)
      return
    }

    await mergeEditingBlockBackward(block, draftText: draft)
  }

  private func mergeEditingBlockBackward(_ block: OrgEditableBlock, draftText: String) async {
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
            || transientDraftBlock?.block.id == block.id
    else {
      statusText = "Block cannot be merged"
      return
    }
    guard let previous = previousMergeTarget(before: block) else {
      statusText = "No previous text block"
      return
    }
    guard let replacement = Self.mergedTextBlockRawText(
      previous: previous,
      current: block,
      currentDraft: draftText
    ) else {
      statusText = "Blocks cannot be merged"
      return
    }

    let isTransientMerge = transientDraftBlock?.block.id == block.id
    let replacementStartLine = previous.startLine
    let replacementEndLineExclusive = isTransientMerge ? previous.endLineExclusive : block.endLineExclusive

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = fileUndoSnapshot(for: source.file)
      let expectedOriginal = try Self.sourceText(
        in: source,
        startLine: replacementStartLine,
        endLineExclusive: replacementEndLineExclusive
      )
      let updatedSource = try Self.replacingSourceRange(
        in: source,
        startLine: replacementStartLine,
        endLineExclusive: replacementEndLineExclusive,
        replacement: replacement
      )
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceSourceRange(
          file: source.file,
          startLine: replacementStartLine,
          endLineExclusive: replacementEndLineExclusive,
          replacement: replacement,
          expectedOriginal: expectedOriginal
        )
      }.value

      let updatedBlocks = await Task.detached(priority: .userInitiated) {
        OrgEntryRenderer.parseEditable(updatedSource.text, baseLine: updatedSource.startLine)
      }.value

      guard selectedEntrySource?.id == source.id else {
        recordFileUndo(from: undoSnapshot)
        return
      }

      recordFileUndo(from: undoSnapshot)
      invalidateCanonicalDocumentCache(for: source.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      selectedEntrySource = updatedSource
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: updatedSource)
      setSelectedRenderedBlocks(updatedVisibleBlocks, preservingMetadata: false)
      if let mergedBlock = blockForSelectionLine(
        previous.startLine,
        mode: .containingOrNearest,
        in: updatedVisibleBlocks
      ) {
        selectedBlockID = mergedBlock.id
        editingBlockID = mergedBlock.id
        editableBlockText = mergedBlock.rawText
        activeBlockDrafts[mergedBlock.id] = mergedBlock.rawText
        activeBlockOriginals[mergedBlock.id] = mergedBlock
      }
      statusText = "Merged block in \(relativePath(source.file))"
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Merge failed"
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
      let undoSnapshot = fileUndoSnapshot(for: source.file)
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
        recordFileUndo(from: undoSnapshot)
        return
      }

      recordFileUndo(from: undoSnapshot)
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
      let undoSnapshot = fileUndoSnapshot(for: source.file)
      let deletionRange = try Self.deletionRange(for: block, in: source)
      let deletion = try Self.deletingSourceRangeCleaningAdjacentBlank(
        in: source,
        startLine: deletionRange.startLine,
        endLineExclusive: deletionRange.endLineExclusive
      )
      let currentRenderedBlocks = selectedRenderedBlocks
      let allowDestructiveDelete = deletion.source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      try await Task.detached(priority: .userInitiated) {
        try Self.deleteSourceRangeCleaningAdjacentBlank(
          file: source.file,
          startLine: deletionRange.startLine,
          endLineExclusive: deletionRange.endLineExclusive,
          allowDestructiveReplacement: allowDestructiveDelete
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
        recordFileUndo(from: undoSnapshot)
        return
      }

      recordFileUndo(from: undoSnapshot)
      invalidateCanonicalDocumentCache(for: source.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      selectedEntrySource = deletion.source
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: deletion.source)
      selectedRenderedBlocks = updatedVisibleBlocks
      let selectionLine: Int
      if case .heading = block.rendered {
        selectionLine = deletion.startLine
      } else {
        selectionLine = block.startLine
      }
      selectedBlockID = blockForSelectionLine(
        selectionLine,
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

  func deleteRenderedTextSelection(_ fragments: [OrgSyntaxTextSelectionDocumentFragment]) async {
    await replaceRenderedTextSelection(fragments, replacementText: "")
  }

  @discardableResult
  func beginRenderedTextSelectionReplacement(
    _ fragments: [OrgSyntaxTextSelectionDocumentFragment],
    replacementText: String
  ) -> Bool {
    guard let write = prepareRenderedTextSelectionReplacement(fragments, replacementText: replacementText) else {
      return false
    }
    Task { @MainActor [weak self] in
      await self?.finishRenderedTextSelectionWrite(write)
    }
    return true
  }

  func replaceRenderedTextSelection(
    _ fragments: [OrgSyntaxTextSelectionDocumentFragment],
    replacementText: String
  ) async {
    guard let write = prepareRenderedTextSelectionReplacement(fragments, replacementText: replacementText) else {
      return
    }
    await finishRenderedTextSelectionWrite(write)
  }

  private func prepareRenderedTextSelectionReplacement(
    _ fragments: [OrgSyntaxTextSelectionDocumentFragment],
    replacementText: String
  ) -> RenderedTextSelectionWrite? {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return nil
    }

    let currentBlocks = selectedRenderedBlocks
    let selectionPairs = Self.renderedTextSelectionPairs(fragments, in: currentBlocks)
    guard !selectionPairs.isEmpty else {
      statusText = "No editable selection"
      return nil
    }

    isSavingBlock = true

    do {
      let replacement = try Self.renderedTextSelectionReplacement(
        pairs: selectionPairs,
        allBlocks: currentBlocks,
        in: source,
        replacementText: replacementText
      )
      let undoSnapshot = fileUndoSnapshot(for: source.file)

      guard selectedEntrySource?.file == source.file else {
        recordFileUndo(from: undoSnapshot)
        isSavingBlock = false
        return nil
      }

      recordFileUndo(from: undoSnapshot)
      invalidateCanonicalDocumentCache(for: source.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      selectedEntrySource = replacement.updatedSource
      pendingBlockSelection = PendingBlockSelection(
        file: source.file,
        line: replacement.startLine,
        mode: .nextOrNearest,
        beginEditing: !replacementText.isEmpty,
        initialSourceUTF16Offset: replacement.caretSourceUTF16Offset
      )
      selectedBlockID = nil
      if replacement.updatedSource.text.isEmpty {
        selectedRenderedBlocks = []
        pendingBlockSelection = nil
        isRenderingEntrySource = false
      } else {
        let blocks = Self.sortEditableBlocksForDisplay(OrgEntryRenderer.parseEditable(
          replacement.updatedSource.text,
          baseLine: replacement.updatedSource.startLine
        ))
        applyRenderedBlocks(blocks, for: replacement.updatedSource)
        isRenderingEntrySource = false
      }
      statusText = replacementText.isEmpty
        ? "Deleted selection in \(relativePath(source.file))"
        : "Replaced selection in \(relativePath(source.file))"
      scheduleAgendaRefresh(preserveSelection: true)

      return RenderedTextSelectionWrite(
        file: source.file,
        startLine: replacement.startLine,
        endLineExclusive: replacement.endLineExclusive,
        replacement: replacement.replacement,
        expectedOriginal: replacement.expectedOriginal,
        allowDestructiveReplacement: replacement.coversWholeDocument
          && replacement.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        failureStatus: replacementText.isEmpty ? "Delete selection failed" : "Replace selection failed"
      )
    } catch {
      isSavingBlock = false
      errorText = error.localizedDescription
      statusText = replacementText.isEmpty ? "Delete selection failed" : "Replace selection failed"
      return nil
    }
  }

  private func finishRenderedTextSelectionWrite(_ write: RenderedTextSelectionWrite) async {
    defer { isSavingBlock = false }
    do {
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceSourceRange(
          file: write.file,
          startLine: write.startLine,
          endLineExclusive: write.endLineExclusive,
          replacement: write.replacement,
          expectedOriginal: write.expectedOriginal,
          allowDestructiveReplacement: write.allowDestructiveReplacement
        )
      }.value
    } catch {
      errorText = error.localizedDescription
      statusText = write.failureStatus
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
      let undoSnapshot = fileUndoSnapshot(for: source.file)
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
        recordFileUndo(from: undoSnapshot)
        return
      }

      recordFileUndo(from: undoSnapshot)
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

  public func refreshOpenClawThreads(showsLoading: Bool = true) async {
    guard !isRefreshingOpenClawThreads else { return }

    guard let corpusRoot else {
      openClawThreads = []
      return
    }

    isRefreshingOpenClawThreads = true
    let shouldShowLoading = showsLoading || openClawThreads.isEmpty
    if shouldShowLoading {
      isLoadingOpenClawThreads = true
    }
    defer {
      isRefreshingOpenClawThreads = false
      if shouldShowLoading {
        isLoadingOpenClawThreads = false
      }
    }

    do {
      let threads = try await Task.detached(priority: .utility) {
        try Self.scanOpenClawThreads(corpusRoot: corpusRoot)
      }.value
      openClawThreads = threads
      syncOpenClawSelectionAfterRefresh()
    } catch {
      errorText = error.localizedDescription
      statusText = "Agent records scan failed"
    }
  }

  public func refreshAssignedWork(showsLoading: Bool = true) async {
    guard !isRefreshingAssignedWork else { return }

    guard let corpusRoot else {
      assignedWorkItems = []
      return
    }

    isRefreshingAssignedWork = true
    let shouldShowLoading = showsLoading || assignedWorkItems.isEmpty
    if shouldShowLoading {
      isLoadingAssignedWork = true
    }
    defer {
      isRefreshingAssignedWork = false
      if shouldShowLoading {
        isLoadingAssignedWork = false
      }
    }

    do {
      let files = corpusFiles.isEmpty ? try Self.scanCorpusFiles(corpusRoot: corpusRoot) : corpusFiles
      let items = try await Task.detached(priority: .utility) {
        try Self.scanAssignedWorkItems(files: files)
      }.value
      assignedWorkItems = items
      if let selectedAssignedWorkItemID,
         let item = items.first(where: { $0.id == selectedAssignedWorkItemID }) {
        if case .assigned = selectedLocation {
          selectedLocation = .assigned(item)
        }
      } else if selectedAssignedWorkItemID != nil {
        self.selectedAssignedWorkItemID = nil
        if case .assigned = selectedLocation {
          selectedLocation = nil
          backlinks = nil
        }
      }
      if selectedSurface == .agenda, agendaMode == .assigned {
        statusText = "\(items.count) all-time item\(items.count == 1 ? "" : "s")"
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Assigned work scan failed"
    }
  }

  private func rebuildAssignedWorkDisplayCache() {
    let terms = Self.filterTerms(from: agendaFilter)
    visibleAssignedWorkItems = assignedWorkSearchRows.compactMap { row in
      guard !terms.isEmpty else { return row.item }
      return terms.allSatisfy { row.searchText.contains($0) } ? row.item : nil
    }
    assignedWorkSections = Self.groupAssignedWorkSections(visibleAssignedWorkItems)
  }

  private static func groupAssignedWorkSections(_ items: [AssignedWorkItem]) -> [AssignedWorkSection] {
    let grouped = Dictionary(grouping: items) { item in
      "\(item.assignee)|\(Self.assignedWorkTodoGroupLabel(for: item))"
    }
    return grouped.keys.sorted { lhs, rhs in
      let left = lhs.split(separator: "|", maxSplits: 1).map(String.init)
      let right = rhs.split(separator: "|", maxSplits: 1).map(String.init)
      if left.first == right.first {
        return (left.dropFirst().first ?? "") < (right.dropFirst().first ?? "")
      }
      return (left.first ?? "") < (right.first ?? "")
    }.map { key in
      let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
      let assignee = parts.first ?? "unassigned"
      let todo = parts.dropFirst().first ?? "TASK"
      let items = (grouped[key] ?? []).sorted {
        if $0.assignedAt == $1.assignedAt {
          return $0.headline < $1.headline
        }
        return ($0.assignedAt ?? "") > ($1.assignedAt ?? "")
      }
      return AssignedWorkSection(
        id: key,
        label: "\(assignee) / \(todo)",
        items: items
      )
    }
  }

  private static func assignedWorkTodoGroupLabel(for item: AssignedWorkItem) -> String {
    let todo = item.todo?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
    return todo?.isEmpty == false ? todo! : "TASK"
  }

  private static func assignedWorkFilterText(for item: AssignedWorkItem) -> String {
    [
      item.todo,
      item.headline,
      item.assignee,
      item.status,
      item.assignedAt,
      item.lastAgentUpdate,
      item.file,
      item.tags.joined(separator: " "),
      item.properties.map { "\($0.key) \($0.value)" }.joined(separator: " ")
    ].compactMap { $0 }.joined(separator: " ").lowercased()
  }

  public func selectAssignedWorkItem(_ item: AssignedWorkItem) {
    deactivateAgendaFilterFocus()
    selectedSurface = .agenda
    selectedAssignedWorkItemID = item.id
    select(.assigned(item))
  }

  public func selectOpenClawThread(_ thread: OpenClawThread) {
    openOpenClawThread(thread, surface: .files)
  }

  private func openOpenClawThread(_ thread: OpenClawThread, surface: WorkspaceSurface? = nil, mode: EntrySourceMode? = nil) {
    if let surface {
      selectedSurface = surface
    }
    activateDetailLocation(.openClaw(thread), mode: mode, recordsHistory: true)
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
    resetQuickOpenSelection()
    isQuickOpenPresented = true
    if corpusFiles.isEmpty {
      Task { await refreshCorpusFiles() }
    }
  }

  public func focusSearchSurface() {
    selectedSurface = .search
    searchFocusToken += 1
  }

  @discardableResult
  public func focusCurrentSearchField() -> Bool {
    if isWorkspaceSurfacePaneClosed {
      return focusPageSearch()
    }

    switch selectedSurface {
    case .agenda:
      focusAgendaFilter(clearsFilter: false)
    case .approvals:
      focusApprovalFilter()
    case .files:
      focusCorpusFileFilter()
    case .home, .meetings, .openClaw:
      return focusPageSearch()
    case .search:
      if selectedLocation != nil {
        return focusPageSearch()
      }
      focusSearchSurface()
    }
    return true
  }

  public var searchNodes: [OrgRoamNodeReference] {
    filterSearchNodes(searchQuery, limit: 100)
  }

  public func selectSearchNode(_ node: OrgRoamNodeReference) {
    let thread = OpenClawThread(
      title: node.title,
      file: node.file,
      line: node.line,
      zone: "node",
      modifiedAt: nil,
      idValue: node.idValue
    )
    selectedSurface = .search
    activateDetailLocation(.openClaw(thread), mode: .entry, recordsHistory: true)
    selectedOpenClawThreadID = nil
    statusText = "Opened \(relativePath(node.file)):\(node.line)"
  }

  public var filteredCorpusFiles: [CorpusFile] {
    filterFiles(corpusFileFilter, limit: 500)
  }

  public var corpusSearchResultGroups: [SearchResultGroup] {
    Self.groupedSearchResultsForDisplay(searchResults)
  }

  nonisolated static func prioritizedSearchResultsForDisplay(_ results: [SearchResult]) -> [SearchResult] {
    results.enumerated()
      .sorted { lhs, rhs in
        let lhsRank = searchResultDisplayRank(lhs.element)
        let rhsRank = searchResultDisplayRank(rhs.element)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  nonisolated static func groupedSearchResultsForDisplay(_ results: [SearchResult]) -> [SearchResultGroup] {
    var grouped: [String: [SearchResult]] = [:]
    var fileOrder: [String] = []

    for result in results {
      if grouped[result.file] == nil {
        fileOrder.append(result.file)
        grouped[result.file] = []
      }
      grouped[result.file]?.append(result)
    }

    return fileOrder.compactMap { file in
      SearchResultGroup(file: file, results: grouped[file] ?? [])
    }
  }

  nonisolated private static func searchResultDisplayRank(_ result: SearchResult) -> Int {
    if result.isActiveTodo { return 0 }
    if result.isTerminalTodo { return 2 }
    return 1
  }

  public var selectedQuickOpenFile: CorpusFile? {
    let files = quickOpenFiles
    if let selectedQuickOpenFileID,
       let selected = files.first(where: { $0.id == selectedQuickOpenFileID }) {
      return selected
    }
    return files.first
  }

  public func resetQuickOpenSelection() {
    selectedQuickOpenFileID = nil
  }

  public func moveQuickOpenSelection(_ direction: QuickOpenSelectionDirection) {
    let files = quickOpenFiles
    guard !files.isEmpty else {
      selectedQuickOpenFileID = nil
      return
    }

    let currentIndex = selectedQuickOpenFileID.flatMap { id in
      files.firstIndex { $0.id == id }
    }
    let nextIndex: Int
    switch (direction, currentIndex) {
    case (.down, nil):
      nextIndex = files.startIndex
    case (.up, nil):
      nextIndex = files.index(before: files.endIndex)
    case (.down, let index?):
      nextIndex = index == files.index(before: files.endIndex) ? files.startIndex : files.index(after: index)
    case (.up, let index?):
      nextIndex = index == files.startIndex ? files.index(before: files.endIndex) : files.index(before: index)
    }
    selectedQuickOpenFileID = files[nextIndex].id
  }

  private func rebuildQuickOpenIndex() {
    quickOpenIndexedFiles = Self.indexQuickOpenFiles(corpusFiles)
  }

  private func scheduleQuickOpenSearch(debounce: Bool = true) {
    quickOpenSearchGeneration += 1
    let generation = quickOpenSearchGeneration
    let query = quickOpenQuery
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    quickOpenSearchTask?.cancel()

    guard !trimmedQuery.isEmpty else {
      isFilteringQuickOpenFiles = false
      quickOpenFiles = Array(corpusFiles.prefix(80))
      pruneQuickOpenSelection()
      return
    }

    let indexedFiles = quickOpenIndexedFiles
    isFilteringQuickOpenFiles = true
    quickOpenFiles = []
    quickOpenSearchTask = Task { [indexedFiles, query, generation, debounce] in
      if debounce {
        try? await Task.sleep(nanoseconds: 80_000_000)
      }
      guard !Task.isCancelled else { return }

      let matches = await Task.detached(priority: .userInitiated) {
        Self.filterIndexedQuickOpenFiles(indexedFiles, query: query, limit: 80)
      }.value
      guard !Task.isCancelled else { return }

      await MainActor.run { [weak self] in
        guard let self, self.quickOpenSearchGeneration == generation else { return }
        self.quickOpenFiles = matches
        self.isFilteringQuickOpenFiles = false
        self.pruneQuickOpenSelection()
      }
    }
  }

  private func pruneQuickOpenSelection() {
    guard let selectedQuickOpenFileID else { return }
    if !quickOpenFiles.contains(where: { $0.id == selectedQuickOpenFileID }) {
      self.selectedQuickOpenFileID = nil
    }
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

  nonisolated private static func indexQuickOpenFiles(_ files: [CorpusFile]) -> [QuickOpenIndexedFile] {
    files.map { file in
      QuickOpenIndexedFile(
        file: file,
        normalizedRelativePath: normalizedQuickOpenCandidate(file.relativePath)
      )
    }
  }

  nonisolated private static func filterIndexedQuickOpenFiles(
    _ files: [QuickOpenIndexedFile],
    query rawQuery: String,
    limit: Int
  ) -> [CorpusFile] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedQuery = normalizedQuickOpenQuery(query)
    guard !normalizedQuery.isEmpty else {
      return Array(files.prefix(limit).map(\.file))
    }

    return files
      .compactMap { indexedFile -> (QuickOpenIndexedFile, Int)? in
        guard let score = fuzzyScore(normalizedQuery: normalizedQuery, normalizedCandidate: indexedFile.normalizedRelativePath)
        else { return nil }
        return (indexedFile, score)
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.file.relativePath.localizedStandardCompare(rhs.0.file.relativePath) == .orderedAscending
      }
      .prefix(limit)
      .map(\.0.file)
  }

  private func filterSearchNodes(_ rawQuery: String, limit: Int) -> [OrgRoamNodeReference] {
    let nodes = corpusFiles.compactMap(Self.scanRoamFileNode)
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return Array(nodes.sorted(by: compareSearchNodes).prefix(limit))
    }

    return nodes
      .compactMap { node -> (OrgRoamNodeReference, Int)? in
        let candidates = [
          node.title,
          node.aliases.joined(separator: " "),
          node.idValue ?? "",
          relativePath(node.file)
        ]
        let bestScore = candidates.compactMap { Self.fuzzyScore(query: query, candidate: $0) }.max()
        guard let bestScore else { return nil }
        let normalizedQuery = query.lowercased()
        let exactBoost = ([node.title] + node.aliases)
          .contains { $0.lowercased().contains(normalizedQuery) } ? 50 : 0
        return (node, bestScore + exactBoost)
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return compareSearchNodes(lhs.0, rhs.0)
      }
      .prefix(limit)
      .map(\.0)
  }

  private func compareSearchNodes(_ lhs: OrgRoamNodeReference, _ rhs: OrgRoamNodeReference) -> Bool {
    let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
    let pathOrder = relativePath(lhs.file).localizedStandardCompare(relativePath(rhs.file))
    if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
    return lhs.line < rhs.line
  }

  private func selectedLocationMatches(_ location: WorkspaceLocation) -> Bool {
    guard let selectedLocation else { return true }
    return Self.selectionIdentity(for: selectedLocation) == Self.selectionIdentity(for: location)
  }

  nonisolated private static func selectionIdentity(for location: WorkspaceLocation) -> String {
    let kind: String
    switch location {
    case .agenda:
      kind = "agenda"
    case .assigned:
      kind = "assigned"
    case .search:
      kind = "search"
    case .backlink:
      kind = "backlink"
    case .openClaw:
      kind = "openClaw"
    case .meeting:
      kind = "meeting"
    }
    return [
      kind,
      location.file,
      "\(location.lineForEditor)",
      location.title
    ].joined(separator: "\u{1F}")
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
    activeBlockInitialSelections.removeAll()
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
    revealRenderedBlockIfHiddenByFold(draft.block.id)
    requestDetailReveal(toBlock: draft.block.id)
  }

  private func revealRenderedBlockIfHiddenByFold(_ blockID: OrgEditableBlock.ID) {
    var nextFoldedIDs = foldedRenderedBlockIDs
    while let ancestorID = OrgRenderedFoldTree.foldedAncestorID(
      hiding: blockID,
      foldedBlockIDs: nextFoldedIDs,
      blocks: selectedRenderedBlocks
    ) {
      nextFoldedIDs.remove(ancestorID)
    }
    if nextFoldedIDs != foldedRenderedBlockIDs {
      foldedRenderedBlockIDs = nextFoldedIDs
    }
  }

  private func saveTransientDraftBlock(_ draft: TransientDraftBlock) async {
    guard selectedEntrySource?.isEditable == true else {
      statusText = "No editable source loaded"
      return
    }

    guard let replacementBody = Self.normalizedTransientDraftText(editingDraftText(for: draft.block), for: draft.block) else {
      discardTransientDraft(status: "Draft discarded")
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    let replacement = "\(draft.replacementPrefix)\(replacementBody)\(draft.replacementSuffix)"
    do {
      let undoSnapshot = fileUndoSnapshot(for: draft.file)
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceSourceRange(
          file: draft.file,
          startLine: draft.insertionLine,
          endLineExclusive: draft.replacementEndLineExclusive,
          replacement: replacement
        )
      }.value
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: draft.file)
      recordFileUndo(from: undoSnapshot)
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
    let undoSnapshot = fileUndoSnapshot(for: source.file)
    try await Task.detached(priority: .userInitiated) {
      try Self.replaceSourceRange(
        file: source.file,
        startLine: block.startLine,
        endLineExclusive: block.endLineExclusive,
        replacement: normalizedReplacement,
        expectedOriginal: block.rawText
      )
    }.value
    let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)

    if encryptedCount > 0 {
      recordFileUndo(from: undoSnapshot)
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
      recordFileUndo(from: undoSnapshot)
      return
    }

    recordFileUndo(from: undoSnapshot)
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

  private func previousMergeTarget(before block: OrgEditableBlock) -> OrgEditableBlock? {
    let sortedBlocks = Self.sortEditableBlocksForDisplay(selectedRenderedBlocks)
    guard let currentIndex = sortedBlocks.firstIndex(where: { $0.id == block.id }) else {
      return sortedBlocks.last { candidate in
        candidate.endLineExclusive <= block.startLine
          && Self.isMergeablePreviousTextBlock(candidate)
      }
    }

    guard currentIndex > 0 else { return nil }
    for candidate in sortedBlocks[..<currentIndex].reversed()
      where Self.isMergeablePreviousTextBlock(candidate) {
      return candidate
    }
    return nil
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

  private func transientDraftEditableBlock(
    startLine: Int,
    endLineExclusive: Int,
    rawText: String,
    rendered: OrgRenderedBlock
  ) -> OrgEditableBlock {
    transientDraftIDCounter += 1
    return OrgEditableBlock(
      id: "transient-draft:\(transientDraftIDCounter):\(startLine):\(endLineExclusive)",
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      rawText: rawText,
      rendered: rendered
    )
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
      block: transientDraftEditableBlock(
        startLine: insertionLine,
        endLineExclusive: insertionLine,
        rawText: rawText,
        rendered: insertionDraftRenderedBlock(for: kind, rawText: rawText, after: previousBlock, in: source)
      ),
      coveredBlocks: []
    )
  }

  private func appendDraftBlock(
    kind: OrgInsertBlockKind,
    in source: EntrySource
  ) -> TransientDraftBlock {
    let rawText = appendDraftRawText(for: kind)
    let isSourceEmpty = source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let insertionLine = isSourceEmpty ? source.startLine : max(source.startLine, source.endLineExclusive)
    let replacementEndLineExclusive = isSourceEmpty
      ? max(source.startLine, source.endLineExclusive)
      : insertionLine
    let replacementPrefix = isSourceEmpty ? "" : "\n"
    let selectionLineOffset = replacementPrefix.isEmpty ? 0 : 1
    return TransientDraftBlock(
      file: source.file,
      insertionLine: insertionLine,
      replacementEndLineExclusive: replacementEndLineExclusive,
      replacementPrefix: replacementPrefix,
      replacementSuffix: "",
      selectionLineOffset: selectionLineOffset,
      block: transientDraftEditableBlock(
        startLine: insertionLine,
        endLineExclusive: insertionLine,
        rawText: rawText,
        rendered: appendDraftRenderedBlock(for: kind, rawText: rawText)
      ),
      coveredBlocks: []
    )
  }

  private func appendDraftRawText(for kind: OrgInsertBlockKind) -> String {
    switch kind {
    case .paragraph:
      return ""
    case .heading:
      return "* "
    case .todo:
      return "* TODO "
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

  private func appendDraftRenderedBlock(for kind: OrgInsertBlockKind, rawText: String) -> OrgRenderedBlock {
    switch kind {
    case .paragraph:
      return .paragraph("")
    case .heading:
      return .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "", tags: []))
    case .todo:
      return .heading(OrgHeadingBlock(level: 1, todo: "TODO", priority: nil, title: "", tags: []))
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
      block: transientDraftEditableBlock(
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
    if kind == .paragraph,
       rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .paragraph("")
    }
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

  public func openHome() {
    selectedSurface = .home
    expandedWorkspaceSurface = nil
    isWorkspaceSurfacePaneClosed = false
    isWorkspaceDetailPaneClosed = false
    isWorkspaceDetailPaneExpanded = false

    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    let url = dailyNotePath(corpusRoot: corpusRoot, date: Date())
    do {
      if !FileManager.default.fileExists(atPath: url.path) {
        try createDailyNote(at: url)
      }
      let file = corpusFile(for: url, corpusRoot: corpusRoot)
      upsertCorpusFile(file)
      selectedCorpusFileID = file.id
      selectedOpenClawThreadID = nil
      let thread = OpenClawThread(
        title: file.name,
        file: file.path,
        line: 1,
        zone: file.directory.isEmpty ? "daily" : file.directory,
        modifiedAt: file.modifiedAt,
        idValue: nil
      )
      activateDetailLocation(.openClaw(thread), mode: .page, recordsHistory: false)
      statusText = "Home"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not open \(url.lastPathComponent)"
    }
  }

  public func ensureHomeDetailReady() {
    selectedSurface = .home
    expandedWorkspaceSurface = nil
    isWorkspaceSurfacePaneClosed = false
    isWorkspaceDetailPaneClosed = false
    isWorkspaceDetailPaneExpanded = false
    guard isTodayHomeDetailSelected else {
      openHome()
      return
    }
  }

  private var isTodayHomeDetailSelected: Bool {
    guard selectedSurface == .home,
          selectedEntrySourceMode == .page,
          let corpusRoot,
          let selectedLocation
    else {
      return false
    }
    return URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path == todayDailyNotePath(corpusRoot: corpusRoot).standardizedFileURL.path
  }

  public var canStartOpenClawVoiceNoteRecording: Bool {
    !isRecordingOpenClawVoiceNote
      && !isTranscribingOpenClawVoiceNote
      && !isRecordingMeeting
      && !isProcessingMeeting
  }

  public func toggleOpenClawVoiceNoteRecording() async {
    if isRecordingOpenClawVoiceNote {
      await stopOpenClawVoiceNoteRecording()
    } else {
      await startOpenClawVoiceNoteRecording()
    }
  }

  public func startOpenClawVoiceNoteRecording() async {
    guard !isRecordingOpenClawVoiceNote else { return }
    guard !isTranscribingOpenClawVoiceNote else {
      openClawVoiceStatusText = "Finish transcribing the current dictation first."
      openClawStatusText = openClawVoiceStatusText
      return
    }
    guard !isRecordingMeeting && !isProcessingMeeting else {
      openClawVoiceStatusText = "Finish the current meeting recording first."
      openClawStatusText = openClawVoiceStatusText
      return
    }

    let audioURL = Self.openClawVoiceNoteURL()
    do {
      try await openClawVoiceRecorder.startRecording(to: audioURL)
      activeOpenClawVoiceNoteURL = audioURL
      isRecordingOpenClawVoiceNote = true
      openClawVoiceStatusText = "Recording OpenClaw dictation..."
      openClawStatusText = openClawVoiceStatusText
      startOpenClawVoiceMetering()
    } catch {
      activeOpenClawVoiceNoteURL = nil
      isRecordingOpenClawVoiceNote = false
      stopOpenClawVoiceMetering()
      errorText = error.localizedDescription
      openClawVoiceStatusText = "Dictation failed: \(error.localizedDescription)"
      openClawStatusText = openClawVoiceStatusText
    }
  }

  public func stopOpenClawVoiceNoteRecording() async {
    guard let audioURL = activeOpenClawVoiceNoteURL else {
      openClawVoiceStatusText = "No active OpenClaw dictation recording."
      openClawStatusText = openClawVoiceStatusText
      return
    }

    do {
      let duration = try openClawVoiceRecorder.stopRecording()
      activeOpenClawVoiceNoteURL = nil
      isRecordingOpenClawVoiceNote = false
      stopOpenClawVoiceMetering()
      guard duration >= 0.2 else {
        try? FileManager.default.removeItem(at: audioURL)
        openClawVoiceStatusText = "Dictation was too short."
        openClawStatusText = openClawVoiceStatusText
        return
      }

      isTranscribingOpenClawVoiceNote = true
      openClawVoiceStatusText = "Transcribing OpenClaw dictation locally..."
      openClawStatusText = openClawVoiceStatusText
      startOpenClawVoiceTranscriptionProgress(audioDuration: duration)
      defer {
        try? FileManager.default.removeItem(at: audioURL)
      }

      let transcript = await transcribeAudioForOpenClawVoiceNote(audioURL)
      isTranscribingOpenClawVoiceNote = false
      stopOpenClawVoiceTranscriptionProgress()
      let dictatedText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard transcript.status == .complete, !dictatedText.isEmpty else {
        let suffix = transcript.errorMessage.map { ": \($0)" } ?? ""
        openClawVoiceStatusText = "Dictation transcription \(transcript.status.label)\(suffix)"
        openClawStatusText = openClawVoiceStatusText
        return
      }

      publishOpenClawComposerDraft(Self.openClawDraftByAppendingDictation(existing: openClawDraft, dictatedText: dictatedText))
      openClawVoiceStatusText = "Sending dictated note to OpenClaw..."
      openClawStatusText = openClawVoiceStatusText
      await sendOpenClawMessage()
    } catch {
      activeOpenClawVoiceNoteURL = nil
      isRecordingOpenClawVoiceNote = false
      isTranscribingOpenClawVoiceNote = false
      stopOpenClawVoiceMetering()
      stopOpenClawVoiceTranscriptionProgress()
      try? FileManager.default.removeItem(at: audioURL)
      errorText = error.localizedDescription
      openClawVoiceStatusText = "Dictation stop failed: \(error.localizedDescription)"
      openClawStatusText = openClawVoiceStatusText
    }
  }

  public func chooseOpenClawImageAttachments() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.image]
    panel.prompt = "Attach"
    if panel.runModal() == .OK {
      attachOpenClawImages(urls: panel.urls)
    }
  }

  public func attachOpenClawImages(urls: [URL]) {
    var attachments = openClawPendingAttachments
    for url in urls {
      do {
        let attachment = try Self.openClawImageAttachment(from: url)
        guard !attachments.contains(where: { $0.data == attachment.data && $0.fileName == attachment.fileName }) else {
          continue
        }
        attachments.append(attachment)
      } catch {
        errorText = error.localizedDescription
        openClawStatusText = "Could not attach \(url.lastPathComponent)"
      }
    }
    openClawPendingAttachments = attachments
    if !attachments.isEmpty {
      openClawStatusText = "\(attachments.count) image attachment\(attachments.count == 1 ? "" : "s") ready"
    }
  }

  public func removeOpenClawPendingAttachment(_ attachment: OpenClawChatAttachment) {
    openClawPendingAttachments.removeAll { $0.id == attachment.id }
  }

  public func clearOpenClawPendingAttachments() {
    openClawPendingAttachments = []
  }

  public func sendOpenClawMessage() async {
    let text = openClawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = openClawPendingAttachments
    guard !text.isEmpty || !attachments.isEmpty else { return }
    clearOpenClawDraftForSelectedThread()
    openClawPendingAttachments = []
    await sendOpenClawMessage(text, attachments: attachments)
  }

  public func sendOpenClawMessage(text rawText: String) async {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    clearOpenClawDraftForSelectedThread()
    await sendOpenClawMessage(text, attachments: [])
  }

  public func sendComposedOpenClawMessage(text rawText: String) async {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = openClawPendingAttachments
    guard !text.isEmpty || !attachments.isEmpty else { return }
    clearOpenClawDraftForSelectedThread()
    openClawPendingAttachments = []
    await sendOpenClawMessage(text, attachments: attachments)
  }

  private func sendOpenClawMessage(_ text: String, attachments: [OpenClawChatAttachment]) async {
    ensureOpenClawChatThread()
    guard let threadID = selectedOpenClawChatThreadID else { return }
    let userMessage = OpenClawChatMessage(
      role: .user,
      content: text,
      attachments: attachments,
      deliveryStatus: .sending
    )
    var messages = openClawMessages(for: threadID)
    messages.append(userMessage)
    replaceOpenClawMessages(messages, for: threadID, shouldPersist: true)
    enqueueOpenClawUserMessage(userMessage.id, in: threadID)
    if drainingOpenClawThreadIDs.contains(threadID) {
      openClawStatusText = openClawQueuedStatusText()
      return
    }
    await drainOpenClawSendQueue(for: threadID)
  }

  private func drainOpenClawSendQueue(for threadID: UUID) async {
    guard !drainingOpenClawThreadIDs.contains(threadID) else { return }
    drainingOpenClawThreadIDs.insert(threadID)
    openClawRequestStartedAtByThreadID[threadID] = Date()
    syncSelectedOpenClawSendState()
    defer {
      drainingOpenClawThreadIDs.remove(threadID)
      openClawRequestStartedAtByThreadID.removeValue(forKey: threadID)
      syncSelectedOpenClawSendState()
    }

    while let userMessageID = openClawPendingUserMessageIDs(for: threadID).first {
      guard let requestMessages = openClawMessagesThrough(userMessageID, in: threadID) else {
        removeFirstPendingOpenClawUserMessage(in: threadID)
        continue
      }
      openClawStatusText = openClawQueuedStatusText()

      do {
        clearOpenClawSendFailure(for: userMessageID, in: threadID)
        let beforeSnapshot = await captureOpenClawCorpusSnapshot()
        let sessionKey = openClawSessionKey(for: threadID) ?? openClawSessionKey
        let reply = try await sendOpenClawRequest(messages: requestMessages, sessionKey: sessionKey)
        let changeSummary = await openClawChangeSummary(since: beforeSnapshot, referencedIn: reply)
        markOpenClawMessageSent(userMessageID, in: threadID)
        insertOpenClawReply(reply, after: userMessageID, in: threadID, changeSummary: changeSummary)
        if let changeSummary {
          await refreshAfterOpenClawChanges(changeSummary)
        }
        removeFirstPendingOpenClawUserMessage(in: threadID)
        if openClawPendingUserMessageIDs(for: threadID).isEmpty {
          openClawStatusText = changeSummary.map {
            "\($0.title): +\($0.totalInsertions) -\($0.totalDeletions)"
          } ?? "OpenClaw replied"
        } else {
          openClawStatusText = openClawQueuedStatusText()
        }
      } catch {
        let failureText = Self.openClawSendFailureText(from: error)
        openClawStatusText = failureText
        markPendingOpenClawMessagesFailed(failureText, in: threadID)
        removeAllPendingOpenClawUserMessages(in: threadID)
        return
      }
    }
  }

  private func sendOpenClawRequest(messages: [OpenClawChatMessage], sessionKey: String) async throws -> String {
    let agentID = openClawAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : openClawAgentID
    let workspaceContext = currentOpenClawWorkspaceContext()
    if let openClawSendHandler {
      return try await openClawSendHandler(messages, agentID, sessionKey, workspaceContext)
    }
    let client = OpenClawChatClient(settings: currentOpenClawSettings(allowKeychainRead: true))
    return try await client.send(
      messages: messages,
      agentID: agentID,
      sessionKey: sessionKey,
      workspaceContext: workspaceContext
    )
  }

  private func openClawMessagesThrough(_ messageID: UUID, in threadID: UUID) -> [OpenClawChatMessage]? {
    let messages = openClawMessages(for: threadID)
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
      return nil
    }
    return Array(messages[...index])
  }

  private func insertOpenClawReply(
    _ reply: String,
    after userMessageID: UUID,
    in threadID: UUID,
    changeSummary: OpenClawCorpusChangeSummary?
  ) {
    let assistantMessage = OpenClawChatMessage(role: .assistant, content: reply, changeSummary: changeSummary)
    var messages = openClawMessages(for: threadID)
    guard let index = messages.firstIndex(where: { $0.id == userMessageID }) else {
      messages.append(assistantMessage)
      replaceOpenClawMessages(
        messages,
        for: threadID,
        shouldPersist: true,
        notifiesForNewAssistantMessages: true
      )
      return
    }
    messages.insert(assistantMessage, at: messages.index(after: index))
    replaceOpenClawMessages(
      messages,
      for: threadID,
      shouldPersist: true,
      notifiesForNewAssistantMessages: true
    )
  }

  public func retryOpenClawMessage(_ messageID: UUID) async {
    guard let threadID = openClawThreadID(containing: messageID),
          let message = openClawMessages(for: threadID).first(where: { $0.id == messageID }),
          message.role == .user,
          message.sendFailure != nil
    else {
      return
    }
    guard !openClawPendingUserMessageIDs(for: threadID).contains(messageID) else { return }
    clearOpenClawSendFailure(for: messageID, in: threadID)
    replaceOpenClawDeliveryStatus(for: messageID, in: threadID, with: .sending)
    enqueueOpenClawUserMessage(messageID, in: threadID)
    if drainingOpenClawThreadIDs.contains(threadID) {
      openClawStatusText = openClawQueuedStatusText()
      return
    }
    await drainOpenClawSendQueue(for: threadID)
  }

  private func clearOpenClawSendFailure(for messageID: UUID, in threadID: UUID) {
    replaceOpenClawSendFailure(for: messageID, in: threadID, with: nil)
  }

  private func markOpenClawMessageSent(_ messageID: UUID, in threadID: UUID) {
    replaceOpenClawDeliveryStatus(for: messageID, in: threadID, with: .sent)
  }

  private func markPendingOpenClawMessagesFailed(_ failureText: String, in threadID: UUID) {
    for messageID in openClawPendingUserMessageIDs(for: threadID) {
      replaceOpenClawSendFailure(for: messageID, in: threadID, with: failureText)
    }
  }

  private func replaceOpenClawSendFailure(for messageID: UUID, in threadID: UUID, with failureText: String?) {
    var messages = openClawMessages(for: threadID)
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
    let message = messages[index]
    let nextStatus: OpenClawChatMessage.DeliveryStatus
    if failureText == nil, message.deliveryStatus == .sending {
      nextStatus = .sending
    } else {
      nextStatus = failureText == nil ? .sent : .failed
    }
    guard message.sendFailure != failureText || message.deliveryStatus != nextStatus else { return }
    messages[index] = message.replacingSendFailure(failureText)
    replaceOpenClawMessages(messages, for: threadID, shouldPersist: true)
  }

  private func replaceOpenClawDeliveryStatus(
    for messageID: UUID,
    in threadID: UUID,
    with deliveryStatus: OpenClawChatMessage.DeliveryStatus
  ) {
    var messages = openClawMessages(for: threadID)
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
    let message = messages[index]
    guard message.deliveryStatus != deliveryStatus || message.sendFailure != nil else { return }
    messages[index] = message.replacingDeliveryStatus(deliveryStatus)
    replaceOpenClawMessages(messages, for: threadID, shouldPersist: true)
  }

  private func openClawMessages(for threadID: UUID) -> [OpenClawChatMessage] {
    if selectedOpenClawChatThreadID == threadID {
      return openClawMessages
    }
    return openClawChatThreads.first(where: { $0.id == threadID })?.messages ?? []
  }

  private func replaceOpenClawMessages(
    _ messages: [OpenClawChatMessage],
    for threadID: UUID,
    shouldPersist: Bool,
    notifiesForNewAssistantMessages: Bool = false
  ) {
    if selectedOpenClawChatThreadID == threadID {
      replaceOpenClawMessages(messages, shouldPersist: false)
    }
    updateOpenClawChatThread(
      threadID,
      messages: messages,
      notifiesForNewAssistantMessages: notifiesForNewAssistantMessages
    )
    if shouldPersist {
      persistOpenClawTranscript()
    }
  }

  private func openClawSessionKey(for threadID: UUID) -> String? {
    openClawChatThreads.first(where: { $0.id == threadID })?.sessionKey
  }

  private func openClawThreadID(containing messageID: UUID) -> UUID? {
    if let selectedOpenClawChatThreadID,
       openClawMessages.contains(where: { $0.id == messageID }) {
      return selectedOpenClawChatThreadID
    }
    return openClawChatThreads.first { thread in
      thread.messages.contains(where: { $0.id == messageID })
    }?.id
  }

  private func openClawPendingUserMessageIDs(for threadID: UUID) -> [UUID] {
    openClawPendingUserMessageIDsByThreadID[threadID] ?? []
  }

  private func enqueueOpenClawUserMessage(_ messageID: UUID, in threadID: UUID) {
    openClawPendingUserMessageIDsByThreadID[threadID, default: []].append(messageID)
    syncSelectedOpenClawSendState()
  }

  private func removeFirstPendingOpenClawUserMessage(in threadID: UUID) {
    guard var pending = openClawPendingUserMessageIDsByThreadID[threadID], !pending.isEmpty else {
      syncSelectedOpenClawSendState()
      return
    }
    pending.removeFirst()
    if pending.isEmpty {
      openClawPendingUserMessageIDsByThreadID.removeValue(forKey: threadID)
    } else {
      openClawPendingUserMessageIDsByThreadID[threadID] = pending
    }
    syncSelectedOpenClawSendState()
  }

  private func removeAllPendingOpenClawUserMessages(in threadID: UUID) {
    openClawPendingUserMessageIDsByThreadID.removeValue(forKey: threadID)
    syncSelectedOpenClawSendState()
  }

  private func removeAllPendingOpenClawUserMessages() {
    openClawPendingUserMessageIDsByThreadID.removeAll()
    syncSelectedOpenClawSendState()
  }

  private func syncSelectedOpenClawSendState() {
    openClawSendingThreadIDs = drainingOpenClawThreadIDs
    guard let selectedOpenClawChatThreadID else {
      isSendingOpenClawMessage = false
      openClawQueuedMessageCount = 0
      openClawRequestStartedAt = nil
      return
    }
    isSendingOpenClawMessage = drainingOpenClawThreadIDs.contains(selectedOpenClawChatThreadID)
    openClawQueuedMessageCount = openClawPendingUserMessageIDs(for: selectedOpenClawChatThreadID).count
    openClawRequestStartedAt = openClawRequestStartedAtByThreadID[selectedOpenClawChatThreadID]
  }

  nonisolated private static func openClawSendFailureText(from error: Error) -> String {
    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? "OpenClaw message failed to send." : message
  }

  private func captureOpenClawCorpusSnapshot() async -> OpenClawCorpusSnapshot? {
    guard let corpusRoot else { return nil }
    let root = corpusRoot.standardizedFileURL
    return try? await Task.detached(priority: .utility) {
      try Self.openClawCorpusSnapshot(corpusRoot: root)
    }.value
  }

  private func openClawChangeSummary(
    since snapshot: OpenClawCorpusSnapshot?,
    referencedIn reply: String
  ) async -> OpenClawCorpusChangeSummary? {
    guard let snapshot else { return nil }
    let root = URL(fileURLWithPath: snapshot.rootPath).standardizedFileURL
    let referencedPaths = openClawReferencedChangeRelativePaths(in: reply)
    for delay in Self.openClawChangeSnapshotRetryDelays {
      if delay > 0 {
        try? await Task.sleep(nanoseconds: delay)
      }
      guard let afterSnapshot = try? await Task.detached(priority: .utility, operation: {
        if referencedPaths.isEmpty {
          return try Self.openClawCorpusSnapshot(corpusRoot: root)
        }
        return try Self.openClawCorpusSnapshot(corpusRoot: root, relativePaths: referencedPaths)
      }).value else {
        continue
      }
      let beforeSnapshot = referencedPaths.isEmpty ? snapshot : snapshot.filtered(to: referencedPaths)
      if let summary = Self.openClawChangeSummary(before: beforeSnapshot, after: afterSnapshot) {
        return attributedOpenClawChangeSummary(summary, referencedPaths: referencedPaths)
      }
    }
    return nil
  }

  private func attributedOpenClawChangeSummary(
    _ summary: OpenClawCorpusChangeSummary,
    referencedIn reply: String
  ) -> OpenClawCorpusChangeSummary {
    attributedOpenClawChangeSummary(
      summary,
      referencedPaths: openClawReferencedChangeRelativePaths(in: reply)
    )
  }

  private func attributedOpenClawChangeSummary(
    _ summary: OpenClawCorpusChangeSummary,
    referencedPaths: Set<String>
  ) -> OpenClawCorpusChangeSummary {
    guard !referencedPaths.isEmpty else { return summary }
    let filteredFiles = summary.files.filter { referencedPaths.contains($0.relativePath) }
    return filteredFiles.isEmpty ? summary : OpenClawCorpusChangeSummary(files: filteredFiles)
  }

  private func openClawReferencedChangeRelativePaths(in reply: String) -> Set<String> {
    guard let corpusRoot else { return [] }
    let rootPath = Self.trimTrailingSlashes(corpusRoot.standardizedFileURL.path)
    var paths = Set<String>()

    for reference in OpenClawFileReference.extract(from: reply, limit: 24) {
      if let relativePath = openClawRelativePathForReference(reference.path, corpusRootPath: rootPath) {
        paths.insert(relativePath)
      }
    }

    return paths
  }

  private func openClawRelativePathForReference(_ rawPath: String, corpusRootPath rootPath: String) -> String? {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }

    var candidates: [String] = []
    if let localPath = localPathForOpenClawReference(path) {
      candidates.append(localPath)
    }

    if let remoteRoot = effectiveOpenClawRemoteCorpusPath().map(Self.trimTrailingSlashes) {
      let normalizedPath = Self.trimTrailingSlashes(path)
      if normalizedPath == remoteRoot {
        candidates.append(rootPath)
      } else if normalizedPath.hasPrefix(remoteRoot + "/") {
        candidates.append(rootPath + "/" + String(normalizedPath.dropFirst(remoteRoot.count + 1)))
      }
    }

    if path.hasPrefix("~/") {
      candidates.append(NSHomeDirectory() + "/" + String(path.dropFirst(2)))
    } else if NSString(string: path).isAbsolutePath {
      candidates.append(path)
    } else {
      candidates.append(rootPath + "/" + path)
    }

    for candidate in candidates {
      let normalized = Self.trimTrailingSlashes(URL(fileURLWithPath: candidate).standardizedFileURL.path)
      if normalized == rootPath {
        return ""
      }
      if normalized.hasPrefix(rootPath + "/") {
        return String(normalized.dropFirst(rootPath.count + 1))
      }
    }
    return nil
  }

  private func refreshAfterOpenClawChanges(_ summary: OpenClawCorpusChangeSummary) async {
    guard let corpusRoot else { return }
    let root = corpusRoot.standardizedFileURL
    let changedFiles = summary.files.map { root.appendingPathComponent($0.relativePath).standardizedFileURL.path }
    let generatedBriefTitle = pendingNodeBriefTitle
    let generatedBriefRelativePath = pendingNodeBriefArtifactRelativePath.flatMap { pending in
      summary.files.contains(where: { $0.relativePath == pending }) ? pending : nil
    }
    for file in changedFiles {
      invalidateCanonicalDocumentCache(for: file)
    }

    if let selectedEntrySource,
       changedFiles.contains(URL(fileURLWithPath: selectedEntrySource.file).standardizedFileURL.path),
       let selectedLocation {
      await loadEntrySource(for: selectedLocation)
    }

    schedulePostOpenClawWorkspaceRefresh()

    if let generatedBriefRelativePath {
      let artifactURL = root.appendingPathComponent(generatedBriefRelativePath).standardizedFileURL
      openNodeBriefArtifact(
        url: artifactURL,
        relativePath: generatedBriefRelativePath,
        title: generatedBriefTitle ?? artifactURL.deletingPathExtension().lastPathComponent
      )
    }
  }

  private func schedulePostOpenClawWorkspaceRefresh() {
    postOpenClawWorkspaceRefreshTask?.cancel()
    postOpenClawWorkspaceRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled, let self else { return }
      await self.refreshCorpusFiles()
      guard !Task.isCancelled else { return }
      await self.refreshAgenda(preserveSelection: true, updatesStatus: false)
      guard !Task.isCancelled else { return }
      await self.refreshMeetings()
      guard !Task.isCancelled else { return }
      await self.refreshOpenClawThreads(showsLoading: false)
    }
  }

  private func openClawQueuedStatusText() -> String {
    if openClawQueuedMessageCount > 1 {
      return "Sending to OpenClaw... \(openClawQueuedMessageCount - 1) queued"
    }
    return "Sending to OpenClaw..."
  }

  public func resetOpenClawChat() {
    ensureOpenClawChatThread()
    let threadID = selectedOpenClawChatThreadID
    openClawMessages = []
    clearOpenClawDraftForSelectedThread()
    openClawPendingAttachments = []
    if let threadID {
      removeAllPendingOpenClawUserMessages(in: threadID)
      drainingOpenClawThreadIDs.remove(threadID)
      openClawRequestStartedAtByThreadID.removeValue(forKey: threadID)
    }
    syncSelectedOpenClawSendState()
    openClawChatScrollPosition = nil
    openClawAssistantChatScrollPosition = nil
    openClawStatusText = Self.openClawStatusText(settings: currentOpenClawSettings())
  }

  public var selectedOpenClawChatThread: OpenClawChatThread? {
    guard let selectedOpenClawChatThreadID else { return nil }
    return openClawChatThreads.first(where: { $0.id == selectedOpenClawChatThreadID })
  }

  public var openClawUnreadMessageCount: Int {
    openClawChatThreads.reduce(0) { $0 + $1.unreadMessageCount }
  }

  public var visibleOpenClawChatThreads: [OpenClawChatThread] {
    Self.sortedOpenClawChatThreadsForDisplay(openClawChatThreads.filter { !$0.isArchived })
  }

  public var archivedOpenClawChatThreads: [OpenClawChatThread] {
    Self.sortedOpenClawChatThreadsForDisplay(openClawChatThreads.filter(\.isArchived))
  }

  public func createOpenClawChatThread() {
    createOpenClawChatThread(title: "New Chat", statusText: "New OpenClaw chat")
  }

  private func createOpenClawChatThread(title: String, statusText: String) {
    let thread = OpenClawChatThread(
      title: title,
      sessionKey: Self.makeOpenClawSessionKey()
    )
    openClawChatThreads.insert(thread, at: 0)
    selectOpenClawChatThread(thread.id, persistsSelection: false)
    persistOpenClawTranscript()
    openClawStatusText = statusText
  }

  private func prepareOpenClawThread(mode: OpenClawThreadMode, title: String, statusText: String) {
    guard mode == .newThread else {
      ensureOpenClawChatThread()
      return
    }
    createOpenClawChatThread(title: Self.normalizedOpenClawThreadTitle(title), statusText: statusText)
  }

  private func prepareOpenClawThreadForNodeBrief(title: String) {
    guard openClawBriefsStartNewThread else { return }
    prepareOpenClawThread(
      mode: .newThread,
      title: "Brief: \(title)",
      statusText: "New OpenClaw brief chat"
    )
  }

  public func selectOpenClawChatThread(_ id: UUID) {
    selectOpenClawChatThread(id, persistsSelection: true)
  }

  public func selectOpenClawChatSearchResult(_ result: OpenClawChatSearchResult) {
    selectedSurface = .openClaw
    selectOpenClawChatThread(result.threadID)
    statusText = "Opened chat thread"
  }

  public func toggleOpenClawChatThreadPin(_ id: UUID) {
    guard let index = openClawChatThreads.firstIndex(where: { $0.id == id }) else { return }
    let thread = openClawChatThreads[index]
    openClawChatThreads[index] = thread.replacingOpenClawChatMetadata(isPinned: !thread.isPinned)
    sortOpenClawChatThreadsForDisplay()
    persistOpenClawTranscript()
  }

  public func renameOpenClawChatThread(_ id: UUID, title rawTitle: String) {
    let title = Self.normalizedOpenClawThreadTitle(rawTitle)
    guard !title.isEmpty,
          let index = openClawChatThreads.firstIndex(where: { $0.id == id })
    else { return }
    let thread = openClawChatThreads[index]
    guard thread.title != title else { return }
    openClawChatThreads[index] = thread.replacingOpenClawChatMetadata(title: title)
    if selectedOpenClawChatThreadID == id {
      openClawStatusText = "Renamed chat thread"
    }
    sortOpenClawChatThreadsForDisplay()
    persistOpenClawTranscript()
  }

  public func archiveOpenClawChatThread(_ id: UUID) {
    guard let index = openClawChatThreads.firstIndex(where: { $0.id == id }) else { return }
    let thread = openClawChatThreads[index]
    openClawChatThreads[index] = thread.replacingOpenClawChatMetadata(isArchived: true)
    sortOpenClawChatThreadsForDisplay()
    persistOpenClawTranscript()

    if selectedOpenClawChatThreadID == id {
      if let next = visibleOpenClawChatThreads.first {
        selectOpenClawChatThread(next.id, persistsSelection: true)
      } else {
        createOpenClawChatThread()
      }
    }
  }

  public func restoreOpenClawChatThread(_ id: UUID) {
    guard let index = openClawChatThreads.firstIndex(where: { $0.id == id }) else { return }
    let thread = openClawChatThreads[index]
    openClawChatThreads[index] = thread.replacingOpenClawChatMetadata(isArchived: false)
    sortOpenClawChatThreadsForDisplay()
    persistOpenClawTranscript()
  }

  private func selectOpenClawChatThread(_ id: UUID, persistsSelection: Bool) {
    guard let thread = openClawChatThreads.first(where: { $0.id == id }) else {
      return
    }
    saveOpenClawDraftForSelectedThread()
    selectedOpenClawChatThreadID = thread.id
    openClawSessionKey = thread.sessionKey
    markOpenClawChatThreadRead(thread.id, shouldPersist: false)
    restoreOpenClawDraft(for: thread.id)
    openClawPendingAttachments = []
    syncSelectedOpenClawSendState()
    openClawChatScrollPosition = nil
    openClawAssistantChatScrollPosition = nil
    replaceOpenClawMessages(thread.messages, shouldPersist: false)
    if persistsSelection {
      persistOpenClawTranscript()
    }
  }

  public func cacheOpenClawComposerDraft(_ draft: String) {
    guard let selectedOpenClawChatThreadID else { return }
    cacheOpenClawDraft(draft, for: selectedOpenClawChatThreadID)
  }

  public func publishOpenClawComposerDraft(_ draft: String) {
    cacheOpenClawComposerDraft(draft)
    guard openClawDraft != draft else { return }
    openClawDraft = draft
  }

  private func saveOpenClawDraftForSelectedThread() {
    guard let selectedOpenClawChatThreadID else { return }
    guard !openClawComposerCachedThreadIDs.contains(selectedOpenClawChatThreadID) else { return }
    cacheOpenClawDraft(openClawDraft, for: selectedOpenClawChatThreadID)
  }

  private func currentOpenClawDraftForSelectedThread() -> String {
    guard let selectedOpenClawChatThreadID else { return openClawDraft }
    guard openClawComposerCachedThreadIDs.contains(selectedOpenClawChatThreadID) else { return openClawDraft }
    return openClawDraftsByThreadID[selectedOpenClawChatThreadID] ?? ""
  }

  private func cacheOpenClawDraft(_ draft: String, for threadID: UUID) {
    openClawComposerCachedThreadIDs.insert(threadID)
    let normalizedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? ""
      : draft
    if normalizedDraft.isEmpty {
      openClawDraftsByThreadID.removeValue(forKey: threadID)
    } else {
      openClawDraftsByThreadID[threadID] = normalizedDraft
    }
  }

  private func restoreOpenClawDraft(for threadID: UUID) {
    openClawDraft = openClawDraftsByThreadID[threadID] ?? ""
  }

  private func clearOpenClawDraftForSelectedThread() {
    if let selectedOpenClawChatThreadID {
      openClawDraftsByThreadID.removeValue(forKey: selectedOpenClawChatThreadID)
      openClawComposerCachedThreadIDs.insert(selectedOpenClawChatThreadID)
    }
    openClawDraft = ""
  }

  private func ensureOpenClawChatThread() {
    if let selectedOpenClawChatThreadID,
       openClawChatThreads.contains(where: { $0.id == selectedOpenClawChatThreadID }) {
      return
    }
    let thread = OpenClawChatThread(
      title: Self.openClawThreadTitle(from: openClawMessages),
      sessionKey: openClawSessionKey,
      messages: openClawMessages
    )
    openClawChatThreads.insert(thread, at: 0)
    selectedOpenClawChatThreadID = thread.id
  }

  public func markSelectedOpenClawChatThreadRead() {
    guard let selectedOpenClawChatThreadID else { return }
    markOpenClawChatThreadRead(selectedOpenClawChatThreadID, shouldPersist: true)
  }

  private func markOpenClawChatThreadRead(_ id: UUID, shouldPersist: Bool) {
    guard let index = openClawChatThreads.firstIndex(where: { $0.id == id }) else { return }
    let thread = openClawChatThreads[index]
    guard thread.unreadMessageCount != 0 else { return }
    openClawChatThreads[index] = thread.replacingOpenClawChatMetadata(unreadMessageCount: 0)
    if shouldPersist {
      persistOpenClawTranscript()
    }
  }

  private func updateSelectedOpenClawChatThread(messages: [OpenClawChatMessage]) {
    ensureOpenClawChatThread()
    guard let selectedOpenClawChatThreadID else {
      return
    }
    updateOpenClawChatThread(selectedOpenClawChatThreadID, messages: messages)
  }

  private func updateOpenClawChatThread(
    _ threadID: UUID,
    messages: [OpenClawChatMessage],
    notifiesForNewAssistantMessages: Bool = false
  ) {
    guard let index = openClawChatThreads.firstIndex(where: { $0.id == threadID })
    else {
      return
    }

    let current = openClawChatThreads[index]
    let newAssistantMessageCount = notifiesForNewAssistantMessages
      ? Self.newAssistantMessageCount(previousMessages: current.messages, currentMessages: messages)
      : 0
    let isThreadOpen = selectedSurface == .openClaw && selectedOpenClawChatThreadID == current.id
    let unreadMessageCount = isThreadOpen
      ? 0
      : current.unreadMessageCount + newAssistantMessageCount
    let title = Self.updatedOpenClawThreadTitle(current: current, messages: messages)
    let updated = OpenClawChatThread(
      id: current.id,
      title: title,
      createdAt: current.createdAt,
      updatedAt: messages.last?.createdAt ?? Date(),
      sessionKey: current.sessionKey,
      messages: messages,
      isPinned: current.isPinned,
      isArchived: current.isArchived,
      unreadMessageCount: unreadMessageCount
    )
    openClawChatThreads[index] = updated
    sortOpenClawChatThreadsForDisplay()
    if newAssistantMessageCount > 0 && !isThreadOpen {
      openClawIncomingMessageSoundPlayer()
    }
  }

  nonisolated private static func newAssistantMessageCount(
    previousMessages: [OpenClawChatMessage],
    currentMessages: [OpenClawChatMessage]
  ) -> Int {
    let previousAssistantIDs = Set(previousMessages
      .filter { $0.role == .assistant }
      .map(\.id))
    return currentMessages
      .filter { $0.role == .assistant && !previousAssistantIDs.contains($0.id) }
      .count
  }

  private func sortOpenClawChatThreadsForDisplay() {
    openClawChatThreads = Self.sortedOpenClawChatThreadsForDisplay(openClawChatThreads)
  }

  nonisolated private static func sortedOpenClawChatThreadsForDisplay(
    _ threads: [OpenClawChatThread]
  ) -> [OpenClawChatThread] {
    threads.sorted { lhs, rhs in
      if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
      if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  nonisolated static func openClawThreadTitle(
    from messages: [OpenClawChatMessage],
    fallback: String = "New Chat"
  ) -> String {
    guard let firstUserMessage = messages.first(where: { $0.role == .user }) else {
      return fallback
    }
    let title = heuristicOpenClawThreadTitle(from: firstUserMessage.content)
    return title.isEmpty ? fallback : title
  }

  nonisolated private static func updatedOpenClawThreadTitle(
    current: OpenClawChatThread,
    messages: [OpenClawChatMessage]
  ) -> String {
    let heuristicTitle = openClawThreadTitle(from: messages, fallback: current.title)
    let currentTitle = normalizedOpenClawThreadTitle(current.title)
    let hasExistingUserMessage = current.messages.contains(where: { $0.role == .user })
    if currentTitle == "New Chat"
      || (hasExistingUserMessage && currentTitle == openClawThreadTitle(from: current.messages, fallback: currentTitle)) {
      return heuristicTitle
    }
    return currentTitle
  }

  nonisolated private static func normalizedOpenClawThreadTitle(_ title: String) -> String {
    let clean = Org2Display.cleanInline(title)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return "New Chat" }
    return clean.count <= 80
      ? clean
      : String(clean.prefix(77)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }

  nonisolated private static func heuristicOpenClawThreadTitle(from content: String) -> String {
    let normalized = normalizedOpenClawTitleSource(content)
    guard !normalized.isEmpty else { return "" }

    let candidates = normalized
      .split(whereSeparator: { ".!?\n".contains($0) })
      .map { cleanedOpenClawTitleCandidate(String($0)) }
      .filter { !$0.isEmpty && !isOpenClawTitleFiller($0) }

    guard let candidate = candidates.first ?? normalized.split(separator: "\n").first.map(String.init) else {
      return ""
    }

    let words = candidate
      .split(whereSeparator: { $0.isWhitespace })
      .map { titleWord(from: String($0)) }
      .filter { !$0.isEmpty && !openClawTitleStopWords.contains($0.lowercased()) }

    let selectedWords = Array(words.prefix(6))
    let rawTitle = (selectedWords.isEmpty ? candidate : selectedWords.joined(separator: " "))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let limitedTitle = rawTitle.count <= 56
      ? rawTitle
      : String(rawTitle.prefix(53)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    return sentenceCaseOpenClawTitle(limitedTitle)
  }

  nonisolated private static func normalizedOpenClawTitleSource(_ content: String) -> String {
    content
      .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\[[^\]]+\]\([^)]+\)"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"<image[^>]*>"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func cleanedOpenClawTitleCandidate(_ candidate: String) -> String {
    var clean = candidate
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#*-_`\"' "))

    let leadingPatterns = [
      #"(?i)^sure\s+let'?s\s+do\s+that\s+to\s+start\b"#,
      #"(?i)^while\s+you'?re\s+doing\s+that\b"#,
      #"(?i)^also\b"#,
      #"(?i)^can\s+you\b"#,
      #"(?i)^could\s+you\b"#,
      #"(?i)^would\s+you\b"#,
      #"(?i)^please\b"#,
      #"(?i)^i\s+think\b"#,
      #"(?i)^it\s+would\s+be\s+good\s+to\b"#,
      #"(?i)^it\s+would\s+be\s+great\s+to\b"#,
      #"(?i)^let'?s\b"#,
      #"(?i)^we\s+should\b"#,
      #"(?i)^our\b"#
    ]

    var changed = true
    while changed {
      changed = false
      for pattern in leadingPatterns {
        let next = clean
          .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if next != clean {
          clean = next
          changed = true
        }
      }
    }
    return clean
  }

  nonisolated private static func isOpenClawTitleFiller(_ candidate: String) -> Bool {
    let normalized = candidate
      .lowercased()
      .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    return openClawTitleFillerPhrases.contains(normalized)
  }

  nonisolated private static func titleWord(from raw: String) -> String {
    raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
  }

  nonisolated private static func sentenceCaseOpenClawTitle(_ title: String) -> String {
    guard let first = title.first else { return title }
    return String(first).uppercased() + String(title.dropFirst())
  }

  nonisolated private static let openClawTitleFillerPhrases = Set([
    "sure",
    "ok",
    "okay",
    "yes",
    "yeah",
    "thanks",
    "thank you",
    "sounds good",
    "that seems good",
    "lets do that",
    "let's do that",
    "sure lets do that to start",
    "sure let's do that to start"
  ])

  nonisolated private static let openClawTitleStopWords = Set([
    "a", "able", "an", "and", "are", "as", "at", "be", "can", "could", "do", "does", "doing",
    "for", "from", "how", "i", "in", "is", "it", "just", "me", "my", "of", "on",
    "or", "our", "please", "should", "start", "that", "the", "this", "to", "we",
    "well", "what", "while", "with", "would", "you", "you're", "youre", "your"
  ])

  nonisolated static func searchOpenClawChatThreads(
    _ threads: [OpenClawChatThread],
    query rawQuery: String,
    limit: Int
  ) -> [OpenClawChatSearchResult] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    return threads
      .compactMap { thread -> (OpenClawChatSearchResult, Int)? in
        let titleScore = fuzzyScore(query: query, candidate: thread.title).map { $0 + 80 }
        let messageMatches = thread.messages.compactMap { message -> (OpenClawChatMessage, Int)? in
          guard let score = fuzzyScore(query: query, candidate: message.content) else { return nil }
          return (message, score)
        }
        let bestMessage = messageMatches.max { lhs, rhs in lhs.1 < rhs.1 }
        let bestScore = max(titleScore ?? 0, bestMessage?.1 ?? 0)
        guard bestScore > 0 else { return nil }

        let snippet: String
        let messageID: UUID?
        if let bestMessage {
          snippet = chatSearchSnippet(message: bestMessage.0.content, query: query)
          messageID = bestMessage.0.id
        } else {
          snippet = thread.messages.first?.content ?? thread.title
          messageID = nil
        }

        return (
          OpenClawChatSearchResult(
            threadID: thread.id,
            messageID: messageID,
            title: thread.title,
            snippet: snippet,
            messageCount: thread.messageCount,
            updatedAt: thread.updatedAt
          ),
          bestScore
        )
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.updatedAt > rhs.0.updatedAt
      }
      .prefix(limit)
      .map(\.0)
  }

  nonisolated private static func chatSearchSnippet(message: String, query: String) -> String {
    let collapsed = message
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return message }
    guard let range = collapsed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
      return String(collapsed.prefix(180))
    }

    let before = collapsed.distance(from: collapsed.startIndex, to: range.lowerBound)
    let startOffset = max(0, before - 72)
    let endOffset = min(collapsed.count, before + query.count + 108)
    let start = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
    let end = collapsed.index(collapsed.startIndex, offsetBy: endOffset)
    let prefix = startOffset > 0 ? "..." : ""
    let suffix = endOffset < collapsed.count ? "..." : ""
    return prefix + String(collapsed[start..<end]) + suffix
  }

  public func openClawChatScrollPosition(isAssistantPanel: Bool) -> Double? {
    isAssistantPanel ? openClawAssistantChatScrollPosition : openClawChatScrollPosition
  }

  public func recordOpenClawChatScrollPosition(_ position: Double, isAssistantPanel: Bool = false) {
    let normalized = min(1, max(0, position))
    if isAssistantPanel {
      openClawAssistantChatScrollPosition = normalized
    } else {
      openClawChatScrollPosition = normalized
    }
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

  public func isPersonalAssignee(_ rawAssignee: String?) -> Bool {
    guard let assignee = rawAssignee?.trimmingCharacters(in: .whitespacesAndNewlines),
          !assignee.isEmpty
    else {
      return true
    }
    return Self.personalAssigneeNames(from: personalAssigneeNamesText)
      .contains(Self.normalizedAssigneeIdentity(assignee))
  }

  public func isAgentAssignee(_ rawAssignee: String?) -> Bool {
    guard let assignee = rawAssignee?.trimmingCharacters(in: .whitespacesAndNewlines),
          !assignee.isEmpty
    else {
      return false
    }
    let normalized = Self.normalizedAssigneeIdentity(assignee)
    let agentNames = [
      agentHandoffAssignee,
      Self.defaultAgentHandoffAssignee
    ]
      .map(Self.normalizedAssigneeIdentity)
      .filter { !$0.isEmpty }
    return Set(agentNames).contains(normalized)
  }

  public func saveOpenClawConfiguration(
    endpoint: String,
    agent: String,
    handoffAssignee: String,
    personalAssigneeNames: String? = nil,
    remoteCorpusPath: String,
    briefsStartNewThread: Bool? = nil,
    token: String,
    clearToken: Bool
  ) -> Bool {
    let rawEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let normalizedEndpoint = OpenClawGatewaySettings.normalizedEndpointString(rawEndpoint) else {
      openClawStatusText = "OpenClaw gateway endpoint is invalid"
      return false
    }

    let rawAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
    let agent = rawAgent.isEmpty ? "main" : rawAgent
    let rawHandoffAssignee = handoffAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
    let handoffAssignee = rawHandoffAssignee.isEmpty ? Self.defaultAgentHandoffAssignee : rawHandoffAssignee
    let personalAssigneeNames = (personalAssigneeNames ?? personalAssigneeNamesText)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let remoteCorpusPath = remoteCorpusPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let briefsStartNewThread = briefsStartNewThread ?? openClawBriefsStartNewThread
    let normalizedToken = OpenClawGatewaySettings.normalizedBearerToken(token)

    do {
      defaults.set(normalizedEndpoint, forKey: openClawEndpointKey)
      defaults.set(agent, forKey: openClawAgentKey)
      defaults.set(handoffAssignee, forKey: agentHandoffAssigneeKey)
      defaults.set(personalAssigneeNames, forKey: personalAssigneeNamesKey)
      defaults.set(remoteCorpusPath, forKey: openClawRemoteCorpusPathKey)
      openClawEndpointText = normalizedEndpoint
      openClawAgentID = agent
      agentHandoffAssignee = handoffAssignee
      personalAssigneeNamesText = personalAssigneeNames
      openClawRemoteCorpusPath = remoteCorpusPath
      openClawBriefsStartNewThread = briefsStartNewThread

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
      statusText = "Encryption settings saved"
      return true
    } catch {
      orgCryptStatusText = error.localizedDescription
      errorText = error.localizedDescription
      return false
    }
  }

  public var orgCryptPublicKeysDirectoryURL: URL? {
    corpusRoot?.appendingPathComponent(Self.orgCryptPublicKeysDirectoryName, isDirectory: true)
  }

  public func refreshOrgCryptManagedRecipientFiles() {
    guard let corpusRoot else {
      orgCryptManagedRecipientFiles = []
      return
    }
    do {
      orgCryptManagedRecipientFiles = try Self.scanOrgCryptManagedRecipientFiles(corpusRoot: corpusRoot)
    } catch {
      orgCryptManagedRecipientFiles = []
      orgCryptStatusText = error.localizedDescription
    }
  }

  public static func scanOrgCryptManagedRecipientFiles(corpusRoot: URL) throws -> [OrgCryptRecipientFile] {
    let root = corpusRoot.standardizedFileURL
    let directory = root.appendingPathComponent(orgCryptPublicKeysDirectoryName, isDirectory: true)
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return []
    }

    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    .filter { url in
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    .map { url in
      let standardized = url.standardizedFileURL
      return OrgCryptRecipientFile(
        path: standardized.path,
        relativePath: Self.relativePath(for: standardized.path, root: root)
      )
    }
    .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
  }

  @discardableResult
  public func importOrgCryptAgentPublicKey(from sourceURL: URL) throws -> OrgCryptRecipientFile {
    guard let corpusRoot else {
      throw OrgCryptPublicKeyImportError.missingCorpusRoot
    }

    let fileManager = FileManager.default
    let source = sourceURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw OrgCryptPublicKeyImportError.invalidSource
    }

    let destinationDirectory = corpusRoot.standardizedFileURL
      .appendingPathComponent(Self.orgCryptPublicKeysDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent, isDirectory: false).standardizedFileURL

    if source.path != destination.path {
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.copyItem(at: source, to: destination)
    }

    refreshOrgCryptManagedRecipientFiles()
    guard let imported = orgCryptManagedRecipientFiles.first(where: { $0.path == destination.path }) else {
      let file = OrgCryptRecipientFile(
        path: destination.path,
        relativePath: Self.relativePath(for: destination.path, root: corpusRoot.standardizedFileURL)
      )
      orgCryptManagedRecipientFiles.append(file)
      orgCryptManagedRecipientFiles.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
      return file
    }
    orgCryptStatusText = "Added \(imported.name) to public keys"
    return imported
  }

  public func chooseOrgCryptAgentPublicKey() -> OrgCryptRecipientFile? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add"
    panel.message = "Choose an agent public key to copy into public-keys"

    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    do {
      return try importOrgCryptAgentPublicKey(from: url)
    } catch {
      orgCryptStatusText = error.localizedDescription
      errorText = error.localizedDescription
      return nil
    }
  }

  public func normalizedOrgCryptRecipientFilePath(_ rawPath: String) -> String {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if NSString(string: trimmed).isAbsolutePath {
      return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
    guard let corpusRoot else { return trimmed }
    return corpusRoot.standardizedFileURL.appendingPathComponent(trimmed).standardizedFileURL.path
  }

  public func selectedManagedOrgCryptRecipientFilePaths(in recipientFilesText: String) -> Set<String> {
    let managed = Set(orgCryptManagedRecipientFiles.map(\.path))
    return Set(OrgCryptSettings.splitListText(recipientFilesText)
      .map { normalizedOrgCryptRecipientFilePath($0) }
      .filter { managed.contains($0) })
  }

  public func manualOrgCryptRecipientFilesText(from recipientFilesText: String) -> String {
    let managed = Set(orgCryptManagedRecipientFiles.map(\.path))
    let manual = OrgCryptSettings.splitListText(recipientFilesText)
      .filter { !managed.contains(normalizedOrgCryptRecipientFilePath($0)) }
    return OrgCryptSettings.listText(manual)
  }

  public func combinedOrgCryptRecipientFilesText(
    manualText: String,
    selectedManagedPaths: Set<String>
  ) -> String {
    var seen = Set<String>()
    var values: [String] = []
    for value in OrgCryptSettings.splitListText(manualText) {
      if seen.insert(normalizedOrgCryptRecipientFilePath(value)).inserted {
        values.append(value)
      }
    }
    for path in selectedManagedPaths.sorted() {
      let normalized = normalizedOrgCryptRecipientFilePath(path)
      if !normalized.isEmpty, seen.insert(normalized).inserted {
        values.append(normalized)
      }
    }
    return OrgCryptSettings.listText(values)
  }

  public func presentOrgCryptConfiguration() {
    isOrgCryptConfigurationPresented = true
  }

  @discardableResult
  public func runOrgCrypt(_ action: OrgCryptAction, line explicitLine: Int? = nil) async -> OrgCryptRunResult {
    guard let file = selectedEntrySource?.file ?? selectedLocation?.file else {
      let message = "Open a file before running encryption"
      statusText = message
      return .failure(message: message)
    }

    let line = explicitLine ?? selectedBlock?.startLine ?? selectedLocation?.lineForEditor ?? 1
    let settings = currentOrgCryptSettings(allowKeychainRead: true)
    orgCryptStatusText = "\(action.title) running \(relativePath(file)):\(line)"
    statusText = orgCryptStatusText
    var arguments = [
      "crypt",
      action.rawValue,
      "--file",
      file,
      "--line",
      "\(line)",
      "--gpg-program",
      settings.gpgProgram,
      "--gpg-timeout",
      "\(settings.gpgTimeout)",
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
      let succeeded = action == .decrypt ? result.changed : true
      orgCryptStatusText = "\(action.title) \(result.changed ? "updated" : "made no changes") \(relativePath(file)):\(result.headingLine)"
      statusText = orgCryptStatusText
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
      if succeeded {
        return .success(changed: result.changed, headingLine: result.headingLine, message: orgCryptStatusText)
      }
      return .failure(message: orgCryptStatusText, headingLine: result.headingLine)
    } catch {
      errorText = error.localizedDescription
      orgCryptStatusText = error.localizedDescription
      statusText = error.localizedDescription
      return .failure(message: error.localizedDescription, headingLine: line)
    }
  }

  private func rebuildAgendaDisplayCache() {
    agendaDisplaySections = Self.makeAgendaDisplaySections(agenda: agenda, mode: agendaMode, filter: agendaFilter)
    visibleAgendaItems = agendaDisplaySections.flatMap(\.items)
  }

  private static func makeAgendaDisplaySections(agenda: AgendaPayload?, mode: AgendaMode, filter: String) -> [AgendaDisplaySection] {
    guard let agenda else { return [] }
    let terms = filterTerms(from: filter)
    let overdue = agenda.overdue.flatMap(\.items).filter { $0.matchesAgendaFilterTerms(terms) }
    let today = agenda.days.filter { $0.date == agenda.range.start }.flatMap(\.items).filter { $0.matchesAgendaFilterTerms(terms) }
    let next7End = Self.isoDate(Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: Self.dateFromISO(agenda.range.start) ?? Date()) ?? Date())
    let next7 = agenda.days
      .filter { $0.date > agenda.range.start && $0.date <= next7End }
      .flatMap(\.items)
      .filter { $0.matchesAgendaFilterTerms(terms) }
    let later = agenda.days
      .filter { $0.date > next7End }
      .flatMap(\.items)
      .filter { $0.matchesAgendaFilterTerms(terms) }

    switch mode {
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
    case .assigned:
      return []
    }
  }

  private static func filterTerms(from query: String) -> [String] {
    query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
  }

  public var visibleAgendaItemCount: Int {
    visibleAgendaItems.count
  }

  public var bulkAgendaSelectionCount: Int {
    let visibleIDs = Set(visibleAgendaItems.map(\.id))
    return bulkSelectedAgendaItemIDs.intersection(visibleIDs).count
  }

  public var hasBulkAgendaSelection: Bool {
    bulkAgendaSelectionCount > 0
  }

  public func isAgendaItemBulkSelected(_ item: AgendaItem) -> Bool {
    bulkSelectedAgendaItemIDs.contains(item.id)
  }

  public func toggleAgendaItemBulkSelection(_ item: AgendaItem) {
    var ids = bulkSelectedAgendaItemIDs
    if ids.contains(item.id) {
      ids.remove(item.id)
    } else {
      ids.insert(item.id)
    }
    bulkSelectedAgendaItemIDs = ids
    updateAgendaBulkSelectionStatusText()
  }

  public func selectAllVisibleAgendaItemsForBulkAction() {
    let ids = Set(visibleAgendaItems.map(\.id))
    bulkSelectedAgendaItemIDs = ids
    if ids.isEmpty {
      statusText = "No visible agenda items"
    } else {
      statusText = ids.count == 1 ? "1 agenda item selected" : "\(ids.count) agenda items selected"
    }
  }

  public func clearAgendaBulkSelection() {
    guard !bulkSelectedAgendaItemIDs.isEmpty else { return }
    bulkSelectedAgendaItemIDs = []
    statusText = "Agenda selection cleared"
  }

  public func handleAgendaItemClick(_ item: AgendaItem, modifiers: NSEvent.ModifierFlags = []) {
    if modifiers.intersection([.command]).contains(.command) {
      toggleAgendaItemBulkSelection(item)
      selectAgendaItem(item)
    } else {
      selectAgendaItem(item)
    }
  }

  public func extendAgendaBulkSelection(by delta: Int) {
    let items = visibleAgendaItems
    guard !items.isEmpty else {
      statusText = "No visible agenda items"
      return
    }

    let currentIndex = selectedAgendaItemID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
    let nextIndex: Int
    if let currentIndex {
      nextIndex = max(0, min(items.count - 1, currentIndex + delta))
    } else {
      nextIndex = delta < 0 ? items.count - 1 : 0
    }

    var ids = bulkSelectedAgendaItemIDs
    if let currentIndex {
      ids.insert(items[currentIndex].id)
    }
    ids.insert(items[nextIndex].id)
    bulkSelectedAgendaItemIDs = ids
    selectAgendaItem(items[nextIndex])
    updateAgendaBulkSelectionStatusText()
  }

  public func selectAgendaItem(_ item: AgendaItem) {
    deactivateAgendaFilterFocus()
    suppressNextAgendaSelectionActivation = false
    selectedSurface = .agenda
    select(.agenda(item))
  }

  private func selectAgendaItemWithoutActivatingEntry(_ item: AgendaItem) {
    suppressNextAgendaSelectionActivation = true
    selectedSurface = .agenda
    selectedAgendaItemID = item.id
  }

  public func moveAgendaSelection(by delta: Int) {
    if agendaMode == .assigned {
      moveAssignedAgendaSelection(by: delta)
      return
    }
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

  public func requestDetailScroll(toBlock blockID: OrgEditableBlock.ID) {
    detailScrollRequest = DetailScrollRequest(
      id: (detailScrollRequest?.id ?? 0) + 1,
      target: .block(blockID)
    )
  }

  public func requestDetailReveal(toBlock blockID: OrgEditableBlock.ID) {
    detailScrollRequest = DetailScrollRequest(
      id: (detailScrollRequest?.id ?? 0) + 1,
      target: .revealBlock(blockID)
    )
  }

  public func selectFirstAgendaItem() {
    if agendaMode == .assigned {
      if let first = visibleAssignedWorkItems.first {
        selectAssignedWorkItem(first)
      }
      return
    }
    pruneAgendaBulkSelection()
    if let first = visibleAgendaItems.first {
      selectAgendaItem(first)
    }
  }

  public func syncAgendaSelectionAfterDisplayOptionsChange() {
    if agendaMode == .assigned {
      syncAssignedAgendaSelectionAfterDisplayOptionsChange()
      return
    }
    let items = visibleAgendaItems
    pruneAgendaBulkSelection(visibleItems: items)
    guard !items.isEmpty else {
      guard selectedAgendaItemID != nil else { return }
      suppressNextAgendaSelectionActivation = true
      selectedAgendaItemID = nil
      return
    }

    if let selectedAgendaItemID, items.contains(where: { $0.id == selectedAgendaItemID }) {
      return
    }

    let nextID = items[0].id
    guard selectedAgendaItemID != nextID else { return }
    suppressNextAgendaSelectionActivation = true
    selectedAgendaItemID = nextID
  }

  public func syncAssignedAgendaSelectionAfterDisplayOptionsChange() {
    guard agendaMode == .assigned else { return }
    selectedAgendaItemID = nil
    let items = visibleAssignedWorkItems
    guard !items.isEmpty else {
      selectedAssignedWorkItemID = nil
      return
    }
    if let selectedAssignedWorkItemID,
       items.contains(where: { $0.id == selectedAssignedWorkItemID }) {
      return
    }
    selectedAssignedWorkItemID = items[0].id
  }

  public func consumeAgendaSelectionActivationSuppression() -> Bool {
    guard suppressNextAgendaSelectionActivation else { return false }
    suppressNextAgendaSelectionActivation = false
    return true
  }

  public func selectLastAgendaItem() {
    if agendaMode == .assigned {
      if let last = visibleAssignedWorkItems.last {
        selectAssignedWorkItem(last)
      }
      return
    }
    if let last = visibleAgendaItems.last {
      selectAgendaItem(last)
    }
  }

  public func moveAssignedAgendaSelection(by delta: Int) {
    let items = assignedWorkSections.flatMap(\.items)
    guard !items.isEmpty else { return }

    let currentIndex = selectedAssignedWorkItemID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
    let nextIndex: Int
    if let currentIndex {
      nextIndex = max(0, min(items.count - 1, currentIndex + delta))
    } else {
      nextIndex = delta < 0 ? items.count - 1 : 0
    }
    selectAssignedWorkItem(items[nextIndex])
  }

  public func setAgendaModeFromKey(_ key: String) {
    if key == "1" { agendaMode = .focus }
    if key == "2" { agendaMode = .today }
    if key == "3" { agendaMode = .range }
    if key == "4" { agendaMode = .assigned }
    syncAgendaSelectionAfterDisplayOptionsChange()
  }

  public func focusAgendaFilter(clearsFilter: Bool = true) {
    selectedSurface = .agenda
    if clearsFilter {
      agendaFilter = ""
    }
    agendaFilterFocusToken += 1
  }

  public func focusApprovalFilter() {
    selectedSurface = .approvals
    approvalFilterFocusToken += 1
  }

  public func focusCorpusFileFilter() {
    selectedSurface = .files
    corpusFileFilterFocusToken += 1
  }

  public func deactivateAgendaFilterFocus() {
    isAgendaFilterFocused = false
  }

  public func clearAgendaFilter() {
    agendaFilter = ""
    syncAgendaSelectionAfterDisplayOptionsChange()
  }

  public var canOrganizeCurrentHeadline: Bool {
    hasBulkAgendaSelection || selectedHeadlineMutationTarget != nil
  }

  private var selectedHeadlineMutationTarget: HeadlineMutationTarget? {
    if selectedSurface == .agenda,
       let item = selectedAgendaItemForMutation() {
      return HeadlineMutationTarget(item: item)
    }
    if let renderedTarget = selectedRenderedHeadlineMutationTarget {
      return renderedTarget
    }
    if let locationTarget = selectedLocationHeadlineMutationTarget {
      return locationTarget
    }
    return nil
  }

  private var selectedRenderedHeadlineMutationTarget: HeadlineMutationTarget? {
    guard let source = selectedEntrySource, source.isEditable else { return nil }
    let visibleBlocks = OrgRenderedFoldTree.visibleBlocks(
      selectedRenderedBlocks,
      foldedBlockIDs: foldedRenderedBlockIDs
    )
    guard !visibleBlocks.isEmpty else { return nil }

    let candidate: OrgEditableBlock?
    if let selectedBlock {
      candidate = visibleBlocks
        .filter { block in
          if case .heading = block.rendered {
            return block.startLine <= selectedBlock.startLine
          }
          return false
        }
        .max { $0.startLine < $1.startLine }
    } else if source.isSubtree {
      candidate = visibleBlocks.first { block in
        if case .heading = block.rendered {
          return block.startLine == source.startLine
        }
        return false
      }
    } else {
      candidate = nil
    }

    guard let candidate,
          case .heading(let heading) = candidate.rendered
    else {
      return nil
    }
    return HeadlineMutationTarget(
      file: source.file,
      line: candidate.startLine,
      title: heading.title.isEmpty ? relativePath(source.file) : Org2Display.cleanInline(heading.title),
      agendaItemID: nil
    )
  }

  private var selectedLocationHeadlineMutationTarget: HeadlineMutationTarget? {
    guard let location = selectedLocation else { return nil }
    if case .agenda(let item) = location {
      return HeadlineMutationTarget(item: item)
    }
    guard selectedEntrySource?.isEditable == true else { return nil }
    let line: Int
    if let source = selectedEntrySource, source.isSubtree, source.file == location.file {
      line = source.startLine
    } else {
      line = location.lineForEditor
    }
    return HeadlineMutationTarget(
      file: location.file,
      line: line,
      title: location.title,
      agendaItemID: nil
    )
  }

  private func headlineMutationTarget(for location: WorkspaceLocation) -> HeadlineMutationTarget? {
    switch location {
    case .agenda(let item):
      return HeadlineMutationTarget(item: item)
    case .assigned(let item):
      return HeadlineMutationTarget(
        file: item.file,
        line: item.lineForEditor,
        title: Org2Display.cleanInline(item.headline)
      )
    case .search(let result):
      return HeadlineMutationTarget(
        file: result.file,
        line: result.lineForEditor,
        title: Org2Display.cleanInline(result.title)
      )
    case .backlink(let backlink):
      return HeadlineMutationTarget(
        file: backlink.file,
        line: backlink.lineForEditor,
        title: Org2Display.cleanInline(backlink.srcTitle)
      )
    case .openClaw(let thread):
      return HeadlineMutationTarget(
        file: thread.file,
        line: thread.lineForEditor,
        title: Org2Display.cleanInline(thread.title)
      )
    case .meeting(let meeting):
      return HeadlineMutationTarget(
        file: meeting.file,
        line: meeting.lineForEditor,
        title: Org2Display.cleanInline(meeting.title)
      )
    }
  }

  private func refreshAfterHeadlineMutation(
    _ target: HeadlineMutationTarget,
    selectMutatedBlock: Bool = true
  ) async {
    invalidateCanonicalDocumentCache(for: target.file)
    if selectedEntrySource?.file == target.file, let selectedLocation {
      if selectMutatedBlock {
        pendingBlockSelection = PendingBlockSelection(
          file: target.file,
          line: target.line,
          mode: .containingOrNearest
        )
      }
      scheduleEntrySourceLoad(for: selectedLocation)
    }
    scheduleAgendaRefresh(preserveSelection: true)
  }

  private func optimisticallyUpdateAgendaItem(id agendaItemID: AgendaItem.ID?, todo: String) {
    guard let agendaItemID,
          let agenda
    else {
      return
    }

    var updatedSelectedItem: AgendaItem?
    let transformItems: ([AgendaItem]) -> [AgendaItem] = { items in
      items.map { item in
        guard item.id == agendaItemID else { return item }
        let updated = item.replacing(todo: todo)
        updatedSelectedItem = updated
        return updated
      }
    }
    let transformGroups: ([AgendaGroup]?) -> [AgendaGroup]? = { groups in
      groups?.map { group in
        AgendaGroup(label: group.label, items: transformItems(group.items))
      }
    }
    let transformDays: ([AgendaDay]) -> [AgendaDay] = { days in
      days.map { day in
        AgendaDay(
          date: day.date,
          weekday: day.weekday,
          items: transformItems(day.items),
          groups: transformGroups(day.groups)
        )
      }
    }

    self.agenda = AgendaPayload(
      schema: agenda.schema,
      range: agenda.range,
      overdue: transformDays(agenda.overdue),
      days: transformDays(agenda.days),
      skippedFiles: agenda.skippedFiles,
      workload: agenda.workload
    )

    if let updatedSelectedItem,
       case .agenda(let currentItem) = selectedLocation,
       currentItem.id == agendaItemID {
      selectedLocation = .agenda(updatedSelectedItem)
    }
  }

  public func presentSimilarTodoAssignment() {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a TODO heading first"
      return
    }
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    do {
      let files = corpusFiles.isEmpty ? try Self.scanCorpusFiles(corpusRoot: corpusRoot) : corpusFiles
      let allCandidates = try Self.scanTodoHeadings(files: files)
      let matched = Self.similarTodoCandidates(to: target, from: allCandidates)
      similarTodoCandidates = matched
      selectedSimilarTodoCandidateIDs = Set(matched.map(\.id))
      similarTodoPattern = Self.inferredAssignmentPattern(from: matched, fallback: target.title)
      similarTodoAssignee = resolvedAgentHandoffAssignee()
      similarTodoStatus = "ready"
      isSimilarTodoAssignmentPresented = true
      statusText = "\(matched.count) similar TODO\(matched.count == 1 ? "" : "s") found"
    } catch {
      errorText = error.localizedDescription
      statusText = "Similar TODO scan failed"
    }
  }

  public func toggleSimilarTodoCandidateSelection(_ candidate: SimilarTodoCandidate) {
    if selectedSimilarTodoCandidateIDs.contains(candidate.id) {
      selectedSimilarTodoCandidateIDs.remove(candidate.id)
    } else {
      selectedSimilarTodoCandidateIDs.insert(candidate.id)
    }
  }

  public func assignSimilarTodos(askOpenClaw: Bool) async {
    let assignee = similarTodoAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !assignee.isEmpty else {
      statusText = "Assignee is required"
      return
    }
    let status = similarTodoStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "ready"
      : similarTodoStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = similarTodoCandidates.filter { selectedSimilarTodoCandidateIDs.contains($0.id) }
    guard !selected.isEmpty else {
      statusText = "Select at least one TODO"
      return
    }

    let timestamp = Self.orgTimestamp(Date())
    do {
      var touchedFiles: Set<String> = []
      for candidate in selected.sorted(by: { lhs, rhs in
        if lhs.file == rhs.file { return lhs.line > rhs.line }
        return lhs.file.localizedStandardCompare(rhs.file) == .orderedAscending
      }) {
        let target = HeadlineMutationTarget(
          file: candidate.file,
          line: candidate.line,
          title: Org2Display.cleanInline(candidate.headline)
        )
        try await setTodoAssignee(assignee, for: target)
        try upsertHeadlineProperties(
          file: candidate.file,
          line: candidate.line,
          properties: [
            "STATUS": status,
            "ASSIGNED_AT": timestamp
          ]
        )
        touchedFiles.insert(candidate.file)
      }
      for file in touchedFiles {
        invalidateCanonicalDocumentCache(for: file)
      }
      statusText = "Assigned \(selected.count) TODO\(selected.count == 1 ? "" : "s") to \(assignee)"
      isSimilarTodoAssignmentPresented = false
      await refreshAgenda(preserveSelection: true, updatesStatus: false)
      await refreshAssignedWork(showsLoading: false)
      if let selectedLocation, touchedFiles.contains(selectedLocation.file) {
        await loadEntrySource(for: selectedLocation)
      }
      if askOpenClaw {
        await askOpenClawToHandleAssignedBacklog(
          assignee: assignee,
          status: status,
          pattern: similarTodoPattern,
          items: selected
        )
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Assignment failed"
    }
  }

  public func askOpenClawToHandleAssignedBacklog(
    assignee: String,
    status: String,
    pattern: String,
    items: [SimilarTodoCandidate]
  ) async {
    guard !items.isEmpty else { return }
    let prompt = Self.openClawAssignedBacklogPrompt(
      assignee: assignee,
      status: status,
      pattern: pattern,
      items: items,
      relativePath: { [weak self] file in self?.relativePath(file) ?? file },
      mappedPath: { [weak self] file in self?.mappedPathForOpenClaw(file) ?? file }
    )
    selectedSurface = .openClaw
    setOpenClawAssistantPanelPresented(true)
    await sendOpenClawMessage(text: prompt)
  }

  public func applyTodoShortcut(_ status: TodoEditStatus?) async {
    let bulkItems = selectedAgendaItemsForBulkMutation()
    if !bulkItems.isEmpty {
      await applyTodoShortcut(status, to: bulkItems)
      return
    }

    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a TODO heading first"
      return
    }
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItems.firstIndex(where: { $0.id == id })
    }
    var shouldAdvanceSelection = status.map { Self.isTerminalTodoStatus($0.rawValue) } ?? false

    do {
      let newStatus: String
      if let status {
        newStatus = try await setTodoStatus(status, for: target)
        statusText = "\(status.label) -> \(target.title)"
      } else {
        newStatus = try await toggleTodoStatus(for: target)
        statusText = "\(newStatus) -> \(target.title)"
        shouldAdvanceSelection = Self.isTerminalTodoStatus(newStatus)
      }
      optimisticallyUpdateAgendaItem(id: target.agendaItemID, todo: newStatus)
      await refreshAfterHeadlineMutation(target)
      preserveAgendaSelectionAfterTodoMutation(
        target: target,
        originalVisibleIndex: originalVisibleIndex,
        shouldAdvanceSelection: shouldAdvanceSelection
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "TODO update failed"
    }
  }

  private func applyAgendaTodoShortcut(_ status: TodoEditStatus) {
    let bulkItems = selectedAgendaItemsForBulkMutation()
    if !bulkItems.isEmpty {
      Task { await applyTodoShortcut(status, to: bulkItems) }
      return
    }

    guard selectedSurface == .agenda,
          let item = selectedAgendaItemForMutation()
    else {
      Task { await applyTodoShortcut(status) }
      return
    }

    let target = HeadlineMutationTarget(item: item)
    let visibleItemsBeforeMutation = visibleAgendaItems
    let originalVisibleIndex = visibleItemsBeforeMutation.firstIndex(where: { $0.id == item.id })
    let shouldAdvanceSelection = Self.isTerminalTodoStatus(status.rawValue)
    let nextSelection = shouldAdvanceSelection
      ? Self.nextActionableAgendaItem(
        afterMutating: item.id,
        originalVisibleIndex: originalVisibleIndex,
        in: visibleItemsBeforeMutation
      )
      : nil

    statusText = "\(status.label) -> \(target.title)"
    optimisticallyUpdateAgendaItem(id: target.agendaItemID, todo: status.label)
    if let nextSelection {
      preserveAgendaItemSelectionWithoutActivatingEntry(nextSelection)
    } else {
      preserveAgendaSelectionAfterTodoMutation(
        target: target,
        originalVisibleIndex: originalVisibleIndex,
        shouldAdvanceSelection: shouldAdvanceSelection
      )
    }

    enqueueAgendaTodoShortcutMutation(status: status, target: target)
  }

  private func enqueueAgendaTodoShortcutMutation(status: TodoEditStatus, target: HeadlineMutationTarget) {
    pendingAgendaTodoShortcutMutations.append(AgendaTodoShortcutMutation(status: status, target: target))
    guard agendaTodoShortcutMutationTask == nil else { return }

    agendaTodoShortcutMutationTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 80_000_000)
      guard !Task.isCancelled else { return }
      await self?.drainAgendaTodoShortcutMutations()
    }
  }

  private func drainAgendaTodoShortcutMutations() async {
    while !Task.isCancelled {
      guard !pendingAgendaTodoShortcutMutations.isEmpty else {
        agendaTodoShortcutMutationTask = nil
        return
      }

      let batch = Self.orderedAgendaTodoShortcutMutations(pendingAgendaTodoShortcutMutations)
      pendingAgendaTodoShortcutMutations = []

      for mutation in batch {
        guard !Task.isCancelled else { return }
        do {
          let newStatus = try await setTodoStatus(mutation.status, for: mutation.target)
          if newStatus != mutation.status.label {
            optimisticallyUpdateAgendaItem(id: mutation.target.agendaItemID, todo: newStatus)
          }
          await refreshAfterHeadlineMutation(mutation.target, selectMutatedBlock: false)
        } catch {
          errorText = error.localizedDescription
          statusText = "TODO update failed"
          await refreshAgenda(preserveSelection: true, updatesStatus: false)
        }
      }
    }
  }

  nonisolated private static func orderedAgendaTodoShortcutMutations(
    _ mutations: [AgendaTodoShortcutMutation]
  ) -> [AgendaTodoShortcutMutation] {
    mutations.sorted { lhs, rhs in
      if lhs.target.file == rhs.target.file {
        if lhs.target.line == rhs.target.line {
          return (lhs.target.agendaItemID ?? "") < (rhs.target.agendaItemID ?? "")
        }
        return lhs.target.line > rhs.target.line
      }
      return lhs.target.file < rhs.target.file
    }
  }

  public func applyTodoShortcut(_ status: TodoEditStatus?, to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select a TODO heading first"
      return
    }
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItems.firstIndex(where: { $0.id == id })
    }
    var shouldAdvanceSelection = status.map { Self.isTerminalTodoStatus($0.rawValue) } ?? false

    do {
      let newStatus: String
      if let status {
        newStatus = try await setTodoStatus(status, for: target)
        statusText = "\(status.label) -> \(target.title)"
      } else {
        newStatus = try await toggleTodoStatus(for: target)
        statusText = "\(newStatus) -> \(target.title)"
        shouldAdvanceSelection = Self.isTerminalTodoStatus(newStatus)
      }
      optimisticallyUpdateAgendaItem(id: target.agendaItemID, todo: newStatus)
      await refreshAfterHeadlineMutation(target)
      preserveAgendaSelectionAfterTodoMutation(
        target: target,
        originalVisibleIndex: originalVisibleIndex,
        shouldAdvanceSelection: shouldAdvanceSelection
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "TODO update failed"
    }
  }

  private func applyTodoShortcut(_ status: TodoEditStatus?, to items: [AgendaItem]) async {
    do {
      var touchedFiles: Set<String> = []
      for item in agendaMutationOrder(items) {
        if let status {
          try await setTodoStatus(status, for: HeadlineMutationTarget(item: item))
        } else {
          _ = try await toggleTodoStatus(for: HeadlineMutationTarget(item: item))
        }
        touchedFiles.insert(item.file)
      }
      for file in touchedFiles {
        invalidateCanonicalDocumentCache(for: file)
      }
      bulkSelectedAgendaItemIDs = []
      await refreshAgenda(updatesStatus: false)
      if let status {
        statusText = "\(status.label) -> \(items.count) items"
      } else {
        statusText = "TODO updated -> \(items.count) items"
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Bulk TODO update failed"
    }
  }

  @discardableResult
  private func setTodoStatus(_ status: TodoEditStatus, for target: HeadlineMutationTarget) async throws -> String {
    let payload: TodoMutationPayload = try await cli.runJSON([
      "todo", "set",
      "--file", target.file,
      "--line", "\(target.line)",
      "--status", status.rawValue,
      "--format", "json",
      "--apply"
    ])
    return payload.newStatus
  }

  private func toggleTodoStatus(for target: HeadlineMutationTarget) async throws -> String {
    let payload: TodoMutationPayload = try await cli.runJSON([
      "todo", "toggle",
      "--file", target.file,
      "--line", "\(target.line)",
      "--format", "json",
      "--apply"
    ])
    return payload.newStatus
  }

  public func applyPlanningShortcut(kind: PlanningEditKind, target: PlanningDateTarget) async {
    guard let mutationTarget = selectedHeadlineMutationTarget else {
      statusText = "Select a heading first"
      return
    }

    await applyPlanningShortcut(kind: kind, target: target, to: mutationTarget)
  }

  public func applyPlanningShortcut(
    kind: PlanningEditKind,
    target: PlanningDateTarget,
    to location: WorkspaceLocation
  ) async {
    guard let mutationTarget = headlineMutationTarget(for: location) else {
      statusText = "Select a heading first"
      return
    }

    await applyPlanningShortcut(kind: kind, target: target, to: mutationTarget)
  }

  private func applyPlanningShortcut(
    kind: PlanningEditKind,
    target: PlanningDateTarget,
    to mutationTarget: HeadlineMutationTarget
  ) async {
    let date = Self.dateString(for: target)
    do {
      let _: PlanMutationPayload = try await cli.runJSON([
        "plan", "set",
        "--file", mutationTarget.file,
        "--line", "\(mutationTarget.line)",
        "--kind", kind.rawValue,
        "--date", date,
        "--format", "json",
        "--apply"
      ])
      statusText = "\(kind.rawValue.uppercased()) \(date) -> \(mutationTarget.title)"
      await refreshAfterHeadlineMutation(mutationTarget)
    } catch {
      errorText = error.localizedDescription
      statusText = "Planning update failed"
    }
  }

  public func applyAgentHandoffShortcut() async {
    let bulkItems = selectedAgendaItemsForBulkMutation()
    if !bulkItems.isEmpty {
      await applyAgentHandoffShortcut(to: bulkItems)
      return
    }

    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a heading first"
      return
    }

    do {
      try await markReadyForAgent(target, timestamp: Self.orgTimestamp(Date()))
      statusText = "Ready for agent -> \(target.title)"
      await refreshAfterHeadlineMutation(target)
    } catch {
      errorText = error.localizedDescription
      statusText = "Agent handoff failed"
    }
  }

  public func applyAgentHandoffShortcut(to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select a heading first"
      return
    }

    do {
      try await markReadyForAgent(target, timestamp: Self.orgTimestamp(Date()))
      statusText = "Ready for agent -> \(target.title)"
      await refreshAfterHeadlineMutation(target)
    } catch {
      errorText = error.localizedDescription
      statusText = "Agent handoff failed"
    }
  }

  private func applyAgentHandoffShortcut(to items: [AgendaItem]) async {
    do {
      let timestamp = Self.orgTimestamp(Date())
      var touchedFiles: Set<String> = []
      for item in agendaMutationOrder(items) {
        try await markReadyForAgent(HeadlineMutationTarget(item: item), timestamp: timestamp)
        touchedFiles.insert(item.file)
      }
      for file in touchedFiles {
        invalidateCanonicalDocumentCache(for: file)
      }
      bulkSelectedAgendaItemIDs = []
      await refreshAgenda(updatesStatus: false)
      statusText = "Ready for agent -> \(items.count) items"
    } catch {
      errorText = error.localizedDescription
      statusText = "Bulk agent handoff failed"
    }
  }

  private func markReadyForAgent(_ target: HeadlineMutationTarget, timestamp: String) async throws {
    if try nestedParentSendHeading(for: target) != nil {
      try await setTodoStatus(.done, for: target)
      return
    }

    let assignee = resolvedAgentHandoffAssignee()
    try await setTodoAssignee(assignee, for: target)
    try upsertHeadlineProperties(
      file: target.file,
      line: target.line,
      properties: [
        "STATUS": "ready",
        "ASSIGNED_AT": timestamp
      ]
    )
  }

  public func applyApproveAndAgentHandoffShortcut() async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select an approval TODO first"
      return
    }
    do {
      try await approveAndAgentHandoff(target)
    } catch {
      errorText = error.localizedDescription
      statusText = "Approve handoff failed"
    }
  }

  public func applyApproveAndAgentHandoffShortcut(to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select an approval TODO first"
      return
    }
    do {
      try await approveAndAgentHandoff(target)
    } catch {
      errorText = error.localizedDescription
      statusText = "Approve handoff failed"
    }
  }

  public func applyRejectApprovalShortcut(endStatus: TodoEditStatus, reason: String) async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select an approval TODO first"
      return
    }
    do {
      try await rejectApproval(target, endStatus: endStatus, reason: reason)
    } catch {
      errorText = error.localizedDescription
      statusText = "Reject approval failed"
    }
  }

  public func applyRejectApprovalShortcut(endStatus: TodoEditStatus, reason: String, to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select an approval TODO first"
      return
    }
    do {
      try await rejectApproval(target, endStatus: endStatus, reason: reason)
    } catch {
      errorText = error.localizedDescription
      statusText = "Reject approval failed"
    }
  }

  public func promptAndApplyRejectApprovalShortcut() {
    guard selectedHeadlineMutationTarget != nil else {
      statusText = "Select an approval TODO first"
      return
    }
    guard let rejection = Self.promptForApprovalRejection() else { return }
    Task { await applyRejectApprovalShortcut(endStatus: rejection.endStatus, reason: rejection.reason) }
  }

  public func promptAndApplyRejectApprovalShortcut(to location: WorkspaceLocation) {
    guard headlineMutationTarget(for: location) != nil else {
      statusText = "Select an approval TODO first"
      return
    }
    guard let rejection = Self.promptForApprovalRejection() else { return }
    Task { await applyRejectApprovalShortcut(endStatus: rejection.endStatus, reason: rejection.reason, to: location) }
  }

  private func approveAndAgentHandoff(_ target: HeadlineMutationTarget) async throws {
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItems.firstIndex(where: { $0.id == id })
    }
    let timestamp = Self.orgTimestamp(Date())

    let approvalIdentity = try approvalMutationIdentity(for: target)
    let mutationTarget = try refreshedApprovalMutationTarget(
      original: target,
      identity: approvalIdentity
    )
    try await setTodoStatus(.done, for: mutationTarget)
    let result = try await activateApprovedAgentAction(for: mutationTarget, timestamp: timestamp)
    let propertyTarget = try refreshedApprovalMutationTarget(
      original: mutationTarget,
      identity: approvalIdentity
    )
    var approvalProperties = try currentApprovalProperties(for: propertyTarget)
    approvalProperties.merge(Self.approvedApprovalProperties(
      existingProperties: approvalProperties,
      timestamp: timestamp,
      pairedTitle: result.title
    )) { _, new in new }
    try upsertHeadlineProperties(
      file: propertyTarget.file,
      line: propertyTarget.line,
      properties: approvalProperties
    )
    invalidateCanonicalDocumentCache(for: result.file)
    await refreshAfterHeadlineMutation(target)
    preserveAgendaSelectionAfterTodoMutation(
      target: target,
      originalVisibleIndex: originalVisibleIndex,
      shouldAdvanceSelection: true
    )
    statusText = result.created
      ? "Approved and created agent action -> \(result.title)"
      : "Approved and activated agent action -> \(result.title)"
  }

  private func currentApprovalProperties(for target: HeadlineMutationTarget) throws -> [String: String] {
    let url = URL(fileURLWithPath: target.file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let lines = Self.normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let targetIndex = max(0, min(lines.count - 1, target.line - 1))
    guard let headingIndex = Self.headingIndex(in: lines, atOrBefore: targetIndex) else {
      return [:]
    }
    return Self.scanPropertyDrawer(lines: lines, afterHeadingIndex: headingIndex)
  }

  nonisolated private static func approvedApprovalProperties(
    existingProperties: [String: String],
    timestamp: String,
    pairedTitle: String
  ) -> [String: String] {
    var properties: [String: String] = [
      "STATUS": "approved",
      "APPROVED_AT": timestamp,
      "PAIRED_SEND_TODO": pairedTitle
    ]

    for key in [
      "ORG2_REVIEW_STATUS",
      "REVIEW_STATUS",
      "REVIEW",
      "FOLLOWUP_STATUS",
      "REPLY_STATUS",
      "ACCESS_POLICY",
      "REVIEW_POLICY"
    ] where existingProperties[key] != nil {
      properties[key] = "approved"
    }

    for key in [
      "WAITING_ON",
      "BLOCKED_BY",
      "ORG2_WAITING_ON",
      "NEXT_ACTION",
      "ACTION_REQUIRED",
      "ORG2_NEXT_ACTION",
      "HANDOFF_SUMMARY",
      "ORG2_HANDOFF_SUMMARY"
    ] {
      guard let value = existingProperties[key]?.lowercased() else { continue }
      if value.contains("approval") || value.contains("approve") || value.contains("review") || value.contains("avi") {
        properties[key] = "approved"
      }
    }

    return properties
  }

  private func approvalMutationIdentity(for target: HeadlineMutationTarget) throws -> ApprovalMutationIdentity {
    if let idValue = target.idValue {
      return ApprovalMutationIdentity(title: target.title, idValue: idValue)
    }

    let url = URL(fileURLWithPath: target.file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let lines = Self.normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let targetIndex = max(0, min(lines.count - 1, target.line - 1))
    guard let headingIndex = Self.headingIndex(in: lines, atOrBefore: targetIndex) else {
      return ApprovalMutationIdentity(title: target.title, idValue: nil)
    }
    let properties = Self.scanPropertyDrawer(lines: lines, afterHeadingIndex: headingIndex)
    return ApprovalMutationIdentity(
      title: target.title,
      idValue: properties["ID"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    )
  }

  private func refreshedApprovalMutationTarget(
    original target: HeadlineMutationTarget,
    identity: ApprovalMutationIdentity
  ) throws -> HeadlineMutationTarget {
    let url = URL(fileURLWithPath: target.file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let lines = Self.normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    if let idValue = identity.idValue {
      for index in lines.indices where Self.parseTodoHeading(lines[index]) != nil {
        let properties = Self.scanPropertyDrawer(lines: lines, afterHeadingIndex: index)
        if properties["ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) == idValue {
          return HeadlineMutationTarget(file: target.file, line: index + 1, title: identity.title, agendaItemID: target.agendaItemID)
        }
      }
    }

    let normalizedTitle = Self.normalizedApprovalActionTitle(identity.title)
    if !normalizedTitle.isEmpty {
      for index in lines.indices {
        guard let heading = Self.parseTodoHeading(lines[index]) else { continue }
        if Self.normalizedApprovalActionTitle(heading.title) == normalizedTitle {
          return HeadlineMutationTarget(file: target.file, line: index + 1, title: heading.title, agendaItemID: target.agendaItemID)
        }
      }
    }

    return target
  }

  private func rejectApproval(_ target: HeadlineMutationTarget, endStatus: TodoEditStatus, reason: String) async throws {
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItems.firstIndex(where: { $0.id == id })
    }
    let timestamp = Self.orgTimestamp(Date())

    let approvalIdentity = try approvalMutationIdentity(for: target)
    let mutationTarget = try refreshedApprovalMutationTarget(
      original: target,
      identity: approvalIdentity
    )
    try await setTodoStatus(endStatus, for: mutationTarget)
    let propertyTarget = try refreshedApprovalMutationTarget(
      original: mutationTarget,
      identity: approvalIdentity
    )
    let currentProperties = try currentApprovalProperties(for: propertyTarget)
    try upsertHeadlineProperties(
      file: propertyTarget.file,
      line: propertyTarget.line,
      properties: [
        "STATUS": "rejected",
        "REJECTED_AT": timestamp,
        "REJECTION_END_STATUS": endStatus.label,
        "REJECTION_REASON": Self.sanitizeOrgPropertyValue(reason)
      ]
    )
    let pairedRejected = try await rejectPairedApprovedAgentAction(
      for: propertyTarget,
      approvalProperties: currentProperties,
      endStatus: endStatus,
      reason: reason,
      timestamp: timestamp
    )
    await refreshAfterHeadlineMutation(target)
    preserveAgendaSelectionAfterTodoMutation(
      target: target,
      originalVisibleIndex: originalVisibleIndex,
      shouldAdvanceSelection: true
    )
    statusText = pairedRejected
      ? "Rejected approval and paired send -> \(target.title)"
      : "Rejected -> \(target.title)"
  }

  private func rejectPairedApprovedAgentAction(
    for target: HeadlineMutationTarget,
    approvalProperties: [String: String],
    endStatus: TodoEditStatus,
    reason: String,
    timestamp: String
  ) async throws -> Bool {
    let url = URL(fileURLWithPath: target.file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let lines = Self.normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let targetIndex = max(0, min(lines.count - 1, target.line - 1))
    guard let approvalHeadingIndex = Self.headingIndex(in: lines, atOrBefore: targetIndex),
          let paired = Self.pairedApprovedAgentActionTarget(
            lines: lines,
            file: target.file,
            approvalHeadingIndex: approvalHeadingIndex,
            approvalProperties: approvalProperties,
            approvalTitle: target.title
          )
    else {
      return false
    }

    let pairedIndex = paired.line - 1
    guard lines.indices.contains(pairedIndex),
          let heading = Self.parseTodoHeading(lines[pairedIndex]),
          !Self.isTerminalTodoStatus(heading.todo)
    else {
      return false
    }

    let pairedProperties = Self.scanPropertyDrawer(lines: lines, afterHeadingIndex: pairedIndex)
    guard !Self.hasSentEvidence(in: pairedProperties) else { return false }

    try await setTodoStatus(endStatus, for: paired)
    try upsertHeadlineProperties(
      file: paired.file,
      line: paired.line,
      properties: [
        "STATUS": "rejected",
        "REJECTED_AT": timestamp,
        "REJECTION_END_STATUS": endStatus.label,
        "REJECTION_REASON": Self.sanitizeOrgPropertyValue(reason),
        "REJECTED_APPROVAL_TODO": target.title
      ]
    )
    return true
  }

  private func activateApprovedAgentAction(
    for target: HeadlineMutationTarget,
    timestamp: String
  ) async throws -> ApprovedAgentActionResult {
    let url = URL(fileURLWithPath: target.file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let lines = Self.normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let targetIndex = max(0, min(lines.count - 1, target.line - 1))
    guard let headingIndex = Self.headingIndex(in: lines, atOrBefore: targetIndex),
          let headingLevel = Self.headingLevel(lines[headingIndex])
    else {
      throw WorkspaceEditError.noHeadline(file: target.file, line: target.line)
    }

    let properties = Self.scanPropertyDrawer(lines: lines, afterHeadingIndex: headingIndex)
    var candidateTitles = Self.pairedApprovalActionTitleCandidates(properties: properties)
    let generatedTitle = Self.approvedAgentActionTitle(for: target.title)
    candidateTitles.append(generatedTitle)

    if let existing = Self.findExistingApprovedAgentAction(
      lines: lines,
      file: target.file,
      excludingHeadingIndex: headingIndex,
      candidateTitles: candidateTitles
    ) {
      try await setTodoStatus(.todo, for: existing)
      try await setTodoAssignee(resolvedAgentHandoffAssignee(), for: existing)
      try upsertHeadlineProperties(
        file: existing.file,
        line: existing.line,
        properties: [
          "STATUS": Self.approvedAgentActionStatus(for: existing.title),
          "APPROVED_AT": timestamp,
          "APPROVAL_TODO": target.title
        ]
      )
      return ApprovedAgentActionResult(
        title: existing.title,
        file: existing.file,
        line: existing.line,
        created: false
      )
    }

    let insertIndex = Self.subtreeEndIndex(lines: lines, headingIndex: headingIndex, level: headingLevel)
    let insertLine = insertIndex + 1
    var insertionLines: [String] = []
    if insertIndex > 0,
       !lines[insertIndex - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      insertionLines.append("")
    }
    let headingLineOffset = insertionLines.count
    let stars = String(repeating: "*", count: headingLevel)
    insertionLines += [
      "\(stars) TODO \(generatedTitle)",
      "SCHEDULED: \(Self.orgDateTimestamp(Date()))",
      ":PROPERTIES:",
      ":APPROVAL_TODO: \(target.title)",
      ":APPROVED_AT: \(timestamp)",
      ":ASSIGNEE: \(resolvedAgentHandoffAssignee())",
      ":STATUS: \(Self.approvedAgentActionStatus(for: generatedTitle))",
      ":END:",
      ""
    ]

    try Self.replaceSourceRange(
      file: target.file,
      startLine: insertLine,
      endLineExclusive: insertLine,
      replacement: insertionLines.joined(separator: "\n")
    )

    return ApprovedAgentActionResult(
      title: generatedTitle,
      file: target.file,
      line: insertLine + headingLineOffset,
      created: true
    )
  }

  private func resolvedAgentHandoffAssignee() -> String {
    let assignee = agentHandoffAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
    return assignee.isEmpty ? Self.defaultAgentHandoffAssignee : assignee
  }

  private func setTodoAssignee(_ assignee: String, for target: HeadlineMutationTarget) async throws {
    let _: TodoAssignmentPayload = try await cli.runJSON([
      "todo", "assign",
      "--file", target.file,
      "--line", "\(target.line)",
      "--assignee", assignee,
      "--format", "json",
      "--apply"
    ])
  }

  public func applyPriorityShortcut(_ priority: String?) async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a heading first"
      return
    }

    await applyPriorityShortcut(priority, to: target)
  }

  public func applyPriorityShortcut(_ priority: String?, to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select a heading first"
      return
    }

    await applyPriorityShortcut(priority, to: target)
  }

  private func applyPriorityShortcut(_ priority: String?, to target: HeadlineMutationTarget) async {
    do {
      try updateHeadlinePriority(file: target.file, line: target.line, priority: priority)
      statusText = priority.map { "Priority [#\($0)] -> \(target.title)" }
        ?? "Priority cleared -> \(target.title)"
      await refreshAfterHeadlineMutation(target)
    } catch {
      errorText = error.localizedDescription
      statusText = "Priority update failed"
    }
  }

  public func promptAndApplyPropertyShortcut() {
    guard selectedHeadlineMutationTarget != nil else {
      statusText = "Select a heading first"
      return
    }

    let alert = NSAlert()
    alert.messageText = "Set Property"
    alert.informativeText = "Use KEY=VALUE on the selected headline."
    alert.addButton(withTitle: "Set")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "ASSIGNEE=openclaw"
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

    presentCapturePanel(
      draft: WorkspaceCaptureDraft(kind: .task, includeScheduled: true, scheduledDate: Date())
    )
  }

  public func presentCapturePanel(draft: WorkspaceCaptureDraft = WorkspaceCaptureDraft()) {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    captureDraft = draft
    isCapturePanelPresented = true
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  public func importPasteboardIntoCaptureDraft() {
    captureDraft = captureDraftByImportingPasteboard(into: captureDraft)
  }

  public func captureDraftByImportingPasteboard(into draft: WorkspaceCaptureDraft) -> WorkspaceCaptureDraft {
    var updated = draft
    let content = Self.capturePasteboardContent(from: .general)
    Self.applyCapturePasteboardContent(content, to: &updated)
    return updated
  }

  private static func applyCapturePasteboardContent(
    _ content: WorkspaceCapturePasteboardContent,
    to draft: inout WorkspaceCaptureDraft
  ) {
    if !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
      draft.body = body.isEmpty
        ? content.text
        : "\(draft.body.trimmingCharacters(in: .newlines))\n\n\(content.text)"
    }
    draft.attachments.append(contentsOf: content.attachments)
    if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let title = Self.captureTitleCandidate(from: content.text) {
      draft.title = title
    }
  }

  public func captureTodo(title: String) async {
    await submitCaptureDraft(WorkspaceCaptureDraft(title: title))
  }

  public func submitCaptureDraft() async {
    await submitCaptureDraft(captureDraft)
  }

  public func submitCaptureDraft(_ draft: WorkspaceCaptureDraft) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    do {
      let target = todayDailyNotePath(corpusRoot: corpusRoot)
      try appendCapture(draft: draft, to: target, corpusRoot: corpusRoot)
      statusText = "Captured \(draft.kind.title.lowercased()) -> \(target.lastPathComponent)"
      isCapturePanelPresented = false
      invalidateCanonicalDocumentCache(for: target.path)
      await refreshAgenda()
      await refreshCorpusFiles()
    } catch {
      errorText = error.localizedDescription
      statusText = "Capture failed"
    }
  }

  public func captureReviewTodoForSelectedMeeting() async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    let selectedMeeting = selectedMeetingID.flatMap { id in
      meetings.first { $0.id == id }
    } ?? {
      if case .meeting(let meeting) = selectedLocation {
        return meeting
      }
      return nil
    }()
    guard let meeting = selectedMeeting ?? meetings.first else {
      selectedSurface = .meetings
      statusText = "Select or record a meeting first"
      return
    }

    do {
      let target = todayDailyNotePath(corpusRoot: corpusRoot)
      try appendCapture(
        draft: WorkspaceCaptureDraft(title: "Review meeting: \(Org2Display.cleanInline(meeting.title))"),
        to: target,
        corpusRoot: corpusRoot
      )
      statusText = "Captured meeting review TODO -> \(target.lastPathComponent)"
      invalidateCanonicalDocumentCache(for: target.path)
      selectedSurface = .agenda
      await refreshAgenda()
    } catch {
      errorText = error.localizedDescription
      statusText = "Meeting review capture failed"
    }
  }

  public func applyPropertyShortcut(key: String, value: String) async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a heading first"
      return
    }

    do {
      try upsertHeadlineProperties(file: target.file, line: target.line, properties: [key: value])
      statusText = "\(key)=\(value) -> \(target.title)"
      await refreshAfterHeadlineMutation(target)
    } catch {
      errorText = error.localizedDescription
      statusText = "Property update failed"
    }
  }

  public func handleWorkspaceKeyDown(
    _ event: NSEvent,
    scope: WorkspaceKeyboardShortcutScope = .all
  ) -> Bool {
    if handleGlobalKeyDown(event, scope: scope) {
      return true
    }
    guard scope == .all else {
      return false
    }
    if selectedSurface == .agenda {
      return handleAgendaKeyDown(event)
    }
    if handleDocumentKeyDown(event) {
      return true
    }
    return handleAgendaKeyDown(event)
  }

  public func makeSurfacePrimary(_ surface: WorkspaceSurface) {
    if surface == .home {
      openHome()
      return
    }
    selectedSurface = surface
    expandedWorkspaceSurface = nil
    isWorkspaceSurfacePaneClosed = false
    isWorkspaceDetailPaneExpanded = false
    isOpenClawAssistantPresented = false
    if surface == .openClaw {
      markSelectedOpenClawChatThreadRead()
    }
    statusText = "\(surface.title) is primary"
  }

  public func makeSelectedSurfacePrimary() {
    makeSurfacePrimary(selectedSurface)
  }

  public func expandSurface(_ surface: WorkspaceSurface) {
    if surface == .home {
      openHome()
      return
    }
    selectedSurface = surface
    expandedWorkspaceSurface = nil
    isWorkspaceSurfacePaneClosed = false
    isWorkspaceDetailPaneClosed = true
    isWorkspaceDetailPaneExpanded = false
    isOpenClawAssistantPresented = false
    statusText = "\(surface.title) expanded"
  }

  public func toggleExpandedSurface(_ surface: WorkspaceSurface) {
    if selectedSurface == surface && isWorkspaceDetailPaneClosed && hasWorkspaceDetailContent {
      isWorkspaceSurfacePaneClosed = false
      statusText = "\(surface.title) restored"
    } else {
      expandSurface(surface)
    }
  }

  public func toggleSelectedSurfaceExpansion() {
    toggleExpandedSurface(selectedSurface)
  }

  public func closeSurfacePane(_ surface: WorkspaceSurface) {
    expandedWorkspaceSurface = nil
    isWorkspaceDetailPaneExpanded = false
    if selectedSurface == surface, hasWorkspaceDetailContent {
      isWorkspaceSurfacePaneClosed = true
      isWorkspaceDetailPaneClosed = false
    }
    isOpenClawAssistantPresented = false
    statusText = "\(surface.title) closed"
  }

  public func closeSelectedSurfacePane() {
    closeSurfacePane(selectedSurface)
  }

  public func makeDetailPanePrimary() {
    guard selectedLocation != nil || selectedEntrySource != nil else {
      statusText = "Open a file first"
      return
    }
    expandedWorkspaceSurface = nil
    isWorkspaceSurfacePaneClosed = true
    isWorkspaceDetailPaneClosed = false
    isWorkspaceDetailPaneExpanded = false
    isOpenClawAssistantPresented = false
    statusText = "Document is primary"
  }

  public func toggleDetailPaneExpansion() {
    guard selectedLocation != nil || selectedEntrySource != nil else {
      statusText = "Open a file first"
      return
    }
    expandedWorkspaceSurface = nil
    isWorkspaceDetailPaneExpanded = false
    isWorkspaceDetailPaneClosed = false
    isOpenClawAssistantPresented = false
    if isWorkspaceSurfacePaneClosed {
      isWorkspaceSurfacePaneClosed = false
      statusText = "Document restored"
    } else {
      isWorkspaceSurfacePaneClosed = true
      statusText = "Document expanded"
    }
  }

  public func closeDetailPane() {
    isWorkspaceDetailPaneClosed = true
    isWorkspaceDetailPaneExpanded = false
    isWorkspaceSurfacePaneClosed = false
    expandedWorkspaceSurface = nil
    statusText = "Document closed"
  }

  public func toggleOpenClawAssistantPanel() {
    makeSurfacePrimary(.openClaw)
  }

  public func setOpenClawAssistantPanelPresented(_ presented: Bool) {
    isOpenClawAssistantPresented = false
    if presented {
      makeSurfacePrimary(.openClaw)
    }
  }

  public func handleGlobalKeyDown(
    _ event: NSEvent,
    scope: WorkspaceKeyboardShortcutScope = .all
  ) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard modifiers == [.command] || modifiers == [.command, .shift] || modifiers == [.command, .option] else {
      return false
    }

    let key = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()
    if modifiers == [.command] {
      switch key {
      case "0":
        makeSurfacePrimary(.openClaw)
      case "1":
        openHome()
      case "2":
        makeSurfacePrimary(.agenda)
      case "3":
        makeSurfacePrimary(.files)
      case "4":
        makeSurfacePrimary(.approvals)
      case "5":
        makeSurfacePrimary(.meetings)
      case "6":
        makeSurfacePrimary(.openClaw)
      case "m":
        makeSurfacePrimary(.meetings)
      case "7":
        openDailyNote(.today)
      case "8":
        openDailyNote(.yesterday)
      case "9":
        openDailyNote(.tomorrow)
      case "f":
        guard focusCurrentSearchField() else { return false }
      case "k", "p":
        presentQuickOpen()
      case "r":
        guard corpusRoot != nil else { return false }
        Task { await refreshWorkspace() }
      case "s":
        guard scope == .all else {
          return OrgSyntaxTextView.saveFocusedTextViewIfPossible(for: event)
        }
        guard canSaveCurrentFile else { return false }
        Task { await saveActiveEdit() }
      case "/":
        isKeyboardShortcutsPresented = true
      case "z":
        guard scope == .all else { return false }
        performUndoCommand()
      default:
        return false
      }
      return true
    }

    if modifiers == [.command, .option] {
      return false
    }

    if modifiers == [.command, .shift] {
      switch key {
      case "f":
        focusSearchSurface()
        return true
      case "m":
        guard corpusRoot != nil else { return false }
        if isRecordingMeeting {
          Task { await stopMeetingRecording() }
        } else {
          promptAndStartMeetingRecording()
        }
        return true
      case "o":
        chooseCorpus()
        return true
      case "z":
        guard scope == .all else { return false }
        performRedoCommand()
        return true
      default:
        break
      }
      if key == "/" || event.characters == "?" {
        isKeyboardShortcutsPresented = true
        return true
      }
    }

    return false
  }

  public func performUndoCommand() {
    guard let action = workspaceUndoStack.popLast() else {
      statusText = "Nothing to undo"
      return
    }
    if applyImmediateWorkspaceUndo(action) {
      return
    }
    Task { @MainActor [weak self] in
      await self?.applyWorkspaceUndo(action)
    }
  }

  public func performRedoCommand() {
    guard let action = workspaceRedoStack.popLast() else {
      statusText = "Nothing to redo"
      return
    }
    if applyImmediateWorkspaceRedo(action) {
      return
    }
    Task { @MainActor [weak self] in
      await self?.applyWorkspaceRedo(action)
    }
  }

  private func recordWorkspaceUndo(_ action: WorkspaceUndoAction) {
    guard workspaceUndoStack.last != action else { return }
    workspaceUndoStack.append(action)
    if workspaceUndoStack.count > Self.workspaceUndoStackLimit {
      workspaceUndoStack.removeFirst(workspaceUndoStack.count - Self.workspaceUndoStackLimit)
    }
    workspaceRedoStack.removeAll()
  }

  private func fileUndoSnapshot(for file: String) -> PendingFileUndoSnapshot? {
    let standardized = URL(fileURLWithPath: file).standardizedFileURL.path
    guard let previous = try? Self.fileText(file: standardized),
          previous.utf8.count <= Self.workspaceUndoSnapshotMaxBytes
    else {
      return nil
    }
    return PendingFileUndoSnapshot(file: standardized, previous: previous)
  }

  private func recordFileUndo(from snapshot: PendingFileUndoSnapshot?) {
    guard let snapshot,
          let next = try? Self.fileText(file: snapshot.file),
          next.utf8.count <= Self.workspaceUndoSnapshotMaxBytes
    else {
      return
    }
    recordFileUndo(file: snapshot.file, previous: snapshot.previous, next: next)
  }

  private func recordFileUndo(file: String, previous: String, next: String) {
    guard Self.normalizeLineEndings(previous) != Self.normalizeLineEndings(next) else {
      return
    }
    recordWorkspaceUndo(.fileSnapshot(file: URL(fileURLWithPath: file).standardizedFileURL.path, previous: previous, next: next))
  }

  private func applyImmediateWorkspaceUndo(_ action: WorkspaceUndoAction) -> Bool {
    switch action {
    case .openClawDraft(let previous, _):
      publishOpenClawComposerDraft(previous)
      openClawStatusText = "Undid OpenClaw draft change"
      statusText = "Undid OpenClaw draft change"
      workspaceRedoStack.append(action)
      return true
    case .fileSnapshot:
      return false
    }
  }

  private func applyImmediateWorkspaceRedo(_ action: WorkspaceUndoAction) -> Bool {
    switch action {
    case .openClawDraft(_, let next):
      publishOpenClawComposerDraft(next)
      openClawStatusText = "Redid OpenClaw draft change"
      statusText = "Redid OpenClaw draft change"
      workspaceUndoStack.append(action)
      return true
    case .fileSnapshot:
      return false
    }
  }

  private func applyWorkspaceUndo(_ action: WorkspaceUndoAction) async {
    switch action {
    case .openClawDraft:
      _ = applyImmediateWorkspaceUndo(action)
    case .fileSnapshot(let file, let previous, let next):
      do {
        try await restoreFileSnapshot(
          file: file,
          text: previous,
          expectedCurrent: next,
          direction: "Undid"
        )
        workspaceRedoStack.append(action)
      } catch {
        workspaceUndoStack.append(action)
        errorText = error.localizedDescription
        statusText = "Undo failed"
      }
    }
  }

  private func applyWorkspaceRedo(_ action: WorkspaceUndoAction) async {
    switch action {
    case .openClawDraft:
      _ = applyImmediateWorkspaceRedo(action)
    case .fileSnapshot(let file, let previous, let next):
      do {
        try await restoreFileSnapshot(
          file: file,
          text: next,
          expectedCurrent: previous,
          direction: "Redid"
        )
        workspaceUndoStack.append(action)
      } catch {
        workspaceRedoStack.append(action)
        errorText = error.localizedDescription
        statusText = "Redo failed"
      }
    }
  }

  private func restoreFileSnapshot(
    file: String,
    text: String,
    expectedCurrent: String,
    direction: String
  ) async throws {
    let standardized = URL(fileURLWithPath: file).standardizedFileURL.path
    let selectedFile = selectedEntrySource?.file ?? selectedLocation?.file
    let affectsSelectedFile = selectedFile.map {
      URL(fileURLWithPath: $0).standardizedFileURL.path == standardized
    } ?? false

    if affectsSelectedFile {
      cancelLiveFileEditorAutosave(resetStatus: false)
    }

    try await Task.detached(priority: .userInitiated) {
      let current = try Self.fileText(file: standardized)
      guard Self.normalizeLineEndings(current) == Self.normalizeLineEndings(expectedCurrent) else {
        throw WorkspaceEditError.fileChanged(file: standardized)
      }
      try Self.writeFileText(text, to: standardized, allowDestructiveReplacement: true)
    }.value

    if affectsSelectedFile {
      isEditingEntry = false
      resetBlockState()
      if isLiveFileEditorSelected, selectedEntrySourceMode == .page {
        editableEntryText = text
        if let selectedEntrySource {
          self.selectedEntrySource = Self.entrySource(selectedEntrySource, replacingText: text)
        }
      }
    }

    invalidateCanonicalDocumentCache(for: standardized)
    if let corpusRoot {
      upsertCorpusFile(corpusFile(for: URL(fileURLWithPath: standardized), corpusRoot: corpusRoot))
    }

    if let selectedLocation,
       URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path == standardized {
      await loadEntrySource(for: selectedLocation)
    }

    let message = "\(direction) edit in \(relativePath(standardized))"
    statusText = message
    if affectsSelectedFile && isLiveFileEditorSelected {
      liveFileEditorStatusText = direction
    }
    scheduleAgendaRefresh(preserveSelection: true)
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

    let key = event.characters ?? event.charactersIgnoringModifiers ?? ""
    let keyIgnoringModifiers = event.charactersIgnoringModifiers ?? key
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

    if isAgendaFilterFocused {
      if event.keyCode == 53, modifiers.isEmpty {
        clearAgendaFilter()
        isAgendaFilterFocused = false
        return true
      }
      return false
    }

    if modifiers == [.command], keyIgnoringModifiers.lowercased() == "a" {
      selectAllVisibleAgendaItemsForBulkAction()
      return true
    }
    if modifiers == [.command, .shift], keyIgnoringModifiers.lowercased() == "a" {
      clearAgendaBulkSelection()
      return true
    }
    if modifiers == [.shift] {
      if event.keyCode == 125 {
        extendAgendaBulkSelection(by: 1)
        return true
      }
      if event.keyCode == 126 {
        extendAgendaBulkSelection(by: -1)
        return true
      }
    }

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
    case "1", "2", "3", "4":
      setAgendaModeFromKey(key)
    case "/":
      focusAgendaFilter()
    case "r":
      if agendaMode == .assigned {
        Task { await refreshAssignedWork() }
      } else {
        Task { await refreshAgenda() }
      }
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
      applyAgendaTodoShortcut(.todo)
    case "i":
      applyAgendaTodoShortcut(.inProgress)
    case "d":
      applyAgendaTodoShortcut(.done)
    case "x":
      applyAgendaTodoShortcut(.canceled)
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

  public var backlinkFileGroups: [BacklinkFileGroup] {
    guard let backlinks else { return [] }
    let grouped = Dictionary(grouping: backlinks.backlinks, by: \.file)
    return grouped.map { file, items in
      let sortedItems = items.sorted {
        if $0.line != $1.line { return $0.line < $1.line }
        return $0.srcTitle.localizedCaseInsensitiveCompare($1.srcTitle) == .orderedAscending
      }
      return BacklinkFileGroup(
        file: file,
        relativePath: relativePath(file),
        backlinks: sortedItems
      )
    }
    .sorted { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
  }

  public var backlinkFileCount: Int {
    backlinkFileGroups.count
  }

  public var backlinkReferenceCount: Int {
    backlinks?.backlinks.count ?? 0
  }

  public var currentNodeBriefArtifact: NodeBriefArtifact? {
    guard let location = selectedLocation,
          let corpusRoot else { return nil }
    let existingID = location.idValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    let relativePath = Self.nodeBriefArtifactRelativePath(
      title: location.title,
      id: existingID?.isEmpty == false ? existingID : nil,
      file: relativePath(location.file),
      line: location.lineForEditor
    )
    let url = corpusRoot.appendingPathComponent(relativePath).standardizedFileURL
    return Self.nodeBriefArtifact(at: url, relativePath: relativePath)
  }

  public func openCurrentNodeBriefArtifact() {
    guard let location = selectedLocation,
          let artifact = currentNodeBriefArtifact else {
      statusText = "No cached node brief yet"
      return
    }
    openNodeBriefArtifact(
      url: URL(fileURLWithPath: artifact.file).standardizedFileURL,
      relativePath: artifact.relativePath,
      title: location.title
    )
  }

  public var relatedBacklinkNodes: [RelatedBacklinkNode] {
    Self.relatedBacklinkNodes(
      from: backlinks?.backlinks ?? [],
      relativePathForFile: { [weak self] file in
        self?.relativePath(file) ?? file
      }
    )
  }

  nonisolated public static func relatedBacklinkNodes(
    from backlinks: [BacklinkItem],
    relativePathForFile: (String) -> String
  ) -> [RelatedBacklinkNode] {
    let grouped = Dictionary(grouping: backlinks.compactMap { backlink -> BacklinkItem? in
      guard backlink.srcId?.isEmpty == false else { return nil }
      let title = Org2Display.cleanInline(backlink.srcTitle).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !isGenericRelatedBacklinkTitle(title) else { return nil }
      return backlink
    }) { backlink in
      backlink.srcId ?? backlink.srcTitle
    }

    return grouped.compactMap { key, items in
      guard let first = items.first else { return nil }
      let sortedItems = items.sorted {
        if $0.file != $1.file {
          return $0.file.localizedCaseInsensitiveCompare($1.file) == .orderedAscending
        }
        return $0.lineForEditor < $1.lineForEditor
      }
      let cleanTitle = Org2Display.cleanInline(first.srcTitle).trimmingCharacters(in: .whitespacesAndNewlines)
      let files = Set(items.map(\.file))
      let examples = sortedItems
        .map { Org2Display.cleanInline($0.context).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { unique, context in
          guard unique.count < 2, !unique.contains(context) else { return }
          unique.append(context)
        }
      return RelatedBacklinkNode(
        id: key,
        idValue: first.srcId,
        title: cleanTitle,
        referenceCount: items.count,
        fileCount: files.count,
        primaryPath: "\(relativePathForFile(sortedItems[0].file)):\(sortedItems[0].lineForEditor)",
        examples: examples
      )
    }
    .sorted { lhs, rhs in
      let lhsScore = lhs.referenceCount + lhs.fileCount
      let rhsScore = rhs.referenceCount + rhs.fileCount
      if lhsScore != rhsScore { return lhsScore > rhsScore }
      if lhs.referenceCount != rhs.referenceCount { return lhs.referenceCount > rhs.referenceCount }
      return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
  }

  nonisolated public static func isGenericRelatedBacklinkTitle(_ title: String) -> Bool {
    let normalized = title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
      .split(separator: " ")
      .joined(separator: " ")
    guard !normalized.isEmpty else { return true }
    return Self.genericRelatedBacklinkTitles.contains(normalized)
  }

  private nonisolated static let genericRelatedBacklinkTitles: Set<String> = [
    "abstract",
    "action items",
    "agenda",
    "background",
    "context",
    "decision",
    "decisions",
    "detail",
    "details",
    "discussion",
    "follow up",
    "follow ups",
    "highlights",
    "notes",
    "overview",
    "raw transcript",
    "recap",
    "recurring themes",
    "related",
    "summary",
    "takeaways",
    "theme",
    "themes",
    "transcript"
  ]

  public func toggleNodeContextPane() {
    isNodeContextPanePresented.toggle()
  }

  public func toggleBacklinkFileGroup(_ group: BacklinkFileGroup) {
    if expandedBacklinkFileIDs.contains(group.id) {
      expandedBacklinkFileIDs.remove(group.id)
    } else {
      expandedBacklinkFileIDs.insert(group.id)
    }
  }

  public func selectBacklink(_ backlink: BacklinkItem) {
    select(.backlink(backlink))
  }

  private func openNodeBriefArtifact(url: URL, relativePath: String, title: String) {
    let modifiedAt = Self.modificationDate(for: url)
    let thread = OpenClawThread(
      title: "Brief: \(title)",
      file: url.path,
      line: 1,
      zone: "views/openclaw",
      modifiedAt: modifiedAt,
      idValue: nil
    )
    selectedSurface = .files
    activateDetailLocation(.openClaw(thread), mode: .page, recordsHistory: true)
    selectedOpenClawThreadID = thread.id
    pendingNodeBriefArtifactRelativePath = nil
    pendingNodeBriefTitle = nil
    openClawStatusText = "Opened cached node brief"
    statusText = "Opened \(relativePath)"
  }

  nonisolated static func nodeBriefArtifactRelativePath(title: String, id: String?, file: String, line: Int) -> String {
    let titleSlug = slug(title)
    let tokenRaw: String
    if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
      tokenRaw = id
    } else {
      tokenRaw = "\(file)-line-\(max(1, line))"
    }
    return "views/openclaw/node-briefs/\(titleSlug)-\(slug(tokenRaw)).org2"
  }

  nonisolated private static func hasUsableNodeBriefArtifact(at url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true,
          (values.fileSize ?? 0) > 0,
          let raw = try? String(contentsOf: url, encoding: .utf8)
    else {
      return false
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return !trimmed.contains("ORG2_NODE_BRIEF_STATUS: pending")
  }

  nonisolated static func nodeBriefArtifact(at url: URL, relativePath: String) -> NodeBriefArtifact? {
    guard hasUsableNodeBriefArtifact(at: url),
          let raw = try? String(contentsOf: url, encoding: .utf8)
    else {
      return nil
    }
    return NodeBriefArtifact(
      relativePath: relativePath,
      file: url.standardizedFileURL.path,
      title: nodeBriefArtifactTitle(raw),
      body: nodeBriefArtifactBody(raw),
      modifiedAt: modificationDate(for: url)
    )
  }

  nonisolated static func nodeBriefArtifactTitle(_ raw: String) -> String {
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      guard text.uppercased().hasPrefix("#+TITLE:") else { continue }
      return text
        .dropFirst("#+TITLE:".count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "Node brief"
  }

  nonisolated static func nodeBriefArtifactBody(_ raw: String) -> String {
    let lines = raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var index = 0
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.uppercased().hasPrefix("#+TITLE:") {
        index += 1
        continue
      }
      if trimmed == ":PROPERTIES:" {
        index += 1
        while index < lines.count,
              lines[index].trimmingCharacters(in: .whitespacesAndNewlines) != ":END:" {
          index += 1
        }
        if index < lines.count { index += 1 }
        continue
      }
      if trimmed.isEmpty {
        index += 1
        continue
      }
      break
    }
    guard index < lines.count else { return "" }
    let body = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard body.count > 20_000 else { return body }
    let end = body.index(body.startIndex, offsetBy: 20_000)
    return String(body[..<end]) + "\n\n[Brief truncated in context pane. Open the full artifact to continue.]"
  }

  nonisolated static func nodeBriefPrompt(
    title: String,
    reference: String,
    artifactRelativePath: String,
    artifactLocalPath: String,
    artifactOpenClawPath: String,
    sourceID: String?
  ) -> String {
    let artifactID = "node-brief-\(slug(sourceID ?? reference))"
    let provenance = [
      sourceID.map { "id:\($0)" },
      "file:\(reference)"
    ].compactMap { $0 }.joined(separator: ", ")
    return """
    Generate a concise, source-cited briefing for the selected org2 node "\(title)" and save it as an org2 view artifact.

    Target artifact relative path: \(artifactRelativePath)
    Target artifact path for OpenClaw: \(artifactOpenClawPath)
    Local artifact path: \(artifactLocalPath)
    Selected node: \(reference)
    \(sourceID.map { "Selected node ID: \($0)" } ?? "Selected node ID: unavailable")

    Use the selected-node source and computed backlink context provided in the org2 workspace context. You may run org2 backlinks/search/query for more source context if needed, but do not run org2 brief to generate this brief.

    Before writing, do a current-state sweep. Search recent and agent/workflow files for the selected node title, aliases, account/company names, and obvious variants. Prefer newer dated entries over older background context when describing current state. Do not discard completed DONE/CANCELED workflow items if they record important current facts such as an email sent, follow-up sent, handoff completed, decision made, current owner, waiting on reply/response, blocked state, or other recent account/project state. Treat properties and phrases such as SENT_AT, LAST_SENT_AT, GMAIL_SENT_MESSAGE_ID, FOLLOWUP_STATUS, FOLLOWUP_SENT_AT, waiting on reply, awaiting response, blocked, sent, approved, or completed as possible current-state evidence even when the TODO itself is no longer active.

    Write for a human trying to quickly understand the node. Focus on what matters, not how org2 stores it. Do not present stable IDs, artifact metadata, file paths, provenance fields, review status, schema fields, or the mere existence of a title/ID as facts or highlights. Use file paths and line numbers only as citations after concrete claims. Mention metadata only in "Node health issues" when it is actually broken, missing, duplicated, stale, or confusing.

    Keep the body concise:
    - Most important facts: 3-6 bullets, including recent material state changes even if they came from completed workflow entries.
    - Active related tasks: only TODO/open/actionable items, up to 5 bullets, or "None found."
    - Recent related decisions: only decisions/commitments/outcomes, up to 5 bullets, or "None found."
    - Open questions: unresolved questions/unknowns/risks, including waiting-on-response states, up to 5 bullets, or "None found."
    - Node health issues: put this last; include only maintenance problems such as contradictory notes, stale generated context, broken links, missing IDs, duplicate IDs, bad citations, or confusing organization.

    Create the parent directory if needed. Replace the artifact file atomically if it already exists. The file must be valid org2 and start with:
    #+TITLE: Node brief: \(title)
    :PROPERTIES:
    :ID: \(artifactID)
    :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
    :ORG2_ARTIFACT_ROLE: view
    :ORG2_PROVENANCE: \(provenance)
    :ORG2_GENERATOR: OpenClaw via Org2Workspace node brief
    :ORG2_GENERATED_AT: <ISO-8601 timestamp>
    :ORG2_CLAIM_STATE: source-backed
    :ORG2_REVIEW_STATUS: review-required
    :ORG2_AI_TASK: node-brief
    :ORG2_PROMPT_TEMPLATE: node-brief@v2
    :END:

    Then write these sections:
    * Most important facts
    * Active related tasks
    * Recent related decisions
    * Open questions
    * Node health issues
    * Sources

    Cite file paths and line numbers for every concrete claim. Prefer specific, user-meaningful facts over generic graph or storage details. Do not edit canonical notes. Reply in chat with only a short confirmation and the artifact path.
    """
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
    if selectedLocation == nil,
       agendaMode == .assigned,
       let selectedAssignedWorkItemID,
       let item = assignedWorkItems.first(where: { $0.id == selectedAssignedWorkItemID }) {
      selectAssignedWorkItem(item)
    }
    guard let selectedLocation else { return }
    open(selectedLocation)
  }

  public func open(_ location: WorkspaceLocation) {
    openFile(path: location.file, line: location.lineForEditor)
  }

  public func revealSelectedLocation() {
    guard let selectedLocation else { return }
    revealFile(path: selectedLocation.file)
  }

  public func revealFile(path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  public func openFileInEditor(path: String, line: Int = 1) {
    openFile(path: path, line: line)
  }

  public func copyFileReference(path: String, line: Int? = nil) {
    let reference = line.map { "\(relativePath(path)):\($0)" } ?? relativePath(path)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(reference, forType: .string)
    statusText = "Copied \(reference)"
  }

  public func relativePath(_ path: String) -> String {
    guard let corpusRoot else { return path }
    return Self.relativePath(for: path, root: corpusRoot)
  }

  private static func relativePath(for path: String, root: URL) -> String {
    let originalPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    if resolvedPath == rootPath { return "." }
    if resolvedPath.hasPrefix(rootPath + "/") {
      return String(resolvedPath.dropFirst(rootPath.count + 1))
    }
    return originalPath
  }

  private func openClawContextPointerForCurrentSelection() -> OpenClawContextPointer? {
    if let selectedBlock,
       let pointer = openClawContextPointer(for: OpenClawBlockContextPointer(source: selectedEntrySource, block: selectedBlock)) {
      return pointer
    }

    if let source = selectedEntrySource {
      let kind = source.isSubtree ? "selected entry" : "selected page"
      let title = selectedLocation?.title ?? Self.titleFromFileStem(URL(fileURLWithPath: source.file).deletingPathExtension().lastPathComponent)
      return OpenClawContextPointer(
        kind: kind,
        reference: "\(mappedPathForOpenClaw(source.file)):\(source.startLine)",
        displayReference: "\(relativePath(source.file)):\(source.startLine)",
        threadTitle: "Ask: \(title)"
      )
    }

    if let location = selectedLocation {
      return OpenClawContextPointer(
        kind: "current selection",
        reference: "\(mappedPathForOpenClaw(location.file)):\(location.lineForEditor)",
        displayReference: "\(relativePath(location.file)):\(location.lineForEditor)",
        threadTitle: "Ask: \(location.title)"
      )
    }

    return nil
  }

  private func openClawContextPointer(for block: OpenClawBlockContextPointer?) -> OpenClawContextPointer? {
    guard let block else { return nil }
    let startLine = max(1, block.startLine)
    let endLineInclusive = max(startLine, block.endLineExclusive - 1)
    let mappedFile = mappedPathForOpenClaw(block.file)
    let displayFile = relativePath(block.file)
    let reference: String
    let displayReference: String
    if endLineInclusive > startLine {
      reference = "\(mappedFile):\(startLine)-\(endLineInclusive)"
      displayReference = "\(displayFile):\(startLine)-\(endLineInclusive)"
    } else {
      reference = "\(mappedFile):\(startLine)"
      displayReference = "\(displayFile):\(startLine)"
    }
    return OpenClawContextPointer(
      kind: "selected block",
      reference: reference,
      displayReference: displayReference,
      threadTitle: "Ask: \(selectedLocation?.title ?? displayFile)"
    )
  }

  private func addOpenClawContext(_ pointer: OpenClawContextPointer, threadMode: OpenClawThreadMode) {
    let injectedContext = "Use \(pointer.kind) at \(pointer.reference) as context.\n\n"
    let hadSelectedThread = selectedOpenClawChatThreadID != nil
    let unthreadedDraft = hadSelectedThread ? "" : openClawDraft
    if !canReuseOpenClawContextDraftThread(for: pointer, mode: threadMode) {
      prepareOpenClawThread(
        mode: threadMode,
        title: pointer.threadTitle,
        statusText: "New OpenClaw context chat"
      )
    }
    let previousDraft = currentOpenClawDraftForSelectedThread()
    let draftToAppend = previousDraft.isEmpty ? unthreadedDraft : previousDraft
    var nextDraft = previousDraft
    if previousDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      nextDraft = injectedContext + draftToAppend
    } else if !draftToAppend.contains(pointer.reference) {
      nextDraft = injectedContext + draftToAppend
    }
    if nextDraft != previousDraft {
      publishOpenClawComposerDraft(nextDraft)
      recordWorkspaceUndo(.openClawDraft(previous: hadSelectedThread ? previousDraft : unthreadedDraft, next: nextDraft))
    }

    setOpenClawAssistantPanelPresented(true)
    openClawStatusText = "Added \(pointer.displayReference) to OpenClaw"
    statusText = "Added \(pointer.displayReference) to OpenClaw"
  }

  private func canReuseOpenClawContextDraftThread(
    for pointer: OpenClawContextPointer,
    mode: OpenClawThreadMode
  ) -> Bool {
    guard mode == .newThread,
          let thread = selectedOpenClawChatThread,
          thread.messages.isEmpty,
          openClawDraft.contains(pointer.reference)
    else { return false }
    return Self.normalizedOpenClawThreadTitle(thread.title) == Self.normalizedOpenClawThreadTitle(pointer.threadTitle)
  }

  private func mappedPathForOpenClaw(_ path: String) -> String {
    guard let corpusRoot,
          let remoteRoot = effectiveOpenClawRemoteCorpusPath().map(Self.trimTrailingSlashes)
    else {
      return path
    }

    let localRoot = Self.trimTrailingSlashes(corpusRoot.standardizedFileURL.path)
    if path == localRoot {
      return remoteRoot
    }
    if path.hasPrefix(localRoot + "/") {
      return remoteRoot + "/" + String(path.dropFirst(localRoot.count + 1))
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

  private func migrateLegacyDefaultsIfNeeded(
    legacyDomains: [String],
    defaultOpenClawEndpoint: String
  ) {
    guard !legacyDomains.isEmpty,
          defaults.object(forKey: legacyDefaultsMigrationKey) == nil
    else {
      return
    }

    let keys = [
      corpusKey,
      agendaModeKey,
      openClawEndpointKey,
      openClawAgentKey,
      agentHandoffAssigneeKey,
      personalAssigneeNamesKey,
      openClawRemoteCorpusPathKey,
      openClawBriefsStartNewThreadKey,
      orgCryptEncryptOnSaveKey,
      orgCryptRecipientsKey,
      orgCryptRecipientFilesKey,
      orgCryptUseDefaultGpgKeyKey,
      orgCryptUseDefaultGpgKeyMigrationKey,
      orgCryptGpgProgramKey
    ]
    let defaultValues: [String: AnyHashable] = [
      openClawEndpointKey: defaultOpenClawEndpoint,
      openClawAgentKey: "main",
      agentHandoffAssigneeKey: Self.defaultAgentHandoffAssignee,
      personalAssigneeNamesKey: "",
      openClawRemoteCorpusPathKey: "",
      openClawBriefsStartNewThreadKey: true,
      orgCryptGpgProgramKey: "gpg"
    ]

    var migratedAny = false
    for domain in legacyDomains {
      guard let legacyDefaults = UserDefaults(suiteName: domain) else { continue }
      for key in keys {
        guard let value = legacyDefaults.object(forKey: key),
              shouldMigrateDefaultValue(forKey: key, defaultValues: defaultValues)
        else {
          continue
        }
        defaults.set(value, forKey: key)
        migratedAny = true
      }
    }

    defaults.set(true, forKey: legacyDefaultsMigrationKey)
    if migratedAny {
      defaults.synchronize()
    }
  }

  private func shouldMigrateDefaultValue(
    forKey key: String,
    defaultValues: [String: AnyHashable]
  ) -> Bool {
    guard let currentValue = defaults.object(forKey: key) else { return true }
    guard let defaultValue = defaultValues[key] else { return false }
    if let currentString = currentValue as? String,
       let defaultString = defaultValue.base as? String {
      return currentString == defaultString
    }
    if let currentBool = currentValue as? Bool,
       let defaultBool = defaultValue.base as? Bool {
      return currentBool == defaultBool
    }
    return false
  }

  private static func shouldIgnoreStandardDefaultsForTests(_ defaults: UserDefaults) -> Bool {
    NSClassFromString("XCTestCase") != nil
      && defaults === UserDefaults.standard
  }

  nonisolated static func shouldMigrateLegacyDefaults(bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return true }
    return bundleIdentifier == "org.org2.workspace"
  }

  nonisolated private static func shouldMigrateLegacyDefaultsForCurrentBundle(bundle: Bundle = .main) -> Bool {
    shouldMigrateLegacyDefaults(bundleIdentifier: bundle.bundleIdentifier)
  }

  private func restoreCorpusRoot() -> URL? {
    guard !Self.shouldIgnoreStandardDefaultsForTests(defaults) else {
      return nil
    }

    if let saved = restoreSavedCorpusRoot() {
      return saved
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

  private func restoreSavedCorpusRoot() -> URL? {
    guard let saved = defaults.string(forKey: corpusKey), isDirectory(saved) else {
      return nil
    }
    return URL(fileURLWithPath: saved).standardizedFileURL
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

  private func persistOpenClawTranscript() {
    do {
      try Self.saveOpenClawTranscript(
        OpenClawTranscriptState(
          threads: openClawChatThreads,
          selectedThreadID: selectedOpenClawChatThreadID
        ),
        to: openClawTranscriptURL
      )
    } catch {
      errorText = "OpenClaw transcript save failed: \(error.localizedDescription)"
    }
  }

  private func switchOpenClawTranscript(to url: URL, migrationSource: URL? = nil) {
    guard !usesFixedOpenClawTranscriptURL else { return }
    let targetURL = url.standardizedFileURL
    let previousURL = openClawTranscriptURL.standardizedFileURL
    guard targetURL.path != previousURL.path else { return }

    let transcript: OpenClawTranscriptState
    let shouldPersistMigratedMessages: Bool
    if FileManager.default.fileExists(atPath: targetURL.path) {
      transcript = Self.loadOpenClawTranscript(from: targetURL)
      shouldPersistMigratedMessages = false
    } else if let migrationSource,
              migrationSource.standardizedFileURL.path != targetURL.path {
      transcript = Self.loadOpenClawTranscript(from: migrationSource.standardizedFileURL)
      shouldPersistMigratedMessages = !transcript.threads.isEmpty
    } else if previousURL.path == appOpenClawTranscriptURL.standardizedFileURL.path,
              !openClawMessages.isEmpty {
      transcript = Self.openClawTranscriptState(fromLegacyMessages: openClawMessages)
      shouldPersistMigratedMessages = true
    } else {
      transcript = OpenClawTranscriptState(threads: [], selectedThreadID: nil)
      shouldPersistMigratedMessages = false
    }

    openClawTranscriptURL = targetURL
    openClawSessionKey = Self.makeOpenClawSessionKey()
    removeAllPendingOpenClawUserMessages()
    drainingOpenClawThreadIDs.removeAll()
    openClawRequestStartedAtByThreadID.removeAll()
    syncSelectedOpenClawSendState()
    applyOpenClawTranscript(transcript, shouldPersist: shouldPersistMigratedMessages)
  }

  private func replaceOpenClawMessages(_ messages: [OpenClawChatMessage], shouldPersist: Bool) {
    let previousPersistence = shouldPersistOpenClawMessages
    shouldPersistOpenClawMessages = false
    isApplyingOpenClawThreadMessages = true
    openClawMessages = messages
    isApplyingOpenClawThreadMessages = false
    shouldPersistOpenClawMessages = previousPersistence
    if shouldPersist {
      updateSelectedOpenClawChatThread(messages: messages)
      persistOpenClawTranscript()
    }
  }

  private func applyOpenClawTranscript(_ transcript: OpenClawTranscriptState, shouldPersist: Bool) {
    let threads = Self.sortedOpenClawChatThreadsForDisplay(transcript.threads)
    openClawChatThreads = threads
    let selectedID = transcript.selectedThreadID
      .flatMap { id in threads.contains(where: { $0.id == id }) ? id : nil }
      ?? threads.first?.id
    selectedOpenClawChatThreadID = selectedID
    let selectedThread = selectedID.flatMap { id in threads.first(where: { $0.id == id }) }
    openClawSessionKey = selectedThread?.sessionKey ?? Self.makeOpenClawSessionKey()
    replaceOpenClawMessages(selectedThread?.messages ?? [], shouldPersist: false)
    if shouldPersist {
      persistOpenClawTranscript()
    }
  }

  private func restoreInterruptedOpenClawSendStatusIfNeeded() {
    let interruptedCount = openClawMessages.filter {
      $0.role == .user && $0.deliveryStatus == .interrupted
    }.count
    guard interruptedCount > 0 else { return }
    openClawStatusText = interruptedCount == 1
      ? "OpenClaw response interrupted; retry the message"
      : "\(interruptedCount) OpenClaw responses interrupted; retry the messages"
  }

  private func renderEntrySource(_ source: EntrySource, generation: Int) {
    let renderKey = Self.entryHTMLRenderKey(for: source)
    if selectedEntryHTMLRenderKey != renderKey {
      prepareEntryHTML(for: source)
    }
    entryHTMLRenderGeneration += 1
    let renderGeneration = entryHTMLRenderGeneration
    isRenderingEntrySource = true
    selectedEntryRenderError = nil

    let cachedHTML = renderedHTMLCache[renderKey]?.html
    if let cachedHTML {
      renderedHTMLCacheOrder.removeAll { $0 == renderKey }
      renderedHTMLCacheOrder.append(renderKey)
      selectedEntryHTML = cachedHTML
      selectedEntryHTMLRenderKey = renderKey
    }

    Task { @MainActor in
      if cachedHTML == nil {
        do {
          let html = try await cli.renderAppHTML(
            source.text,
            sourcePath: source.file,
            sourceLineOffset: max(0, source.startLine - 1)
          )
          guard generation == self.entrySourceLoadGeneration,
                renderGeneration == self.entryHTMLRenderGeneration,
                self.selectedEntrySource?.id == source.id,
                self.selectedEntryHTMLRenderKey == renderKey
          else {
            return
          }
          self.cacheRenderedHTML(html, key: renderKey)
          self.selectedEntryHTML = html
          self.selectedEntryRenderError = nil
        } catch {
          guard generation == self.entrySourceLoadGeneration,
                renderGeneration == self.entryHTMLRenderGeneration,
                self.selectedEntrySource?.id == source.id,
                self.selectedEntryHTMLRenderKey == renderKey
          else {
            return
          }
          self.selectedEntryHTML = nil
          self.selectedEntryRenderError = error.localizedDescription
        }
      }

      let modifiedAt = Self.modificationDate(for: URL(fileURLWithPath: source.file).standardizedFileURL)
      let blocks: [OrgEditableBlock]
      if let cachedBlocks = self.cachedRenderedBlocks(for: source, modifiedAt: modifiedAt) {
        blocks = cachedBlocks
      } else {
        blocks = await Task.detached(priority: .utility) {
          OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)
        }.value
      }
      guard generation == self.entrySourceLoadGeneration,
            renderGeneration == self.entryHTMLRenderGeneration,
            self.selectedEntrySource?.id == source.id,
            self.selectedEntryHTMLRenderKey == renderKey
      else {
        return
      }
      if self.cachedRenderedBlocks(for: source, modifiedAt: modifiedAt) == nil {
        self.cacheRenderedBlocks(blocks, for: source, modifiedAt: modifiedAt)
      }
      self.applyRenderedBlocks(blocks, for: source)
      self.isRenderingEntrySource = false
    }
  }

  public func retrySelectedEntryRendering() {
    guard let source = selectedEntrySource else { return }
    let key = Self.entryHTMLRenderKey(for: source)
    renderedHTMLCache.removeValue(forKey: key)
    renderedHTMLCacheOrder.removeAll { $0 == key }
    selectedEntryHTML = nil
    selectedEntryRenderError = nil
    selectedEntryHTMLRenderKey = key
    renderEntrySource(source, generation: entrySourceLoadGeneration)
  }

  private func prepareEntryHTML(for source: EntrySource) {
    let renderKey = Self.entryHTMLRenderKey(for: source)
    guard selectedEntryHTMLRenderKey != renderKey else { return }
    entryHTMLRenderGeneration += 1
    selectedEntryHTML = nil
    selectedEntryRenderError = nil
    selectedEntryHTMLRenderKey = renderKey
    selectedRenderedBlocks = []
    selectedBlockID = nil
  }

  private func cacheRenderedHTML(_ html: String, key: String) {
    renderedHTMLCache[key] = RenderedHTMLCacheEntry(html: html)
    renderedHTMLCacheOrder.removeAll { $0 == key }
    renderedHTMLCacheOrder.append(key)
    while renderedHTMLCacheOrder.count > Self.renderedHTMLCacheLimit {
      let evicted = renderedHTMLCacheOrder.removeFirst()
      renderedHTMLCache.removeValue(forKey: evicted)
    }
  }

  nonisolated private static func entryHTMLRenderKey(for source: EntrySource) -> String {
    let path = URL(fileURLWithPath: source.file).standardizedFileURL.path
    let digest = SHA256.hash(data: Data(source.text.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(path)|\(source.startLine)|\(source.endLineExclusive)|\(digest)"
  }

  private func applyRenderedBlocks(_ blocks: [OrgEditableBlock], for source: EntrySource) {
    let visibleBlocks = blocksWithTransientDraft(blocks, for: source)
    if selectedRenderedBlocks != visibleBlocks {
      selectedRenderedBlocks = visibleBlocks
    }
    if let pending = pendingBlockSelection,
       pending.file == source.file {
      let pendingBlock = blockForSelectionLine(pending.line, mode: pending.mode, in: visibleBlocks)
      selectedBlockID = pendingBlock?.id
      pendingBlockSelection = nil
      if pending.beginEditing,
         let pendingBlock,
         pendingBlock.isEditable,
         source.isEditable {
        beginEditingSource(
          for: pendingBlock,
          selection: pending.initialSourceUTF16Offset.map {
            Self.editableSelection(for: pendingBlock, sourceUTF16Offset: $0)
          }
        )
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
    invalidateEntrySourceCache(for: file)
    invalidateRenderedBlocksCache(for: file)
    invalidateRenderedHTMLCache(for: file)
  }

  private func entrySourceCacheKey(for location: WorkspaceLocation, mode: EntrySourceMode) -> String {
    "\(Self.selectionIdentity(for: location))|\(mode.rawValue)"
  }

  private func cacheEntrySource(
    _ source: EntrySource,
    for location: WorkspaceLocation,
    mode: EntrySourceMode,
    modifiedAt: Date?
  ) {
    let key = entrySourceCacheKey(for: location, mode: mode)
    entrySourceCache[key] = EntrySourceCacheEntry(modifiedAt: modifiedAt, source: source)
    entrySourceCacheOrder.removeAll { $0 == key }
    entrySourceCacheOrder.append(key)

    while entrySourceCacheOrder.count > Self.entrySourceCacheLimit {
      let evicted = entrySourceCacheOrder.removeFirst()
      entrySourceCache.removeValue(forKey: evicted)
    }
  }

  private func cachedEntrySource(for location: WorkspaceLocation, mode: EntrySourceMode) -> EntrySource? {
    let key = entrySourceCacheKey(for: location, mode: mode)
    guard let cached = entrySourceCache[key],
          cached.modifiedAt == Self.modificationDate(for: URL(fileURLWithPath: location.file).standardizedFileURL)
    else {
      return nil
    }
    entrySourceCacheOrder.removeAll { $0 == key }
    entrySourceCacheOrder.append(key)
    return cached.source
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

  private func invalidateRenderedHTMLCache(for file: String) {
    let path = URL(fileURLWithPath: file).standardizedFileURL.path + "|"
    let keys = renderedHTMLCache.keys.filter { $0.hasPrefix(path) }
    for key in keys {
      renderedHTMLCache.removeValue(forKey: key)
    }
    renderedHTMLCacheOrder.removeAll { $0.hasPrefix(path) }
  }

  private func invalidateEntrySourceCache(for file: String) {
    let path = URL(fileURLWithPath: file).standardizedFileURL.path
    let keys = entrySourceCache.keys.filter { $0.contains("\u{1F}\(path)\u{1F}") }
    for key in keys {
      entrySourceCache.removeValue(forKey: key)
    }
    entrySourceCacheOrder.removeAll { key in
      key.contains("\u{1F}\(path)\u{1F}")
    }
  }

  private func currentOpenClawWorkspaceContext() -> OpenClawWorkspaceContext {
    let source: EntrySource?
    if (isEditingEntry || isLiveFileEditorAvailable), let selectedEntrySource {
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
      searchResults: searchResults,
      agentThreadDirectories: currentOpenClawAgentThreadDirectories()
    )
  }

  private func currentOpenClawAgentThreadDirectories() -> [String] {
    guard let corpusRoot else { return [] }
    return Self.openClawThreadDirectories(corpusRoot: corpusRoot)
      .map { mappedPathForOpenClaw($0.path) }
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

  nonisolated static func normalizedAssigneeIdentity(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
  }

  nonisolated static func personalAssigneeNames(from text: String) -> Set<String> {
    Set(text
      .split(whereSeparator: { character in
        character == "," || character == ";" || character.isNewline
      })
      .map { normalizedAssigneeIdentity(String($0)) }
      .filter { !$0.isEmpty })
  }

  private static func defaultOpenClawStatusText() -> String {
    openClawStatusText(settings: OpenClawGatewaySettings.resolve())
  }

  private static func defaultMeetingStatusText() -> String {
    "Local transcription: \(LocalWhisperTranscriber.resolvedBackendDescription())"
  }

  nonisolated private static func makeOpenClawSessionKey() -> String {
    "org2-workspace:\(UUID().uuidString)"
  }

  nonisolated private static func openClawVoiceNoteURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-voice", isDirectory: true)
      .appendingPathComponent("\(UUID().uuidString).wav")
  }

  nonisolated static func openClawImageAttachment(from url: URL) throws -> OpenClawChatAttachment {
    let standardized = url.standardizedFileURL
    let data = try Data(contentsOf: standardized)
    guard data.count <= openClawImageAttachmentMaxBytes else {
      throw OpenClawAttachmentError.imageTooLarge(
        standardized.lastPathComponent,
        maxMegabytes: openClawImageAttachmentMaxBytes / 1_000_000
      )
    }
    let type = UTType(filenameExtension: standardized.pathExtension)
    guard type?.conforms(to: .image) == true else {
      throw OpenClawAttachmentError.unsupportedImage(standardized.lastPathComponent)
    }
    return OpenClawChatAttachment(
      fileName: standardized.lastPathComponent,
      mimeType: type?.preferredMIMEType ?? "image/png",
      data: data
    )
  }

  nonisolated private static let openClawImageAttachmentMaxBytes = 20_000_000

  nonisolated static func openClawDraftByAppendingDictation(existing: String, dictatedText: String) -> String {
    let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    let dictatedText = dictatedText.trimmingCharacters(in: .whitespacesAndNewlines)
    if existing.isEmpty { return dictatedText }
    if dictatedText.isEmpty { return existing }
    return "\(existing)\n\n\(dictatedText)"
  }

  nonisolated private static func defaultOpenClawTranscriptURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base
      .appendingPathComponent("Org2Workspace", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
  }

  nonisolated private static func openClawTranscriptURL(corpusRoot: URL) -> URL {
    corpusRoot.standardizedFileURL
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
  }

  nonisolated private static func loadOpenClawMessages(from url: URL) -> [OpenClawChatMessage] {
    let transcript = loadOpenClawTranscript(from: url)
    let selectedID = transcript.selectedThreadID
    return selectedID
      .flatMap { id in transcript.threads.first(where: { $0.id == id })?.messages }
      ?? transcript.threads.first?.messages
      ?? []
  }

  nonisolated private static func saveOpenClawMessages(_ messages: [OpenClawChatMessage], to url: URL) throws {
    try saveOpenClawTranscript(openClawTranscriptState(fromLegacyMessages: messages), to: url)
  }

  nonisolated private static func loadOpenClawTranscript(from url: URL) -> OpenClawTranscriptState {
    guard let data = try? Data(contentsOf: url),
          let payload = try? JSONDecoder().decode(OpenClawTranscriptPayload.self, from: data)
    else {
      return OpenClawTranscriptState(threads: [], selectedThreadID: nil)
    }
    if let threads = payload.threads {
      return openClawTranscriptStateByMarkingInterruptedSends(
        OpenClawTranscriptState(
          threads: threads,
          selectedThreadID: payload.selectedThreadID
        )
      )
    }
    return openClawTranscriptStateByMarkingInterruptedSends(
      openClawTranscriptState(fromLegacyMessages: payload.messages ?? [])
    )
  }

  nonisolated private static func openClawTranscriptStateByMarkingInterruptedSends(
    _ transcript: OpenClawTranscriptState
  ) -> OpenClawTranscriptState {
    OpenClawTranscriptState(
      threads: transcript.threads.map { thread in
        let messages = thread.messages.map { message in
          guard message.role == .user,
                message.deliveryStatus == .sending
          else {
            return message
          }
          return message.replacingDeliveryStatus(
            .interrupted,
            sendFailure: openClawInterruptedSendFailureText
          )
        }
        return thread.replacingMessages(messages)
      },
      selectedThreadID: transcript.selectedThreadID
    )
  }

  nonisolated private static func saveOpenClawTranscript(_ transcript: OpenClawTranscriptState, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload = OpenClawTranscriptPayload(
      version: 2,
      messages: nil,
      threads: transcript.threads,
      selectedThreadID: transcript.selectedThreadID
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    try data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  nonisolated private static func openClawTranscriptState(fromLegacyMessages messages: [OpenClawChatMessage]) -> OpenClawTranscriptState {
    guard !messages.isEmpty else {
      return OpenClawTranscriptState(threads: [], selectedThreadID: nil)
    }
    let createdAt = messages.first?.createdAt ?? Date()
    let updatedAt = messages.last?.createdAt ?? createdAt
    let thread = OpenClawChatThread(
      title: openClawThreadTitle(from: messages),
      createdAt: createdAt,
      updatedAt: updatedAt,
      sessionKey: makeOpenClawSessionKey(),
      messages: messages
    )
    return OpenClawTranscriptState(threads: [thread], selectedThreadID: thread.id)
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

  nonisolated private static func installWhisperCppAndDefaultModel() throws {
    let fileManager = FileManager.default
    let brewCandidates = [
      "/opt/homebrew/bin/brew",
      "/usr/local/bin/brew"
    ]
    guard let brew = brewCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
      throw AudioSettingsError.homebrewNotFound
    }

    let modelURL = LocalWhisperTranscriber.defaultWhisperCppModelURL
    try fileManager.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let command = [
      "\(shellQuote(brew)) install whisper-cpp",
      "mkdir -p \(shellQuote(modelURL.deletingLastPathComponent().path))",
      "curl -fL --retry 3 --continue-at - --output \(shellQuote(modelURL.path)) \(shellQuote(LocalWhisperTranscriber.defaultWhisperCppModelDownloadURL.absoluteString))"
    ].joined(separator: " && ")

    let result = runAudioSettingsShellCommand(command)
    guard result.exitCode == 0 else {
      throw AudioSettingsError.installFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }
  }

  nonisolated private static func runAudioSettingsShellCommand(_ command: String) -> AudioSettingsProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    var environment = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if let existing = environment["PATH"], !existing.isEmpty {
      environment["PATH"] = "\(defaultPath):\(existing)"
    } else {
      environment["PATH"] = defaultPath
    }
    process.environment = environment

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    do {
      try process.run()
      let outputData = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let text = String(data: outputData, encoding: .utf8) ?? ""
      return AudioSettingsProcessResult(
        exitCode: process.terminationStatus,
        stdout: text,
        stderr: text
      )
    } catch {
      return AudioSettingsProcessResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
    }
  }

  nonisolated private static func shellQuote(_ raw: String) -> String {
    "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func syncAgendaSelectionAfterRefresh(preserveSelection: Bool = false) {
    let items = visibleAgendaItems
    pruneAgendaBulkSelection(visibleItems: items)
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

  private func pruneAgendaBulkSelection(visibleItems: [AgendaItem]? = nil) {
    guard !bulkSelectedAgendaItemIDs.isEmpty else { return }
    let visibleIDs = Set((visibleItems ?? visibleAgendaItems).map(\.id))
    let prunedIDs = bulkSelectedAgendaItemIDs.intersection(visibleIDs)
    if prunedIDs != bulkSelectedAgendaItemIDs {
      bulkSelectedAgendaItemIDs = prunedIDs
    }
  }

  private func updateAgendaBulkSelectionStatusText() {
    let count = bulkAgendaSelectionCount
    statusText = count == 1 ? "1 agenda item selected" : "\(count) agenda items selected"
  }

  private func selectedAgendaItemsForBulkMutation() -> [AgendaItem] {
    guard !bulkSelectedAgendaItemIDs.isEmpty else { return [] }
    let items = visibleAgendaItems
    pruneAgendaBulkSelection(visibleItems: items)
    guard !bulkSelectedAgendaItemIDs.isEmpty else { return [] }
    return items.filter { bulkSelectedAgendaItemIDs.contains($0.id) }
  }

  private func selectedAgendaItemForMutation() -> AgendaItem? {
    if let selectedAgendaItemID {
      return visibleAgendaItems.first(where: { $0.id == selectedAgendaItemID })
    }
    if case .agenda(let item) = selectedLocation {
      return item
    }
    return visibleAgendaItems.first
  }

  private func agendaMutationOrder(_ items: [AgendaItem]) -> [AgendaItem] {
    items.sorted { lhs, rhs in
      if lhs.file == rhs.file {
        if lhs.lineForEditor == rhs.lineForEditor {
          return lhs.id < rhs.id
        }
        return lhs.lineForEditor > rhs.lineForEditor
      }
      return lhs.file < rhs.file
    }
  }

  private func preserveAgendaSelectionAfterTodoMutation(
    target: HeadlineMutationTarget,
    originalVisibleIndex: Int?,
    shouldAdvanceSelection: Bool
  ) {
    guard let agendaItemID = target.agendaItemID else { return }
    if shouldAdvanceSelection,
       selectNextActionableAgendaItem(afterMutating: agendaItemID, originalVisibleIndex: originalVisibleIndex) {
      return
    }

    if let item = visibleAgendaItems.first(where: { $0.id == agendaItemID }) {
      preserveAgendaItemSelectionWithoutActivatingEntry(item)
    } else if selectedAgendaItemID == agendaItemID {
      selectedAgendaItemID = nil
    }
  }

  private func preserveAgendaItemSelectionWithoutActivatingEntry(_ item: AgendaItem) {
    selectedSurface = .agenda
    if selectedAgendaItemID != item.id {
      selectAgendaItemWithoutActivatingEntry(item)
    }
  }

  @discardableResult
  private func selectNextActionableAgendaItem(afterMutating mutatedID: String, originalVisibleIndex: Int?) -> Bool {
    guard let item = Self.nextActionableAgendaItem(
      afterMutating: mutatedID,
      originalVisibleIndex: originalVisibleIndex,
      in: visibleAgendaItems
    ) else {
      return false
    }
    selectAgendaItemWithoutActivatingEntry(item)
    return true
  }

  nonisolated private static func nextActionableAgendaItem(
    afterMutating mutatedID: String,
    originalVisibleIndex: Int?,
    in items: [AgendaItem]
  ) -> AgendaItem? {
    guard !items.isEmpty else { return nil }
    let actionableItems = items.enumerated().filter { _, item in
      item.id != mutatedID && item.isActionable
    }
    guard !actionableItems.isEmpty else { return nil }

    let anchor = originalVisibleIndex ?? 0
    return (actionableItems.first { offset, _ in
      offset >= anchor
    } ?? actionableItems.last)?.element
  }

  nonisolated private static func isTerminalTodoStatus(_ status: String) -> Bool {
    let normalized = status.uppercased()
    return normalized == "DONE" || normalized == "CANCELED" || normalized == "CANCELLED"
  }

  private func syncOpenClawSelectionAfterRefresh() {
    guard !openClawThreads.isEmpty,
          case .openClaw = selectedLocation
    else {
      return
    }
    if let selectedOpenClawThreadID,
       let thread = openClawThreads.first(where: { $0.id == selectedOpenClawThreadID }) {
      select(.openClaw(thread))
    }
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

  nonisolated private static func lineBreakCount(in text: String) -> Int {
    text.reduce(0) { count, character in
      character == "\n" ? count + 1 : count
    }
  }

  nonisolated private static func replaceEntrySource(
    _ source: EntrySource,
    with replacement: String,
    allowDestructiveReplacement: Bool = false
  ) throws {
    try replaceSourceRange(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.endLineExclusive,
      replacement: replacement,
      expectedOriginal: source.text,
      allowDestructiveReplacement: allowDestructiveReplacement
    )
  }

  nonisolated private static func fileText(file: String) throws -> String {
    try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
  }

  nonisolated private static func writeFileText(
    _ text: String,
    to file: String,
    allowDestructiveReplacement: Bool = false
  ) throws {
    let url = URL(fileURLWithPath: file)
    let previous = FileManager.default.fileExists(atPath: url.path)
      ? try String(contentsOf: url, encoding: .utf8)
      : ""
    try writeOrgTextSafely(
      text,
      to: url,
      replacing: previous,
      operation: "file snapshot restore",
      allowDestructiveReplacement: allowDestructiveReplacement
    )
  }

  nonisolated private static func writeOrgTextSafely(
    _ text: String,
    to url: URL,
    replacing previousText: String,
    operation: String,
    allowDestructiveReplacement: Bool = false
  ) throws {
    let assessment = orgFileWriteSafetyAssessment(
      url: url,
      previousText: previousText,
      nextText: text
    )
    var backupPath: String?

    if let assessment {
      let backupURL = try writeOrgRecoveryBackup(
        for: url,
        previousText: previousText,
        reason: assessment.reason
      )
      backupPath = backupURL.path
    }

    if assessment?.shouldBlock == true, !allowDestructiveReplacement {
      throw WorkspaceEditError.destructiveWriteBlocked(
        file: url.path,
        backup: backupPath,
        operation: operation
      )
    }

    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  nonisolated private static func orgFileWriteSafetyAssessment(
    url: URL,
    previousText: String,
    nextText: String
  ) -> (reason: String, shouldBlock: Bool)? {
    guard isOrgTextFile(url),
          !url.pathComponents.contains(".org2-recovery")
    else {
      return nil
    }

    let previous = normalizeLineEndings(previousText)
    let next = normalizeLineEndings(nextText)
    guard !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }

    if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ("empty-write", true)
    }

    let previousByteCount = previous.utf8.count
    let nextByteCount = next.utf8.count
    if previousByteCount >= 8192,
       nextByteCount < max(512, previousByteCount / 20) {
      return ("large-shrink", false)
    }

    return nil
  }

  nonisolated private static func isOrgTextFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ext == "org" || ext == "org2"
  }

  nonisolated private static func writeOrgRecoveryBackup(
    for url: URL,
    previousText: String,
    reason: String
  ) throws -> URL {
    let backupDirectory = url
      .deletingLastPathComponent()
      .appendingPathComponent(".org2-recovery", isDirectory: true)
    try FileManager.default.createDirectory(
      at: backupDirectory,
      withIntermediateDirectories: true
    )

    let sanitizedFileName = url.lastPathComponent.replacingOccurrences(
      of: #"[^A-Za-z0-9._-]+"#,
      with: "-",
      options: .regularExpression
    )
    let sanitizedReason = reason.replacingOccurrences(
      of: #"[^A-Za-z0-9._-]+"#,
      with: "-",
      options: .regularExpression
    )
    let baseName = "\(sanitizedFileName).before-\(sanitizedReason).\(orgRecoveryTimestamp())"
    var backupURL = backupDirectory.appendingPathComponent(baseName)
    var collisionIndex = 1
    while FileManager.default.fileExists(atPath: backupURL.path) {
      backupURL = backupDirectory.appendingPathComponent("\(baseName).\(collisionIndex)")
      collisionIndex += 1
    }
    try previousText.write(to: backupURL, atomically: true, encoding: .utf8)
    return backupURL
  }

  nonisolated private static func orgRecoveryTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  nonisolated private static func entrySource(_ source: EntrySource, replacingText replacement: String) -> EntrySource {
    let normalized = normalizeLineEndings(replacement)
    return EntrySource(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.startLine + max(1, lineCount(in: normalized)),
      text: normalized,
      isSubtree: source.isSubtree,
      isEditable: source.isEditable
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

  nonisolated private static func sourceText(
    in source: EntrySource,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> String {
    let lines = normalizeLineEndings(source.text)
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
    return lines[startIndex..<endIndex].joined(separator: "\n")
  }

  nonisolated private static func sourceText(
    file: String,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> String {
    try sourceText(
      in: pageSource(file: file),
      startLine: startLine,
      endLineExclusive: endLineExclusive
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

  nonisolated private static func deletionRange(
    for block: OrgEditableBlock,
    in source: EntrySource
  ) throws -> (startLine: Int, endLineExclusive: Int) {
    guard case .heading = block.rendered else {
      return (block.startLine, block.endLineExclusive)
    }

    let lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let headingIndex = block.startLine - source.startLine
    guard headingIndex >= 0,
          headingIndex < lines.count,
          let level = headingLevel(lines[headingIndex])
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: block.startLine)
    }

    let endIndex = subtreeEndIndex(lines: lines, headingIndex: headingIndex, level: level)
    return (
      startLine: block.startLine,
      endLineExclusive: source.startLine + endIndex
    )
  }

  nonisolated private static func renderedTextSelectionPairs(
    _ fragments: [OrgSyntaxTextSelectionDocumentFragment],
    in blocks: [OrgEditableBlock]
  ) -> [(fragment: OrgSyntaxTextSelectionDocumentFragment, block: OrgEditableBlock)] {
    var seenBlockIDs = Set<String>()
    var pairs: [(fragment: OrgSyntaxTextSelectionDocumentFragment, block: OrgEditableBlock)] = []

    for fragment in fragments {
      guard let block = blocks.first(where: { $0.id == fragment.context.blockID })
        ?? blocks.first(where: {
          $0.startLine == fragment.context.startLine
            && $0.endLineExclusive == fragment.context.endLineExclusive
        })
      else {
        continue
      }
      guard seenBlockIDs.insert(block.id).inserted else { continue }
      pairs.append((fragment, block))
    }

    return pairs.sorted { lhs, rhs in
      if lhs.block.startLine != rhs.block.startLine {
        return lhs.block.startLine < rhs.block.startLine
      }
      return lhs.fragment.sourceRange.location < rhs.fragment.sourceRange.location
    }
  }

  nonisolated private static func renderedTextSelectionReplacement(
    pairs: [(fragment: OrgSyntaxTextSelectionDocumentFragment, block: OrgEditableBlock)],
    allBlocks: [OrgEditableBlock],
    in source: EntrySource,
    replacementText: String
  ) throws -> (
    startLine: Int,
    endLineExclusive: Int,
    replacement: String,
    expectedOriginal: String,
    updatedSource: EntrySource,
    caretSourceUTF16Offset: Int,
    coversWholeDocument: Bool
  ) {
    let sortedPairs = pairs.sorted { lhs, rhs in
      if lhs.block.startLine != rhs.block.startLine {
        return lhs.block.startLine < rhs.block.startLine
      }
      return lhs.fragment.sourceRange.location < rhs.fragment.sourceRange.location
    }
    guard let firstPair = sortedPairs.first,
          let lastPair = sortedPairs.last
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: source.startLine)
    }

    let coversWholeDocument = selectionCoversWholeRenderedTextDocument(
      pairs: sortedPairs,
      allBlocks: allBlocks
    )
    let startLine = coversWholeDocument ? source.startLine : firstPair.block.startLine
    let endLineExclusive = coversWholeDocument ? source.endLineExclusive : lastPair.block.endLineExclusive
    let normalizedReplacementText = normalizeLineEndings(replacementText)
    let replacementUTF16Length = (normalizedReplacementText as NSString).length
    let replacement: String
    let caretSourceUTF16Offset: Int

    if coversWholeDocument {
      replacement = normalizedReplacementText
      caretSourceUTF16Offset = replacementUTF16Length
    } else if sortedPairs.count == 1 {
      let rawText = sourceTextForSelectionFragment(firstPair.fragment, block: firstPair.block)
      let range = clampedRange(firstPair.fragment.sourceRange, in: rawText)
      replacement = replacingSelection(
        in: rawText,
        fragment: firstPair.fragment,
        replacementText: normalizedReplacementText
      )
      caretSourceUTF16Offset = firstPair.fragment.selectsEntireEditor
        ? replacementUTF16Length
        : range.location + replacementUTF16Length
    } else {
      let firstRawText = sourceTextForSelectionFragment(firstPair.fragment, block: firstPair.block)
      let lastRawText = sourceTextForSelectionFragment(lastPair.fragment, block: lastPair.block)
      let firstRange = clampedRange(firstPair.fragment.sourceRange, in: firstRawText)
      let lastRange = clampedRange(lastPair.fragment.sourceRange, in: lastRawText)
      let firstPrefix = firstPair.fragment.selectsEntireEditor
        ? ""
        : (firstRawText as NSString).substring(to: firstRange.location)
      let lastSuffix = lastPair.fragment.selectsEntireEditor
        ? ""
        : (lastRawText as NSString).substring(from: NSMaxRange(lastRange))
      let joined = firstPrefix + normalizedReplacementText + lastSuffix
      replacement = joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : joined
      caretSourceUTF16Offset = (firstPrefix as NSString).length + replacementUTF16Length
    }

    let expectedOriginal = try sourceText(
      in: source,
      startLine: startLine,
      endLineExclusive: endLineExclusive
    )
    let updatedSource = try replacingSourceRange(
      in: source,
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      replacement: replacement
    )
    return (
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      replacement: replacement,
      expectedOriginal: expectedOriginal,
      updatedSource: updatedSource,
      caretSourceUTF16Offset: caretSourceUTF16Offset,
      coversWholeDocument: coversWholeDocument
    )
  }

  nonisolated private static func editableSelection(
    for block: OrgEditableBlock,
    sourceUTF16Offset: Int
  ) -> NSRange {
    let prefixLength = editorToSourceUTF16Offset(for: block)
    let editableLength = max(0, (block.rawText as NSString).length - prefixLength)
    let location = min(max(0, sourceUTF16Offset - prefixLength), editableLength)
    return NSRange(location: location, length: 0)
  }

  nonisolated private static func editorToSourceUTF16Offset(for block: OrgEditableBlock) -> Int {
    guard case .listItem = block.rendered else { return 0 }
    return listPrefixUTF16Length(in: block.rawText)
  }

  nonisolated private static func listPrefixUTF16Length(in rawText: String) -> Int {
    guard let regex = try? NSRegularExpression(
      pattern: #"^\s*(?:[-+]|[0-9]+[.)])\s+(?:\[(?: |X|x|-)\]\s*)?"#
    ) else {
      return 0
    }
    let nsText = rawText as NSString
    let match = regex.firstMatch(in: rawText, range: NSRange(location: 0, length: nsText.length))
    guard let match,
          match.range.location == 0
    else {
      return 0
    }
    return match.range.length
  }

  nonisolated private static func selectionCoversWholeRenderedTextDocument(
    pairs: [(fragment: OrgSyntaxTextSelectionDocumentFragment, block: OrgEditableBlock)],
    allBlocks: [OrgEditableBlock]
  ) -> Bool {
    guard !pairs.isEmpty,
          pairs.allSatisfy({ $0.fragment.selectsEntireEditor })
    else {
      return false
    }

    let nonBlankBlocks = allBlocks.filter { block in
      if case .blank = block.rendered { return false }
      return true
    }
    guard !nonBlankBlocks.isEmpty,
          nonBlankBlocks.allSatisfy(isRenderedTextSelectionBlock)
    else {
      return false
    }

    let selectedBlockIDs = Set(pairs.map(\.block.id))
    return nonBlankBlocks.allSatisfy { selectedBlockIDs.contains($0.id) }
  }

  nonisolated private static func isRenderedTextSelectionBlock(_ block: OrgEditableBlock) -> Bool {
    switch block.rendered {
    case .heading, .paragraph, .listItem:
      return true
    default:
      return false
    }
  }

  nonisolated private static func replacingSelection(
    in rawText: String,
    fragment: OrgSyntaxTextSelectionDocumentFragment,
    replacementText: String
  ) -> String {
    if fragment.selectsEntireEditor {
      return replacementText
    }
    let range = clampedRange(fragment.sourceRange, in: rawText)
    let nsRawText = rawText as NSString
    return nsRawText.replacingCharacters(in: range, with: replacementText)
  }

  nonisolated private static func sourceTextForSelectionFragment(
    _ fragment: OrgSyntaxTextSelectionDocumentFragment,
    block: OrgEditableBlock
  ) -> String {
    let editorText = normalizeLineEndings(fragment.editorText)
    guard fragment.context.editorToSourceUTF16Offset > 0 else {
      return editorText
    }
    let blockRawText = normalizeLineEndings(block.rawText)
    let prefixLength = min(fragment.context.editorToSourceUTF16Offset, (blockRawText as NSString).length)
    return (blockRawText as NSString).substring(to: prefixLength) + editorText
  }

  nonisolated private static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
    let length = (text as NSString).length
    let location = min(max(0, range.location), length)
    return NSRange(location: location, length: min(max(0, range.length), length - location))
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

  nonisolated private static func replaceSourceRange(
    file: String,
    startLine: Int,
    endLineExclusive: Int,
    replacement: String,
    expectedOriginal: String? = nil,
    allowDestructiveReplacement: Bool = false
  ) throws {
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

    if let expectedOriginal {
      let currentOriginal = lines[startIndex..<endIndex].joined(separator: "\n")
      guard currentOriginal == normalizeLineEndings(expectedOriginal) else {
        throw WorkspaceEditError.fileChanged(file: file)
      }
    }

    let normalizedReplacement = normalizeLineEndings(replacement)
    let replacementLines = normalizedReplacement.isEmpty
      ? []
      : normalizedReplacement
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    lines.replaceSubrange(startIndex..<endIndex, with: replacementLines)

    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.isEmpty, !output.hasSuffix("\n") {
      output += "\n"
    }
    try writeOrgTextSafely(
      output,
      to: url,
      replacing: raw,
      operation: "source range edit",
      allowDestructiveReplacement: allowDestructiveReplacement
    )
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

      if nextText.isEmpty,
         let parsedCurrent = OrgEntryRenderer.parseEditable(currentText).first,
         case .listItem(let indent, let marker, let checkbox, _) = parsedCurrent.rendered {
        let prefix = continuedListPrefix(
          draft: currentText,
          fallbackMarker: marker,
          checkbox: checkbox
        )
        return SplitBlockPlan(
          replacement: currentText,
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: lineCount(in: currentText),
            displayLineOffset: lineCount(in: currentText),
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

      if nextText.isEmpty {
        return SplitBlockPlan(
          replacement: currentText.isEmpty ? nil : currentText,
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: currentText.isEmpty ? 0 : lineCount(in: currentText),
            displayLineOffset: currentText.isEmpty ? 0 : lineCount(in: currentText),
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
            insertionLineOffset: firstBlock.isEmpty ? 0 : lineCount(in: firstBlock),
            displayLineOffset: firstBlock.isEmpty ? 0 : lineCount(in: firstBlock),
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

  private func transientDraftBlock(
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
      block: transientDraftEditableBlock(
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

  nonisolated private static func isMergeablePreviousTextBlock(_ block: OrgEditableBlock) -> Bool {
    switch block.rendered {
    case .heading, .paragraph, .listItem:
      return true
    default:
      return false
    }
  }

  nonisolated private static func mergedTextBlockRawText(
    previous: OrgEditableBlock,
    current: OrgEditableBlock,
    currentDraft: String
  ) -> String? {
    guard isMergeablePreviousTextBlock(previous),
          let tail = mergeTailText(for: current, draft: currentDraft)
    else {
      return nil
    }

    let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    if case .heading = previous.rendered {
      return headingRawTextAppending(previous.rawText, tail: trimmedTail)
    }

    let head = normalizeLineEndings(previous.rawText).trimmingCharacters(in: .whitespacesAndNewlines)
    if head.isEmpty { return trimmedTail }
    if trimmedTail.isEmpty { return head }
    return "\(head) \(trimmedTail)"
  }

  nonisolated private static func mergeTailText(for block: OrgEditableBlock, draft: String) -> String? {
    let normalizedDraft = normalizeLineEndings(draft)
    switch block.rendered {
    case .heading:
      let firstLine = normalizedDraft.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? normalizedDraft
      let title = headingTitle(from: firstLine)
      return title.isEmpty ? normalizedDraft : title
    case .paragraph:
      return normalizedDraft
    case .listItem:
      return listItemBodyText(from: normalizedDraft)
    default:
      return nil
    }
  }

  nonisolated private static func listItemBodyText(from rawText: String) -> String {
    let firstLine = rawText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawText
    guard let regex = try? NSRegularExpression(pattern: #"^\s*(?:[-+*]|\d+[.)])\s+(?:\[[ Xx-]\]\s+)?"#) else {
      return rawText
    }
    let nsFirstLine = firstLine as NSString
    let fullRange = NSRange(location: 0, length: nsFirstLine.length)
    guard let match = regex.firstMatch(in: firstLine, range: fullRange),
          match.range.location == 0
    else {
      return rawText
    }
    let prefixLength = match.range.length
    let nsRawText = rawText as NSString
    guard prefixLength <= nsRawText.length else { return "" }
    return nsRawText.substring(from: prefixLength)
  }

  nonisolated private static func headingRawTextAppending(_ rawText: String, tail: String) -> String? {
    let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTail.isEmpty else {
      return normalizeLineEndings(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
    var body = nsFirst.substring(with: match.range(at: 2))
      .trimmingCharacters(in: .whitespaces)
    var tagsSuffix = ""
    if let tagRange = body.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      tagsSuffix = String(body[tagRange]).trimmingCharacters(in: .whitespaces)
      body.removeSubrange(tagRange)
      body = body.trimmingCharacters(in: .whitespaces)
    }

    let mergedBody = body.isEmpty ? trimmedTail : "\(body) \(trimmedTail)"
    lines[0] = "\(prefix)\(mergedBody)\(tagsSuffix.isEmpty ? "" : " \(tagsSuffix)")"
    return lines.joined(separator: "\n")
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
    updateMeetingInputMeter(force: true)
    meetingMeterTask = Task { [weak self] in
      while !Task.isCancelled {
        let shouldContinue = await MainActor.run { () -> Bool in
          guard let self, self.isRecordingMeeting else { return false }
          self.updateMeetingInputMeter()
          return true
        }
        guard shouldContinue else { return }
        try? await Task.sleep(nanoseconds: Self.meetingMeterPublishIntervalNanoseconds)
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

  private func updateMeetingInputMeter(force: Bool = false) {
    let snapshot = meetingRecorder.inputMeterSnapshot
    let systemSnapshot = meetingSystemAudioRecorder.inputMeterSnapshot
    publishMeetingMeterLevels(microphone: snapshot, systemAudio: systemSnapshot, force: force)
  }

  private func publishMeetingMeterLevels(
    microphone: MeetingInputMeterSnapshot,
    systemAudio: MeetingInputMeterSnapshot,
    force: Bool
  ) {
    publishMeetingMeterLevel(current: &meetingInputAverageLevel, next: microphone.averageLevel, force: force)
    publishMeetingMeterLevel(current: &meetingInputPeakLevel, next: microphone.peakLevel, force: force)
    publishMeetingMeterLevel(current: &meetingSystemAudioAverageLevel, next: systemAudio.averageLevel, force: force)
    publishMeetingMeterLevel(current: &meetingSystemAudioPeakLevel, next: systemAudio.peakLevel, force: force)
  }

  private func publishMeetingMeterLevel(current: inout Double, next: Double, force: Bool) {
    guard force || Self.shouldPublishMeetingMeterLevelChange(current: current, next: next) else { return }
    current = next
  }

  nonisolated static func shouldPublishMeetingMeterLevelChange(current: Double, next: Double) -> Bool {
    if current == next { return false }
    if current == 0 || next == 0 { return true }
    if current >= 0.95 || next >= 0.95 { return true }
    return abs(current - next) >= meetingMeterPublishThreshold
  }

  private func startOpenClawVoiceMetering() {
    openClawVoiceMeterTask?.cancel()
    updateOpenClawVoiceMeter()
    openClawVoiceMeterTask = Task { [weak self] in
      while !Task.isCancelled {
        let shouldContinue = await MainActor.run { () -> Bool in
          guard let self, self.isRecordingOpenClawVoiceNote else { return false }
          self.updateOpenClawVoiceMeter()
          return true
        }
        guard shouldContinue else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  private func stopOpenClawVoiceMetering() {
    openClawVoiceMeterTask?.cancel()
    openClawVoiceMeterTask = nil
    openClawVoiceAverageLevel = 0
    openClawVoicePeakLevel = 0
  }

  private func updateOpenClawVoiceMeter() {
    let snapshot = openClawVoiceRecorder.inputMeterSnapshot
    openClawVoiceAverageLevel = snapshot.averageLevel
    openClawVoicePeakLevel = snapshot.peakLevel
  }

  private func startMeetingTranscriptionProgress(title: String, audioDuration: TimeInterval?) -> UUID {
    meetingTranscriptionProgressTask?.cancel()
    let id = UUID()
    meetingTranscriptionProgressID = id
    meetingTranscriptionProgressTitle = title
    meetingTranscriptionStartedAt = Date()
    meetingTranscriptionEstimatedDuration = Self.estimatedMeetingTranscriptionDuration(for: audioDuration)
    updateMeetingTranscriptionProgress()
    meetingTranscriptionProgressTask = Task { [weak self] in
      while !Task.isCancelled {
        let shouldContinue = await MainActor.run { () -> Bool in
          guard let self,
                self.isProcessingMeeting,
                self.meetingTranscriptionProgressID == id
          else { return false }
          self.updateMeetingTranscriptionProgress()
          return true
        }
        guard shouldContinue else { return }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
    return id
  }

  private func stopMeetingTranscriptionProgress(id: UUID?) {
    if let id, meetingTranscriptionProgressID != id {
      return
    }
    meetingTranscriptionProgressTask?.cancel()
    meetingTranscriptionProgressTask = nil
    meetingTranscriptionProgressID = nil
    meetingTranscriptionProgressTitle = ""
    meetingTranscriptionStartedAt = nil
    meetingTranscriptionEstimatedDuration = 120
    meetingTranscriptionProgress = 0
    meetingTranscriptionElapsedText = ""
  }

  private func updateMeetingTranscriptionProgress() {
    let elapsed = meetingTranscriptionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    let progress = Self.meetingTranscriptionProgress(
      elapsed: elapsed,
      estimatedDuration: meetingTranscriptionEstimatedDuration
    )
    meetingTranscriptionProgress = progress
    meetingTranscriptionElapsedText = Self.openClawVoiceTranscriptionElapsedText(elapsed: elapsed)
    guard !meetingTranscriptionProgressTitle.isEmpty, !isRecordingMeeting else { return }
    meetingStatusText = "Transcribing \(meetingTranscriptionProgressTitle) locally... \(Int(progress * 100))%"
  }

  nonisolated static func estimatedMeetingTranscriptionDuration(for audioDuration: TimeInterval?) -> TimeInterval {
    guard let audioDuration, audioDuration > 0 else { return 120 }
    return min(3_600, max(30, audioDuration * 2))
  }

  nonisolated static func meetingTranscriptionProgress(
    elapsed: TimeInterval,
    estimatedDuration: TimeInterval
  ) -> Double {
    guard estimatedDuration > 0 else { return 0 }
    return min(0.95, max(0.02, elapsed / estimatedDuration))
  }

  private func startOpenClawVoiceTranscriptionProgress(audioDuration: TimeInterval) {
    openClawVoiceTranscriptionProgressTask?.cancel()
    openClawVoiceTranscriptionStartedAt = Date()
    openClawVoiceTranscriptionEstimatedDuration = Self.estimatedOpenClawVoiceTranscriptionDuration(for: audioDuration)
    updateOpenClawVoiceTranscriptionProgress()
    openClawVoiceTranscriptionProgressTask = Task { [weak self] in
      while !Task.isCancelled {
        let shouldContinue = await MainActor.run { () -> Bool in
          guard let self, self.isTranscribingOpenClawVoiceNote else { return false }
          self.updateOpenClawVoiceTranscriptionProgress()
          return true
        }
        guard shouldContinue else { return }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
  }

  private func stopOpenClawVoiceTranscriptionProgress() {
    openClawVoiceTranscriptionProgressTask?.cancel()
    openClawVoiceTranscriptionProgressTask = nil
    openClawVoiceTranscriptionStartedAt = nil
    openClawVoiceTranscriptionEstimatedDuration = 8
    openClawVoiceTranscriptionProgress = 0
    openClawVoiceTranscriptionElapsedText = ""
  }

  private func updateOpenClawVoiceTranscriptionProgress() {
    let elapsed = openClawVoiceTranscriptionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    let progress = Self.openClawVoiceTranscriptionProgress(
      elapsed: elapsed,
      estimatedDuration: openClawVoiceTranscriptionEstimatedDuration
    )
    openClawVoiceTranscriptionProgress = progress
    openClawVoiceTranscriptionElapsedText = Self.openClawVoiceTranscriptionElapsedText(elapsed: elapsed)
    openClawVoiceStatusText = "Transcribing OpenClaw dictation locally... \(Int(progress * 100))%"
    openClawStatusText = openClawVoiceStatusText
  }

  nonisolated static func estimatedOpenClawVoiceTranscriptionDuration(for audioDuration: TimeInterval) -> TimeInterval {
    min(180, max(8, audioDuration * 4))
  }

  nonisolated static func openClawVoiceTranscriptionProgress(
    elapsed: TimeInterval,
    estimatedDuration: TimeInterval
  ) -> Double {
    guard estimatedDuration > 0 else { return 0 }
    return min(0.95, max(0.02, elapsed / estimatedDuration))
  }

  nonisolated static func openClawVoiceTranscriptionElapsedText(elapsed: TimeInterval) -> String {
    let seconds = max(0, Int(elapsed.rounded(.down)))
    if seconds < 60 {
      return "\(seconds)s"
    }
    return "\(seconds / 60)m \(seconds % 60)s"
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

  private func transcribeAudioForOpenClawVoiceNote(_ audioURL: URL) async -> MeetingTranscriptResult {
    await transcribeAudioForMeeting(audioURL)
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
    Task { await refreshOpenClawThreads(showsLoading: false) }
  }

  private func beginMeetingProcessing(paths: MeetingArtifactPaths, status: String) {
    let processingID = Self.meetingProcessingID(for: paths)
    activeMeetingProcessingIDs.insert(processingID)
    activeMeetingProcessingItems[processingID] = MeetingProcessingItem(
      id: processingID,
      title: paths.title,
      status: status,
      startedAt: Date()
    )
    activeMeetingProcessingCount = activeMeetingProcessingIDs.count
    publishMeetingProcessingItems()
    if !isRecordingMeeting {
      meetingStatusText = status
    }
    statusText = status
  }

  func beginMeetingProcessingForTesting(paths: MeetingArtifactPaths, status: String) {
    beginMeetingProcessing(paths: paths, status: status)
  }

  private func endMeetingProcessing(paths: MeetingArtifactPaths) {
    let processingID = Self.meetingProcessingID(for: paths)
    activeMeetingProcessingIDs.remove(processingID)
    activeMeetingProcessingItems.removeValue(forKey: processingID)
    activeMeetingProcessingCount = activeMeetingProcessingIDs.count
    publishMeetingProcessingItems()
  }

  private func reconcileMeetingProcessingState(with items: [MeetingWorkspaceItem]) {
    guard isProcessingMeeting else { return }

    let completedIDs = Set(items.compactMap { item -> String? in
      guard item.transcriptionStatus?.lowercased() == MeetingTranscriptionStatus.complete.rawValue else {
        return nil
      }
      return Self.meetingProcessingID(for: item)
    })

    if !activeMeetingProcessingIDs.isEmpty {
      for completedID in completedIDs {
        activeMeetingProcessingIDs.remove(completedID)
        activeMeetingProcessingItems.removeValue(forKey: completedID)
      }
      activeMeetingProcessingCount = activeMeetingProcessingIDs.count
      publishMeetingProcessingItems()
      if activeMeetingProcessingIDs.isEmpty {
        clearMeetingProcessingState()
      }
    } else if let staleTitle = Self.transcribingMeetingTitle(fromStatus: meetingStatusText),
              items.contains(where: { item in
                item.transcriptionStatus?.lowercased() == MeetingTranscriptionStatus.complete.rawValue
                  && Self.normalizedMeetingProcessingTitle(item.title) == Self.normalizedMeetingProcessingTitle(staleTitle)
              }) {
      clearMeetingProcessingState()
    }

    if !isProcessingMeeting,
       !isRecordingMeeting,
       meetingStatusText.lowercased().hasPrefix("transcribing ") {
      if let latest = items.first {
        meetingStatusText = "\(items.count) meeting\(items.count == 1 ? "" : "s"); latest: \(Org2Display.cleanInline(latest.title))"
      } else {
        meetingStatusText = Self.defaultMeetingStatusText()
      }
    }
  }

  nonisolated private static func normalizedMeetingProcessingTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  nonisolated private static func meetingProcessingID(for paths: MeetingArtifactPaths) -> String {
    paths.noteURL.standardizedFileURL.path
  }

  nonisolated private static func meetingProcessingID(for item: MeetingWorkspaceItem) -> String {
    URL(fileURLWithPath: item.file).standardizedFileURL.path
  }

  private func clearMeetingProcessingState() {
    activeMeetingProcessingIDs = []
    activeMeetingProcessingItems = [:]
    activeMeetingProcessingCount = 0
    isProcessingMeeting = false
    processingMeetings = []
    stopMeetingTranscriptionProgress(id: nil)
  }

  private func publishMeetingProcessingItems() {
    processingMeetings = activeMeetingProcessingItems.values.sorted {
      if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  nonisolated private static func transcribingMeetingTitle(fromStatus status: String) -> String? {
    let prefix = "Transcribing "
    let suffix = " locally..."
    guard status.hasPrefix(prefix), status.hasSuffix(suffix) else { return nil }
    let start = status.index(status.startIndex, offsetBy: prefix.count)
    let end = status.index(status.endIndex, offsetBy: -suffix.count)
    let title = String(status[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }

  private func meetingArtifactURLs(for meeting: MeetingWorkspaceItem, corpusRoot: URL) -> [URL] {
    var urls: [URL] = [URL(fileURLWithPath: meeting.file)]
    for artifact in [meeting.audioArtifact, meeting.systemAudioArtifact, meeting.transcriptArtifact].compactMap(\.self) {
      urls.append(url(forMeetingArtifact: artifact, corpusRoot: corpusRoot))
    }
    var seen: Set<String> = []
    return urls.filter { url in
      let key = url.standardizedFileURL.path
      guard !seen.contains(key) else { return false }
      seen.insert(key)
      return true
    }
  }

  private func url(forMeetingArtifact artifact: String, corpusRoot: URL) -> URL {
    if artifact.hasPrefix("/") {
      return URL(fileURLWithPath: artifact)
    }
    return corpusRoot.appendingPathComponent(artifact)
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
    endLineExclusive: Int,
    allowDestructiveReplacement: Bool = false
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
    try writeOrgTextSafely(
      output,
      to: url,
      replacing: raw,
      operation: "source range delete",
      allowDestructiveReplacement: allowDestructiveReplacement
    )
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
    try writeOrgTextSafely(
      output,
      to: url,
      replacing: raw,
      operation: "source range swap"
    )
  }

  nonisolated private static func scanAssignedWorkItems(files: [CorpusFile]) throws -> [AssignedWorkItem] {
    try scanTodoHeadings(files: files).compactMap { heading in
      guard let assignee = heading.properties["ASSIGNEE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !assignee.isEmpty
      else {
        return nil
      }
      let status = heading.properties["STATUS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return AssignedWorkItem(
        file: heading.file,
        line: heading.line,
        headline: heading.headline,
        todo: heading.todo,
        assignee: assignee,
        status: status?.isEmpty == false ? status! : "ready",
        assignedAt: heading.properties["ASSIGNED_AT"],
        lastAgentUpdate: heading.properties["LAST_AGENT_UPDATE"],
        tags: heading.tags,
        properties: heading.properties
      )
    }.sorted {
      if $0.assignee == $1.assignee {
        if $0.status == $1.status {
          return $0.headline.localizedStandardCompare($1.headline) == .orderedAscending
        }
        return $0.status.localizedStandardCompare($1.status) == .orderedAscending
      }
      return $0.assignee.localizedStandardCompare($1.assignee) == .orderedAscending
    }
  }

  nonisolated private static func scanTodoHeadings(files: [CorpusFile]) throws -> [SimilarTodoCandidate] {
    var candidates: [SimilarTodoCandidate] = []
    let allowedExtensions = Set(["org", "org2"])
    for file in files {
      guard allowedExtensions.contains(URL(fileURLWithPath: file.path).pathExtension.lowercased()),
            let raw = try? String(contentsOf: URL(fileURLWithPath: file.path), encoding: .utf8)
      else {
        continue
      }
      let lines = normalizeLineEndings(raw)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      for (index, line) in lines.enumerated() {
        guard let heading = parseTodoHeading(line) else { continue }
        let properties = scanPropertyDrawer(lines: lines, afterHeadingIndex: index)
        candidates.append(SimilarTodoCandidate(
          file: file.path,
          line: index + 1,
          headline: heading.title,
          todo: heading.todo,
          tags: heading.tags,
          properties: properties,
          score: 1
        ))
      }
    }
    return candidates
  }

  nonisolated private static func parseTodoHeading(_ line: String) -> (todo: String, title: String, tags: [String])? {
    guard let regex = try? NSRegularExpression(pattern: #"^\*+\s+(.+)$"#) else { return nil }
    let nsLine = line as NSString
    let range = NSRange(location: 0, length: nsLine.length)
    guard let match = regex.firstMatch(in: line, range: range) else { return nil }
    var rest = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    var tags: [String] = []
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      let rawTags = String(rest[tagRange]).trimmingCharacters(in: .whitespacesAndNewlines)
      tags = rawTags
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.isEmpty }
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let first = tokens.first,
          allHeadingTodoKeywords.contains(first.uppercased())
    else {
      return nil
    }
    let todo = first.uppercased()
    tokens.removeFirst()
    if let first = tokens.first,
       first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }
    let title = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    return (todo, title, tags)
  }

  nonisolated private static func pairedApprovalActionTitleCandidates(properties: [String: String]) -> [String] {
    [
      "PAIRED_SEND_TODO",
      "PAIRED_AGENT_TODO",
      "PAIRED_TODO",
      "NEXT_AGENT_TODO",
      "SEND_TODO"
    ]
    .compactMap { key in
      let title = properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      return title?.isEmpty == false ? title : nil
    }
  }

  nonisolated private static func approvedAgentActionTitle(for title: String) -> String {
    let clean = Org2Display.cleanInline(title)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    guard !clean.isEmpty else { return "Continue approved task" }

    for prefix in ["Approve "] {
      if clean.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
        let rest = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? "Continue approved task" : "Send approved \(rest)"
      }
    }
    return "Continue approved \(clean)"
  }

  nonisolated private static func approvedAgentActionStatus(for title: String) -> String {
    normalizedApprovalActionTitle(title).hasPrefix("send approved ")
      ? "approved-to-send"
      : "ready-for-agent"
  }

  nonisolated private static func isApprovedAgentActionTitle(_ title: String) -> Bool {
    let normalized = normalizedApprovalActionTitle(title)
    return normalized.hasPrefix("send approved ") || normalized.hasPrefix("continue approved ")
  }

  nonisolated private static func pairedApprovedAgentActionTarget(
    lines: [String],
    file: String,
    approvalHeadingIndex: Int,
    approvalProperties: [String: String],
    approvalTitle: String
  ) -> HeadlineMutationTarget? {
    var candidateTitles = pairedApprovalActionTitleCandidates(properties: approvalProperties)
    candidateTitles.append(approvedAgentActionTitle(for: approvalTitle))
    if let existing = findExistingApprovedAgentAction(
      lines: lines,
      file: file,
      excludingHeadingIndex: approvalHeadingIndex,
      candidateTitles: candidateTitles
    ) {
      return existing
    }

    guard let approvalLevel = headingLevel(lines[approvalHeadingIndex]), approvalLevel > 1 else {
      return nil
    }

    var index = approvalHeadingIndex - 1
    while index >= 0 {
      guard let level = headingLevel(lines[index]) else {
        index -= 1
        continue
      }
      if level < approvalLevel {
        let title = headingTitle(from: lines[index])
        guard isApprovedAgentActionTitle(title) else { return nil }
        return HeadlineMutationTarget(file: file, line: index + 1, title: title)
      }
      index -= 1
    }
    return nil
  }

  nonisolated private static func findExistingApprovedAgentAction(
    lines: [String],
    file: String,
    excludingHeadingIndex excludedIndex: Int,
    candidateTitles: [String]
  ) -> HeadlineMutationTarget? {
    let normalizedCandidates = Set(candidateTitles
      .map(normalizedApprovalActionTitle)
      .filter { !$0.isEmpty })
    guard !normalizedCandidates.isEmpty else { return nil }

    for (index, line) in lines.enumerated() where index != excludedIndex {
      guard let heading = parseTodoHeading(line) else { continue }
      let normalizedTitle = normalizedApprovalActionTitle(heading.title)
      guard normalizedCandidates.contains(normalizedTitle) else { continue }
      return HeadlineMutationTarget(file: file, line: index + 1, title: heading.title)
    }
    return nil
  }

  nonisolated private static func hasSentEvidence(in properties: [String: String]) -> Bool {
    for key in ["SENT_AT", "LAST_SENT_AT", "GMAIL_SENT_MESSAGE_ID", "FOLLOWUP_SENT_AT"] {
      if properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        return true
      }
    }
    if let status = properties["STATUS"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
       ["sent", "bounced", "bounce", "contact-route", "contact-route-needed", "contact-route-missing"].contains(status) {
      return true
    }
    return false
  }

  nonisolated private static func normalizedApprovalActionTitle(_ title: String) -> String {
    Org2Display.cleanInline(title)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
  }

  nonisolated private static func sanitizeOrgPropertyValue(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @MainActor
  private static func promptForApprovalRejection() -> ApprovalRejectionChoice? {
    let alert = NSAlert()
    alert.messageText = "Reject Approval"
    alert.informativeText = "Choose the final TODO state and record why this approval was rejected."
    alert.addButton(withTitle: "Reject")
    alert.addButton(withTitle: "Cancel")

    let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 124))

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false

    let statusLabel = NSTextField(labelWithString: "Final TODO state")
    statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    statusLabel.textColor = .secondaryLabelColor

    let statusPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    statusPopup.addItem(withTitle: "Canceled")
    statusPopup.addItem(withTitle: "Done")
    statusPopup.translatesAutoresizingMaskIntoConstraints = false

    let reasonField = NSTextField()
    reasonField.placeholderString = "Reason"
    reasonField.translatesAutoresizingMaskIntoConstraints = false
    reasonField.lineBreakMode = .byWordWrapping
    reasonField.maximumNumberOfLines = 4

    accessoryView.addSubview(stack)
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(statusPopup)
    stack.addArrangedSubview(reasonField)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: accessoryView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: accessoryView.bottomAnchor),
      statusPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
      statusPopup.heightAnchor.constraint(equalToConstant: 28),
      reasonField.widthAnchor.constraint(equalTo: stack.widthAnchor),
      reasonField.heightAnchor.constraint(equalToConstant: 50),
    ])
    alert.accessoryView = accessoryView

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let reason = reasonField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty else { return nil }
    let status: TodoEditStatus = statusPopup.indexOfSelectedItem == 1 ? .done : .canceled
    return ApprovalRejectionChoice(endStatus: status, reason: reason)
  }

  nonisolated private static func scanPropertyDrawer(lines: [String], afterHeadingIndex headingIndex: Int) -> [String: String] {
    var index = headingIndex + 1
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("*") { return [:] }
      if trimmed == ":PROPERTIES:" { break }
      index += 1
    }
    guard index < lines.count else { return [:] }
    index += 1
    var properties: [String: String] = [:]
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == ":END:" { break }
      if trimmed.hasPrefix(":"),
         let separator = trimmed.dropFirst().firstIndex(of: ":") {
        let keyStart = trimmed.index(after: trimmed.startIndex)
        let key = String(trimmed[keyStart..<separator]).uppercased()
        let valueStart = trimmed.index(after: separator)
        let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
          properties[key] = value
        }
      }
      index += 1
    }
    return properties
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

  nonisolated static func scanRecoverableMeetingRecordings(corpusRoot: URL) throws -> [RecoverableMeetingRecording] {
    let fileManager = FileManager.default
    let meetingsDirectory = corpusRoot.appendingPathComponent("meetings", isDirectory: true)
    guard isDirectoryURL(meetingsDirectory),
          let enumerator = fileManager.enumerator(
            at: meetingsDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
          )
    else {
      return []
    }

    let audioExtensions = Set(["aif", "aiff", "flac", "m4a", "mp3", "ogg", "wav"])
    var primaryAudioFiles: [URL] = []
    var systemAudioFilesByBaseName: [String: URL] = [:]

    for case let fileURL as URL in enumerator {
      let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      let ext = fileURL.pathExtension.lowercased()
      guard audioExtensions.contains(ext) else { continue }
      let baseName = fileURL.deletingPathExtension().lastPathComponent
      if let systemRange = baseName.range(of: ".system", options: [.caseInsensitive, .backwards]),
         systemRange.upperBound == baseName.endIndex {
        let primaryBaseName = String(baseName[..<systemRange.lowerBound])
        systemAudioFilesByBaseName[primaryBaseName] = fileURL
      } else {
        primaryAudioFiles.append(fileURL)
      }
    }

    var recoverable: [RecoverableMeetingRecording] = []
    for audioURL in primaryAudioFiles {
      let baseName = audioURL.deletingPathExtension().lastPathComponent
      let noteURL = meetingsDirectory.appendingPathComponent("\(baseName).org2")
      let transcriptURL = meetingsDirectory.appendingPathComponent("\(baseName).transcript.org2")
      guard !fileManager.fileExists(atPath: noteURL.path),
            !fileManager.fileExists(atPath: transcriptURL.path)
      else {
        continue
      }

      let values = try? audioURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
      let parsed = recoverableMeetingTitleAndDate(
        baseName: baseName,
        fallbackDate: values?.creationDate ?? values?.contentModificationDate ?? Date()
      )
      let systemAudioURL = systemAudioFilesByBaseName[baseName]
      let paths = MeetingArtifactPaths(
        meetingID: UUID().uuidString.lowercased(),
        title: parsed.title,
        recordedAt: parsed.recordedAt,
        baseName: baseName,
        noteURL: noteURL,
        audioURL: audioURL,
        systemAudioURL: systemAudioURL ?? meetingsDirectory.appendingPathComponent("\(baseName).system.m4a"),
        transcriptURL: transcriptURL
      )
      recoverable.append(RecoverableMeetingRecording(
        paths: paths,
        duration: MeetingArtifactWriter.audioDuration(at: audioURL),
        systemAudioURL: systemAudioURL,
        systemAudioCaptureError: nil,
        captureSources: systemAudioURL == nil ? "recovered_audio" : "recovered_audio, system_audio"
      ))
    }

    return recoverable.sorted {
      if $0.paths.recordedAt != $1.paths.recordedAt {
        return $0.paths.recordedAt > $1.paths.recordedAt
      }
      return $0.paths.title.localizedCaseInsensitiveCompare($1.paths.title) == .orderedAscending
    }
  }

  nonisolated private static func recoverableMeetingTitleAndDate(
    baseName: String,
    fallbackDate: Date
  ) -> (title: String, recordedAt: Date) {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"

    if baseName.count > 18 {
      let timestampEnd = baseName.index(baseName.startIndex, offsetBy: 17)
      let timestamp = String(baseName[..<timestampEnd])
      let separator = baseName[timestampEnd]
      if separator == "-",
         let recordedAt = formatter.date(from: timestamp) {
        let titleSlugStart = baseName.index(after: timestampEnd)
        let title = titleFromMeetingSlug(String(baseName[titleSlugStart...]))
        return (title, recordedAt)
      }
    }

    return (titleFromMeetingSlug(baseName), fallbackDate)
  }

  nonisolated private static func titleFromMeetingSlug(_ slug: String) -> String {
    let words = slug
      .split(separator: "-", omittingEmptySubsequences: true)
      .map(String.init)
    let title = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Recovered Meeting" : title.capitalized
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
          break
        case "ID":
          break
        case "ROAM_ALIASES", "ROAM_ALIAS":
          if currentHeading != nil {
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
          if currentHeading != nil, currentHeading?.idValue == nil {
            currentHeading?.idValue = property.value
          }
        case "ROAM_ALIASES", "ROAM_ALIAS":
          if currentHeading != nil {
            currentHeading?.aliases.append(contentsOf: parseRoamAliases(property.value))
          }
        default:
          break
        }
      }
    }

    flushCurrentHeading()
    if let fileNode = scanRoamFileNode(file: file, lines: lines) {
      nodes.append(fileNode)
    }
    return nodes
  }

  nonisolated private static func scanRoamFileNode(file: CorpusFile) -> OrgRoamNodeReference? {
    guard let raw = try? String(contentsOf: URL(fileURLWithPath: file.path), encoding: .utf8) else {
      return nil
    }

    let lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    return scanRoamFileNode(file: file, lines: lines)
  }

  nonisolated private static func scanRoamFileNode(file: CorpusFile, lines: [String]) -> OrgRoamNodeReference? {
    var fileTitle: (value: String, line: Int)?
    var fileAliases: [String] = []
    var fileID: String?

    for (index, line) in lines.enumerated() {
      if roamHeadingTitle(line) != nil {
        break
      }
      let lineNumber = index + 1
      if let keyword = roamKeyword(line) {
        switch keyword.key {
        case "TITLE":
          if fileTitle == nil {
            fileTitle = (Org2Display.cleanInline(keyword.value), lineNumber)
          }
        case "ID":
          fileID = fileID ?? keyword.value
        case "ROAM_ALIASES", "ROAM_ALIAS":
          fileAliases.append(contentsOf: parseRoamAliases(keyword.value))
        default:
          break
        }
        continue
      }

      if let property = roamProperty(line) {
        switch property.key {
        case "ID":
          fileID = fileID ?? property.value
        case "ROAM_ALIASES", "ROAM_ALIAS":
          fileAliases.append(contentsOf: parseRoamAliases(property.value))
        default:
          break
        }
      }
    }

    let fallbackFileTitle = Self.titleFromFileStem(URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent)
    let resolvedFileTitle = fileTitle?.value ?? fallbackFileTitle
    return OrgRoamNodeReference(
      idValue: fileID,
      title: resolvedFileTitle,
      aliases: fileAliases,
      file: file.path,
      line: fileTitle?.line ?? 1,
      isPageNode: true
    )
  }

  nonisolated private static func titleFromFileStem(_ stem: String) -> String {
    stem
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
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

  nonisolated private static func openClawCorpusSnapshot(corpusRoot: URL) throws -> OpenClawCorpusSnapshot {
    let root = corpusRoot.standardizedFileURL
    let rootPath = root.path
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return OpenClawCorpusSnapshot(rootPath: rootPath, files: [:])
    }

    var files: [String: OpenClawSnapshotFile] = [:]
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
        continue
      }
      if values.isDirectory == true {
        if shouldSkipDefaultCorpusDirectory(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }

      guard values.isRegularFile == true,
            openClawChangeSnapshotAllowedExtensions.contains(url.pathExtension.lowercased()),
            let byteCount = values.fileSize,
            byteCount <= openClawChangeSnapshotMaxFileBytes,
            let data = try? Data(contentsOf: url),
            !data.contains(0),
            let text = String(data: data, encoding: .utf8)
      else {
        continue
      }

      let path = url.standardizedFileURL.path
      let relativePath = path.hasPrefix(rootPath + "/")
        ? String(path.dropFirst(rootPath.count + 1))
        : url.lastPathComponent
      files[relativePath] = OpenClawSnapshotFile(text: text)
    }

    return OpenClawCorpusSnapshot(rootPath: rootPath, files: files)
  }

  nonisolated private static func openClawCorpusSnapshot(
    corpusRoot: URL,
    relativePaths: Set<String>
  ) throws -> OpenClawCorpusSnapshot {
    let root = corpusRoot.standardizedFileURL
    let rootPath = root.path
    guard !relativePaths.isEmpty else {
      return OpenClawCorpusSnapshot(rootPath: rootPath, files: [:])
    }

    var files: [String: OpenClawSnapshotFile] = [:]
    for relativePath in relativePaths {
      guard let file = try openClawSnapshotFile(corpusRoot: root, relativePath: relativePath) else {
        continue
      }
      files[relativePath] = file
    }
    return OpenClawCorpusSnapshot(rootPath: rootPath, files: files)
  }

  nonisolated private static func openClawSnapshotFile(
    corpusRoot root: URL,
    relativePath: String
  ) throws -> OpenClawSnapshotFile? {
    let rootPath = root.standardizedFileURL.path
    let cleanRelativePath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanRelativePath.isEmpty,
          cleanRelativePath != ".",
          !cleanRelativePath.hasPrefix("/"),
          !cleanRelativePath.split(separator: "/").contains(where: { $0 == ".." })
    else {
      return nil
    }

    let url = root
      .appendingPathComponent(cleanRelativePath, isDirectory: false)
      .standardizedFileURL
    guard url.path.hasPrefix(rootPath + "/") else { return nil }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true,
          openClawChangeSnapshotAllowedExtensions.contains(url.pathExtension.lowercased()),
          let byteCount = values.fileSize,
          byteCount <= openClawChangeSnapshotMaxFileBytes,
          let data = try? Data(contentsOf: url),
          !data.contains(0),
          let text = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return OpenClawSnapshotFile(text: text)
  }

  nonisolated private static func openClawChangeSummary(
    before: OpenClawCorpusSnapshot,
    after: OpenClawCorpusSnapshot
  ) -> OpenClawCorpusChangeSummary? {
    let changedFiles = Set(before.files.keys)
      .union(after.files.keys)
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .compactMap { relativePath -> OpenClawCorpusFileChange? in
        switch (before.files[relativePath], after.files[relativePath]) {
        case let (oldFile?, newFile?):
          guard oldFile.text != newFile.text else { return nil }
          let counts = openClawLineChangeCounts(before: oldFile.text, after: newFile.text)
          return OpenClawCorpusFileChange(
            relativePath: relativePath,
            status: .modified,
            insertions: counts.insertions,
            deletions: counts.deletions
          )
        case let (nil, newFile?):
          return OpenClawCorpusFileChange(
            relativePath: relativePath,
            status: .created,
            insertions: openClawTextLines(newFile.text).count,
            deletions: 0
          )
        case let (oldFile?, nil):
          return OpenClawCorpusFileChange(
            relativePath: relativePath,
            status: .deleted,
            insertions: 0,
            deletions: openClawTextLines(oldFile.text).count
          )
        case (nil, nil):
          return nil
        }
      }

    return changedFiles.isEmpty ? nil : OpenClawCorpusChangeSummary(files: changedFiles)
  }

  nonisolated private static func openClawLineChangeCounts(before oldText: String, after newText: String) -> (insertions: Int, deletions: Int) {
    let oldLines = openClawTextLines(oldText)
    let newLines = openClawTextLines(newText)
    guard !oldLines.isEmpty || !newLines.isEmpty else {
      return (0, 0)
    }

    let canRunExactDiff = oldLines.count <= 1_000_000 / max(1, newLines.count)
    let commonLineCount = canRunExactDiff
      ? openClawLongestCommonSubsequenceCount(oldLines, newLines)
      : openClawPrefixSuffixCommonLineCount(oldLines, newLines)
    return (
      insertions: max(0, newLines.count - commonLineCount),
      deletions: max(0, oldLines.count - commonLineCount)
    )
  }

  nonisolated private static func openClawTextLines(_ text: String) -> [String] {
    let normalized = normalizeLineEndings(text)
    guard !normalized.isEmpty else { return [] }
    var lines = normalized
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    if normalized.hasSuffix("\n") {
      lines.removeLast()
    }
    return lines
  }

  nonisolated private static func openClawLongestCommonSubsequenceCount(_ oldLines: [String], _ newLines: [String]) -> Int {
    guard !oldLines.isEmpty, !newLines.isEmpty else { return 0 }
    var previous = Array(repeating: 0, count: newLines.count + 1)
    var current = previous

    for oldLine in oldLines {
      current[0] = 0
      for (newIndex, newLine) in newLines.enumerated() {
        if oldLine == newLine {
          current[newIndex + 1] = previous[newIndex] + 1
        } else {
          current[newIndex + 1] = max(previous[newIndex + 1], current[newIndex])
        }
      }
      swap(&previous, &current)
    }

    return previous[newLines.count]
  }

  nonisolated private static func openClawPrefixSuffixCommonLineCount(_ oldLines: [String], _ newLines: [String]) -> Int {
    var prefixCount = 0
    while prefixCount < oldLines.count,
          prefixCount < newLines.count,
          oldLines[prefixCount] == newLines[prefixCount] {
      prefixCount += 1
    }

    var oldEnd = oldLines.count
    var newEnd = newLines.count
    var suffixCount = 0
    while oldEnd > prefixCount,
          newEnd > prefixCount,
          oldLines[oldEnd - 1] == newLines[newEnd - 1] {
      oldEnd -= 1
      newEnd -= 1
      suffixCount += 1
    }

    return prefixCount + suffixCount
  }

  nonisolated private static func scanCorpusFiles(corpusRoot: URL) throws -> [CorpusFile] {
    let root = corpusRoot.standardizedFileURL
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
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
        if shouldSkipDefaultCorpusDirectory(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }

      guard values.isRegularFile == true,
            allowedExtensions.contains(url.pathExtension.lowercased()),
            !isDefaultIgnoredSyncArtifactPath(url.path)
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

  nonisolated private static let defaultIgnoredCorpusDirectories = Set([
    ".git",
    ".hg",
    ".svn",
    ".stversions",
    ".trash",
    ".org2",
    "node_modules",
    "dist",
    "build",
    ".build",
    "DerivedData",
    "sync-conflicts"
  ])

  nonisolated private static func shouldSkipDefaultCorpusDirectory(_ name: String) -> Bool {
    name.hasPrefix(".") || defaultIgnoredCorpusDirectories.contains(name)
  }

  nonisolated private static func hasDefaultIgnoredCorpusPathComponent(_ path: String) -> Bool {
    path.split(separator: "/").contains { component in
      defaultIgnoredCorpusDirectories.contains(String(component))
    }
  }

  nonisolated private static func isDefaultIgnoredSyncArtifactPath(_ path: String) -> Bool {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return hasDefaultIgnoredCorpusPathComponent(path)
      || name.hasPrefix(".syncthing.")
      || name.hasPrefix(".")
      || name.contains(".sync-conflict-")
      || name.hasSuffix(".tmp")
  }

  nonisolated private static func fuzzyScore(query: String, candidate: String) -> Int? {
    fuzzyScore(
      normalizedQuery: normalizedQuickOpenQuery(query),
      normalizedCandidate: normalizedQuickOpenCandidate(candidate)
    )
  }

  nonisolated private static func normalizedQuickOpenQuery(_ query: String) -> String {
    query.lowercased().filter { !$0.isWhitespace }
  }

  nonisolated private static func normalizedQuickOpenCandidate(_ candidate: String) -> String {
    candidate.lowercased()
  }

  nonisolated private static func fuzzyScore(normalizedQuery query: String, normalizedCandidate candidate: String) -> Int? {
    guard !query.isEmpty else { return 0 }

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

  nonisolated static func normalizedRenderedSearchHighlightQuery(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let scopedPrefixes = ["id:", "file:", "tag:", "todo:"]
    let lowercased = trimmed.lowercased()
    for prefix in scopedPrefixes where lowercased.hasPrefix(prefix) {
      let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count > 1 {
      let unquoted = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
      return unquoted.isEmpty ? nil : unquoted
    }
    return trimmed
  }

  nonisolated static func countSearchOccurrences(in text: String, query: String) -> Int {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return 0 }

    let lowerText = text.lowercased()
    let lowerQuery = query.lowercased()
    var count = 0
    var index = lowerText.startIndex
    while index < lowerText.endIndex,
          let range = lowerText.range(of: lowerQuery, range: index..<lowerText.endIndex) {
      count += 1
      index = range.upperBound
    }
    return count
  }

  nonisolated private static func renderedPageSearchMatches(
    in blocks: [OrgEditableBlock],
    query: String
  ) -> [PageSearchRenderedMatch] {
    blocks.enumerated().flatMap { index, block -> [PageSearchRenderedMatch] in
      let count = countSearchOccurrences(in: block.rawText, query: query)
      guard count > 0 else { return [] }
      return (0..<count).map { offset in
        PageSearchRenderedMatch(
          blockID: block.id,
          blockIndex: index,
          occurrenceOffsetInBlock: offset
        )
      }
    }
  }

  nonisolated public static func slug(_ raw: String) -> String {
    let lowercased = raw.lowercased()
    var output = ""
    var lastWasSeparator = false
    for scalar in lowercased.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        output.unicodeScalars.append(scalar)
        lastWasSeparator = false
      } else if !lastWasSeparator {
        output.append("-")
        lastWasSeparator = true
      }
    }
    let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "untitled" : String(trimmed.prefix(80))
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
    let targetIndex = max(0, min(lines.count - 1, line - 1))
    guard let headingIndex = Self.headingIndex(in: lines, atOrBefore: targetIndex),
          lines[headingIndex].range(of: #"^\*+\s+"#, options: .regularExpression) != nil
    else {
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

  private func nestedParentSendHeading(for target: HeadlineMutationTarget) throws -> (line: Int, id: String?)? {
    guard target.title.range(of: #"^Approve\b"#, options: [.regularExpression, .caseInsensitive]) != nil else {
      return nil
    }

    let raw = try String(contentsOf: URL(fileURLWithPath: target.file), encoding: .utf8)
      .replacingOccurrences(of: "\r\n", with: "\n")
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let targetIndex = max(0, min(lines.count - 1, target.line - 1))
    guard let childIndex = Self.headingIndex(in: lines, atOrBefore: targetIndex),
          let childLevel = Self.headingLevel(lines[childIndex]),
          childLevel > 1
    else { return nil }

    for index in stride(from: childIndex - 1, through: 0, by: -1) {
      guard let level = Self.headingLevel(lines[index]) else { continue }
      if level >= childLevel { continue }
      let properties = Self.scanPropertyDrawer(lines: lines, afterHeadingIndex: index)
      let candidateID = (properties["ID"] ?? properties["CUSTOM_ID"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let title = Self.headingTitle(from: lines[index])
      if title.range(of: #"^Send\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
        return nil
      }
      return (line: index + 1, id: candidateID.isEmpty ? nil : candidateID)
    }

    return nil
  }

  nonisolated private static func headingTitle(from line: String) -> String {
    var rest = line.replacingOccurrences(of: #"^\*+\s+"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    rest = rest.replacingOccurrences(of: #"^[A-Z][A-Z0-9_-]*(\s+|$)"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    rest = rest.replacingOccurrences(of: #"\s+:[^\s:]+(:[^\s:]+)*:\s*$"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Org2Display.cleanInline(rest)
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

  private func knowledgeNodePath(corpusRoot: URL, title: String) -> URL {
    let config = Self.workspaceConfig(corpusRoot: corpusRoot)
    let rawBase = config?.roam?.indexDir?.trimmingCharacters(in: .whitespacesAndNewlines)
    let base: URL
    if let rawBase, !rawBase.isEmpty {
      base = NSString(string: rawBase).isAbsolutePath
        ? URL(fileURLWithPath: rawBase)
        : corpusRoot.appendingPathComponent(rawBase, isDirectory: true)
    } else {
      base = corpusRoot.appendingPathComponent("notes", isDirectory: true)
    }
    return base.appendingPathComponent("\(Self.slug(title)).org2")
  }

  private func ensureKnowledgeNode(title: String, sourceLocation: WorkspaceLocation?) throws -> CreatedKnowledgeNode {
    guard let corpusRoot else {
      throw WorkspaceEditError.noCorpusRoot
    }
    let cleanTitle = Org2Display.cleanInline(title).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else {
      throw WorkspaceEditError.emptyTitle
    }

    let target = knowledgeNodePath(corpusRoot: corpusRoot, title: cleanTitle)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let id: String
    if FileManager.default.fileExists(atPath: target.path) {
      let existing = try String(contentsOf: target, encoding: .utf8)
      id = Self.firstOrgID(in: existing) ?? UUID().uuidString
    } else {
      id = UUID().uuidString
      let sourceLink: String
      if let sourceLocation {
        sourceLink = "\nOrigin: [[file:\(relativePath(sourceLocation.file))][\(sourceLocation.title)]]"
      } else {
        sourceLink = ""
      }
      let text = """
      #+TITLE: \(cleanTitle)

      * \(cleanTitle)
      :PROPERTIES:
      :ID: \(id)
      :ORG2_CREATED_AT: \(Self.orgDateTimestamp(Date()))
      :END:
      \(sourceLink)

      """
      try text.write(to: target, atomically: true, encoding: .utf8)
    }
    return CreatedKnowledgeNode(title: cleanTitle, file: target.path, id: id)
  }

  public func createKnowledgeNode(title: String) async {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    let cleanTitle = Org2Display.cleanInline(title).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else {
      statusText = "Knowledge node creation canceled"
      return
    }

    do {
      let node = try ensureKnowledgeNode(title: cleanTitle, sourceLocation: selectedLocation)
      statusText = "Knowledge node ready -> \(relativePath(node.file))"
      invalidateCanonicalDocumentCache(for: node.file)
      await refreshCorpusFiles()
      searchQuery = "id:\(node.id)"
      selectedSurface = .search
      await runSearch()
    } catch {
      errorText = error.localizedDescription
      statusText = "Knowledge node creation failed"
    }
  }

  nonisolated public static func selectedText(in text: String, range: NSRange) -> String? {
    trimmedSelection(in: text, range: range)?.text
  }

  nonisolated public static func replacingSelection(
    in text: String,
    range: NSRange,
    with replacement: String
  ) -> InlineSelectionReplacement? {
    guard let swiftRange = Range(range, in: text) else { return nil }
    var output = text
    output.replaceSubrange(swiftRange, with: replacement)
    return InlineSelectionReplacement(
      text: output,
      selectedRange: NSRange(location: range.location, length: (replacement as NSString).length)
    )
  }

  nonisolated public static func backlinkReplacementForSelectedText(
    in text: String,
    range: NSRange
  ) -> InlineSelectionReplacement? {
    guard let selected = trimmedSelection(in: text, range: range) else { return nil }
    return replacingSelection(in: text, range: selected.range, with: "[[\(selected.text)]]")
  }

  nonisolated public static func nodeLinkReplacementForSelectedText(
    in text: String,
    range: NSRange,
    id: String,
    title: String
  ) -> InlineSelectionReplacement? {
    let cleanTitle = Org2Display.cleanInline(title).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { return nil }
    guard let selected = trimmedSelection(in: text, range: range) else { return nil }
    return replacingSelection(in: text, range: selected.range, with: "[[id:\(id)][\(cleanTitle)]]")
  }

  nonisolated private static func trimmedSelection(
    in text: String,
    range: NSRange
  ) -> (text: String, range: NSRange)? {
    guard range.length > 0 else { return nil }
    let ns = text as NSString
    let location = min(max(0, range.location), ns.length)
    let length = min(max(0, range.length), ns.length - location)
    guard length > 0,
          let swiftRange = Range(NSRange(location: location, length: length), in: text)
    else {
      return nil
    }

    var lower = swiftRange.lowerBound
    var upper = swiftRange.upperBound
    while lower < upper, text[lower].isWhitespace {
      lower = text.index(after: lower)
    }
    while lower < upper {
      let beforeUpper = text.index(before: upper)
      guard text[beforeUpper].isWhitespace else { break }
      upper = beforeUpper
    }
    guard lower < upper else { return nil }

    return (
      text: String(text[lower..<upper]),
      range: NSRange(lower..<upper, in: text)
    )
  }

  public func createKnowledgeNodeFromSelection(text: String, range: NSRange) async -> InlineSelectionReplacement? {
    guard let title = Self.selectedText(in: text, range: range) else {
      statusText = "Select text first"
      return nil
    }

    do {
      let node = try ensureKnowledgeNode(title: title, sourceLocation: selectedLocation)
      invalidateCanonicalDocumentCache(for: node.file)
      await refreshCorpusFiles()
      statusText = "Created node \(relativePath(node.file))"
      return Self.nodeLinkReplacementForSelectedText(in: text, range: range, id: node.id, title: node.title)
    } catch {
      errorText = error.localizedDescription
      statusText = "Create node from selection failed"
      return nil
    }
  }

  func createKnowledgeNodeFromWikiLinkCompletion(
    text: String,
    match: ParagraphWikiLinkCompletionMatch
  ) async -> InlineSelectionReplacement? {
    let title = match.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      statusText = "Type a link title first"
      return nil
    }

    do {
      let node = try ensureKnowledgeNode(title: title, sourceLocation: selectedLocation)
      invalidateCanonicalDocumentCache(for: node.file)
      await refreshCorpusFiles()
      statusText = "Created node \(relativePath(node.file))"
      return ParagraphWikiLinkCompletion.replacement(
        in: text,
        match: match,
        node: OrgRoamNodeReference(
          idValue: node.id,
          title: node.title,
          file: node.file,
          line: 1
        )
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Create node from link failed"
      return nil
    }
  }

  public func promptAndCreateKnowledgeNode() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }

    let alert = NSAlert()
    alert.messageText = "Create Knowledge Node"
    alert.informativeText = "Create a linked Org2 node in the corpus."
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = selectedLocation?.title ?? "New knowledge node"
    alert.accessoryView = field

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    Task { await createKnowledgeNode(title: title.isEmpty ? field.placeholderString ?? "" : title) }
  }

  private func appendCapture(draft: WorkspaceCaptureDraft, to target: URL, corpusRoot: URL) throws {
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let entry = try captureEntryText(draft: draft, corpusRoot: corpusRoot)
    if !FileManager.default.fileExists(atPath: target.path) {
      guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    try Self.appendText(entry, to: target)
  }

  nonisolated private static func appendText(_ text: String, to target: URL) throws {
    let handle = try FileHandle(forUpdating: target)
    defer {
      try? handle.close()
    }

    let byteCount = try handle.seekToEnd()
    var prefix = ""
    if byteCount > 0 {
      try handle.seek(toOffset: byteCount - 1)
      let lastByte = handle.readData(ofLength: 1)
      if lastByte != Data([0x0A]) {
        prefix = "\n"
      }
      try handle.seekToEnd()
    }

    try handle.write(contentsOf: Data("\(prefix)\(text)".utf8))
  }

  private func captureEntryText(draft: WorkspaceCaptureDraft, corpusRoot: URL) throws -> String {
    let safeTitle = draft.title
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeTitle.isEmpty else {
      throw WorkspaceEditError.emptyTitle
    }

    let priority = Self.normalizePriority(draft.priority)
    let tagsSuffix = Self.captureTagsSuffix(draft.tagsText)
    let headingPrefix: String
    switch draft.kind {
    case .task:
      headingPrefix = "* \(draft.todoStatus.label)"
    case .note:
      headingPrefix = "*"
    }
    let priorityPart = priority.map { " [#\($0)]" } ?? ""
    var lines = ["\(headingPrefix)\(priorityPart) \(safeTitle)\(tagsSuffix)"]
    if draft.includeScheduled {
      lines.append("SCHEDULED: \(Self.orgDateTimestamp(draft.scheduledDate))")
    }
    if draft.includeDeadline {
      lines.append("DEADLINE: \(Self.orgDateTimestamp(draft.deadlineDate))")
    }

    var properties = ["CAPTURED_AT": Self.orgTimestamp(Date())]
    if draft.assignToAgent {
      properties["ASSIGNEE"] = resolvedAgentHandoffAssignee()
      properties["STATUS"] = "ready"
      properties["ASSIGNED_AT"] = Self.orgTimestamp(Date())
    }
    lines.append(":PROPERTIES:")
    for key in properties.keys.sorted() {
      if let value = properties[key] {
        lines.append(":\(key): \(value)")
      }
    }
    lines.append(":END:")

    let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
    if !body.isEmpty {
      lines.append("")
      lines.append(body)
    }

    let attachmentLines = try draft.attachments.map { attachment in
      try materializeCaptureAttachment(attachment, corpusRoot: corpusRoot)
    }
    if !attachmentLines.isEmpty {
      lines.append("")
      lines.append(contentsOf: attachmentLines)
    }

    return lines.joined(separator: "\n") + "\n"
  }

  private func materializeCaptureAttachment(
    _ attachment: WorkspaceCaptureAttachmentDraft,
    corpusRoot: URL
  ) throws -> String {
    if attachment.kind == .link, let sourceURL = attachment.sourceURL {
      let label = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
      return Self.orgLink(target: sourceURL.absoluteString, label: label.isEmpty ? sourceURL.absoluteString : label)
    }

    let attachmentsDirectory = corpusRoot.appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)

    let fileName = Self.captureAttachmentFileName(for: attachment)
    let target = Self.uniqueAttachmentURL(in: attachmentsDirectory, fileName: fileName)
    if let data = attachment.data {
      try data.write(to: target, options: .atomic)
    } else if let sourceURL = attachment.sourceURL, sourceURL.isFileURL {
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.copyItem(at: sourceURL, to: target)
    } else if let sourceURL = attachment.sourceURL {
      let label = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
      return Self.orgLink(target: sourceURL.absoluteString, label: label.isEmpty ? sourceURL.absoluteString : label)
    } else {
      return attachment.name
    }

    let relativePath = Self.relativePath(for: target.standardizedFileURL.path, root: corpusRoot.standardizedFileURL)
    let label = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return Self.orgLink(target: "file:\(relativePath)", label: label.isEmpty ? target.lastPathComponent : label)
  }

  private static func captureTagsSuffix(_ raw: String) -> String {
    let tags = raw
      .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
      .map { token in
        token.trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines))
      }
      .filter { !$0.isEmpty }
      .map { tag in
        tag.replacingOccurrences(of: #"[^A-Za-z0-9_@#%.-]"#, with: "_", options: .regularExpression)
      }
      .filter { !$0.isEmpty }
    guard !tags.isEmpty else { return "" }
    return " :\(Array(Set(tags)).sorted().joined(separator: ":")):"
  }

  private static func captureTitleCandidate(from raw: String) -> String? {
    let firstLine = raw
      .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstLine, !firstLine.isEmpty else { return nil }
    return String(firstLine.prefix(80))
  }

  private static func capturePasteboardContent(from pasteboard: NSPasteboard) -> WorkspaceCapturePasteboardContent {
    var content = WorkspaceCapturePasteboardContent()
    let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    var representedURLStrings: Set<String> = []

    for url in fileURLs {
      representedURLStrings.insert(url.absoluteString)
      if url.isFileURL {
        content.attachments.append(WorkspaceCaptureAttachmentDraft(
          kind: captureAttachmentKind(for: url),
          name: url.lastPathComponent,
          sourceURL: url,
          suggestedExtension: url.pathExtension
        ))
      } else {
        content.attachments.append(WorkspaceCaptureAttachmentDraft(
          kind: .link,
          name: url.host ?? url.absoluteString,
          sourceURL: url
        ))
      }
    }

    if let urlString = pasteboard.string(forType: .URL),
       let url = URL(string: urlString),
       !representedURLStrings.contains(url.absoluteString) {
      representedURLStrings.insert(url.absoluteString)
      content.attachments.append(WorkspaceCaptureAttachmentDraft(
        kind: .link,
        name: url.host ?? url.absoluteString,
        sourceURL: url
      ))
    }

    if fileURLs.isEmpty, let imageData = capturePasteboardImagePNGData(from: pasteboard) {
      content.attachments.append(WorkspaceCaptureAttachmentDraft(
        kind: .image,
        name: "pasted image",
        data: imageData,
        suggestedExtension: "png"
      ))
    }

    if let string = pasteboard.string(forType: .string) {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && !representedURLStrings.contains(trimmed) {
        content.text = string
      }
    }

    return content
  }

  private static func capturePasteboardImagePNGData(from pasteboard: NSPasteboard) -> Data? {
    if let data = pasteboard.data(forType: .png) {
      return data
    }
    if let data = pasteboard.data(forType: .tiff),
       let bitmap = NSBitmapImageRep(data: data) {
      return bitmap.representation(using: .png, properties: [:])
    }
    if let image = NSImage(pasteboard: pasteboard),
       let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff) {
      return bitmap.representation(using: .png, properties: [:])
    }
    return nil
  }

  private static func captureAttachmentKind(for url: URL) -> WorkspaceCaptureAttachmentKind {
    let ext = url.pathExtension.lowercased()
    if ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp"].contains(ext) {
      return .image
    }
    if ["mov", "mp4", "m4v", "avi", "webm"].contains(ext) {
      return .video
    }
    return .file
  }

  private static func orgLink(target: String, label: String) -> String {
    let cleanTarget = target.replacingOccurrences(of: "]", with: "%5D")
    let cleanLabel = label
      .replacingOccurrences(of: "[", with: "(")
      .replacingOccurrences(of: "]", with: ")")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return "[[\(cleanTarget)][\(cleanLabel.isEmpty ? cleanTarget : cleanLabel)]]"
  }

  private static func captureAttachmentFileName(for attachment: WorkspaceCaptureAttachmentDraft) -> String {
    let ext = captureAttachmentExtension(for: attachment)
    let baseName = URL(fileURLWithPath: attachment.name).deletingPathExtension().lastPathComponent
    let slug = Self.slug(baseName.isEmpty ? attachment.kind.rawValue : baseName)
    return ext.isEmpty ? slug : "\(slug).\(ext)"
  }

  private static func captureAttachmentExtension(for attachment: WorkspaceCaptureAttachmentDraft) -> String {
    let suggested = attachment.suggestedExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !suggested.isEmpty { return suggested }
    if let sourceURL = attachment.sourceURL {
      let ext = sourceURL.pathExtension.lowercased()
      if !ext.isEmpty { return ext }
    }
    switch attachment.kind {
    case .image:
      return "png"
    case .video:
      return "mov"
    case .file, .link:
      return ""
    }
  }

  private static func uniqueAttachmentURL(in directory: URL, fileName: String) -> URL {
    let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    let ext = URL(fileURLWithPath: fileName).pathExtension
    let stamp = captureFileTimestamp(Date())
    var candidate = directory.appendingPathComponent("\(stamp)-\(fileName)")
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      let suffix = ext.isEmpty ? "\(stamp)-\(base)-\(counter)" : "\(stamp)-\(base)-\(counter).\(ext)"
      candidate = directory.appendingPathComponent(suffix)
      counter += 1
    }
    return candidate
  }

  private static func captureFileTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }

  nonisolated public static func workspaceHealthChecks(cli: Org2CLI, corpusRoot: URL?) -> [WorkspaceHealthCheck] {
    let fileManager = FileManager.default
    let repoRoot = cli.repoRoot.standardizedFileURL
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let cliScript = dist.appendingPathComponent("cli.js")
    let parseScript = dist.appendingPathComponent("parse.js")
    let packageFile = repoRoot.appendingPathComponent("package.json")
    let nodeModules = repoRoot.appendingPathComponent("node_modules", isDirectory: true)
    let macPackage = repoRoot.appendingPathComponent("apps/macos/Org2Workspace/Package.swift")

    var checks: [WorkspaceHealthCheck] = [
      WorkspaceHealthCheck(
        id: "repo-root",
        title: "Repo root",
        status: fileManager.fileExists(atPath: repoRoot.path) ? .ready : .blocking,
        detail: repoRoot.path
      ),
      WorkspaceHealthCheck(
        id: "node-build",
        title: "Node build",
        status: fileManager.fileExists(atPath: cliScript.path) && fileManager.fileExists(atPath: parseScript.path) ? .ready : .blocking,
        detail: fileManager.fileExists(atPath: cliScript.path) && fileManager.fileExists(atPath: parseScript.path)
          ? "dist/cli.js and dist/parse.js are available"
          : "Run npm run build from the repo root",
        remediationTitle: fileManager.fileExists(atPath: cliScript.path) && fileManager.fileExists(atPath: parseScript.path) ? nil : "Build CLI"
      ),
      WorkspaceHealthCheck(
        id: "package-json",
        title: "Package manifest",
        status: fileManager.fileExists(atPath: packageFile.path) ? .ready : .warning,
        detail: fileManager.fileExists(atPath: packageFile.path)
          ? "package.json found"
          : "Repo package.json was not found",
        remediationTitle: fileManager.fileExists(atPath: packageFile.path) ? nil : "Check repo root"
      ),
      WorkspaceHealthCheck(
        id: "node-modules",
        title: "Node dependencies",
        status: fileManager.fileExists(atPath: nodeModules.path) ? .ready : .warning,
        detail: fileManager.fileExists(atPath: nodeModules.path)
          ? "node_modules found"
          : "Run npm install before using local CLI workflows",
        remediationTitle: fileManager.fileExists(atPath: nodeModules.path) ? nil : "Install deps"
      ),
      WorkspaceHealthCheck(
        id: "mac-package",
        title: "Mac package",
        status: fileManager.fileExists(atPath: macPackage.path) ? .ready : .blocking,
        detail: fileManager.fileExists(atPath: macPackage.path)
          ? "Swift package manifest found"
          : "apps/macos/Org2Workspace/Package.swift was not found",
        remediationTitle: fileManager.fileExists(atPath: macPackage.path) ? nil : "Restore package"
      )
    ]

    if let corpusRoot {
      let config = corpusRoot.appendingPathComponent("org2.json")
      let corpusWritable = fileManager.isWritableFile(atPath: corpusRoot.path)
      checks.append(WorkspaceHealthCheck(
        id: "corpus-root",
        title: "Corpus",
        status: fileManager.fileExists(atPath: corpusRoot.path) ? .ready : .blocking,
        detail: corpusRoot.path
      ))
      checks.append(WorkspaceHealthCheck(
        id: "corpus-writable",
        title: "Corpus writable",
        status: corpusWritable ? .ready : .blocking,
        detail: corpusWritable
          ? "App can create notes and capture entries in the selected corpus"
          : "Selected corpus is not writable",
        remediationTitle: corpusWritable ? nil : "Fix permissions"
      ))
      checks.append(WorkspaceHealthCheck(
        id: "corpus-config",
        title: "Corpus config",
        status: fileManager.fileExists(atPath: config.path) ? .ready : .warning,
        detail: fileManager.fileExists(atPath: config.path)
          ? "org2.json found"
          : "No org2.json in selected corpus; defaults will be used",
        remediationTitle: fileManager.fileExists(atPath: config.path) ? nil : "Add config"
      ))
    } else {
      checks.append(WorkspaceHealthCheck(
        id: "corpus-root",
        title: "Corpus",
        status: .blocking,
        detail: "Open a corpus to enable agenda, meetings, search, capture, and notes",
        remediationTitle: "Open Corpus"
      ))
    }

    return checks
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

  nonisolated private static func similarTodoCandidates(
    to target: HeadlineMutationTarget,
    from candidates: [SimilarTodoCandidate]
  ) -> [SimilarTodoCandidate] {
    let targetTokens = assignmentSimilarityTokens(target.title)
    let scored = candidates.compactMap { candidate -> SimilarTodoCandidate? in
      guard candidate.todo.map({ !isTerminalTodoStatus($0) }) ?? false else { return nil }
      let score = assignmentSimilarityScore(targetTokens: targetTokens, candidate: candidate.headline)
      let isTarget = candidate.file == target.file && candidate.line == target.line
      guard isTarget || score >= 0.42 else { return nil }
      return SimilarTodoCandidate(
        file: candidate.file,
        line: candidate.line,
        headline: candidate.headline,
        todo: candidate.todo,
        tags: candidate.tags,
        properties: candidate.properties,
        score: isTarget ? max(1, score) : score
      )
    }
    return scored.sorted {
      if $0.score == $1.score {
        if $0.file == $1.file { return $0.line < $1.line }
        return $0.file.localizedStandardCompare($1.file) == .orderedAscending
      }
      return $0.score > $1.score
    }.prefix(75).map { $0 }
  }

  nonisolated private static func assignmentSimilarityTokens(_ title: String) -> [String] {
    title
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .filter { $0.count > 1 }
  }

  nonisolated private static func assignmentSimilarityScore(targetTokens: [String], candidate: String) -> Double {
    let target = Set(targetTokens)
    let candidateTokens = assignmentSimilarityTokens(candidate)
    let other = Set(candidateTokens)
    guard !target.isEmpty, !other.isEmpty else { return 0 }
    let overlap = target.intersection(other).count
    let union = target.union(other).count
    var prefix = 0
    for (lhs, rhs) in zip(targetTokens, candidateTokens) {
      guard lhs == rhs else { break }
      prefix += 1
    }
    return max(Double(overlap) / Double(union), Double(prefix) / Double(max(targetTokens.count, 1)))
  }

  nonisolated private static func inferredAssignmentPattern(
    from candidates: [SimilarTodoCandidate],
    fallback: String
  ) -> String {
    let titles = Array(candidates.prefix(8).map(\.headline))
    guard titles.count >= 2 else { return fallback }
    let tokenized = titles.map(assignmentSimilarityTokens)
    guard var prefix = tokenized.first, !prefix.isEmpty else { return fallback }
    for tokens in tokenized.dropFirst() {
      var next: [String] = []
      for (lhs, rhs) in zip(prefix, tokens) where lhs == rhs {
        next.append(lhs)
      }
      prefix = next
      if prefix.isEmpty { break }
    }
    guard prefix.count >= 2 else { return fallback }
    return "\(prefix.joined(separator: " ")) {{target}}"
  }

  nonisolated private static func openClawAssignedBacklogPrompt(
    assignee: String,
    status: String,
    pattern: String,
    items: [SimilarTodoCandidate],
    relativePath: (String) -> String,
    mappedPath: (String) -> String
  ) -> String {
    let refs = items.map { item in
      "- \(mappedPath(item.file)):\(item.line) (\(relativePath(item.file)):\(item.line)) \(item.todo ?? "TODO") \(item.headline)"
    }.joined(separator: "\n")
    return """
    Take a pass on this assigned org2 backlog.

    Assignee: \(assignee)
    Current assignment status: \(status)
    Repeated task pattern: \(pattern.isEmpty ? "unspecified" : pattern)

    Items:
    \(refs)

    Workflow:
    1. Inspect the repeated task shape and figure out how to complete one representative item.
    2. Apply that approach across the selected backlog items.
    3. Update each org heading as you work so progress is visible in Org2 Workspace.

    Update convention:
    - Keep ASSIGNEE: \(assignee)
    - Set STATUS to in_progress while actively working an item.
    - Set STATUS to blocked with a short BLOCKED_REASON property if you cannot complete it.
    - Set STATUS to done and mark the TODO done only when the requested work is complete.
    - Add LAST_AGENT_UPDATE with an org timestamp when you materially update an item.
    - Add concise logbook notes or body notes with evidence/source URLs where useful.

    Do not create a separate runner. Edit the org files directly and keep each item auditable.
    """
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

private struct AudioSettingsProcessResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

private enum AudioSettingsError: LocalizedError {
  case homebrewNotFound
  case installFailed(String)

  var errorDescription: String? {
    switch self {
    case .homebrewNotFound:
      "Homebrew is required to install whisper.cpp automatically."
    case .installFailed(let output):
      output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Audio transcription install failed."
        : "Audio transcription install failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
  }
}

private enum OpenClawAttachmentError: LocalizedError {
  case unsupportedImage(String)
  case imageTooLarge(String, maxMegabytes: Int)

  var errorDescription: String? {
    switch self {
    case .unsupportedImage(let name):
      return "\(name) is not a supported image attachment."
    case .imageTooLarge(let name, let maxMegabytes):
      return "\(name) is larger than the \(maxMegabytes) MB OpenClaw image attachment limit."
    }
  }
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

private struct OpenClawTranscriptState {
  let threads: [OpenClawChatThread]
  let selectedThreadID: UUID?
}

private struct OpenClawTranscriptPayload: Codable {
  let version: Int
  let messages: [OpenClawChatMessage]?
  let threads: [OpenClawChatThread]?
  let selectedThreadID: UUID?
}

private enum WorkspaceEditError: LocalizedError {
  case noCorpusRoot
  case emptyTitle
  case noHeadline(file: String, line: Int)
  case invalidRange(file: String, line: Int)
  case fileChanged(file: String)
  case destructiveWriteBlocked(file: String, backup: String?, operation: String)

  var errorDescription: String? {
    switch self {
    case .noCorpusRoot:
      "No corpus selected"
    case .emptyTitle:
      "Title cannot be empty"
    case .noHeadline(let file, let line):
      "No headline found at \(file):\(line)"
    case .invalidRange(let file, let line):
      "Invalid edit range at \(file):\(line)"
    case .fileChanged(let file):
      "File changed on disk; reload \(file) before saving"
    case .destructiveWriteBlocked(let file, let backup, let operation):
      if let backup {
        "Blocked \(operation) because it would empty \(file). Recovery copy saved at \(backup)."
      } else {
        "Blocked \(operation) because it would empty \(file)."
      }
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
  case home
  case agenda
  case approvals
  case files
  case search
  case meetings
  case openClaw

  public var id: String { rawValue }

  public static var sidebarCases: [WorkspaceSurface] {
    [.home, .agenda, .files, .approvals, .search, .meetings, .openClaw]
  }

  public var title: String {
    switch self {
    case .home: "Home"
    case .agenda: "Agenda"
    case .approvals: "Approvals"
    case .files: "Files"
    case .search: "Search"
    case .meetings: "Meetings"
    case .openClaw: "OpenClaw Chat"
    }
  }

  public var systemImage: String {
    switch self {
    case .home: "house"
    case .agenda: "calendar"
    case .approvals: "checkmark.seal"
    case .files: "doc.text"
    case .search: "magnifyingglass"
    case .meetings: "mic"
    case .openClaw: "sparkles"
    }
  }

  public var commandShortcutTitle: String {
    switch self {
    case .home: "⌘1"
    case .agenda: "⌘2"
    case .approvals: "⌘4"
    case .files: "⌘3"
    case .search: "⌘⇧F"
    case .meetings: "⌘5/⌘M"
    case .openClaw: "⌘6"
    }
  }
}

public enum WorkspaceSearchMode: String, CaseIterable, Identifiable, Sendable {
  case text
  case nodes

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .text: "Text"
    case .nodes: "Nodes"
    }
  }

  public var subtitle: String {
    switch self {
    case .text: "Full-text corpus search"
    case .nodes: "Node title, alias, ID, and path search"
    }
  }

  public var placeholder: String {
    switch self {
    case .text: "Search all org text"
    case .nodes: "Search nodes by title, alias, ID, or path"
    }
  }

  public var helpText: String {
    switch self {
    case .text:
      "Literal, case-insensitive search across .org and .org2 files under the selected corpus."
    case .nodes:
      "Live search over the local node index, including titles, aliases, IDs, and file paths."
    }
  }
}

public enum NodeContextTab: String, CaseIterable, Identifiable, Sendable {
  case overview
  case references
  case related
  case brief

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .overview: "Overview"
    case .references: "References"
    case .related: "Related"
    case .brief: "Brief"
    }
  }
}

public struct BacklinkFileGroup: Identifiable, Hashable, Sendable {
  public let file: String
  public let relativePath: String
  public let backlinks: [BacklinkItem]

  public init(file: String, relativePath: String, backlinks: [BacklinkItem]) {
    self.file = file
    self.relativePath = relativePath
    self.backlinks = backlinks
  }

  public var id: String { file }
  public var count: Int { backlinks.count }
  public var displayTitle: String {
    URL(fileURLWithPath: relativePath).lastPathComponent
  }
}

public struct RelatedBacklinkNode: Identifiable, Hashable, Sendable {
  public let id: String
  public let idValue: String?
  public let title: String
  public let referenceCount: Int
  public let fileCount: Int
  public let primaryPath: String
  public let examples: [String]

  public init(
    id: String,
    idValue: String?,
    title: String,
    referenceCount: Int,
    fileCount: Int,
    primaryPath: String,
    examples: [String]
  ) {
    self.id = id
    self.idValue = idValue
    self.title = title
    self.referenceCount = referenceCount
    self.fileCount = fileCount
    self.primaryPath = primaryPath
    self.examples = examples
  }
}

public struct NodeBriefArtifact: Identifiable, Hashable, Sendable {
  public var id: String { relativePath }
  public let relativePath: String
  public let file: String
  public let title: String
  public let body: String
  public let modifiedAt: Date?

  public init(relativePath: String, file: String, title: String, body: String, modifiedAt: Date?) {
    self.relativePath = relativePath
    self.file = file
    self.title = title
    self.body = body
    self.modifiedAt = modifiedAt
  }
}
