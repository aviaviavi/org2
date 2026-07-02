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

private struct OpenClawContextPointer: Equatable, Sendable {
  let kind: String
  let reference: String
  let displayReference: String
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
}

private struct ResolvedOpenClawSettings: Sendable {
  let settings: OpenClawGatewaySettings
  let bearerToken: String?
  let hasStoredToken: Bool
}

private struct PreparedDailyNote: Sendable {
  let file: CorpusFile
}

private struct PreparedOpenClawAttachments: Sendable {
  let attachments: [OpenClawChatAttachment]
  let failureFileName: String?
  let failureMessage: String?
}

private struct PreparedOpenClawSendRequest: Sendable {
  let userMessageID: UUID
  let userMessageIndex: Int
  let messages: [OpenClawChatMessage]
}

private struct OpenClawThreadScanResult: Sendable {
  let threads: [OpenClawThread]
  let directories: [URL]
}

private struct WorkspaceSelectionIdentity: Equatable, Sendable {
  let kind: String
  let file: String
  let line: Int
  let title: String
}

private struct OpenClawSnapshotFile: Sendable {
  let text: String
}

private struct OpenClawTranscriptSwitchRequest: Sendable {
  let targetURL: URL
  let previousURL: URL
  let migrationSource: URL?
  let legacyMessages: [OpenClawChatMessage]
  let canMigrateLegacyMessages: Bool
  let switchGeneration: Int
  let contentGeneration: Int
}

private struct OpenClawTranscriptSwitchResult: Sendable {
  let transcript: OpenClawTranscriptState
  let shouldPersist: Bool
}

private enum WorkspaceUndoAction: Equatable, Sendable {
  case openClawDraft(previous: String, next: String)
}

public enum QuickOpenSelectionDirection: Equatable, Sendable {
  case up
  case down
}

private struct QuickOpenIndexedFile: Sendable {
  let file: CorpusFile
  let normalizedRelativePath: String
}

private struct IndexedSearchNode: Sendable {
  let node: OrgRoamNodeReference
  let relativePath: String
  let aliasesText: String
}

private struct CorpusFileDisplayState: Sendable {
  let files: [CorpusFile]
  let filesByID: [CorpusFile.ID: CorpusFile]
  let indexedSearchNodes: [OrgRoamNodeReference]
  let indexedSearchNodeRows: [IndexedSearchNode]
  let searchNodeRelativePathsByFile: [String: String]
  let quickOpenIndexedFiles: [QuickOpenIndexedFile]
}

private struct AgendaRefreshRequest: Equatable, Sendable {
  let corpusRoot: URL
  let startDate: String
  let endDate: String
  let preserveSelection: Bool
  let updatesStatus: Bool
}

private struct AssignedWorkSearchRow: Sendable {
  let item: AssignedWorkItem
  let searchText: String
}

private struct AssignedWorkRefreshRequest: Equatable, Sendable {
  let corpusRoot: URL
  let filesSignature: String
}

private struct OpenClawThreadRefreshRequest: Equatable, Sendable {
  let corpusRoot: URL
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

private struct PageSearchMatchResult: Sendable {
  let query: String
  let sourceID: EntrySource.ID?
  let matches: [PageSearchRenderedMatch]
  let occurrenceCount: Int
}

private struct LoadedEntrySource: Sendable {
  let source: EntrySource
  let fullFileText: String
}

private struct PreparedRenderedEntrySource: Sendable {
  let blocks: [OrgEditableBlock]
  let canonicalDocument: Org2CanonicalDocument?
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

  init(file: String, line: Int, title: String, agendaItemID: String? = nil) {
    self.file = file
    self.line = line
    self.title = title
    self.agendaItemID = agendaItemID
  }

  init(item: AgendaItem) {
    self.init(
      file: item.file,
      line: item.lineForEditor,
      title: Org2Display.cleanInline(item.headline),
      agendaItemID: item.id
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

public struct MeetingInputMeterLevels: Equatable, Sendable {
  public let microphoneAverageLevel: Double
  public let microphonePeakLevel: Double
  public let systemAverageLevel: Double
  public let systemPeakLevel: Double

  public init(
    microphoneAverageLevel: Double = 0,
    microphonePeakLevel: Double = 0,
    systemAverageLevel: Double = 0,
    systemPeakLevel: Double = 0
  ) {
    self.microphoneAverageLevel = microphoneAverageLevel
    self.microphonePeakLevel = microphonePeakLevel
    self.systemAverageLevel = systemAverageLevel
    self.systemPeakLevel = systemPeakLevel
  }
}

public struct VoiceInputMeterLevels: Equatable, Sendable {
  public let averageLevel: Double
  public let peakLevel: Double

  public init(averageLevel: Double = 0, peakLevel: Double = 0) {
    self.averageLevel = averageLevel
    self.peakLevel = peakLevel
  }
}

public struct TranscriptionProgressState: Equatable, Sendable {
  public let progress: Double
  public let elapsedText: String

  public init(progress: Double = 0, elapsedText: String = "") {
    self.progress = progress
    self.elapsedText = elapsedText
  }
}

public struct OpenClawSendState: Equatable, Sendable {
  public let isSending: Bool
  public let startedAt: Date?

  public init(isSending: Bool = false, startedAt: Date? = nil) {
    self.isSending = isSending
    self.startedAt = startedAt
  }
}

@MainActor
public final class WorkspaceStore: ObservableObject {
  nonisolated public static let meetingCaptureSourceSummary = "Captures microphone and system/call audio. System audio uses macOS ScreenCaptureKit permission; Org2 records audio only."
  nonisolated public static let defaultAgentHandoffAssignee = "OpenClaw"

  @Published public var selectedSurface: WorkspaceSurface = .home {
    didSet {
      guard oldValue != selectedSurface else { return }
      setIfChanged(\.isWorkspaceSurfacePaneClosed, false)
      setIfChanged(\.expandedWorkspaceSurface, nil)
      setIfChanged(\.isWorkspaceDetailPaneExpanded, false)
    }
  }
  @Published public var expandedWorkspaceSurface: WorkspaceSurface?
  @Published public var isWorkspaceSurfacePaneClosed = false
  @Published public var isWorkspaceDetailPaneClosed = false
  @Published public var isWorkspaceDetailPaneExpanded = false
  @Published public var agendaMode: AgendaMode = .focus {
    willSet {
      guard newValue != agendaMode else { return }
      defaults.set(newValue.rawValue, forKey: agendaModeKey)
      rebuildAgendaDisplayCache(mode: newValue)
    }
  }
  @Published public var agendaFilter = "" {
    willSet {
      guard newValue != agendaFilter else { return }
      rebuildAgendaDisplayCache(filter: newValue)
      rebuildAssignedWorkDisplayCache(filter: newValue)
    }
  }
  @Published public var agendaFilterFocusToken = 0
  @Published public var isAgendaFilterFocused = false
  @Published public var selectedAgendaItemID: String?
  @Published public var bulkSelectedAgendaItemIDs: Set<String> = []
  private var suppressNextAgendaSelectionActivation = false
  private var suppressNextApprovalSelectionActivation = false
  private var suppressNextAssignedWorkSelectionActivation = false
  private var suppressedCorpusFileSelectionActivation: CorpusFile?
  private var suppressNextMeetingSelectionActivation = false
  @Published public var corpusRoot: URL? {
    didSet {
      guard oldValue?.standardizedFileURL.path != corpusRoot?.standardizedFileURL.path else { return }
      relativePathCache = [:]
      relativePathStandardRootPath = corpusRoot?.standardizedFileURL.path
      relativePathResolvedRootPath = corpusRoot.map { Self.resolvedPath(for: $0) }
      rebuildAgendaDisplayCache()
      rebuildApprovalDisplayCache()
      rebuildAssignedWorkDisplayCache()
      rebuildMeetingDisplaySections()
      rebuildSearchResultDisplayCache()
      rebuildSearchNodeDisplayCache()
    }
  }
  private var corpusFileScanTask: Task<CorpusFileDisplayState, Error>?
  private var corpusFileScanRoot: URL?
  private var corpusFileScanGeneration = 0
  private var cachedOpenClawAgentThreadDirectories: [String] = []
  private var agendaRefreshTask: Task<AgendaPayload, Error>?
  private var agendaRefreshRequest: AgendaRefreshRequest?
  private var agendaRefreshGeneration = 0
  @Published public var agenda: AgendaPayload? {
    willSet {
      rebuildAgendaDisplayCache(agenda: newValue)
    }
  }
  public private(set) var agendaDisplaySections: [AgendaDisplaySection] = []
  public private(set) var visibleAgendaItems: [AgendaItem] = []
  private var visibleAgendaItemsByID: [AgendaItem.ID: AgendaItem] = [:]
  private var visibleAgendaItemIndicesByID: [AgendaItem.ID: Int] = [:]
  private var visibleAgendaItemIDs: Set<AgendaItem.ID> = []
  @Published public private(set) var approvalItems: [ApprovalItem] = [] {
    willSet {
      rebuildApprovalDisplayCache(items: newValue)
    }
  }
  @Published public var approvalFilter = "" {
    willSet {
      guard newValue != approvalFilter else { return }
      rebuildApprovalDisplayCache(filter: newValue)
    }
  }
  public private(set) var visibleApprovalItems: [ApprovalItem] = []
  public private(set) var approvalDisplayItems: [ApprovalDisplayItem] = []
  private var visibleApprovalItemsByID: [ApprovalItem.ID: ApprovalItem] = [:]
  @Published public var selectedApprovalItemID: ApprovalItem.ID?
  @Published public var isLoadingApprovals = false
  @Published public var corpusFiles: [CorpusFile] = [] {
    willSet {
      let displayState: CorpusFileDisplayState
      if let staged = stagedCorpusFileDisplayState, staged.files == newValue {
        displayState = staged
        stagedCorpusFileDisplayState = nil
      } else {
        displayState = Self.corpusFileDisplayState(files: newValue)
      }
      applyCorpusFileDisplayState(displayState)
      rebuildFilteredCorpusFiles(files: newValue)
      rebuildSearchNodeCacheIfNeeded(indexedNodes: indexedSearchNodes)
    }

    didSet {
      scheduleQuickOpenSearch(debounce: false)
    }
  }
  @Published public private(set) var orgRoamLinkResolver = OrgRoamLinkResolver.empty {
    didSet {
      rebuildSearchNodeCacheIfNeeded()
    }
  }
  @Published public var selectedCorpusFileID: String?
  @Published public var corpusFileFilter = "" {
    willSet {
      guard newValue != corpusFileFilter else { return }
      rebuildFilteredCorpusFiles(query: newValue)
    }
  }
  public private(set) var filteredCorpusFiles: [CorpusFile] = []
  private var corpusFilesByID: [CorpusFile.ID: CorpusFile] = [:]
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
    willSet {
      assignedWorkItemsByID = Self.lookupByID(newValue)
      let rows = newValue.map { item in
        AssignedWorkSearchRow(item: item, searchText: Self.assignedWorkFilterText(for: item))
      }
      assignedWorkSearchRows = rows
      rebuildAssignedWorkDisplayCache(searchRows: rows)
    }
  }
  private var assignedWorkRefreshTask: Task<[AssignedWorkItem], Error>?
  private var assignedWorkRefreshRequest: AssignedWorkRefreshRequest?
  private var assignedWorkRefreshGeneration = 0
  public private(set) var visibleAssignedWorkItems: [AssignedWorkItem] = []
  private var assignedWorkItemsByID: [AssignedWorkItem.ID: AssignedWorkItem] = [:]
  private var visibleAssignedWorkItemsByID: [AssignedWorkItem.ID: AssignedWorkItem] = [:]
  private var displayedAssignedWorkItems: [AssignedWorkItem] = []
  private var displayedAssignedWorkItemIndicesByID: [AssignedWorkItem.ID: Int] = [:]
  public private(set) var assignedWorkSections: [AssignedWorkSection] = []
  @Published public var selectedAssignedWorkItemID: AssignedWorkItem.ID?
  @Published public var isLoadingAssignedWork = false
  @Published public var detailScrollRequest: DetailScrollRequest?
  @Published public var quickOpenQuery = "" {
    didSet {
      setIfChanged(\.selectedQuickOpenFileID, nil)
      scheduleQuickOpenSearch()
    }
  }
  @Published public var selectedQuickOpenFileID: String?
  @Published public private(set) var quickOpenFiles: [CorpusFile] = [] {
    willSet {
      rebuildQuickOpenDisplayLookup(files: newValue)
    }
  }
  private var quickOpenFilesByID: [CorpusFile.ID: CorpusFile] = [:]
  private var quickOpenFileIndicesByID: [CorpusFile.ID: Int] = [:]
  @Published public private(set) var isFilteringQuickOpenFiles = false
  @Published public var searchMode: WorkspaceSearchMode = .text {
    willSet {
      guard newValue != searchMode else { return }
      scheduleSearchNodeFilter(mode: newValue, debounce: false)
    }
  }
  @Published public var searchQuery = "" {
    willSet {
      guard newValue != searchQuery else { return }
      scheduleSearchNodeFilter(query: newValue)
    }
  }
  @Published public var searchFocusToken = 0
  @Published public var searchResults: [SearchResult] = [] {
    willSet {
      searchResultIDs = newValue.map(\.id)
      corpusSearchResultGroups = Self.groupedSearchResultsForDisplay(newValue)
      rebuildSearchResultDisplayCache(results: newValue)
    }
  }
  public private(set) var searchResultIDs: [SearchResult.ID] = []
  public private(set) var corpusSearchResultGroups: [SearchResultGroup] = []
  public private(set) var corpusSearchResultDisplayGroups: [SearchResultDisplayGroup] = []
  public private(set) var searchNodes: [OrgRoamNodeReference] = [] {
    willSet {
      rebuildSearchNodeDisplayCache(nodes: newValue)
    }
  }
  public private(set) var searchNodeDisplayItems: [SearchNodeDisplayItem] = []
  private var indexedSearchNodes: [OrgRoamNodeReference] = []
  private var indexedSearchNodeRows: [IndexedSearchNode] = []
  private var searchNodeRelativePathsByFile: [String: String] = [:]
  private var searchNodeFilterTask: Task<Void, Never>?
  private var searchNodeFilterGeneration = 0
  @Published public var openClawChatSearchResults: [OpenClawChatSearchResult] = []
  @Published public var renderedSearchHighlightQuery: String?
  @Published public var isPageSearchPresented = false
  @Published public var pageSearchQuery = "" {
    didSet {
      guard isPageSearchPresented else { return }
      schedulePageSearchMatches(selectFirst: true)
    }
  }
  @Published public var pageSearchFocusToken = 0
  @Published public private(set) var pageSearchOccurrenceCount = 0
  @Published public private(set) var pageSearchSelectedOccurrenceIndex: Int?
  private var pageSearchRenderedMatches: [PageSearchRenderedMatch] = []
  private var pageSearchFullFileTextCache: (sourceID: EntrySource.ID, text: String)?
  private var pageSearchMatchTask: Task<Void, Never>?
  private var pageSearchMatchGeneration = 0
  @Published public var meetings: [MeetingWorkspaceItem] = [] {
    willSet {
      meetingsByID = Self.lookupByID(newValue)
      meetingDisplaySections = Self.makeMeetingDisplaySections(newValue, corpusRoot: corpusRoot)
    }
  }
  private var meetingsByID: [MeetingWorkspaceItem.ID: MeetingWorkspaceItem] = [:]
  public private(set) var meetingDisplaySections: [MeetingSection] = []
  private var meetingScanTask: Task<[MeetingWorkspaceItem], Error>?
  private var meetingScanRoot: URL?
  private var meetingScanGeneration = 0
  @Published public var selectedMeetingID: String?
  @Published public var meetingTitleDraft = ""
  @Published public var meetingStatusText = WorkspaceStore.defaultMeetingStatusText()
  @Published public private(set) var meetingInputMeterLevels = MeetingInputMeterLevels()
  public var meetingInputAverageLevel: Double { meetingInputMeterLevels.microphoneAverageLevel }
  public var meetingInputPeakLevel: Double { meetingInputMeterLevels.microphonePeakLevel }
  public var meetingSystemAudioAverageLevel: Double { meetingInputMeterLevels.systemAverageLevel }
  public var meetingSystemAudioPeakLevel: Double { meetingInputMeterLevels.systemPeakLevel }
  @Published public private(set) var meetingTranscriptionState = TranscriptionProgressState()
  public var meetingTranscriptionProgress: Double { meetingTranscriptionState.progress }
  public var meetingTranscriptionElapsedText: String { meetingTranscriptionState.elapsedText }
  @Published public var audioSettingsStatus = LocalWhisperInstallationStatus.checking
  public var isAudioSettingsExpanded = false
  @Published public var isInstallingFastTranscriber = false
  @Published public var audioSettingsStatusText = ""
  @Published public private(set) var meetingTranscriptionBackendText = LocalWhisperTranscriber.resolvedBackendDescription()
  @Published public var workspaceRuntimeIdentity = WorkspaceRuntimeIdentity.current()
  @Published public var isCapturingSystemAudio = false
  @Published public var meetingSystemAudioStatusText = "System audio not recording"
  public var openClawMessages: [OpenClawChatMessage] = [] {
    willSet {
      setIfChanged(\.openClawMessageCount, newValue.count)
      rebuildVisibleOpenClawMessages(messages: newValue)
    }
    didSet {
      guard !isApplyingOpenClawThreadMessages else { return }
      updateSelectedOpenClawChatThread(messages: openClawMessages)
      guard shouldPersistOpenClawMessages else { return }
      persistOpenClawTranscript()
    }
  }
  @Published public private(set) var openClawChatThreads: [OpenClawChatThread] = [] {
    willSet {
      rebuildOpenClawThreadDisplayCache(threads: newValue)
    }
  }
  public private(set) var visibleOpenClawChatThreads: [OpenClawChatThreadDisplayItem] = []
  public private(set) var archivedOpenClawChatThreads: [OpenClawChatThreadDisplayItem] = []
  public private(set) var visibleOpenClawChatThreadsRenderSignature = WorkspaceStore.openClawThreadDisplayItemsRenderSignature(for: [])
  public private(set) var archivedOpenClawChatThreadsRenderSignature = WorkspaceStore.openClawThreadDisplayItemsRenderSignature(for: [])
  public private(set) var openClawUnreadMessageCount = 0
  private var openClawChatThreadIndicesByID: [UUID: Int] = [:]
  private var openClawMessagesByThreadID: [UUID: [OpenClawChatMessage]] = [:]
  @Published public private(set) var visibleOpenClawMessages: [OpenClawChatMessage] = []
  public private(set) var visibleOpenClawMessagesRenderSignature = WorkspaceStore.openClawMessagesRenderSignature(for: [])
  @Published public private(set) var openClawMessageCount = 0
  public var hiddenOpenClawMessageCount: Int {
    max(0, openClawMessageCount - visibleOpenClawMessages.count)
  }
  public private(set) var openClawVisibleMessageLimit = WorkspaceStore.defaultOpenClawVisibleMessageLimit
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
  @Published public var openClawHasStoredToken = false
  @Published public var openClawStatusText = WorkspaceStore.defaultOpenClawStatusText()
  @Published public var isRecordingOpenClawVoiceNote = false
  @Published public var isTranscribingOpenClawVoiceNote = false
  @Published public private(set) var openClawVoiceMeterLevels = VoiceInputMeterLevels()
  public var openClawVoiceAverageLevel: Double { openClawVoiceMeterLevels.averageLevel }
  public var openClawVoicePeakLevel: Double { openClawVoiceMeterLevels.peakLevel }
  @Published public private(set) var openClawVoiceTranscriptionState = TranscriptionProgressState()
  public var openClawVoiceTranscriptionProgress: Double { openClawVoiceTranscriptionState.progress }
  public var openClawVoiceTranscriptionElapsedText: String { openClawVoiceTranscriptionState.elapsedText }
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
  @Published public private(set) var openClawSendState = OpenClawSendState()
  public var isSendingOpenClawMessage: Bool { openClawSendState.isSending }
  @Published public private(set) var openClawQueuedMessageCount = 0
  public var openClawRequestStartedAt: Date? { openClawSendState.startedAt }
  @Published public var isOpenClawAssistantPresented = false
  public private(set) var openClawChatScrollPosition: Double?
  public private(set) var openClawAssistantChatScrollPosition: Double?
  @Published public var openClawThreads: [OpenClawThread] = []
  @Published public var selectedOpenClawThreadID: String?
  @Published public var workspaceHealthChecks: [WorkspaceHealthCheck] = []
  @Published public var isCheckingWorkspaceHealth = false
  @Published public var selectedLocation: WorkspaceLocation?
  @Published public var selectedEntrySource: EntrySource? {
    didSet {
      pageSearchFullFileTextCache = nil
    }
  }
  @Published public var selectedRenderedBlocks: [OrgEditableBlock] = [] {
    willSet {
      prepareSelectedRenderedBlocksDisplayState(for: newValue)
    }

    didSet {
      if isPageSearchPresented {
        schedulePageSearchMatches(selectFirst: false, debounce: false)
      }
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
    willSet {
      sourceBlockRunsRenderSignature = Self.sourceBlockRunsRenderSignature(for: newValue)
    }
  }
  public private(set) var sourceBlockRunsRenderSignature = WorkspaceStore.sourceBlockRunsRenderSignature(for: [:])
  @Published public var backlinks: BacklinksPayload? {
    willSet {
      rebuildBacklinkDisplayCacheForAssignment(newValue)
    }
  }
  public private(set) var backlinkFileGroups: [BacklinkFileGroup] = []
  public private(set) var backlinkFileCount = 0
  public private(set) var backlinkReferenceCount = 0
  public private(set) var relatedBacklinkNodes: [RelatedBacklinkNode] = []
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
  nonisolated private static let orgCryptPublicKeysDirectoryName = "public-keys"
  private static let canonicalParserLineLimit = 2_000
  private static let renderedBlocksCacheLimit = 12
  private static let detailNavigationHistoryLimit = 100
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
  private var openClawTranscriptURL: URL
  private let appOpenClawTranscriptURL: URL
  private let usesFixedOpenClawTranscriptURL: Bool
  private let openClawSendHandler: (@Sendable ([OpenClawChatMessage], String, String, OpenClawWorkspaceContext?) async throws -> String)?
  private var openClawSessionKey = WorkspaceStore.makeOpenClawSessionKey()
  private var shouldPersistOpenClawMessages = false
  private var isApplyingOpenClawThreadMessages = false
  private var openClawThreadRefreshTask: Task<OpenClawThreadScanResult, Error>?
  private var openClawThreadRefreshRequest: OpenClawThreadRefreshRequest?
  private var openClawThreadRefreshGeneration = 0
  private var openClawTranscriptPersistenceTask: Task<Void, Never>?
  private var openClawTranscriptSwitchTask: Task<Void, Never>?
  private var openClawTranscriptSwitchGeneration = 0
  private var openClawTranscriptContentGeneration = 0
  private static let openClawTranscriptContentPersistenceDelay: UInt64 = 120_000_000
  private static let openClawTranscriptSelectionPersistenceDelay: UInt64 = 750_000_000
  private var openClawBearerToken: String?
  private var openClawPendingUserMessageIDs: [UUID] = [] {
    didSet {
      setIfChanged(\.openClawQueuedMessageCount, openClawPendingUserMessageIDs.count)
    }
  }
  private var isDrainingOpenClawQueue = false
  private var activeMeetingRecording: PendingMeetingRecording?
  private var activeMeetingProcessingCount = 0 {
    didSet {
      setIfChanged(\.isProcessingMeeting, activeMeetingProcessingCount > 0)
    }
  }
  private var activeMeetingProcessingTitles: Set<String> = []
  private var activeOpenClawVoiceNoteURL: URL?
  private var meetingMeterTask: Task<Void, Never>?
  nonisolated static let meetingMeterPublishIntervalNanoseconds: UInt64 = 250_000_000
  nonisolated static let scheduledBacklinkLoadDebounceNanoseconds: UInt64 = 80_000_000

  private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<WorkspaceStore, Value>, _ value: Value) {
    if self[keyPath: keyPath] != value {
      self[keyPath: keyPath] = value
    }
  }

  private func clearSelectedRenderedBlocks() {
    guard !selectedRenderedBlocks.isEmpty else { return }
    selectedRenderedBlocks = []
  }

  nonisolated private static func lookupByID<Item: Identifiable>(_ items: [Item]) -> [Item.ID: Item] where Item.ID: Hashable {
    var lookup: [Item.ID: Item] = [:]
    lookup.reserveCapacity(items.count)
    for item in items {
      lookup[item.id] = item
    }
    return lookup
  }

  private func assignCorpusFiles(_ displayState: CorpusFileDisplayState) {
    stagedCorpusFileDisplayState = displayState
    corpusFiles = displayState.files
  }

  private func applyCorpusFileDisplayState(_ displayState: CorpusFileDisplayState) {
    corpusFilesByID = displayState.filesByID
    indexedSearchNodes = displayState.indexedSearchNodes
    indexedSearchNodeRows = displayState.indexedSearchNodeRows
    searchNodeRelativePathsByFile = displayState.searchNodeRelativePathsByFile
    quickOpenIndexedFiles = displayState.quickOpenIndexedFiles
  }

  private func currentOrScannedCorpusFiles() async throws -> [CorpusFile] {
    if !corpusFiles.isEmpty {
      return corpusFiles
    }
    guard let corpusRoot else { return [] }
    let displayState = try await Task.detached(priority: .utility) {
      try Self.scanCorpusFileDisplayState(corpusRoot: corpusRoot)
    }.value
    assignCorpusFiles(displayState)
    return displayState.files
  }

  nonisolated private static func corpusFilesRefreshSignature(_ files: [CorpusFile]) -> String {
    files.map { file in
      [
        file.id,
        file.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "",
        file.byteCount.map(String.init) ?? ""
      ].joined(separator: "\u{1F}")
    }.joined(separator: "\u{1E}")
  }

  nonisolated private static func corpusFileDisplayState(files: [CorpusFile]) -> CorpusFileDisplayState {
    let searchNodes = files.compactMap(scanRoamFileNode)
    let relativePathsByFile = Dictionary(uniqueKeysWithValues: files.map { file in
      (file.path, file.relativePath)
    })
    return CorpusFileDisplayState(
      files: files,
      filesByID: lookupByID(files),
      indexedSearchNodes: searchNodes,
      indexedSearchNodeRows: indexSearchNodes(searchNodes, relativePathsByFile: relativePathsByFile),
      searchNodeRelativePathsByFile: relativePathsByFile,
      quickOpenIndexedFiles: indexQuickOpenFiles(files)
    )
  }
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
  nonisolated static let defaultOpenClawVisibleMessageLimit = 80
  nonisolated private static let openClawVisibleMessageLimitStep = 80
  nonisolated private static let openClawThreadTitleSourceLimit = 2_000
  nonisolated private static let openClawMessageRenderSignatureContentSampleLimit = 160
  nonisolated static let openClawScrollPositionRecordEpsilon = 0.002
  private var pendingNodeBriefArtifactRelativePath: String?
  private var pendingNodeBriefTitle: String?
  private var pendingG = false
  private var orgRoamLinkResolverGeneration = 0
  private var orgCryptManagedRecipientFilesRefreshGeneration = 0
  private var audioSettingsStatusTask: Task<Void, Never>?
  private var pendingAudioSettingsRefreshPreservesStatusText = false
  private var audioSettingsStatusRefreshGeneration = 0
  private var stagedCorpusFileDisplayState: CorpusFileDisplayState?
  private var quickOpenIndexedFiles: [QuickOpenIndexedFile] = []
  private var quickOpenSearchTask: Task<Void, Never>?
  private var quickOpenSearchGeneration = 0
  private var searchIndexTask: Task<Void, Never>?
  private var searchIndexGeneration = 0
  private var entrySourceLoadTask: Task<Void, Never>?
  private var entrySourceLoadGeneration = 0
  private var backlinksLoadTask: Task<Void, Never>?
  private var backlinksLoadGeneration = 0
  private var detailNavigationBackStack: [DetailNavigationSnapshot] = [] {
    didSet {
      setIfChanged(\.canNavigateBackInDetail, !detailNavigationBackStack.isEmpty)
    }
  }
  private var workspaceUndoStack: [WorkspaceUndoAction] = []
  private var workspaceRedoStack: [WorkspaceUndoAction] = []
  private var canonicalDocumentCache: [String: CanonicalDocumentCacheEntry] = [:]
  private var relativePathCache: [String: String] = [:]
  private var relativePathStandardRootPath: String?
  private var relativePathResolvedRootPath: String?
  private var renderedBlocksCache: [String: RenderedBlocksCacheEntry] = [:]
  private var renderedBlocksCacheOrder: [String] = []
  private var pendingBlockSelection: PendingBlockSelection?
  private var transientDraftBlock: TransientDraftBlock?
  private var activeBlockDrafts: [OrgEditableBlock.ID: String] = [:]
  private var activeBlockOriginals: [OrgEditableBlock.ID: OrgEditableBlock] = [:]
  private var deferredStableAutosaves: [OrgEditableBlock.ID: DeferredStableAutosave] = [:]
  private var preservesSelectedRenderedBlocksMetadataForNextAssignment = false
  private var scheduledAgendaRefreshTask: Task<Void, Never>?
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
        defaults === UserDefaults.standard && !Self.shouldIgnoreStandardDefaultsForTests(defaults)
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
    refreshAudioSettingsStatus()
  }

  private func cancelManagedTasks() {
    openClawTranscriptPersistenceTask?.cancel()
    openClawTranscriptPersistenceTask = nil
    openClawTranscriptSwitchTask?.cancel()
    openClawTranscriptSwitchTask = nil
    meetingMeterTask?.cancel()
    meetingMeterTask = nil
    meetingTranscriptionProgressTask?.cancel()
    meetingTranscriptionProgressTask = nil
    openClawVoiceMeterTask?.cancel()
    openClawVoiceMeterTask = nil
    openClawVoiceTranscriptionProgressTask?.cancel()
    openClawVoiceTranscriptionProgressTask = nil
    audioSettingsStatusTask?.cancel()
    audioSettingsStatusTask = nil
    quickOpenSearchTask?.cancel()
    quickOpenSearchTask = nil
    searchNodeFilterTask?.cancel()
    searchNodeFilterTask = nil
    pageSearchMatchTask?.cancel()
    pageSearchMatchTask = nil
    pageSearchMatchGeneration += 1
    searchIndexTask?.cancel()
    searchIndexTask = nil
    entrySourceLoadTask?.cancel()
    entrySourceLoadTask = nil
    backlinksLoadTask?.cancel()
    backlinksLoadTask = nil
    scheduledAgendaRefreshTask?.cancel()
    scheduledAgendaRefreshTask = nil
    agendaTodoShortcutMutationTask?.cancel()
    agendaTodoShortcutMutationTask = nil
  }

  public func bootstrap() async {
    refreshAudioSettingsStatus()
    if corpusRoot == nil {
      if let screenshotCorpusRoot = screenshotCorpusRootFromEnvironment() {
        setCorpusRoot(screenshotCorpusRoot, persistsDefault: false)
      } else {
        corpusRoot = restoreCorpusRoot()
        if let corpusRoot {
          refreshCachedOpenClawAgentThreadDirectories(corpusRoot: corpusRoot, directories: nil)
          await switchOpenClawTranscript(
            to: Self.openClawTranscriptURL(corpusRoot: corpusRoot),
            migrationSource: appOpenClawTranscriptURL
          )
        }
      }
    }

    if corpusRoot != nil {
      await refreshAgenda()
      await refreshMeetings()
      await refreshCorpusFiles()
      await refreshAssignedWork()
      await refreshApprovals()
      await refreshOrgCryptManagedRecipientFilesNow()
      if selectedSurface == .home {
        await openHomeNow()
      }
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
      await openHomeNow()
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
      openClawDraft = "Summarize the current launch plan and call out open risks."
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
      await openHomeNow()
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
    if corpusRoot?.standardizedFileURL.path == standardized.path {
      if persistsDefault {
        defaults.set(standardized.path, forKey: corpusKey)
      }
      return
    }
    corpusRoot = standardized
    refreshCachedOpenClawAgentThreadDirectories(corpusRoot: standardized, directories: nil)
    if persistsDefault {
      defaults.set(standardized.path, forKey: corpusKey)
    }
    scheduleOpenClawTranscriptSwitch(to: Self.openClawTranscriptURL(corpusRoot: standardized))
    agenda = nil
    approvalItems = []
    selectedApprovalItemID = nil
    setIfChanged(\.approvalFilter, "")
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
    selectedRenderedBlocks = []
    foldedRenderedBlockIDs = []
    sourceBlockRuns = [:]
    editableEntryText = ""
    canonicalDocumentCache = [:]
    renderedBlocksCache = [:]
    renderedBlocksCacheOrder = []
    scheduledAgendaRefreshTask?.cancel()
    scheduledAgendaRefreshTask = nil
    agendaTodoShortcutMutationTask?.cancel()
    agendaTodoShortcutMutationTask = nil
    pendingAgendaTodoShortcutMutations = []
    searchIndexTask?.cancel()
    searchIndexTask = nil
    searchIndexGeneration += 1
    searchNodeFilterTask?.cancel()
    searchNodeFilterTask = nil
    searchNodeFilterGeneration += 1
    pageSearchMatchTask?.cancel()
    pageSearchMatchTask = nil
    pageSearchMatchGeneration += 1
    entrySourceLoadTask?.cancel()
    entrySourceLoadTask = nil
    backlinksLoadTask?.cancel()
    backlinksLoadTask = nil
    isBuildingSearchIndex = false
    searchIndexStatusText = ""
    resetBlockState()
    isEditingEntry = false
    isRenderingEntrySource = false
    entrySourceLoadGeneration += 1
    setIfChanged(\.backlinks, nil)
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
    await refreshOrgCryptManagedRecipientFilesNow()
    Task { await refreshOpenClawThreads() }
  }

  public func refreshAudioSettingsStatus(preserveStatusText: Bool = false) {
    if audioSettingsStatusTask != nil {
      pendingAudioSettingsRefreshPreservesStatusText =
        pendingAudioSettingsRefreshPreservesStatusText && preserveStatusText
      return
    }
    pendingAudioSettingsRefreshPreservesStatusText = preserveStatusText
    audioSettingsStatusRefreshGeneration += 1
    let generation = audioSettingsStatusRefreshGeneration
    audioSettingsStatusTask = Task { @MainActor [weak self] in
      await self?.refreshAudioSettingsStatusNow(
        preserveStatusText: self?.pendingAudioSettingsRefreshPreservesStatusText ?? preserveStatusText,
        generation: generation
      )
      guard self?.audioSettingsStatusRefreshGeneration == generation else { return }
      self?.audioSettingsStatusTask = nil
    }
  }

  public func refreshAudioSettingsStatusNow(preserveStatusText: Bool = false) async {
    audioSettingsStatusRefreshGeneration += 1
    let generation = audioSettingsStatusRefreshGeneration
    audioSettingsStatusTask?.cancel()
    audioSettingsStatusTask = nil
    pendingAudioSettingsRefreshPreservesStatusText = preserveStatusText
    await refreshAudioSettingsStatusNow(preserveStatusText: preserveStatusText, generation: generation)
  }

  private func refreshAudioSettingsStatusNow(preserveStatusText: Bool, generation: Int) async {
    let runtimeIdentity = WorkspaceRuntimeIdentity.current()
    let status = await Task.detached(priority: .utility) {
      LocalWhisperTranscriber.installationStatus()
    }.value
    guard !Task.isCancelled, generation == audioSettingsStatusRefreshGeneration else { return }
    setIfChanged(\.audioSettingsStatus, status)
    setIfChanged(\.meetingTranscriptionBackendText, status.backendDescription)
    setIfChanged(\.workspaceRuntimeIdentity, runtimeIdentity)
    if !preserveStatusText && (audioSettingsStatusText.isEmpty || !isInstallingFastTranscriber) {
      setIfChanged(\.audioSettingsStatusText, status.detailText)
    }
  }

  public func flushAudioSettingsStatusRefresh() async {
    await audioSettingsStatusTask?.value
  }

  public func setAudioSettingsExpanded(_ expanded: Bool) {
    isAudioSettingsExpanded = expanded
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
      cachedOpenClawAgentThreadDirectories = []
      orgRoamLinkResolver = .empty
      orgRoamLinkResolverGeneration += 1
      searchIndexTask?.cancel()
      searchIndexTask = nil
      searchIndexGeneration += 1
      searchNodeFilterTask?.cancel()
      searchNodeFilterTask = nil
      searchNodeFilterGeneration += 1
      pageSearchMatchTask?.cancel()
      pageSearchMatchTask = nil
      pageSearchMatchGeneration += 1
      isBuildingSearchIndex = false
      searchIndexStatusText = ""
      return
    }

    let scanRoot = corpusRoot.standardizedFileURL
    if let corpusFileScanTask,
       corpusFileScanRoot == scanRoot {
      _ = try? await corpusFileScanTask.value
      return
    }

    let scanTask = Task.detached(priority: .utility) {
      try Self.scanCorpusFileDisplayState(corpusRoot: scanRoot)
    }
    corpusFileScanGeneration += 1
    let scanGeneration = corpusFileScanGeneration
    corpusFileScanTask = scanTask
    corpusFileScanRoot = scanRoot
    isScanningCorpusFiles = true
    defer {
      if corpusFileScanGeneration == scanGeneration {
        corpusFileScanTask = nil
        corpusFileScanRoot = nil
        isScanningCorpusFiles = false
      }
    }

    do {
      let displayState = try await scanTask.value
      guard self.corpusRoot?.standardizedFileURL == scanRoot else { return }
      let files = displayState.files
      assignCorpusFiles(displayState)
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
    guard let corpusRoot else {
      if updatesStatus {
        statusText = "No corpus selected"
      }
      return
    }

    let startDate = Self.formatDate(Date())
    let endDate = Self.formatDate(Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: Date()) ?? Date())
    let request = AgendaRefreshRequest(
      corpusRoot: corpusRoot.standardizedFileURL,
      startDate: startDate,
      endDate: endDate,
      preserveSelection: preserveSelection,
      updatesStatus: updatesStatus
    )
    if let agendaRefreshTask,
       agendaRefreshRequest == request {
      _ = try? await agendaRefreshTask.value
      return
    }

    let cli = cli
    let task = Task {
      try await cli.runJSON([
        "agenda",
        "--dir", request.corpusRoot.path,
        "--recursive",
        "--from", request.startDate,
        "--to", request.endDate,
        "--format", "json",
        "--workload"
      ]) as AgendaPayload
    }
    agendaRefreshGeneration += 1
    let generation = agendaRefreshGeneration
    agendaRefreshTask = task
    agendaRefreshRequest = request
    isLoadingAgenda = true
    errorText = nil
    defer {
      if agendaRefreshGeneration == generation {
        agendaRefreshTask = nil
        agendaRefreshRequest = nil
        isLoadingAgenda = false
      }
    }

    do {
      let payload = try await task.value
      guard self.corpusRoot?.standardizedFileURL == request.corpusRoot else { return }
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
    guard !isLoadingApprovals else {
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

    isLoadingApprovals = true
    errorText = nil
    defer { isLoadingApprovals = false }
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
          let displayState = try await Task.detached(priority: .utility) {
            try Self.scanCorpusFileDisplayState(corpusRoot: corpusRoot)
          }.value
          let files = displayState.files
          assignCorpusFiles(displayState)
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
    setIfChanged(\.approvalFilter, "")
  }

  public func selectApprovalItem(_ item: ApprovalItem) {
    setIfChanged(\.selectedApprovalItemID, item.id)
    select(.agenda(item.agendaItem()))
    setIfChanged(\.statusText, item.sourceLabel)
  }

  public func activateApprovalItemFromRowTap(_ item: ApprovalItem) {
    guard selectedApprovalItemID != item.id else { return }
    selectApprovalItem(item)
    suppressNextApprovalSelectionActivation = true
  }

  public func consumeApprovalSelectionActivationSuppression() -> Bool {
    guard suppressNextApprovalSelectionActivation else { return false }
    suppressNextApprovalSelectionActivation = false
    return true
  }

  public func approve(_ item: ApprovalItem) async {
    await approveAndAgentHandoff(HeadlineMutationTarget(
      file: item.file,
      line: item.line,
      title: Org2Display.cleanInline(item.title),
      agendaItemID: nil
    ))
    await refreshApprovals(updatesStatus: false)
  }

  public func discussApprovalInOpenClaw(_ item: ApprovalItem, message: String? = nil) async {
    let text = Self.openClawApprovalDiscussionPrompt(item: item, message: message)
    setIfChanged(\.selectedSurface, .openClaw)
    await sendOpenClawMessage(text: text)
  }

  public func copyApprovalDiscussionText(_ item: ApprovalItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.discussionText, forType: .string)
    setIfChanged(\.statusText, "Copied approval discussion text")
  }

  private func syncApprovalSelectionAfterRefresh() {
    guard !visibleApprovalItems.isEmpty else {
      setIfChanged(\.selectedApprovalItemID, nil)
      return
    }
    if let selectedApprovalItemID,
       visibleApprovalItemsByID[selectedApprovalItemID] != nil {
      return
    }
    if selectedSurface == .approvals {
      selectApprovalItem(visibleApprovalItems[0])
    }
  }

  private func rebuildApprovalDisplayCache(
    items: [ApprovalItem]? = nil,
    filter: String? = nil
  ) {
    let sourceItems = items ?? approvalItems
    let sourceFilter = filter ?? approvalFilter
    visibleApprovalItems = sourceItems.filter { $0.matchesApprovalFilter(sourceFilter) }
    let standardizedRoot = corpusRoot?.standardizedFileURL
    approvalDisplayItems = visibleApprovalItems.map { item in
      ApprovalDisplayItem(
        item: item,
        relativePath: standardizedRoot.map { Self.relativePath(for: item.file, root: $0) } ?? item.file
      )
    }
    visibleApprovalItemsByID = Self.lookupByID(visibleApprovalItems)
    if let selectedApprovalItemID,
       visibleApprovalItemsByID[selectedApprovalItemID] == nil {
      setIfChanged(\.selectedApprovalItemID, nil)
    }
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
    let chatResults = Self.searchOpenClawChatThreads(
      openClawChatThreadsForCurrentMessages(),
      query: query,
      limit: 25
    )
    guard let corpusRoot else {
      searchResults = []
      openClawChatSearchResults = chatResults
      setIfChanged(\.selectedSurface, .search)
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
      setIfChanged(\.selectedSurface, .search)
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

    let scanRoot = corpusRoot.standardizedFileURL
    if let meetingScanTask,
       meetingScanRoot == scanRoot {
      _ = try? await meetingScanTask.value
      return
    }

    let scanTask = Task.detached(priority: .utility) {
      try Self.scanMeetingItems(corpusRoot: scanRoot)
    }
    meetingScanGeneration += 1
    let scanGeneration = meetingScanGeneration
    meetingScanTask = scanTask
    meetingScanRoot = scanRoot
    isLoadingMeetings = true
    defer {
      if meetingScanGeneration == scanGeneration {
        meetingScanTask = nil
        meetingScanRoot = nil
        isLoadingMeetings = false
      }
    }

    do {
      let items = try await scanTask.value
      guard self.corpusRoot?.standardizedFileURL == scanRoot else { return }
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
      setIfChanged(\.selectedSurface, .meetings)
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
      beginMeetingProcessing(title: recording.paths.title, status: "Transcribing \(recording.paths.title) locally...")
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
      endMeetingProcessing(title: recording.paths.title)
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
      let titleKey = Self.normalizedMeetingProcessingTitle(recording.paths.title)
      guard !activeMeetingProcessingTitles.contains(titleKey) else { continue }
      let relativeAudio = MeetingArtifactWriter.relativePath(from: corpusRoot, to: recording.paths.audioURL)
      guard !knownAudioArtifacts.contains(relativeAudio) else { continue }

      beginMeetingProcessing(
        title: recording.paths.title,
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
      endMeetingProcessing(title: recording.paths.title)
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

    var processingTitle: String?
    var progressID: UUID?
    defer {
      if let processingTitle {
        endMeetingProcessing(title: processingTitle)
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
      processingTitle = paths.title
      beginMeetingProcessing(title: paths.title, status: "Importing \(paths.title)...")
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
    setIfChanged(\.selectedSurface, .meetings)
    select(.meeting(meeting))
  }

  public func activateMeetingFromRowTap(_ meeting: MeetingWorkspaceItem) {
    guard !isActiveMeeting(meeting) else { return }
    selectMeeting(meeting)
    suppressNextMeetingSelectionActivation = true
  }

  public func consumeMeetingSelectionActivationSuppression() -> Bool {
    guard suppressNextMeetingSelectionActivation else { return false }
    suppressNextMeetingSelectionActivation = false
    return true
  }

  private func isActiveMeeting(_ meeting: MeetingWorkspaceItem) -> Bool {
    guard selectedMeetingID == meeting.id else { return false }
    guard selectedLocationMatches(.meeting(meeting)) else { return false }
    return selectedEntrySource != nil || isRenderingEntrySource || (isLoadingEntrySource && entrySourceLoadTask != nil)
  }

  public func askOpenClawAboutSelectedMeeting() {
    guard case .meeting = selectedLocation else {
      statusText = "Select a meeting first"
      return
    }
    openClawDraft = "Use the selected meeting note and transcript artifact as context. Summarize the meeting, extract decisions, list action items, and cite the org2 file paths you used."
    setIfChanged(\.selectedSurface, .openClaw)
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
      Task { await refreshOpenClawThreads() }
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
    selectedLocation != nil && corpusRoot != nil && !isBuildingNodeBrief && !isSendingOpenClawMessage
  }

  public var canLinkifyCurrentFile: Bool {
    corpusRoot != nil && (selectedEntrySource?.file != nil || selectedLocation?.file != nil)
  }

  public func askOpenClawAboutCurrentSelection() {
    guard let pointer = openClawContextPointerForCurrentSelection() else {
      statusText = "Select a page or entry first"
      return
    }

    addOpenClawContext(pointer)
  }

  public func askOpenClawAboutBlock(_ block: OrgEditableBlock) {
    if selectedRenderedBlockIndexes[block.id] != nil {
      setIfChanged(\.selectedBlockID, block.id)
    }

    guard let pointer = openClawContextPointer(for: OpenClawBlockContextPointer(source: selectedEntrySource, block: block)) else {
      askOpenClawAboutCurrentSelection()
      return
    }

    addOpenClawContext(pointer)
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
      Task { await refreshOpenClawThreads() }
      openNodeBriefArtifact(url: url, relativePath: relativePath, title: title)
      return true
    }
    return false
  }

  private func rebuildMeetingDisplaySections() {
    meetingDisplaySections = Self.makeMeetingDisplaySections(meetings, corpusRoot: corpusRoot)
  }

  private static func makeMeetingDisplaySections(
    _ meetings: [MeetingWorkspaceItem],
    corpusRoot: URL?
  ) -> [MeetingSection] {
    let grouped = Dictionary(grouping: meetings) { item -> String in
      guard let recordedAt = item.recordedAt, recordedAt.count >= 10 else {
        return "Unknown date"
      }
      return String(recordedAt.prefix(10))
    }
    let standardizedRoot = corpusRoot?.standardizedFileURL
    return grouped.keys.sorted(by: >).map { key in
      let items = (grouped[key] ?? []).sorted {
        ($0.recordedAt ?? "") > ($1.recordedAt ?? "")
      }.map { item in
        MeetingDisplayItem(
          meeting: item,
          relativePath: standardizedRoot.map { Self.relativePath(for: item.file, root: $0) } ?? item.file
        )
      }
      return MeetingSection(id: key, label: key, meetings: items)
    }
  }

  public func select(_ location: WorkspaceLocation) {
    if case .search = location {
      setIfChanged(\.isPageSearchPresented, false)
      setIfChanged(\.pageSearchQuery, "")
      setIfChanged(\.renderedSearchHighlightQuery, Self.normalizedRenderedSearchHighlightQuery(searchQuery))
      resetPageSearchMatches()
    } else {
      setIfChanged(\.isPageSearchPresented, false)
      setIfChanged(\.pageSearchQuery, "")
      setIfChanged(\.renderedSearchHighlightQuery, nil)
      resetPageSearchMatches()
    }
    activateDetailLocation(location, mode: nil, recordsHistory: true)
  }

  public var hasRenderedSearchHighlight: Bool {
    renderedSearchHighlightQuery?.isEmpty == false
  }

  public func clearRenderedSearchHighlight() {
    setIfChanged(\.renderedSearchHighlightQuery, nil)
    setIfChanged(\.pageSearchQuery, "")
    setIfChanged(\.isPageSearchPresented, false)
    resetPageSearchMatches()
  }

  @discardableResult
  public func focusPageSearch() -> Bool {
    guard selectedLocation != nil else { return false }
    let wasPresented = isPageSearchPresented
    let nextQuery = renderedSearchHighlightQuery ?? ""
    let queryChanged = pageSearchQuery != nextQuery
    setIfChanged(\.isPageSearchPresented, true)
    if queryChanged {
      pageSearchQuery = nextQuery
    }
    if !wasPresented || queryChanged {
      schedulePageSearchMatches(selectFirst: true, debounce: false)
    }
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
    guard !pageSearchRenderedMatches.isEmpty else {
      schedulePageSearchMatches(selectFirst: false, debounce: false)
      return
    }
    let current = pageSearchSelectedOccurrenceIndex ?? 0
    let count = pageSearchRenderedMatches.count
    let next = (current + delta + count) % count
    selectPageSearchOccurrence(at: next)
  }

  private func schedulePageSearchMatches(selectFirst: Bool, debounce: Bool = true) {
    let query = Self.normalizedRenderedSearchHighlightQuery(pageSearchQuery)
    setIfChanged(\.renderedSearchHighlightQuery, query)
    pageSearchMatchGeneration += 1
    let generation = pageSearchMatchGeneration
    pageSearchMatchTask?.cancel()

    guard let query else {
      pageSearchMatchTask = nil
      resetPageSearchMatches(cancelPending: false)
      return
    }

    let source = selectedEntrySource
    let sourceID = source?.id
    let fullText = pageSearchFullFileTextSnapshot(for: source)
    let blocks = selectedRenderedBlocks
    pageSearchMatchTask = Task { [blocks, debounce, fullText, generation, query, selectFirst, sourceID] in
      if debounce {
        try? await Task.sleep(nanoseconds: 60_000_000)
      }
      guard !Task.isCancelled else { return }

      let result = await Task.detached(priority: .userInitiated) {
        PageSearchMatchResult(
          query: query,
          sourceID: sourceID,
          matches: Self.renderedPageSearchMatches(in: blocks, query: query),
          occurrenceCount: Self.countSearchOccurrences(in: fullText, query: query)
        )
      }.value
      guard !Task.isCancelled else { return }

      await MainActor.run { [weak self] in
        guard let self,
              self.pageSearchMatchGeneration == generation,
              self.renderedSearchHighlightQuery == result.query,
              self.selectedEntrySource?.id == result.sourceID
        else {
          return
        }
        self.applyPageSearchMatches(result, selectFirst: selectFirst)
      }
    }
  }

  public func flushPageSearchMatches() async {
    await pageSearchMatchTask?.value
  }

  private func applyPageSearchMatches(_ result: PageSearchMatchResult, selectFirst: Bool) {
    pageSearchRenderedMatches = result.matches
    setIfChanged(\.pageSearchOccurrenceCount, result.occurrenceCount)

    guard !result.matches.isEmpty else {
      setIfChanged(\.pageSearchSelectedOccurrenceIndex, nil)
      return
    }

    let selectedIndex = pageSearchSelectedOccurrenceIndex
    let nextIndex: Int
    if selectFirst || selectedIndex == nil {
      nextIndex = 0
    } else {
      nextIndex = min(selectedIndex ?? 0, result.matches.count - 1)
    }
    selectPageSearchOccurrence(at: nextIndex)
  }

  private func resetPageSearchMatches(cancelPending: Bool = true) {
    if cancelPending {
      pageSearchMatchTask?.cancel()
      pageSearchMatchTask = nil
      pageSearchMatchGeneration += 1
    }
    if !pageSearchRenderedMatches.isEmpty {
      pageSearchRenderedMatches = []
    }
    setIfChanged(\.pageSearchOccurrenceCount, 0)
    setIfChanged(\.pageSearchSelectedOccurrenceIndex, nil)
  }

  private func selectPageSearchOccurrence(at index: Int) {
    guard pageSearchRenderedMatches.indices.contains(index) else { return }
    let match = pageSearchRenderedMatches[index]
    setIfChanged(\.pageSearchSelectedOccurrenceIndex, index)
    setIfChanged(\.selectedBlockID, match.blockID)
    requestDetailScroll(toBlock: match.blockID)
  }

  private func pageSearchFullFileTextSnapshot(for source: EntrySource?) -> String {
    guard let source else { return "" }
    if let cache = pageSearchFullFileTextCache, cache.sourceID == source.id {
      return cache.text
    }
    return source.text
  }

  public func navigateBackInDetail() {
    guard let snapshot = detailNavigationBackStack.popLast() else { return }
    setIfChanged(\.selectedSurface, snapshot.selectedSurface)
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
      setIfChanged(\.selectedLocation, location)
      return
    }

    setIfChanged(\.isWorkspaceDetailPaneClosed, false)
    setIfChanged(\.isWorkspaceDetailPaneExpanded, false)
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
      setIfChanged(\.isPageSearchPresented, false)
      setIfChanged(\.pageSearchQuery, "")
      setIfChanged(\.renderedSearchHighlightQuery, nil)
      resetPageSearchMatches()
    }

    applyDetailSelectionMetadata(for: location)
    setIfChanged(\.selectedLocation, location)
    setIfChanged(\.isEditingEntry, false)
    setIfChanged(\.editableEntryText, "")
    resetBlockState()
    setIfChanged(\.selectedEntrySourceMode, nextMode)
    setIfChanged(\.selectedEntrySource, nil)
    clearSelectedRenderedBlocks()
    setIfChanged(\.isRenderingEntrySource, false)
    scheduleBacklinksLoad(for: location)
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
    return selectedEntrySource != nil || isRenderingEntrySource || (isLoadingEntrySource && entrySourceLoadTask != nil)
  }

  private func applyDetailSelectionMetadata(for location: WorkspaceLocation) {
    if case .agenda(let item) = location {
      setIfChanged(\.selectedAgendaItemID, item.id)
    }
    if case .assigned(let item) = location {
      setIfChanged(\.selectedAssignedWorkItemID, item.id)
    }
    if case .openClaw(let thread) = location {
      setIfChanged(\.selectedOpenClawThreadID, thread.id)
    }
    if case .meeting(let meeting) = location {
      setIfChanged(\.selectedMeetingID, meeting.id)
    }
  }

  public func loadEntrySource(for location: WorkspaceLocation) async {
    entrySourceLoadTask?.cancel()
    entrySourceLoadTask = nil
    entrySourceLoadGeneration += 1
    let generation = entrySourceLoadGeneration
    await loadEntrySource(for: location, generation: generation)
  }

  private func scheduleEntrySourceLoad(for location: WorkspaceLocation) {
    entrySourceLoadGeneration += 1
    let generation = entrySourceLoadGeneration
    entrySourceLoadTask?.cancel()
    entrySourceLoadTask = Task { @MainActor [weak self] in
      await self?.loadEntrySource(for: location, generation: generation)
    }
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
      let loaded = try await Task.detached(priority: .userInitiated) {
        try Self.loadedEntrySource(file: location.file, line: location.lineForEditor, mode: mode)
      }.value
      guard generation == entrySourceLoadGeneration,
            selectedLocationMatches(location)
      else {
        return
      }
      let source = loaded.source
      selectedEntrySource = source
      pageSearchFullFileTextCache = (source.id, loaded.fullFileText)
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
      clearSelectedRenderedBlocks()
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
    setIfChanged(\.selectedBlockID, nil)
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
      setIfChanged(\.statusText, "Select a block first")
      return
    }
    let blocks = selectableBlocks
    guard let index = blocks.firstIndex(where: { $0.id == selectedBlock.id }) else {
      setIfChanged(\.selectedBlockID, nil)
      return
    }

    let nextIndex: Int
    switch direction {
    case .up:
      nextIndex = max(0, index - 1)
    case .down:
      nextIndex = min(blocks.count - 1, index + 1)
    }
    setIfChanged(\.selectedBlockID, blocks[nextIndex].id)
  }

  public func toggleRenderedBlockFold(_ block: OrgEditableBlock) {
    setRenderedBlock(block, folded: !foldedRenderedBlockIDs.contains(block.id))
  }

  @discardableResult
  public func collapseSelectedRenderedBlock() -> Bool {
    guard let selectedBlock else {
      setIfChanged(\.statusText, "Select a block first")
      return false
    }
    return setRenderedBlock(selectedBlock, folded: true)
  }

  @discardableResult
  public func expandSelectedRenderedBlock() -> Bool {
    guard let selectedBlock else {
      setIfChanged(\.statusText, "Select a block first")
      return false
    }
    return setRenderedBlock(selectedBlock, folded: false)
  }

  public func collapseAllRenderedBlocks() {
    let foldableIDs = OrgRenderedFoldTree.allFoldableIDs(in: selectedRenderedBlocks)
    setIfChanged(\.foldedRenderedBlockIDs, foldableIDs)
    if let selectedBlockID,
       let ancestorID = OrgRenderedFoldTree.foldedAncestorID(
        hiding: selectedBlockID,
        foldedBlockIDs: foldableIDs,
        blocks: selectedRenderedBlocks
       ) {
      setIfChanged(\.selectedBlockID, ancestorID)
    }
    setIfChanged(\.statusText, foldableIDs.isEmpty ? "Nothing to collapse" : "Collapsed rendered blocks")
  }

  public func expandAllRenderedBlocks() {
    setIfChanged(\.foldedRenderedBlockIDs, [])
    setIfChanged(\.statusText, "Expanded rendered blocks")
  }

  @discardableResult
  private func setRenderedBlock(_ block: OrgEditableBlock, folded: Bool) -> Bool {
    guard OrgRenderedFoldTree.isFoldable(block, in: selectedRenderedBlocks) else {
      setIfChanged(\.statusText, "Selected block has nothing to \(folded ? "collapse" : "expand")")
      return false
    }

    var nextFoldedIDs = foldedRenderedBlockIDs
    if folded {
      nextFoldedIDs.insert(block.id)
      if let selectedBlockID,
         let range = OrgRenderedFoldTree.childrenRange(for: block, in: selectedRenderedBlocks),
         let selectedIndex = selectedRenderedBlocks.firstIndex(where: { $0.id == selectedBlockID }),
         range.contains(selectedIndex) {
        setIfChanged(\.selectedBlockID, block.id)
      }
      setIfChanged(\.statusText, "Collapsed block")
    } else {
      nextFoldedIDs.remove(block.id)
      setIfChanged(\.statusText, "Expanded block")
    }
    setIfChanged(\.foldedRenderedBlockIDs, nextFoldedIDs)
    return true
  }

  public func beginEditingSelectedBlock() {
    guard let selectedBlock else {
      setIfChanged(\.statusText, "Select a block first")
      return
    }
    beginEditingBlock(selectedBlock)
  }

  public func beginEditingSelectedBlock(appending text: String) -> Bool {
    guard let selectedBlock else {
      setIfChanged(\.statusText, "Select a block first")
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
      setIfChanged(\.statusText, "Select a block first")
      return
    }
    await duplicateBlock(selectedBlock)
  }

  public func deleteSelectedBlock() async {
    guard let selectedBlock else {
      setIfChanged(\.statusText, "Select a block first")
      return
    }
    await deleteBlock(selectedBlock)
  }

  public func moveSelectedBlock(_ direction: OrgBlockMoveDirection) async {
    guard let selectedBlock else {
      setIfChanged(\.statusText, "Select a block first")
      return
    }
    await moveBlock(selectedBlock, direction: direction)
  }

  public func insertBlockAfterSelected(_ kind: OrgInsertBlockKind, initialText: String? = nil) async {
    guard let selectedBlock else {
      setIfChanged(\.statusText, "Select a block first")
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
        block.startLine >= source.startLine
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
          replacement: replacement,
          expectedOriginal: block.rawText
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
          replacement: normalizedReplacement,
          expectedOriginal: block.rawText
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
  }

  private func prepareSelectedRenderedBlocksDisplayState(for blocks: [OrgEditableBlock]) {
    let prunedFoldedBlockIDs = OrgRenderedFoldTree.prunedFoldedIDs(foldedRenderedBlockIDs, blocks: blocks)

    if preservesSelectedRenderedBlocksMetadataForNextAssignment {
      selectedRenderedBlocksRenderSignature = Self.renderedBlocksRenderSignature(for: blocks)
      preservesSelectedRenderedBlocksMetadataForNextAssignment = false
    } else {
      let metadata = Self.renderedBlocksMetadata(for: blocks)
      selectedRenderedBlocksRenderSignature = metadata.renderSignature
      selectedRenderedBlocksSignature = metadata.structureSignature
      selectedRenderedBlockIndexes = metadata.indexes
    }

    if prunedFoldedBlockIDs != foldedRenderedBlockIDs {
      foldedRenderedBlockIDs = prunedFoldedBlockIDs
    }
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
            replacement: replacement,
            expectedOriginal: block.rawText
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
      let deletionRange = try Self.deletionRange(for: block, in: source)
      let deletion = try Self.deletingSourceRangeCleaningAdjacentBlank(
        in: source,
        startLine: deletionRange.startLine,
        endLineExclusive: deletionRange.endLineExclusive
      )
      let currentRenderedBlocks = selectedRenderedBlocks
      try await Task.detached(priority: .userInitiated) {
        try Self.deleteSourceRangeCleaningAdjacentBlank(
          file: source.file,
          startLine: deletionRange.startLine,
          endLineExclusive: deletionRange.endLineExclusive
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
      cachedOpenClawAgentThreadDirectories = []
      return
    }

    let refreshRoot = corpusRoot.standardizedFileURL
    let request = OpenClawThreadRefreshRequest(corpusRoot: refreshRoot)
    isLoadingOpenClawThreads = true
    if let openClawThreadRefreshTask,
       openClawThreadRefreshRequest == request {
      _ = try? await openClawThreadRefreshTask.value
      return
    }

    let task = Task.detached(priority: .utility) {
      try Self.scanOpenClawThreads(corpusRoot: refreshRoot)
    }
    openClawThreadRefreshGeneration += 1
    let generation = openClawThreadRefreshGeneration
    openClawThreadRefreshTask = task
    openClawThreadRefreshRequest = request
    defer {
      if openClawThreadRefreshGeneration == generation {
        openClawThreadRefreshTask = nil
        openClawThreadRefreshRequest = nil
        isLoadingOpenClawThreads = false
      }
    }

    do {
      let result = try await task.value
      guard self.corpusRoot?.standardizedFileURL == refreshRoot else { return }
      refreshCachedOpenClawAgentThreadDirectories(corpusRoot: refreshRoot, directories: result.directories)
      openClawThreads = result.threads
      syncOpenClawSelectionAfterRefresh()
    } catch {
      errorText = error.localizedDescription
      statusText = "Agent records scan failed"
    }
  }

  public func refreshAssignedWork() async {
    guard let corpusRoot else {
      assignedWorkItems = []
      return
    }

    let refreshRoot = corpusRoot.standardizedFileURL
    isLoadingAssignedWork = true
    defer {
      if assignedWorkRefreshTask == nil {
        isLoadingAssignedWork = false
      }
    }

    do {
      let files = try await currentOrScannedCorpusFiles()
      let request = AssignedWorkRefreshRequest(
        corpusRoot: refreshRoot,
        filesSignature: Self.corpusFilesRefreshSignature(files)
      )
      if let assignedWorkRefreshTask,
         assignedWorkRefreshRequest == request {
        _ = try? await assignedWorkRefreshTask.value
        return
      }

      let task = Task.detached(priority: .utility) {
        try Self.scanAssignedWorkItems(files: files)
      }
      assignedWorkRefreshGeneration += 1
      let generation = assignedWorkRefreshGeneration
      assignedWorkRefreshTask = task
      assignedWorkRefreshRequest = request
      defer {
        if assignedWorkRefreshGeneration == generation {
          assignedWorkRefreshTask = nil
          assignedWorkRefreshRequest = nil
          isLoadingAssignedWork = false
        }
      }

      let items = try await task.value
      guard self.corpusRoot?.standardizedFileURL == refreshRoot else { return }
      assignedWorkItems = items
      if let selectedAssignedWorkItemID,
         let item = assignedWorkItemsByID[selectedAssignedWorkItemID] {
        if case .assigned = selectedLocation {
          selectedLocation = .assigned(item)
        }
      } else if selectedAssignedWorkItemID != nil {
        self.selectedAssignedWorkItemID = nil
        if case .assigned = selectedLocation {
          selectedLocation = nil
          setIfChanged(\.backlinks, nil)
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

  private func rebuildAssignedWorkDisplayCache(
    searchRows: [AssignedWorkSearchRow]? = nil,
    filter: String? = nil
  ) {
    let rows = searchRows ?? assignedWorkSearchRows
    let terms = Self.filterTerms(from: filter ?? agendaFilter)
    visibleAssignedWorkItems = rows.compactMap { row in
      guard !terms.isEmpty else { return row.item }
      return terms.allSatisfy { row.searchText.contains($0) } ? row.item : nil
    }
    visibleAssignedWorkItemsByID = Self.lookupByID(visibleAssignedWorkItems)
    assignedWorkSections = Self.groupAssignedWorkSections(visibleAssignedWorkItems, corpusRoot: corpusRoot)
    displayedAssignedWorkItems = assignedWorkSections.flatMap(\.items).map(\.item)
    var indicesByID: [AssignedWorkItem.ID: Int] = [:]
    indicesByID.reserveCapacity(displayedAssignedWorkItems.count)
    for (index, item) in displayedAssignedWorkItems.enumerated() {
      indicesByID[item.id] = index
    }
    displayedAssignedWorkItemIndicesByID = indicesByID
  }

  private static func groupAssignedWorkSections(
    _ items: [AssignedWorkItem],
    corpusRoot: URL?
  ) -> [AssignedWorkSection] {
    let grouped = Dictionary(grouping: items) { item in
      "\(item.assignee)|\(Self.assignedWorkTodoGroupLabel(for: item))"
    }
    let standardizedRoot = corpusRoot?.standardizedFileURL
    func displayItems(_ items: [AssignedWorkItem]) -> [AssignedWorkDisplayItem] {
      items.map { item in
        AssignedWorkDisplayItem(
          item: item,
          relativePath: standardizedRoot.map { Self.relativePath(for: item.file, root: $0) } ?? item.file
        )
      }
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
        items: displayItems(items)
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
    setIfChanged(\.selectedSurface, .agenda)
    setIfChanged(\.selectedAssignedWorkItemID, item.id)
    select(.assigned(item))
  }

  public func activateAssignedWorkItemFromRowTap(_ item: AssignedWorkItem) {
    guard selectedAssignedWorkItemID != item.id else { return }
    selectAssignedWorkItem(item)
    suppressNextAssignedWorkSelectionActivation = true
  }

  public func consumeAssignedWorkSelectionActivationSuppression() -> Bool {
    guard suppressNextAssignedWorkSelectionActivation else { return false }
    suppressNextAssignedWorkSelectionActivation = false
    return true
  }

  public func selectOpenClawThread(_ thread: OpenClawThread) {
    openOpenClawThread(thread, surface: .files)
  }

  private func openOpenClawThread(_ thread: OpenClawThread, surface: WorkspaceSurface? = nil, mode: EntrySourceMode? = nil) {
    guard !isActiveOpenClawThread(thread, mode: mode) else { return }
    if let surface {
      setIfChanged(\.selectedSurface, surface)
    }
    activateDetailLocation(.openClaw(thread), mode: mode, recordsHistory: true)
  }

  private func isActiveOpenClawThread(_ thread: OpenClawThread, mode: EntrySourceMode?) -> Bool {
    let location = WorkspaceLocation.openClaw(thread)
    let nextMode = resolvedEntrySourceMode(for: location, requestedMode: mode)
    guard selectedLocation != nil,
          selectedLocationMatches(location),
          selectedEntrySourceMode == nextMode
    else {
      return false
    }
    return selectedEntrySource != nil || isLoadingEntrySource || isRenderingEntrySource
  }

  public func selectCorpusFile(_ file: CorpusFile) {
    setIfChanged(\.selectedSurface, .files)
    setIfChanged(\.selectedCorpusFileID, file.id)
    let thread = OpenClawThread(
      title: file.name,
      file: file.path,
      line: 1,
      zone: file.directory.isEmpty ? "corpus" : file.directory,
      modifiedAt: file.modifiedAt,
      idValue: nil
    )
    activateDetailLocation(.openClaw(thread), mode: .page, recordsHistory: true)
    setIfChanged(\.selectedOpenClawThreadID, nil)
    setIfChanged(\.statusText, "Opened \(file.relativePath)")
  }

  public func activateCorpusFileFromRowTap(_ file: CorpusFile) {
    guard !isActiveCorpusFile(file) else { return }
    suppressedCorpusFileSelectionActivation = file
    selectCorpusFile(file)
  }

  public func consumeCorpusFileSelectionActivationSuppression(for id: CorpusFile.ID) -> Bool {
    guard let file = suppressedCorpusFileSelectionActivation, file.id == id else {
      suppressedCorpusFileSelectionActivation = nil
      return false
    }
    defer {
      suppressedCorpusFileSelectionActivation = nil
    }
    return selectedCorpusFileLocationMatches(file)
  }

  private func isActiveCorpusFile(_ file: CorpusFile) -> Bool {
    guard selectedCorpusFileLocationMatches(file) else { return false }
    return selectedEntrySource != nil || isLoadingEntrySource || isRenderingEntrySource
  }

  private func selectedCorpusFileLocationMatches(_ file: CorpusFile) -> Bool {
    guard selectedCorpusFileID == file.id,
          let selectedLocation
    else {
      return false
    }
    let selectedPath = URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path
    let filePath = URL(fileURLWithPath: file.path).standardizedFileURL.path
    return selectedPath == filePath
  }

  public func corpusFile(id: CorpusFile.ID) -> CorpusFile? {
    corpusFilesByID[id]
  }

  public func presentQuickOpen() {
    guard corpusRoot != nil else {
      setIfChanged(\.statusText, "No corpus selected")
      return
    }
    setIfChanged(\.quickOpenQuery, "")
    resetQuickOpenSelection()
    setIfChanged(\.isQuickOpenPresented, true)
    if corpusFiles.isEmpty, !isScanningCorpusFiles {
      Task { await refreshCorpusFiles() }
    }
  }

  public func focusSearchSurface() {
    setIfChanged(\.selectedSurface, .search)
    searchFocusToken += 1
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
    setIfChanged(\.selectedSurface, .search)
    activateDetailLocation(.openClaw(thread), mode: .entry, recordsHistory: true)
    setIfChanged(\.selectedOpenClawThreadID, nil)
    setIfChanged(\.statusText, "Opened \(relativePath(node.file)):\(node.line)")
  }

  private func rebuildFilteredCorpusFiles(files: [CorpusFile]? = nil, query: String? = nil) {
    filteredCorpusFiles = filterFiles(query ?? corpusFileFilter, in: files ?? corpusFiles, limit: 500)
  }

  private func rebuildSearchNodeCacheIfNeeded(
    mode: WorkspaceSearchMode? = nil,
    query: String? = nil,
    indexedNodes: [OrgRoamNodeReference]? = nil
  ) {
    let sourceNodes = indexedNodes ?? indexedSearchNodes
    let relativePathsByFile = searchNodeRelativePathsByFile
    let indexedRows = Self.indexSearchNodes(sourceNodes, relativePathsByFile: relativePathsByFile)
    if indexedNodes != nil {
      indexedSearchNodeRows = indexedRows
    }
    scheduleSearchNodeFilter(mode: mode, query: query, indexedRows: indexedRows, debounce: false)
  }

  private func scheduleSearchNodeFilter(
    mode: WorkspaceSearchMode? = nil,
    query: String? = nil,
    indexedRows: [IndexedSearchNode]? = nil,
    debounce: Bool = true
  ) {
    let resolvedMode = mode ?? searchMode
    searchNodeFilterGeneration += 1
    let generation = searchNodeFilterGeneration
    searchNodeFilterTask?.cancel()

    guard resolvedMode == .nodes else {
      if !searchNodes.isEmpty {
        searchNodes = []
      }
      searchNodeFilterTask = nil
      return
    }

    let rows = indexedRows ?? indexedSearchNodeRows
    let searchText = query ?? searchQuery
    searchNodeFilterTask = Task { [rows, searchText, generation, debounce] in
      if debounce {
        try? await Task.sleep(nanoseconds: 80_000_000)
      }
      guard !Task.isCancelled else { return }

      let filtered = await Task.detached(priority: .userInitiated) {
        Self.filterIndexedSearchNodes(rows, query: searchText, limit: 100)
      }.value
      guard !Task.isCancelled else { return }

      await MainActor.run { [weak self] in
        guard let self, self.searchNodeFilterGeneration == generation else { return }
        self.searchNodes = filtered
      }
    }
  }

  public func flushSearchNodeFilter() async {
    await searchNodeFilterTask?.value
  }

  private func rebuildSearchResultDisplayCache(results newResults: [SearchResult]? = nil) {
    corpusSearchResultDisplayGroups = Self.groupedSearchResultDisplayGroups(
      newResults ?? searchResults,
      corpusRoot: corpusRoot
    )
  }

  private func rebuildSearchNodeDisplayCache(nodes newNodes: [OrgRoamNodeReference]? = nil) {
    let nodes = newNodes ?? searchNodes
    let standardizedRoot = corpusRoot?.standardizedFileURL
    searchNodeDisplayItems = nodes.map { node in
      SearchNodeDisplayItem(
        node: node,
        relativePath: standardizedRoot.map { Self.relativePath(for: node.file, root: $0) }
          ?? searchNodeRelativePathsByFile[node.file]
          ?? node.file
      )
    }
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

  nonisolated static func groupedSearchResultDisplayGroups(
    _ results: [SearchResult],
    corpusRoot: URL?
  ) -> [SearchResultDisplayGroup] {
    let standardizedRoot = corpusRoot?.standardizedFileURL
    let displayItems = results.map { result in
      SearchResultDisplayItem(
        result: result,
        relativePath: standardizedRoot.map { Self.relativePath(for: result.file, root: $0) } ?? result.file
      )
    }
    var grouped: [String: [SearchResultDisplayItem]] = [:]
    var fileOrder: [String] = []

    for item in displayItems {
      let file = item.result.file
      if grouped[file] == nil {
        fileOrder.append(file)
        grouped[file] = []
      }
      grouped[file]?.append(item)
    }

    return fileOrder.compactMap { file in
      SearchResultDisplayGroup(file: file, results: grouped[file] ?? [])
    }
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
    if let selectedQuickOpenFileID,
       let selected = quickOpenFilesByID[selectedQuickOpenFileID] {
      return selected
    }
    return quickOpenFiles.first
  }

  public func resetQuickOpenSelection() {
    setIfChanged(\.selectedQuickOpenFileID, nil)
  }

  public func moveQuickOpenSelection(_ direction: QuickOpenSelectionDirection) {
    let files = quickOpenFiles
    guard !files.isEmpty else {
      setIfChanged(\.selectedQuickOpenFileID, nil)
      return
    }

    let currentIndex = selectedQuickOpenFileID.flatMap { quickOpenFileIndicesByID[$0] }
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
    setIfChanged(\.selectedQuickOpenFileID, files[nextIndex].id)
  }

  private func rebuildQuickOpenIndex(files: [CorpusFile]? = nil) {
    quickOpenIndexedFiles = Self.indexQuickOpenFiles(files ?? corpusFiles)
  }

  private func rebuildQuickOpenDisplayLookup(files: [CorpusFile]? = nil) {
    let sourceFiles = files ?? quickOpenFiles
    quickOpenFilesByID = Self.lookupByID(sourceFiles)
    var indicesByID: [CorpusFile.ID: Int] = [:]
    indicesByID.reserveCapacity(sourceFiles.count)
    for (index, file) in sourceFiles.enumerated() {
      indicesByID[file.id] = index
    }
    quickOpenFileIndicesByID = indicesByID
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
    if quickOpenFilesByID[selectedQuickOpenFileID] == nil {
      setIfChanged(\.selectedQuickOpenFileID, nil)
    }
  }

  private func filterFiles(_ rawQuery: String, in files: [CorpusFile]? = nil, limit: Int) -> [CorpusFile] {
    let sourceFiles = files ?? corpusFiles
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return Array(sourceFiles.prefix(limit))
    }

    return sourceFiles
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

  nonisolated private static func indexSearchNodes(
    _ nodes: [OrgRoamNodeReference],
    relativePathsByFile: [String: String]
  ) -> [IndexedSearchNode] {
    nodes.map { node in
      IndexedSearchNode(
        node: node,
        relativePath: relativePathsByFile[node.file] ?? node.file,
        aliasesText: node.aliases.joined(separator: " ")
      )
    }
  }

  nonisolated private static func filterIndexedSearchNodes(
    _ rows: [IndexedSearchNode],
    query rawQuery: String,
    limit: Int
  ) -> [OrgRoamNodeReference] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return Array(rows.sorted(by: compareIndexedSearchNodes).prefix(limit).map(\.node))
    }

    let normalizedQuery = query.lowercased()
    return rows
      .compactMap { row -> (IndexedSearchNode, Int)? in
        let candidates = [
          row.node.title,
          row.aliasesText,
          row.node.idValue ?? "",
          row.relativePath
        ]
        let bestScore = candidates.compactMap { Self.fuzzyScore(query: query, candidate: $0) }.max()
        guard let bestScore else { return nil }
        let exactBoost = ([row.node.title] + row.node.aliases)
          .contains { $0.lowercased().contains(normalizedQuery) } ? 50 : 0
        return (row, bestScore + exactBoost)
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return compareIndexedSearchNodes(lhs.0, rhs.0)
      }
      .prefix(limit)
      .map(\.0.node)
  }

  nonisolated private static func compareIndexedSearchNodes(_ lhs: IndexedSearchNode, _ rhs: IndexedSearchNode) -> Bool {
    let titleOrder = lhs.node.title.localizedCaseInsensitiveCompare(rhs.node.title)
    if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
    let pathOrder = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
    if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
    return lhs.node.line < rhs.node.line
  }

  private func selectedLocationMatches(_ location: WorkspaceLocation) -> Bool {
    guard let selectedLocation else { return true }
    return Self.selectionIdentity(for: selectedLocation) == Self.selectionIdentity(for: location)
  }

  nonisolated private static func selectionIdentity(for location: WorkspaceLocation) -> WorkspaceSelectionIdentity {
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
    return WorkspaceSelectionIdentity(
      kind: kind,
      file: location.file,
      line: location.lineForEditor,
      title: selectionIdentityTitle(for: location)
    )
  }

  nonisolated private static func selectionIdentityTitle(for location: WorkspaceLocation) -> String {
    switch location {
    case .agenda(let item):
      item.headline
    case .assigned(let item):
      item.headline
    case .search(let result):
      result.title
    case .backlink(let backlink):
      backlink.srcTitle
    case .openClaw(let thread):
      thread.title
    case .meeting(let meeting):
      meeting.title
    }
  }

  private func scheduleAgendaRefresh(preserveSelection: Bool = true, updatesStatus: Bool = false) {
    scheduledAgendaRefreshTask?.cancel()
    scheduledAgendaRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled, let self else { return }
      await self.refreshAgenda(preserveSelection: preserveSelection, updatesStatus: updatesStatus)
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
    setIfChanged(\.editingBlockID, nil)
    setIfChanged(\.editableBlockText, "")
    if !activeBlockDrafts.isEmpty {
      activeBlockDrafts.removeAll()
    }
    if !activeBlockOriginals.isEmpty {
      activeBlockOriginals.removeAll()
    }
    if !deferredStableAutosaves.isEmpty {
      deferredStableAutosaves.removeAll()
    }
    if wasEditingBlock, pendingAgendaRefreshAfterBlockEditing {
      pendingAgendaRefreshAfterBlockEditing = false
      scheduleAgendaRefresh(preserveSelection: true)
    }
  }

  private func resetBlockState() {
    setIfChanged(\.selectedBlockID, nil)
    if pendingBlockSelection != nil {
      pendingBlockSelection = nil
    }
    if transientDraftBlock != nil {
      transientDraftBlock = nil
    }
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

    guard let replacementBody = Self.normalizedTransientDraftText(editingDraftText(for: draft.block), for: draft.block) else {
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
        replacement: normalizedReplacement,
        expectedOriginal: block.rawText
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

  private func appendDraftBlock(
    kind: OrgInsertBlockKind,
    in source: EntrySource
  ) -> TransientDraftBlock {
    let rawText = appendDraftRawText(for: kind)
    let insertionLine = max(source.startLine, source.endLineExclusive)
    let isSourceEmpty = source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let replacementPrefix = isSourceEmpty ? "" : "\n"
    let selectionLineOffset = replacementPrefix.isEmpty ? 0 : 1
    return TransientDraftBlock(
      file: source.file,
      insertionLine: insertionLine,
      replacementEndLineExclusive: insertionLine,
      replacementPrefix: replacementPrefix,
      replacementSuffix: "",
      selectionLineOffset: selectionLineOffset,
      block: OrgEditableBlock(
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
    Task { await openDailyNoteNow(target) }
  }

  public func openDailyNoteNow(_ target: DailyNoteTarget) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    do {
      let prepared = try await Task.detached(priority: .userInitiated) {
        try Self.prepareDailyNote(corpusRoot: corpusRoot, date: Self.date(for: target))
      }.value
      openPreparedDailyNote(prepared, home: false)
      statusText = "Opened \(prepared.file.relativePath)"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not open daily note"
    }
  }

  public func openHome() {
    Task { await openHomeNow() }
  }

  public func openHomeNow() async {
    setIfChanged(\.selectedSurface, .home)
    setIfChanged(\.expandedWorkspaceSurface, nil)
    setIfChanged(\.isWorkspaceSurfacePaneClosed, false)
    setIfChanged(\.isWorkspaceDetailPaneClosed, false)
    setIfChanged(\.isWorkspaceDetailPaneExpanded, false)

    guard let corpusRoot else {
      setIfChanged(\.statusText, "No corpus selected")
      return
    }

    do {
      let prepared = try await Task.detached(priority: .userInitiated) {
        try Self.prepareDailyNote(corpusRoot: corpusRoot, date: Date())
      }.value
      openPreparedDailyNote(prepared, home: true)
      statusText = "Home"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not open daily note"
    }
  }

  private func openPreparedDailyNote(_ prepared: PreparedDailyNote, home: Bool) {
    let file = prepared.file
    upsertCorpusFile(file)
    if !home {
      setIfChanged(\.selectedSurface, .files)
    }
    selectedCorpusFileID = file.id
    selectedOpenClawThreadID = nil
    let thread = OpenClawThread(
      title: file.name,
      file: file.path,
      line: 1,
      zone: file.directory.isEmpty ? (home ? "daily" : "corpus") : file.directory,
      modifiedAt: file.modifiedAt,
      idValue: nil
    )
    activateDetailLocation(.openClaw(thread), mode: .page, recordsHistory: !home)
  }

  nonisolated private static func prepareDailyNote(corpusRoot: URL, date: Date) throws -> PreparedDailyNote {
    let root = corpusRoot.standardizedFileURL
    let url = Self.dailyNotePath(corpusRoot: root, date: date)
    if !FileManager.default.fileExists(atPath: url.path) {
      try Self.createDailyNote(at: url)
    }
    return PreparedDailyNote(file: Self.corpusFile(for: url, corpusRoot: root))
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

      openClawDraft = Self.openClawDraftByAppendingDictation(existing: openClawDraft, dictatedText: dictatedText)
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
    Task { await attachOpenClawImagesNow(urls: urls) }
  }

  public func attachOpenClawImagesNow(urls: [URL]) async {
    let prepared = await Self.prepareOpenClawImageAttachments(from: urls)
    var attachments = openClawPendingAttachments
    for attachment in prepared.attachments {
      guard !attachments.contains(where: { $0.data == attachment.data && $0.fileName == attachment.fileName }) else {
        continue
      }
      attachments.append(attachment)
    }
    setIfChanged(\.openClawPendingAttachments, attachments)
    if let failureFileName = prepared.failureFileName {
      errorText = prepared.failureMessage
      openClawStatusText = "Could not attach \(failureFileName)"
    }
    if !attachments.isEmpty {
      openClawStatusText = "\(attachments.count) image attachment\(attachments.count == 1 ? "" : "s") ready"
    }
  }

  public func removeOpenClawPendingAttachment(_ attachment: OpenClawChatAttachment) {
    openClawPendingAttachments.removeAll { $0.id == attachment.id }
  }

  public func clearOpenClawPendingAttachments() {
    setIfChanged(\.openClawPendingAttachments, [])
  }

  public func setOpenClawDraft(_ draft: String) {
    setIfChanged(\.openClawDraft, draft)
  }

  public func clearOpenClawDraft() {
    setOpenClawDraft("")
  }

  public func sendOpenClawMessage() async {
    let text = openClawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = openClawPendingAttachments
    guard !text.isEmpty || !attachments.isEmpty else { return }
    setIfChanged(\.openClawDraft, "")
    setIfChanged(\.openClawPendingAttachments, [])
    await sendOpenClawMessage(text, attachments: attachments)
  }

  public func sendOpenClawMessage(text rawText: String) async {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    setIfChanged(\.openClawDraft, "")
    await sendOpenClawMessage(text, attachments: [])
  }

  public func sendComposedOpenClawMessage(text rawText: String) async {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = openClawPendingAttachments
    guard !text.isEmpty || !attachments.isEmpty else { return }
    setIfChanged(\.openClawDraft, "")
    setIfChanged(\.openClawPendingAttachments, [])
    enqueueOpenClawMessage(text, attachments: attachments)
    guard !isDrainingOpenClawQueue else {
      setIfChanged(\.openClawStatusText, openClawQueuedStatusText())
      return
    }
    Task { @MainActor in
      await self.drainOpenClawSendQueue()
    }
  }

  private func sendOpenClawMessage(_ text: String, attachments: [OpenClawChatAttachment]) async {
    enqueueOpenClawMessage(text, attachments: attachments)
    if isDrainingOpenClawQueue {
      setIfChanged(\.openClawStatusText, openClawQueuedStatusText())
      return
    }
    await drainOpenClawSendQueue()
  }

  private func enqueueOpenClawMessage(_ text: String, attachments: [OpenClawChatAttachment]) {
    ensureOpenClawChatThread()
    let userMessage = OpenClawChatMessage(role: .user, content: text, attachments: attachments)
    openClawMessages.append(userMessage)
    openClawPendingUserMessageIDs.append(userMessage.id)
  }

  private func setOpenClawSending(_ isSending: Bool) {
    setIfChanged(
      \.openClawSendState,
      OpenClawSendState(isSending: isSending, startedAt: isSending ? Date() : nil)
    )
  }

  private func drainOpenClawSendQueue() async {
    guard !isDrainingOpenClawQueue else { return }
    isDrainingOpenClawQueue = true
    setOpenClawSending(true)
    defer {
      isDrainingOpenClawQueue = false
      setOpenClawSending(false)
    }

    while let userMessageID = openClawPendingUserMessageIDs.first {
      guard let request = await prepareOpenClawSendRequest(for: userMessageID) else {
        openClawPendingUserMessageIDs.removeFirst()
        continue
      }
      setIfChanged(\.openClawStatusText, openClawQueuedStatusText())

      do {
        clearOpenClawSendFailure(for: userMessageID, at: request.userMessageIndex)
        let beforeSnapshot = await captureOpenClawCorpusSnapshot()
        let reply = try await sendOpenClawRequest(messages: request.messages)
        let changeSummary = await openClawChangeSummary(since: beforeSnapshot, referencedIn: reply)
        insertOpenClawReply(
          reply,
          after: userMessageID,
          expectedIndex: request.userMessageIndex,
          changeSummary: changeSummary
        )
        if let changeSummary {
          await refreshAfterOpenClawChanges(changeSummary)
        }
        openClawPendingUserMessageIDs.removeFirst()
        if openClawPendingUserMessageIDs.isEmpty {
          setIfChanged(\.openClawStatusText, changeSummary.map {
            "\($0.title): +\($0.totalInsertions) -\($0.totalDeletions)"
          } ?? "OpenClaw replied")
        } else {
          setIfChanged(\.openClawStatusText, openClawQueuedStatusText())
        }
      } catch {
        let failureText = Self.openClawSendFailureText(from: error)
        setIfChanged(\.openClawStatusText, failureText)
        markPendingOpenClawMessagesFailed(failureText)
        openClawPendingUserMessageIDs.removeAll()
        return
      }
    }
  }

  private func sendOpenClawRequest(messages: [OpenClawChatMessage]) async throws -> String {
    let agentID = openClawAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : openClawAgentID
    let workspaceContext = currentOpenClawWorkspaceContext()
    if let openClawSendHandler {
      return try await openClawSendHandler(messages, agentID, openClawSessionKey, workspaceContext)
    }
    let userEndpoint = openClawEndpointText
    let cachedBearerToken = openClawBearerToken
    let hasStoredToken = openClawHasStoredToken
    let resolved = await Task.detached(priority: .utility) {
      Self.resolvedOpenClawSettings(
        userEndpoint: userEndpoint,
        cachedBearerToken: cachedBearerToken,
        hasStoredToken: hasStoredToken,
        allowKeychainRead: true
      )
    }.value
    openClawBearerToken = resolved.bearerToken
    setIfChanged(\.openClawHasStoredToken, resolved.hasStoredToken)
    let client = OpenClawChatClient(settings: resolved.settings)
    return try await client.send(
      messages: messages,
      agentID: agentID,
      sessionKey: openClawSessionKey,
      workspaceContext: workspaceContext
    )
  }

  private func prepareOpenClawSendRequest(for messageID: UUID) async -> PreparedOpenClawSendRequest? {
    let messages = openClawMessages
    return await Task.detached(priority: .userInitiated) {
      Self.preparedOpenClawSendRequest(messages: messages, userMessageID: messageID)
    }.value
  }

  nonisolated private static func preparedOpenClawSendRequest(
    messages: [OpenClawChatMessage],
    userMessageID: UUID
  ) -> PreparedOpenClawSendRequest? {
    guard let index = messages.firstIndex(where: { $0.id == userMessageID }) else {
      return nil
    }
    return PreparedOpenClawSendRequest(
      userMessageID: userMessageID,
      userMessageIndex: index,
      messages: Array(messages[...index])
    )
  }

  private func insertOpenClawReply(
    _ reply: String,
    after userMessageID: UUID,
    expectedIndex: Int? = nil,
    changeSummary: OpenClawCorpusChangeSummary?
  ) {
    let assistantMessage = OpenClawChatMessage(role: .assistant, content: reply, changeSummary: changeSummary)
    if let expectedIndex,
       openClawMessages.indices.contains(expectedIndex),
       openClawMessages[expectedIndex].id == userMessageID {
      openClawMessages.insert(assistantMessage, at: openClawMessages.index(after: expectedIndex))
      return
    }
    guard let index = openClawMessages.firstIndex(where: { $0.id == userMessageID }) else {
      openClawMessages.append(assistantMessage)
      return
    }
    openClawMessages.insert(assistantMessage, at: openClawMessages.index(after: index))
  }

  public func retryOpenClawMessage(_ messageID: UUID) async {
    guard let message = openClawMessages.first(where: { $0.id == messageID }),
          message.role == .user,
          message.sendFailure != nil
    else {
      return
    }
    guard !openClawPendingUserMessageIDs.contains(messageID) else { return }
    clearOpenClawSendFailure(for: messageID)
    openClawPendingUserMessageIDs.append(messageID)
    if isDrainingOpenClawQueue {
      setIfChanged(\.openClawStatusText, openClawQueuedStatusText())
      return
    }
    await drainOpenClawSendQueue()
  }

  private func clearOpenClawSendFailure(for messageID: UUID) {
    replaceOpenClawSendFailure(for: messageID, with: nil)
  }

  private func clearOpenClawSendFailure(for messageID: UUID, at expectedIndex: Int) {
    replaceOpenClawSendFailure(for: messageID, expectedIndex: expectedIndex, with: nil)
  }

  private func markPendingOpenClawMessagesFailed(_ failureText: String) {
    for messageID in openClawPendingUserMessageIDs {
      replaceOpenClawSendFailure(for: messageID, with: failureText)
    }
  }

  private func replaceOpenClawSendFailure(
    for messageID: UUID,
    expectedIndex: Int? = nil,
    with failureText: String?
  ) {
    if let expectedIndex,
       openClawMessages.indices.contains(expectedIndex),
       openClawMessages[expectedIndex].id == messageID {
      let message = openClawMessages[expectedIndex]
      guard message.sendFailure != failureText else { return }
      openClawMessages[expectedIndex] = message.replacingSendFailure(failureText)
      return
    }
    guard let index = openClawMessages.firstIndex(where: { $0.id == messageID }) else { return }
    let message = openClawMessages[index]
    guard message.sendFailure != failureText else { return }
    openClawMessages[index] = message.replacingSendFailure(failureText)
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
    for delay in Self.openClawChangeSnapshotRetryDelays {
      if delay > 0 {
        try? await Task.sleep(nanoseconds: delay)
      }
      guard let afterSnapshot = try? await Task.detached(priority: .utility, operation: {
        try Self.openClawCorpusSnapshot(corpusRoot: root)
      }).value else {
        continue
      }
      if let summary = Self.openClawChangeSummary(before: snapshot, after: afterSnapshot) {
        return attributedOpenClawChangeSummary(summary, referencedIn: reply)
      }
    }
    return nil
  }

  private func attributedOpenClawChangeSummary(
    _ summary: OpenClawCorpusChangeSummary,
    referencedIn reply: String
  ) -> OpenClawCorpusChangeSummary {
    let referencedPaths = openClawReferencedChangeRelativePaths(in: reply)
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

    await refreshCorpusFiles()
    await refreshAgenda(preserveSelection: true, updatesStatus: false)
    await refreshMeetings()
    Task { await refreshOpenClawThreads() }

    if let generatedBriefRelativePath {
      let artifactURL = root.appendingPathComponent(generatedBriefRelativePath).standardizedFileURL
      openNodeBriefArtifact(
        url: artifactURL,
        relativePath: generatedBriefRelativePath,
        title: generatedBriefTitle ?? artifactURL.deletingPathExtension().lastPathComponent
      )
    }
  }

  private func openClawQueuedStatusText() -> String {
    if openClawPendingUserMessageIDs.count > 1 {
      return "Sending to OpenClaw... \(openClawPendingUserMessageIDs.count - 1) queued"
    }
    return "Sending to OpenClaw..."
  }

  public func resetOpenClawChat() {
    ensureOpenClawChatThread()
    setIfChanged(\.openClawMessages, [])
    setIfChanged(\.openClawDraft, "")
    setIfChanged(\.openClawPendingAttachments, [])
    if !openClawPendingUserMessageIDs.isEmpty {
      openClawPendingUserMessageIDs.removeAll()
    }
    isDrainingOpenClawQueue = false
    setOpenClawSending(false)
    openClawChatScrollPosition = nil
    openClawAssistantChatScrollPosition = nil
    openClawStatusText = Self.openClawStatusText(settings: currentOpenClawSettings())
  }

  public var selectedOpenClawChatThread: OpenClawChatThread? {
    guard let selectedOpenClawChatThreadID else { return nil }
    guard let thread = openClawChatThread(with: selectedOpenClawChatThreadID) else { return nil }
    return openClawChatThreadForStorage(thread, messages: openClawMessages(for: thread))
  }

  public func createOpenClawChatThread() {
    guard !isSendingOpenClawMessage else { return }
    let thread = OpenClawChatThread(
      title: "New Chat",
      sessionKey: Self.makeOpenClawSessionKey()
    )
    openClawChatThreads.insert(thread, at: 0)
    selectOpenClawChatThread(thread.id, persistsSelection: false)
    persistOpenClawTranscript()
    openClawStatusText = "New OpenClaw chat"
  }

  public func selectOpenClawChatThread(_ id: UUID) {
    selectOpenClawChatThread(id, persistsSelection: true)
  }

  public func selectOpenClawChatSearchResult(_ result: OpenClawChatSearchResult) {
    selectOpenClawChatThread(result.threadID)
    setIfChanged(\.selectedSurface, .openClaw)
    setIfChanged(\.statusText, "Opened chat thread")
  }

  public func toggleOpenClawChatThreadPin(_ id: UUID) {
    guard let index = openClawChatThreadIndex(for: id) else { return }
    var threads = openClawChatThreads
    let thread = threads[index]
    threads[index] = Self.openClawChatThreadWithoutMessages(
      thread.replacingOpenClawChatMetadata(isPinned: !thread.isPinned)
    )
    openClawChatThreads = Self.sortedOpenClawChatThreadsForDisplay(threads)
    persistOpenClawTranscript()
  }

  public func archiveOpenClawChatThread(_ id: UUID) {
    guard let index = openClawChatThreadIndex(for: id) else { return }
    var threads = openClawChatThreads
    let thread = threads[index]
    threads[index] = Self.openClawChatThreadWithoutMessages(
      thread.replacingOpenClawChatMetadata(isArchived: true)
    )
    openClawChatThreads = Self.sortedOpenClawChatThreadsForDisplay(threads)
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
    guard let index = openClawChatThreadIndex(for: id) else { return }
    var threads = openClawChatThreads
    let thread = threads[index]
    threads[index] = Self.openClawChatThreadWithoutMessages(
      thread.replacingOpenClawChatMetadata(isArchived: false)
    )
    openClawChatThreads = Self.sortedOpenClawChatThreadsForDisplay(threads)
    persistOpenClawTranscript()
  }

  private func selectOpenClawChatThread(_ id: UUID, persistsSelection: Bool) {
    guard !isSendingOpenClawMessage,
          let thread = openClawChatThread(with: id)
    else {
      return
    }
    if selectedOpenClawChatThreadID == thread.id {
      let markedRead = markOpenClawChatThreadRead(thread.id, shouldPersist: false)
      if persistsSelection && markedRead {
        persistOpenClawTranscript(delayNanoseconds: Self.openClawTranscriptSelectionPersistenceDelay)
      }
      return
    }

    storeSelectedOpenClawThreadMessagesForInactiveUse()
    let selectedMessages = openClawMessages(for: thread)
    setIfChanged(\.selectedOpenClawChatThreadID, thread.id)
    openClawSessionKey = thread.sessionKey
    markOpenClawChatThreadRead(thread.id, shouldPersist: false)
    setIfChanged(\.openClawDraft, "")
    setIfChanged(\.openClawPendingAttachments, [])
    if !openClawPendingUserMessageIDs.isEmpty {
      openClawPendingUserMessageIDs.removeAll()
    }
    isDrainingOpenClawQueue = false
    setOpenClawSending(false)
    openClawChatScrollPosition = nil
    openClawAssistantChatScrollPosition = nil
    resetOpenClawVisibleMessageLimit(rebuildsVisibleMessages: false)
    replaceOpenClawMessages(selectedMessages, shouldPersist: false)
    detachSelectedOpenClawThreadMessagesForActiveUse()
    if persistsSelection {
      persistOpenClawTranscript(delayNanoseconds: Self.openClawTranscriptSelectionPersistenceDelay)
    }
  }

  public func showOlderOpenClawMessages() {
    guard hiddenOpenClawMessageCount > 0 else { return }
    setOpenClawVisibleMessageLimit(
      min(openClawMessages.count, openClawVisibleMessageLimit + Self.openClawVisibleMessageLimitStep)
    )
  }

  private func resetOpenClawVisibleMessageLimit(rebuildsVisibleMessages: Bool = true) {
    setOpenClawVisibleMessageLimit(
      Self.defaultOpenClawVisibleMessageLimit,
      rebuildsVisibleMessages: rebuildsVisibleMessages
    )
  }

  private func setOpenClawVisibleMessageLimit(
    _ limit: Int,
    rebuildsVisibleMessages: Bool = true
  ) {
    let nextLimit = max(0, limit)
    guard openClawVisibleMessageLimit != nextLimit else { return }
    openClawVisibleMessageLimit = nextLimit
    if rebuildsVisibleMessages {
      rebuildVisibleOpenClawMessages(limit: nextLimit)
    }
  }

  private func rebuildVisibleOpenClawMessages(
    messages: [OpenClawChatMessage]? = nil,
    limit: Int? = nil
  ) {
    let sourceMessages = messages ?? openClawMessages
    let messageLimit = max(0, limit ?? openClawVisibleMessageLimit)
    guard sourceMessages.count > messageLimit else {
      setVisibleOpenClawMessages(sourceMessages)
      return
    }
    setVisibleOpenClawMessages(Array(sourceMessages.suffix(messageLimit)))
  }

  private func setVisibleOpenClawMessages(_ messages: [OpenClawChatMessage]) {
    let signature = Self.openClawMessagesRenderSignature(for: messages)
    guard visibleOpenClawMessagesRenderSignature != signature else { return }
    visibleOpenClawMessagesRenderSignature = signature
    visibleOpenClawMessages = messages
  }

  private func ensureOpenClawChatThread() {
    if let selectedOpenClawChatThreadID,
       openClawChatThreadIndex(for: selectedOpenClawChatThreadID) != nil {
      return
    }
    let thread = OpenClawChatThread(
      title: Self.openClawThreadTitle(from: openClawMessages),
      sessionKey: openClawSessionKey,
      messages: openClawMessages
    )
    storeOpenClawMessages(openClawMessages, for: thread.id)
    openClawChatThreads.insert(Self.openClawChatThreadWithoutMessages(thread), at: 0)
    setIfChanged(\.selectedOpenClawChatThreadID, thread.id)
  }

  public func markSelectedOpenClawChatThreadRead() {
    guard let selectedOpenClawChatThreadID else { return }
    markOpenClawChatThreadRead(selectedOpenClawChatThreadID, shouldPersist: true)
  }

  @discardableResult
  private func markOpenClawChatThreadRead(_ id: UUID, shouldPersist: Bool) -> Bool {
    guard let index = openClawChatThreadIndex(for: id) else { return false }
    var threads = openClawChatThreads
    let thread = threads[index]
    guard thread.unreadMessageCount != 0 else { return false }
    threads[index] = Self.openClawChatThreadWithoutMessages(
      thread.replacingOpenClawChatMetadata(unreadMessageCount: 0)
    )
    openClawChatThreads = threads
    if shouldPersist {
      persistOpenClawTranscript()
    }
    return true
  }

  private func updateSelectedOpenClawChatThread(messages: [OpenClawChatMessage]) {
    ensureOpenClawChatThread()
    guard let selectedOpenClawChatThreadID,
          let index = openClawChatThreadIndex(for: selectedOpenClawChatThreadID)
    else {
      return
    }

    let current = openClawChatThreads[index]
    let previousMessages = openClawStoredMessages(for: current)
    let previousSignature = Self.openClawMessageHistorySignature(for: previousMessages)
    let currentSignature = Self.openClawMessageHistorySignature(for: messages)
    guard previousSignature != currentSignature else { return }
    storeOpenClawMessages(messages, for: current.id)
    let isThreadOpen = selectedSurface == .openClaw && selectedOpenClawChatThreadID == current.id
    let newAssistantMessageCount = isThreadOpen
      ? 0
      : Self.newAssistantMessageCount(
        previousMessages: previousMessages,
        currentMessages: messages
      )
    let unreadMessageCount = isThreadOpen
      ? 0
      : current.unreadMessageCount + newAssistantMessageCount
    let updated = openClawChatThread(
      current,
      applyingMessages: messages,
      storesMessages: false,
      unreadMessageCount: unreadMessageCount
    )
    relocateOpenClawChatThread(at: index, with: updated)
    if newAssistantMessageCount > 0 && !isThreadOpen {
      openClawIncomingMessageSoundPlayer()
    }
  }

  private func storeSelectedOpenClawThreadMessagesForInactiveUse() {
    guard let selectedOpenClawChatThreadID,
          let index = openClawChatThreadIndex(for: selectedOpenClawChatThreadID)
    else {
      return
    }
    let current = openClawChatThreads[index]
    storeOpenClawMessages(openClawMessages, for: current.id)
    let updated = openClawChatThreadForDisplayStorage(current, messages: openClawMessages)
    relocateOpenClawChatThread(at: index, with: updated)
  }

  private func detachSelectedOpenClawThreadMessagesForActiveUse() {
    guard let selectedOpenClawChatThreadID,
          let index = openClawChatThreadIndex(for: selectedOpenClawChatThreadID)
    else {
      return
    }
    let current = openClawChatThreads[index]
    guard !current.messages.isEmpty else { return }
    storeOpenClawMessages(current.messages, for: current.id)
    let detached = OpenClawChatThread(
      id: current.id,
      title: current.title,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
      sessionKey: current.sessionKey,
      messages: [],
      isPinned: current.isPinned,
      isArchived: current.isArchived,
      unreadMessageCount: current.unreadMessageCount
    )
    relocateOpenClawChatThread(at: index, with: detached)
  }

  private func openClawChatThreadsForCurrentMessages() -> [OpenClawChatThread] {
    openClawChatThreads.map { thread in
      openClawChatThreadForStorage(thread, messages: openClawMessages(for: thread))
    }
  }

  private func openClawChatThread(
    _ thread: OpenClawChatThread,
    applyingMessages messages: [OpenClawChatMessage],
    storesMessages: Bool,
    unreadMessageCount: Int? = nil
  ) -> OpenClawChatThread {
    OpenClawChatThread(
      id: thread.id,
      title: Self.openClawThreadTitle(from: messages, fallback: thread.title),
      createdAt: thread.createdAt,
      updatedAt: messages.last?.createdAt ?? thread.updatedAt,
      sessionKey: thread.sessionKey,
      messages: storesMessages ? messages : [],
      isPinned: thread.isPinned,
      isArchived: thread.isArchived,
      unreadMessageCount: unreadMessageCount ?? thread.unreadMessageCount
    )
  }

  private func openClawChatThreadForStorage(
    _ thread: OpenClawChatThread,
    messages: [OpenClawChatMessage]
  ) -> OpenClawChatThread {
    OpenClawChatThread(
      id: thread.id,
      title: thread.title,
      createdAt: thread.createdAt,
      updatedAt: messages.last?.createdAt ?? thread.updatedAt,
      sessionKey: thread.sessionKey,
      messages: messages,
      isPinned: thread.isPinned,
      isArchived: thread.isArchived,
      unreadMessageCount: thread.unreadMessageCount
    )
  }

  private func openClawChatThreadForDisplayStorage(
    _ thread: OpenClawChatThread,
    messages: [OpenClawChatMessage]
  ) -> OpenClawChatThread {
    OpenClawChatThread(
      id: thread.id,
      title: thread.title,
      createdAt: thread.createdAt,
      updatedAt: messages.last?.createdAt ?? thread.updatedAt,
      sessionKey: thread.sessionKey,
      messages: [],
      isPinned: thread.isPinned,
      isArchived: thread.isArchived,
      unreadMessageCount: thread.unreadMessageCount
    )
  }

  private func openClawMessages(for thread: OpenClawChatThread) -> [OpenClawChatMessage] {
    if selectedOpenClawChatThreadID == thread.id {
      return openClawMessages
    }
    return openClawStoredMessages(for: thread)
  }

  private func openClawStoredMessages(for thread: OpenClawChatThread) -> [OpenClawChatMessage] {
    openClawMessagesByThreadID[thread.id] ?? thread.messages
  }

  private func storeOpenClawMessages(_ messages: [OpenClawChatMessage], for threadID: UUID) {
    if messages.isEmpty {
      openClawMessagesByThreadID.removeValue(forKey: threadID)
    } else {
      openClawMessagesByThreadID[threadID] = messages
    }
  }

  nonisolated private static func openClawChatThreadWithoutMessages(_ thread: OpenClawChatThread) -> OpenClawChatThread {
    guard !thread.messages.isEmpty else { return thread }
    return OpenClawChatThread(
      id: thread.id,
      title: thread.title,
      createdAt: thread.createdAt,
      updatedAt: thread.updatedAt,
      sessionKey: thread.sessionKey,
      messages: [],
      isPinned: thread.isPinned,
      isArchived: thread.isArchived,
      unreadMessageCount: thread.unreadMessageCount
    )
  }

  nonisolated private static func newAssistantMessageCount(
    previousMessages: [OpenClawChatMessage],
    currentMessages: [OpenClawChatMessage]
  ) -> Int {
    guard currentMessages.count > previousMessages.count else { return 0 }
    return currentMessages
      .dropFirst(previousMessages.count)
      .filter { $0.role == .assistant }
      .count
  }

  private func rebuildOpenClawThreadDisplayCache(threads: [OpenClawChatThread]? = nil) {
    let sourceThreads = threads ?? openClawChatThreads
    var visible: [OpenClawChatThreadDisplayItem] = []
    var archived: [OpenClawChatThreadDisplayItem] = []
    var indicesByID: [UUID: Int] = [:]
    var unreadCount = 0
    visible.reserveCapacity(sourceThreads.count)
    indicesByID.reserveCapacity(sourceThreads.count)
    for (index, thread) in sourceThreads.enumerated() {
      indicesByID[thread.id] = index
      unreadCount += thread.unreadMessageCount
      let item = OpenClawChatThreadDisplayItem(thread: thread)
      if thread.isArchived {
        archived.append(item)
      } else {
        visible.append(item)
      }
    }
    visibleOpenClawChatThreads = visible
    archivedOpenClawChatThreads = archived
    visibleOpenClawChatThreadsRenderSignature = Self.openClawThreadDisplayItemsRenderSignature(for: visible)
    archivedOpenClawChatThreadsRenderSignature = Self.openClawThreadDisplayItemsRenderSignature(for: archived)
    openClawChatThreadIndicesByID = indicesByID
    openClawUnreadMessageCount = unreadCount
  }

  private func openClawChatThreadIndex(for id: UUID) -> Int? {
    if let index = openClawChatThreadIndicesByID[id],
       openClawChatThreads.indices.contains(index),
       openClawChatThreads[index].id == id {
      return index
    }
    return openClawChatThreads.firstIndex { $0.id == id }
  }

  private func openClawChatThread(with id: UUID) -> OpenClawChatThread? {
    guard let index = openClawChatThreadIndex(for: id) else { return nil }
    return openClawChatThreads[index]
  }

  private func relocateOpenClawChatThread(at index: Int, with updated: OpenClawChatThread) {
    guard openClawChatThreads.indices.contains(index) else { return }
    guard !Self.openClawChatThreadDisplayStorageMatches(openClawChatThreads[index], updated) else { return }
    var threads = openClawChatThreads
    threads.remove(at: index)
    let insertionIndex = threads.firstIndex { candidate in
      Self.openClawChatThread(updated, sortsBefore: candidate)
    } ?? threads.endIndex
    threads.insert(updated, at: insertionIndex)
    openClawChatThreads = threads
  }

  nonisolated private static func sortedOpenClawChatThreadsForDisplay(
    _ threads: [OpenClawChatThread]
  ) -> [OpenClawChatThread] {
    threads.sorted(by: openClawChatThread(_:sortsBefore:))
  }

  nonisolated private static func openClawChatThreadDisplayStorageMatches(
    _ lhs: OpenClawChatThread,
    _ rhs: OpenClawChatThread
  ) -> Bool {
    lhs.id == rhs.id
      && lhs.title == rhs.title
      && lhs.createdAt == rhs.createdAt
      && lhs.updatedAt == rhs.updatedAt
      && lhs.sessionKey == rhs.sessionKey
      && lhs.isPinned == rhs.isPinned
      && lhs.isArchived == rhs.isArchived
      && lhs.unreadMessageCount == rhs.unreadMessageCount
      && openClawMessageHistorySignature(for: lhs.messages) == openClawMessageHistorySignature(for: rhs.messages)
  }

  nonisolated static func openClawMessageHistorySignature(
    _ messages: [OpenClawChatMessage]
  ) -> String {
    openClawMessageHistorySignature(for: messages)
  }

  nonisolated static func openClawMessageHistorySignature(
    for messages: [OpenClawChatMessage]
  ) -> String {
    guard !messages.isEmpty else { return "empty" }
    let first = messages.first
    let last = messages.last
    var hasher = Hasher()
    hasher.combine(messages.count)
    hasher.combine(first?.id)
    hasher.combine(last?.id)
    hasher.combine(last?.role)
    if let content = last?.content {
      combineBoundedOpenClawContentSignature(content, into: &hasher)
    } else {
      hasher.combine(0)
    }
    hasher.combine(last?.sendFailure)
    hasher.combine(last?.createdAt)
    return "\(messages.count):\(hasher.finalize())"
  }

  nonisolated private static func openClawChatThread(_ lhs: OpenClawChatThread, sortsBefore rhs: OpenClawChatThread) -> Bool {
    if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
    if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
    return lhs.updatedAt > rhs.updatedAt
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
    String(content.prefix(openClawThreadTitleSourceLimit))
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
    let current = openClawChatScrollPosition(isAssistantPanel: isAssistantPanel)
    if let current,
       abs(current - normalized) < Self.openClawScrollPositionRecordEpsilon {
      return
    }
    if isAssistantPanel {
      openClawAssistantChatScrollPosition = normalized
    } else {
      openClawChatScrollPosition = normalized
    }
  }

  public func openChatFileReference(_ reference: OpenClawFileReference) {
    guard let file = localPathForOpenClawReference(reference.path) else {
      setIfChanged(\.openClawStatusText, "Could not resolve file link: \(reference.path)")
      return
    }

    let line = reference.line ?? 1
    guard !isActiveOpenClawFileReference(file: file, line: line) else { return }

    let url = URL(fileURLWithPath: file)
    let thread = OpenClawThread(
      title: url.deletingPathExtension().lastPathComponent,
      file: file,
      line: line,
      zone: "chat link",
      modifiedAt: nil,
      idValue: nil
    )
    activateDetailLocation(.openClaw(thread), mode: .page, recordsHistory: true)
    setIfChanged(\.statusText, "Opened \(relativePath(file))")
  }

  private func isActiveOpenClawFileReference(file: String, line: Int) -> Bool {
    guard case .openClaw(let thread)? = selectedLocation,
          selectedEntrySourceMode == .page
    else {
      return false
    }
    let selectedPath = URL(fileURLWithPath: thread.file).standardizedFileURL.path
    let filePath = URL(fileURLWithPath: file).standardizedFileURL.path
    guard selectedPath == filePath, thread.lineForEditor == max(1, line) else { return false }
    return selectedEntrySource != nil || isLoadingEntrySource || isRenderingEntrySource
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
    Task { await refreshOrgCryptManagedRecipientFilesNow() }
  }

  public func refreshOrgCryptManagedRecipientFilesNow() async {
    orgCryptManagedRecipientFilesRefreshGeneration += 1
    let generation = orgCryptManagedRecipientFilesRefreshGeneration
    guard let corpusRoot else {
      setIfChanged(\.orgCryptManagedRecipientFiles, [])
      return
    }
    let root = corpusRoot.standardizedFileURL
    do {
      let files = try await Task.detached(priority: .utility) {
        try Self.scanOrgCryptManagedRecipientFiles(corpusRoot: root)
      }.value
      guard generation == orgCryptManagedRecipientFilesRefreshGeneration,
            self.corpusRoot?.standardizedFileURL.path == root.path
      else {
        return
      }
      setIfChanged(\.orgCryptManagedRecipientFiles, files)
    } catch {
      guard generation == orgCryptManagedRecipientFilesRefreshGeneration else { return }
      setIfChanged(\.orgCryptManagedRecipientFiles, [])
      orgCryptStatusText = error.localizedDescription
    }
  }

  nonisolated public static func scanOrgCryptManagedRecipientFiles(corpusRoot: URL) throws -> [OrgCryptRecipientFile] {
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
      orgCryptStatusText = "Added \(file.name) to public keys"
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

  private func rebuildAgendaDisplayCache(
    mode: AgendaMode? = nil,
    filter: String? = nil
  ) {
    applyAgendaDisplayCache(agenda: agenda, mode: mode ?? agendaMode, filter: filter ?? agendaFilter)
  }

  private func rebuildAgendaDisplayCache(agenda newAgenda: AgendaPayload?) {
    applyAgendaDisplayCache(agenda: newAgenda, mode: agendaMode, filter: agendaFilter)
  }

  private func applyAgendaDisplayCache(agenda sourceAgenda: AgendaPayload?, mode: AgendaMode, filter: String) {
    agendaDisplaySections = Self.makeAgendaDisplaySections(
      agenda: sourceAgenda,
      mode: mode,
      filter: filter,
      corpusRoot: corpusRoot
    )
    visibleAgendaItems = agendaDisplaySections.flatMap(\.items).map(\.item)
    visibleAgendaItemsByID = Self.lookupByID(visibleAgendaItems)
    var indicesByID: [AgendaItem.ID: Int] = [:]
    indicesByID.reserveCapacity(visibleAgendaItems.count)
    for (index, item) in visibleAgendaItems.enumerated() {
      indicesByID[item.id] = index
    }
    visibleAgendaItemIndicesByID = indicesByID
    visibleAgendaItemIDs = Set(visibleAgendaItems.map(\.id))
  }

  private static func makeAgendaDisplaySections(
    agenda: AgendaPayload?,
    mode: AgendaMode,
    filter: String,
    corpusRoot: URL?
  ) -> [AgendaDisplaySection] {
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
    let standardizedRoot = corpusRoot?.standardizedFileURL
    func displayItems(_ items: [AgendaItem]) -> [AgendaDisplayItem] {
      items.map { item in
        AgendaDisplayItem(
          item: item,
          relativePath: standardizedRoot.map { Self.relativePath(for: item.file, root: $0) } ?? item.file
        )
      }
    }

    switch mode {
    case .focus:
      let todayActionable = today.filter(\.isActionable)
      let overdueActionable = overdue.filter(\.isActionable)
      let doneToday = today.filter { !$0.isActionable }
      return [
        AgendaDisplaySection(id: "focus-today", label: "Today", items: displayItems(todayActionable), hint: "today"),
        AgendaDisplaySection(id: "focus-overdue", label: "Overdue", items: displayItems(overdueActionable), hint: "overdue"),
        AgendaDisplaySection(id: "focus-closed", label: "Done or canceled", items: displayItems(doneToday), hint: "today")
      ].filter { !$0.items.isEmpty }
    case .today:
      return [
        AgendaDisplaySection(id: "today", label: "Today", items: displayItems(today), hint: "today"),
        AgendaDisplaySection(id: "overdue", label: "Overdue", items: displayItems(overdue), hint: "overdue")
      ].filter { !$0.items.isEmpty }
    case .range:
      return [
        AgendaDisplaySection(id: "overdue", label: "Overdue", items: displayItems(overdue), hint: "overdue"),
        AgendaDisplaySection(id: "today", label: "Today", items: displayItems(today), hint: "today"),
        AgendaDisplaySection(id: "next-7-days", label: "Next 7 days", items: displayItems(next7), hint: "upcoming"),
        AgendaDisplaySection(id: "later", label: "Later", items: displayItems(later), hint: "upcoming")
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

  public func visibleAgendaItem(id: AgendaItem.ID) -> AgendaItem? {
    visibleAgendaItemsByID[id]
  }

  public func visibleAgendaItemIndex(id: AgendaItem.ID) -> Int? {
    visibleAgendaItemIndicesByID[id]
  }

  public func visibleApprovalItem(id: ApprovalItem.ID) -> ApprovalItem? {
    visibleApprovalItemsByID[id]
  }

  public func assignedWorkItem(id: AssignedWorkItem.ID) -> AssignedWorkItem? {
    assignedWorkItemsByID[id]
  }

  public func visibleAssignedWorkItem(id: AssignedWorkItem.ID) -> AssignedWorkItem? {
    visibleAssignedWorkItemsByID[id]
  }

  public func meeting(id: MeetingWorkspaceItem.ID) -> MeetingWorkspaceItem? {
    meetingsByID[id]
  }

  public var bulkAgendaSelectionCount: Int {
    bulkSelectedAgendaItemIDs.intersection(visibleAgendaItemIDs).count
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
    setIfChanged(\.bulkSelectedAgendaItemIDs, ids)
    updateAgendaBulkSelectionStatusText()
  }

  public func selectAllVisibleAgendaItemsForBulkAction() {
    let ids = visibleAgendaItemIDs
    setIfChanged(\.bulkSelectedAgendaItemIDs, ids)
    if ids.isEmpty {
      setIfChanged(\.statusText, "No visible agenda items")
    } else {
      setIfChanged(
        \.statusText,
        ids.count == 1 ? "1 agenda item selected" : "\(ids.count) agenda items selected"
      )
    }
  }

  public func clearAgendaBulkSelection() {
    guard !bulkSelectedAgendaItemIDs.isEmpty else { return }
    setIfChanged(\.bulkSelectedAgendaItemIDs, Set<String>())
    setIfChanged(\.statusText, "Agenda selection cleared")
  }

  public func handleAgendaItemClick(_ item: AgendaItem, modifiers: NSEvent.ModifierFlags = []) {
    if modifiers.intersection([.command]).contains(.command) {
      toggleAgendaItemBulkSelection(item)
      selectAgendaItem(item)
    } else {
      selectAgendaItem(item)
    }
  }

  public func activateAgendaItemFromRowTap(_ item: AgendaItem, modifiers: NSEvent.ModifierFlags = []) {
    let previousID = selectedAgendaItemID
    guard modifiers.intersection([.command]).contains(.command) || previousID != item.id else { return }
    handleAgendaItemClick(item, modifiers: modifiers)
    suppressNextAgendaSelectionActivation = previousID != selectedAgendaItemID
  }

  public func extendAgendaBulkSelection(by delta: Int) {
    let items = visibleAgendaItems
    guard !items.isEmpty else {
      statusText = "No visible agenda items"
      return
    }

    let currentIndex = selectedAgendaItemID.flatMap { visibleAgendaItemIndicesByID[$0] }
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
    setIfChanged(\.bulkSelectedAgendaItemIDs, ids)
    selectAgendaItem(items[nextIndex])
    updateAgendaBulkSelectionStatusText()
  }

  public func selectAgendaItem(_ item: AgendaItem) {
    deactivateAgendaFilterFocus()
    suppressNextAgendaSelectionActivation = false
    setIfChanged(\.selectedSurface, .agenda)
    select(.agenda(item))
  }

  private func selectAgendaItemWithoutActivatingEntry(_ item: AgendaItem) {
    suppressNextAgendaSelectionActivation = true
    setIfChanged(\.selectedSurface, .agenda)
    setIfChanged(\.selectedAgendaItemID, item.id)
  }

  public func moveAgendaSelection(by delta: Int) {
    if agendaMode == .assigned {
      moveAssignedAgendaSelection(by: delta)
      return
    }
    let items = visibleAgendaItems
    guard !items.isEmpty else { return }

    let currentIndex = selectedAgendaItemID.flatMap { visibleAgendaItemIndicesByID[$0] }
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
      setIfChanged(\.selectedAgendaItemID, nil)
      return
    }

    if let selectedAgendaItemID, visibleAgendaItemIDs.contains(selectedAgendaItemID) {
      return
    }

    let nextID = items[0].id
    guard selectedAgendaItemID != nextID else { return }
    suppressNextAgendaSelectionActivation = true
    setIfChanged(\.selectedAgendaItemID, nextID)
  }

  public func syncAssignedAgendaSelectionAfterDisplayOptionsChange() {
    guard agendaMode == .assigned else { return }
    setIfChanged(\.selectedAgendaItemID, nil)
    let items = visibleAssignedWorkItems
    guard !items.isEmpty else {
      setIfChanged(\.selectedAssignedWorkItemID, nil)
      return
    }
    if let selectedAssignedWorkItemID,
       visibleAssignedWorkItemsByID[selectedAssignedWorkItemID] != nil {
      return
    }
    setIfChanged(\.selectedAssignedWorkItemID, items[0].id)
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
    let items = displayedAssignedWorkItems
    guard !items.isEmpty else { return }

    let currentIndex = selectedAssignedWorkItemID.flatMap { displayedAssignedWorkItemIndicesByID[$0] }
    let nextIndex: Int
    if let currentIndex {
      nextIndex = max(0, min(items.count - 1, currentIndex + delta))
    } else {
      nextIndex = delta < 0 ? items.count - 1 : 0
    }
    selectAssignedWorkItem(items[nextIndex])
  }

  public func setAgendaModeFromKey(_ key: String) {
    let nextMode: AgendaMode?
    switch key {
    case "1":
      nextMode = .focus
    case "2":
      nextMode = .today
    case "3":
      nextMode = .range
    case "4":
      nextMode = .assigned
    default:
      nextMode = nil
    }
    guard let nextMode, nextMode != agendaMode else { return }
    setIfChanged(\.agendaMode, nextMode)
    syncAgendaSelectionAfterDisplayOptionsChange()
  }

  public func focusAgendaFilter() {
    setIfChanged(\.selectedSurface, .agenda)
    setIfChanged(\.agendaFilter, "")
    agendaFilterFocusToken += 1
  }

  public func deactivateAgendaFilterFocus() {
    setIfChanged(\.isAgendaFilterFocused, false)
  }

  public func clearAgendaFilter() {
    setIfChanged(\.agendaFilter, "")
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
    Task { await prepareSimilarTodoAssignment() }
  }

  private func prepareSimilarTodoAssignment() async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a TODO heading first"
      return
    }
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }

    do {
      statusText = "Finding similar TODOs..."
      let files = try await currentOrScannedCorpusFiles()
      let allCandidates = try await Task.detached(priority: .userInitiated) {
        try Self.scanTodoHeadings(files: files)
      }.value
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
        try await Self.upsertHeadlinePropertiesOffMain(
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
      await refreshAssignedWork()
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
    setIfChanged(\.selectedSurface, .openClaw)
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
      visibleAgendaItemIndicesByID[id]
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
      visibleAgendaItemIndicesByID[id]
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
    if try await Self.nestedParentSendHeadingOffMain(for: target) != nil {
      try await setTodoStatus(.done, for: target)
      return
    }

    let assignee = resolvedAgentHandoffAssignee()
    try await setTodoAssignee(assignee, for: target)
    try await Self.upsertHeadlinePropertiesOffMain(
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
    await approveAndAgentHandoff(target)
  }

  public func applyApproveAndAgentHandoffShortcut(to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select an approval TODO first"
      return
    }
    await approveAndAgentHandoff(target)
  }

  public func applyRejectApprovalShortcut(endStatus: TodoEditStatus, reason: String) async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select an approval TODO first"
      return
    }
    await rejectApproval(target, endStatus: endStatus, reason: reason)
  }

  public func applyRejectApprovalShortcut(endStatus: TodoEditStatus, reason: String, to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select an approval TODO first"
      return
    }
    await rejectApproval(target, endStatus: endStatus, reason: reason)
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

  private func approveAndAgentHandoff(_ target: HeadlineMutationTarget) async {
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItemIndicesByID[id]
    }
    let timestamp = Self.orgTimestamp(Date())

    do {
      let approvalIdentity = try await Self.approvalMutationIdentityOffMain(for: target)
      try await setTodoStatus(.done, for: target)
      let result = try await activateApprovedAgentAction(for: target, timestamp: timestamp)
      let currentTarget = try await Self.refreshedApprovalMutationTargetOffMain(
        original: target,
        identity: approvalIdentity
      )
      var approvalProperties = try await Self.currentApprovalPropertiesOffMain(for: currentTarget)
      approvalProperties.merge(Self.approvedApprovalProperties(
        existingProperties: approvalProperties,
        timestamp: timestamp,
        pairedTitle: result.title
      )) { _, new in new }
      try await Self.upsertHeadlinePropertiesOffMain(
        file: currentTarget.file,
        line: currentTarget.line,
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
    } catch {
      errorText = error.localizedDescription
      statusText = "Approve handoff failed"
    }
  }

  nonisolated private static func currentApprovalPropertiesOffMain(
    for target: HeadlineMutationTarget
  ) async throws -> [String: String] {
    try await Task.detached(priority: .userInitiated) {
      try currentApprovalProperties(for: target)
    }.value
  }

  nonisolated private static func currentApprovalProperties(for target: HeadlineMutationTarget) throws -> [String: String] {
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

  nonisolated private static func approvalMutationIdentityOffMain(
    for target: HeadlineMutationTarget
  ) async throws -> ApprovalMutationIdentity {
    try await Task.detached(priority: .userInitiated) {
      try approvalMutationIdentity(for: target)
    }.value
  }

  nonisolated private static func approvalMutationIdentity(for target: HeadlineMutationTarget) throws -> ApprovalMutationIdentity {
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

  nonisolated private static func refreshedApprovalMutationTargetOffMain(
    original target: HeadlineMutationTarget,
    identity: ApprovalMutationIdentity
  ) async throws -> HeadlineMutationTarget {
    try await Task.detached(priority: .userInitiated) {
      try refreshedApprovalMutationTarget(original: target, identity: identity)
    }.value
  }

  nonisolated private static func refreshedApprovalMutationTarget(
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

  private func rejectApproval(_ target: HeadlineMutationTarget, endStatus: TodoEditStatus, reason: String) async {
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItemIndicesByID[id]
    }
    let timestamp = Self.orgTimestamp(Date())

    do {
      let approvalIdentity = try await Self.approvalMutationIdentityOffMain(for: target)
      try await setTodoStatus(endStatus, for: target)
      let currentTarget = try await Self.refreshedApprovalMutationTargetOffMain(
        original: target,
        identity: approvalIdentity
      )
      try await Self.upsertHeadlinePropertiesOffMain(
        file: currentTarget.file,
        line: currentTarget.line,
        properties: [
          "STATUS": "rejected",
          "REJECTED_AT": timestamp,
          "REJECTION_END_STATUS": endStatus.label,
          "REJECTION_REASON": Self.sanitizeOrgPropertyValue(reason)
        ]
      )
      await refreshAfterHeadlineMutation(target)
      preserveAgendaSelectionAfterTodoMutation(
        target: target,
        originalVisibleIndex: originalVisibleIndex,
        shouldAdvanceSelection: true
      )
      statusText = "Rejected -> \(target.title)"
    } catch {
      errorText = error.localizedDescription
      statusText = "Reject approval failed"
    }
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
      try await Self.upsertHeadlinePropertiesOffMain(
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

    try await Self.replaceSourceRangeOffMain(
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
      try await Self.updateHeadlinePriorityOffMain(file: target.file, line: target.line, priority: priority)
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
    let content = Self.capturePasteboardContent(from: .general)
    if !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let body = captureDraft.body.trimmingCharacters(in: .whitespacesAndNewlines)
      captureDraft.body = body.isEmpty
        ? content.text
        : "\(captureDraft.body.trimmingCharacters(in: .newlines))\n\n\(content.text)"
    }
    captureDraft.attachments.append(contentsOf: content.attachments)
    if captureDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let title = Self.captureTitleCandidate(from: content.text) {
      captureDraft.title = title
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
      let assignee = resolvedAgentHandoffAssignee()
      let target = try await Self.appendCaptureOffMain(
        draft: draft,
        corpusRoot: corpusRoot,
        assignee: assignee
      )
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
      setIfChanged(\.selectedSurface, .meetings)
      statusText = "Select or record a meeting first"
      return
    }

    do {
      let target = try await Self.appendCaptureOffMain(
        draft: WorkspaceCaptureDraft(title: "Review meeting: \(Org2Display.cleanInline(meeting.title))"),
        corpusRoot: corpusRoot,
        assignee: resolvedAgentHandoffAssignee()
      )
      statusText = "Captured meeting review TODO -> \(target.lastPathComponent)"
      invalidateCanonicalDocumentCache(for: target.path)
      setIfChanged(\.selectedSurface, .agenda)
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
      try await Self.upsertHeadlinePropertiesOffMain(file: target.file, line: target.line, properties: [key: value])
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
    if handleGlobalKeyDown(event) {
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
    setIfChanged(\.selectedSurface, surface)
    setIfChanged(\.expandedWorkspaceSurface, nil)
    setIfChanged(\.isWorkspaceSurfacePaneClosed, false)
    setIfChanged(\.isWorkspaceDetailPaneExpanded, false)
    setIfChanged(\.isOpenClawAssistantPresented, false)
    if surface == .openClaw {
      markSelectedOpenClawChatThreadRead()
    }
    setIfChanged(\.statusText, "\(surface.title) is primary")
  }

  public func makeSelectedSurfacePrimary() {
    makeSurfacePrimary(selectedSurface)
  }

  public func expandSurface(_ surface: WorkspaceSurface) {
    if surface == .home {
      openHome()
      return
    }
    setIfChanged(\.selectedSurface, surface)
    setIfChanged(\.expandedWorkspaceSurface, nil)
    setIfChanged(\.isWorkspaceSurfacePaneClosed, false)
    setIfChanged(\.isWorkspaceDetailPaneClosed, true)
    setIfChanged(\.isWorkspaceDetailPaneExpanded, false)
    setIfChanged(\.isOpenClawAssistantPresented, false)
    setIfChanged(\.statusText, "\(surface.title) expanded")
  }

  public func toggleExpandedSurface(_ surface: WorkspaceSurface) {
    if selectedSurface == surface && isWorkspaceDetailPaneClosed && hasWorkspaceDetailContent {
      setIfChanged(\.isWorkspaceSurfacePaneClosed, false)
      setIfChanged(\.statusText, "\(surface.title) restored")
    } else {
      expandSurface(surface)
    }
  }

  public func toggleSelectedSurfaceExpansion() {
    toggleExpandedSurface(selectedSurface)
  }

  public func closeSurfacePane(_ surface: WorkspaceSurface) {
    setIfChanged(\.expandedWorkspaceSurface, nil)
    setIfChanged(\.isWorkspaceDetailPaneExpanded, false)
    if selectedSurface == surface, hasWorkspaceDetailContent {
      setIfChanged(\.isWorkspaceSurfacePaneClosed, true)
      setIfChanged(\.isWorkspaceDetailPaneClosed, false)
    }
    setIfChanged(\.isOpenClawAssistantPresented, false)
    setIfChanged(\.statusText, "\(surface.title) closed")
  }

  public func closeSelectedSurfacePane() {
    closeSurfacePane(selectedSurface)
  }

  public func makeDetailPanePrimary() {
    guard selectedLocation != nil || selectedEntrySource != nil else {
      setIfChanged(\.statusText, "Open a file first")
      return
    }
    setIfChanged(\.expandedWorkspaceSurface, nil)
    setIfChanged(\.isWorkspaceSurfacePaneClosed, true)
    setIfChanged(\.isWorkspaceDetailPaneClosed, false)
    setIfChanged(\.isWorkspaceDetailPaneExpanded, false)
    setIfChanged(\.isOpenClawAssistantPresented, false)
    setIfChanged(\.statusText, "Document is primary")
  }

  public func toggleDetailPaneExpansion() {
    guard selectedLocation != nil || selectedEntrySource != nil else {
      setIfChanged(\.statusText, "Open a file first")
      return
    }
    setIfChanged(\.expandedWorkspaceSurface, nil)
    setIfChanged(\.isWorkspaceDetailPaneExpanded, false)
    setIfChanged(\.isWorkspaceDetailPaneClosed, false)
    setIfChanged(\.isOpenClawAssistantPresented, false)
    if isWorkspaceSurfacePaneClosed {
      setIfChanged(\.isWorkspaceSurfacePaneClosed, false)
      setIfChanged(\.statusText, "Document restored")
    } else {
      setIfChanged(\.isWorkspaceSurfacePaneClosed, true)
      setIfChanged(\.statusText, "Document expanded")
    }
  }

  public func closeDetailPane() {
    setIfChanged(\.isWorkspaceDetailPaneClosed, true)
    setIfChanged(\.isWorkspaceDetailPaneExpanded, false)
    setIfChanged(\.isWorkspaceSurfacePaneClosed, false)
    setIfChanged(\.expandedWorkspaceSurface, nil)
    setIfChanged(\.statusText, "Document closed")
  }

  public func toggleOpenClawAssistantPanel() {
    makeSurfacePrimary(.openClaw)
  }

  public func setOpenClawAssistantPanelPresented(_ presented: Bool) {
    setIfChanged(\.isOpenClawAssistantPresented, false)
    if presented {
      makeSurfacePrimary(.openClaw)
    }
  }

  public func handleGlobalKeyDown(_ event: NSEvent) -> Bool {
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
      case "7":
        openDailyNote(.today)
      case "8":
        openDailyNote(.yesterday)
      case "9":
        openDailyNote(.tomorrow)
      case "f":
        guard focusPageSearch() else { return false }
      case "k", "p":
        presentQuickOpen()
      case "r":
        guard corpusRoot != nil else { return false }
        Task { await refreshWorkspace() }
      case "s":
        guard canSaveCurrentFile else { return false }
        Task { await saveActiveEdit() }
      case "/":
        isKeyboardShortcutsPresented = true
      case "z":
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
    if performTextUndo(redo: false) {
      return
    }
    if let action = workspaceUndoStack.popLast() {
      applyWorkspaceUndo(action)
      workspaceRedoStack.append(action)
      return
    }
    statusText = "Undo is available while editing text"
  }

  public func performRedoCommand() {
    if performTextUndo(redo: true) {
      return
    }
    if let action = workspaceRedoStack.popLast() {
      applyWorkspaceRedo(action)
      workspaceUndoStack.append(action)
      return
    }
    statusText = "Redo is available while editing text"
  }

  private func recordWorkspaceUndo(_ action: WorkspaceUndoAction) {
    guard workspaceUndoStack.last != action else { return }
    workspaceUndoStack.append(action)
    if workspaceUndoStack.count > 100 {
      workspaceUndoStack.removeFirst(workspaceUndoStack.count - 100)
    }
    workspaceRedoStack.removeAll()
  }

  private func applyWorkspaceUndo(_ action: WorkspaceUndoAction) {
    switch action {
    case .openClawDraft(let previous, _):
      openClawDraft = previous
      openClawStatusText = "Undid OpenClaw draft change"
      statusText = "Undid OpenClaw draft change"
    }
  }

  private func applyWorkspaceRedo(_ action: WorkspaceUndoAction) {
    switch action {
    case .openClawDraft(_, let next):
      openClawDraft = next
      openClawStatusText = "Redid OpenClaw draft change"
      statusText = "Redid OpenClaw draft change"
    }
  }

  @discardableResult
  private func performTextUndo(redo: Bool) -> Bool {
    guard let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
          let undoManager = textView.undoManager
    else {
      return false
    }

    if redo {
      guard undoManager.canRedo else { return true }
      undoManager.redo()
    } else {
      guard undoManager.canUndo else { return true }
      undoManager.undo()
    }
    return true
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
    backlinksLoadTask?.cancel()
    backlinksLoadTask = nil
    backlinksLoadGeneration += 1
    let generation = backlinksLoadGeneration

    guard let corpusRoot else {
      setIfChanged(\.backlinks, nil)
      return
    }

    setIfChanged(\.isLoadingBacklinks, true)
    defer {
      if generation == backlinksLoadGeneration {
        setIfChanged(\.isLoadingBacklinks, false)
      }
    }

    do {
      guard let id = try await backlinkTargetID(for: location), !id.isEmpty else {
        guard generation == backlinksLoadGeneration, selectedLocationMatches(location) else { return }
        setIfChanged(\.backlinks, nil)
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
      setIfChanged(\.backlinks, payload)
    } catch {
      guard generation == backlinksLoadGeneration, selectedLocationMatches(location) else { return }
      setIfChanged(\.backlinks, nil)
      errorText = error.localizedDescription
    }
  }

  private func scheduleBacklinksLoad(for location: WorkspaceLocation) {
    backlinksLoadGeneration += 1
    let generation = backlinksLoadGeneration
    backlinksLoadTask?.cancel()
    backlinksLoadTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.scheduledBacklinkLoadDebounceNanoseconds)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.loadBacklinks(for: location, generation: generation)
    }
  }

  private func loadBacklinks(for location: WorkspaceLocation, generation: Int) async {
    guard generation == backlinksLoadGeneration else { return }

    guard let corpusRoot else {
      setIfChanged(\.backlinks, nil)
      return
    }

    setIfChanged(\.isLoadingBacklinks, true)
    defer {
      if generation == backlinksLoadGeneration {
        setIfChanged(\.isLoadingBacklinks, false)
      }
    }

    do {
      guard let id = try await backlinkTargetID(for: location), !id.isEmpty else {
        guard generation == backlinksLoadGeneration, selectedLocationMatches(location) else { return }
        setIfChanged(\.backlinks, nil)
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
      setIfChanged(\.backlinks, payload)
    } catch {
      guard generation == backlinksLoadGeneration, selectedLocationMatches(location) else { return }
      setIfChanged(\.backlinks, nil)
      errorText = error.localizedDescription
    }
  }

  private func rebuildBacklinkDisplayCache(backlinks sourceBacklinks: BacklinksPayload? = nil) {
    guard let backlinks = sourceBacklinks ?? backlinks else {
      backlinkFileGroups = []
      backlinkFileCount = 0
      backlinkReferenceCount = 0
      relatedBacklinkNodes = []
      return
    }
    let grouped = Dictionary(grouping: backlinks.backlinks, by: \.file)
    backlinkFileGroups = grouped.map { file, items in
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
    backlinkFileCount = backlinkFileGroups.count
    backlinkReferenceCount = backlinks.backlinks.count
    relatedBacklinkNodes = Self.relatedBacklinkNodes(
      from: backlinks.backlinks,
      relativePathForFile: { [weak self] file in
        self?.relativePath(file) ?? file
      }
    )
  }

  private func rebuildBacklinkDisplayCacheForAssignment(_ sourceBacklinks: BacklinksPayload?) {
    guard let backlinks = sourceBacklinks else {
      backlinkFileGroups = []
      backlinkFileCount = 0
      backlinkReferenceCount = 0
      relatedBacklinkNodes = []
      return
    }
    rebuildBacklinkDisplayCache(backlinks: backlinks)
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
    setIfChanged(\.selectedSurface, .files)
    activateDetailLocation(.openClaw(thread), mode: .page, recordsHistory: true)
    setIfChanged(\.selectedOpenClawThreadID, thread.id)
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
       let item = assignedWorkItemsByID[selectedAssignedWorkItemID] {
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
    if let cached = relativePathCache[path] {
      return cached
    }
    let standardRootPath = relativePathStandardRootPath ?? corpusRoot.standardizedFileURL.path
    let resolvedRootPath = relativePathResolvedRootPath ?? Self.resolvedPath(for: corpusRoot)
    relativePathStandardRootPath = standardRootPath
    relativePathResolvedRootPath = resolvedRootPath
    let relativePath = Self.relativePath(
      for: path,
      standardizedRootPath: standardRootPath,
      resolvedRootPath: resolvedRootPath
    )
    relativePathCache[path] = relativePath
    return relativePath
  }

  nonisolated private static func relativePath(for path: String, root: URL) -> String {
    relativePath(
      for: path,
      standardizedRootPath: root.standardizedFileURL.path,
      resolvedRootPath: resolvedPath(for: root)
    )
  }

  nonisolated private static func resolvedPath(for url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  nonisolated private static func relativePath(
    for path: String,
    standardizedRootPath: String,
    resolvedRootPath rootPath: String
  ) -> String {
    let originalPath = URL(fileURLWithPath: path).standardizedFileURL.path
    if originalPath == standardizedRootPath { return "." }
    if originalPath.hasPrefix(standardizedRootPath + "/") {
      return String(originalPath.dropFirst(standardizedRootPath.count + 1))
    }
    let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
      return OpenClawContextPointer(
        kind: kind,
        reference: "\(mappedPathForOpenClaw(source.file)):\(source.startLine)",
        displayReference: "\(relativePath(source.file)):\(source.startLine)"
      )
    }

    if let location = selectedLocation {
      return OpenClawContextPointer(
        kind: "current selection",
        reference: "\(mappedPathForOpenClaw(location.file)):\(location.lineForEditor)",
        displayReference: "\(relativePath(location.file)):\(location.lineForEditor)"
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
      displayReference: displayReference
    )
  }

  private func addOpenClawContext(_ pointer: OpenClawContextPointer) {
    let injectedContext = "Use \(pointer.kind) at \(pointer.reference) as context.\n\n"
    let previousDraft = openClawDraft
    if openClawDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      openClawDraft = injectedContext
    } else if !openClawDraft.contains(pointer.reference) {
      openClawDraft = injectedContext + openClawDraft
    }
    if openClawDraft != previousDraft {
      recordWorkspaceUndo(.openClawDraft(previous: previousDraft, next: openClawDraft))
    }

    if shouldPresentOpenClawForContextInsertion {
      setOpenClawAssistantPanelPresented(true)
    }
    setIfChanged(\.openClawStatusText, "Added \(pointer.displayReference) to OpenClaw")
    setIfChanged(\.statusText, "Added \(pointer.displayReference) to OpenClaw")
  }

  private var shouldPresentOpenClawForContextInsertion: Bool {
    selectedSurface != .openClaw || isWorkspaceSurfacePaneClosed || isWorkspaceDetailPaneExpanded
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

  nonisolated private static func resolvedOpenClawSettings(
    userEndpoint: String,
    cachedBearerToken: String?,
    hasStoredToken: Bool,
    allowKeychainRead: Bool
  ) -> ResolvedOpenClawSettings {
    var bearerToken = cachedBearerToken
    var tokenExists = hasStoredToken
    if allowKeychainRead, bearerToken == nil, hasStoredToken {
      bearerToken = OpenClawKeychain.readToken(allowUserInteraction: true)
      tokenExists = bearerToken != nil || OpenClawKeychain.containsToken()
    }
    return ResolvedOpenClawSettings(
      settings: OpenClawGatewaySettings.resolve(
        userEndpoint: userEndpoint,
        userBearerToken: bearerToken
      ),
      bearerToken: bearerToken,
      hasStoredToken: tokenExists
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

  private func persistOpenClawTranscript(
    delayNanoseconds: UInt64 = WorkspaceStore.openClawTranscriptContentPersistenceDelay
  ) {
    openClawTranscriptContentGeneration += 1
    let generation = openClawTranscriptContentGeneration
    let url = openClawTranscriptURL
    openClawTranscriptPersistenceTask?.cancel()
    openClawTranscriptPersistenceTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: delayNanoseconds)
      guard !Task.isCancelled else { return }
      do {
        guard let transcript = await MainActor.run(body: { () -> OpenClawTranscriptState? in
          guard let self,
                self.openClawTranscriptContentGeneration == generation
          else {
            return nil
          }
          return OpenClawTranscriptState(
            threads: self.openClawChatThreadsForCurrentMessages(),
            selectedThreadID: self.selectedOpenClawChatThreadID
          )
        }) else {
          return
        }
        guard !Task.isCancelled else { return }
        try await Task.detached(priority: .utility) {
          try Self.saveOpenClawTranscript(transcript, to: url)
        }.value
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self?.errorText = "OpenClaw transcript save failed: \(error.localizedDescription)"
        }
      }
    }
  }

  public func flushOpenClawTranscriptPersistence() async {
    await openClawTranscriptPersistenceTask?.value
  }

  public func flushOpenClawTranscriptSwitch() async {
    await openClawTranscriptSwitchTask?.value
  }

  private func scheduleOpenClawTranscriptSwitch(to url: URL, migrationSource: URL? = nil) {
    guard let request = beginOpenClawTranscriptSwitch(to: url, migrationSource: migrationSource) else { return }
    openClawTranscriptSwitchTask?.cancel()
    openClawTranscriptSwitchTask = Task { @MainActor [weak self] in
      await self?.finishOpenClawTranscriptSwitch(request)
    }
  }

  private func switchOpenClawTranscript(to url: URL, migrationSource: URL? = nil) async {
    guard let request = beginOpenClawTranscriptSwitch(to: url, migrationSource: migrationSource) else { return }
    openClawTranscriptSwitchTask?.cancel()
    openClawTranscriptSwitchTask = nil
    await finishOpenClawTranscriptSwitch(request)
  }

  private func beginOpenClawTranscriptSwitch(
    to url: URL,
    migrationSource: URL?
  ) -> OpenClawTranscriptSwitchRequest? {
    guard !usesFixedOpenClawTranscriptURL else { return nil }
    let targetURL = url.standardizedFileURL
    let previousURL = openClawTranscriptURL.standardizedFileURL
    guard targetURL.path != previousURL.path else { return nil }

    openClawTranscriptSwitchGeneration += 1
    openClawTranscriptSwitchTask?.cancel()
    openClawTranscriptPersistenceTask?.cancel()
    openClawTranscriptPersistenceTask = nil
    let request = OpenClawTranscriptSwitchRequest(
      targetURL: targetURL,
      previousURL: previousURL,
      migrationSource: migrationSource?.standardizedFileURL,
      legacyMessages: openClawMessages,
      canMigrateLegacyMessages: previousURL.path == appOpenClawTranscriptURL.standardizedFileURL.path,
      switchGeneration: openClawTranscriptSwitchGeneration,
      contentGeneration: openClawTranscriptContentGeneration
    )

    openClawTranscriptURL = targetURL
    openClawSessionKey = Self.makeOpenClawSessionKey()
    openClawMessagesByThreadID = [:]
    if !openClawPendingUserMessageIDs.isEmpty {
      openClawPendingUserMessageIDs.removeAll()
    }
    isDrainingOpenClawQueue = false
    setOpenClawSending(false)
    openClawChatThreads = []
    setIfChanged(\.selectedOpenClawChatThreadID, nil)
    replaceOpenClawMessages([], shouldPersist: false)
    return request
  }

  private func finishOpenClawTranscriptSwitch(_ request: OpenClawTranscriptSwitchRequest) async {
    let result = await Task.detached(priority: .utility) {
      Self.resolveOpenClawTranscriptSwitch(request)
    }.value
    guard request.switchGeneration == openClawTranscriptSwitchGeneration,
          request.contentGeneration == openClawTranscriptContentGeneration
    else {
      return
    }
    applyOpenClawTranscript(result.transcript, shouldPersist: result.shouldPersist)
  }

  nonisolated private static func resolveOpenClawTranscriptSwitch(
    _ request: OpenClawTranscriptSwitchRequest
  ) -> OpenClawTranscriptSwitchResult {
    let transcript: OpenClawTranscriptState
    let shouldPersistMigratedMessages: Bool
    if FileManager.default.fileExists(atPath: request.targetURL.path) {
      transcript = loadOpenClawTranscript(from: request.targetURL)
      shouldPersistMigratedMessages = false
    } else if let migrationSource = request.migrationSource,
              migrationSource.path != request.targetURL.path {
      transcript = loadOpenClawTranscript(from: migrationSource)
      shouldPersistMigratedMessages = !transcript.threads.isEmpty
    } else if request.canMigrateLegacyMessages,
              !request.legacyMessages.isEmpty {
      transcript = openClawTranscriptState(fromLegacyMessages: request.legacyMessages)
      shouldPersistMigratedMessages = true
    } else {
      transcript = OpenClawTranscriptState(threads: [], selectedThreadID: nil)
      shouldPersistMigratedMessages = false
    }
    return OpenClawTranscriptSwitchResult(
      transcript: transcript,
      shouldPersist: shouldPersistMigratedMessages
    )
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
    openClawMessagesByThreadID = Dictionary(
      uniqueKeysWithValues: transcript.threads
        .filter { !$0.messages.isEmpty }
        .map { ($0.id, $0.messages) }
    )
    let threads = Self.sortedOpenClawChatThreadsForDisplay(
      transcript.threads.map(Self.openClawChatThreadWithoutMessages)
    )
    openClawChatThreads = threads
    let selectedID = transcript.selectedThreadID
      .flatMap { id in threads.contains(where: { $0.id == id }) ? id : nil }
      ?? threads.first?.id
    setIfChanged(\.selectedOpenClawChatThreadID, selectedID)
    let selectedThread = selectedID.flatMap { id in threads.first(where: { $0.id == id }) }
    openClawSessionKey = selectedThread?.sessionKey ?? Self.makeOpenClawSessionKey()
    replaceOpenClawMessages(selectedThread.map(openClawStoredMessages(for:)) ?? [], shouldPersist: false)
    detachSelectedOpenClawThreadMessagesForActiveUse()
    if shouldPersist {
      persistOpenClawTranscript()
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

    let cli = cli
    let canonicalParserLineLimit = Self.canonicalParserLineLimit
    Task { @MainActor [weak self] in
      let prepared = await Task.detached(priority: .userInitiated) {
        await Self.prepareRenderedEntrySource(
          source,
          cli: cli,
          canonicalParserLineLimit: canonicalParserLineLimit
        )
      }.value
      guard let self else { return }
      guard generation == self.entrySourceLoadGeneration,
            self.selectedEntrySource?.id == source.id
      else {
        return
      }
      if let canonicalDocument = prepared.canonicalDocument,
         !source.isSubtree,
         source.startLine == 1 {
        let cacheKey = URL(fileURLWithPath: source.file).standardizedFileURL.path
        self.canonicalDocumentCache[cacheKey] = CanonicalDocumentCacheEntry(
          modifiedAt: modifiedAt,
          document: canonicalDocument
        )
      }
      self.cacheRenderedBlocks(prepared.blocks, for: source, modifiedAt: modifiedAt)
      self.applyRenderedBlocks(prepared.blocks, for: source)
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

  nonisolated private static func prepareRenderedEntrySource(
    _ source: EntrySource,
    cli: Org2CLI,
    canonicalParserLineLimit: Int
  ) async -> PreparedRenderedEntrySource {
    guard source.endLineExclusive - source.startLine <= canonicalParserLineLimit else {
      return PreparedRenderedEntrySource(
        blocks: OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine),
        canonicalDocument: nil
      )
    }

    do {
      let document = try await canonicalDocument(for: source, cli: cli)
      return PreparedRenderedEntrySource(
        blocks: OrgEntryRenderer.parseEditable(
          source.text,
          baseLine: source.startLine,
          canonicalDocument: document
        ),
        canonicalDocument: document
      )
    } catch {
      return PreparedRenderedEntrySource(
        blocks: OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine),
        canonicalDocument: nil
      )
    }
  }

  nonisolated private static func canonicalDocument(
    for source: EntrySource,
    cli: Org2CLI
  ) async throws -> Org2CanonicalDocument {
    if source.isSubtree || source.startLine != 1 {
      return try await cli.parseTextJSON(
        source.text,
        sourceRanges: true,
        sourceLineOffset: max(0, source.startLine - 1)
      )
    }

    return try await cli.parseFileJSON(URL(fileURLWithPath: source.file).standardizedFileURL, sourceRanges: true)
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

  nonisolated static func openClawMessagesRenderSignature(for messages: [OpenClawChatMessage]) -> String {
    guard !messages.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(messages.count)
    for message in messages {
      combineOpenClawMessageRenderSignature(message, into: &hasher)
    }
    return "\(messages.count):\(hasher.finalize())"
  }

  nonisolated static func openClawMessageRenderSignature(for message: OpenClawChatMessage) -> String {
    var hasher = Hasher()
    combineOpenClawMessageRenderSignature(message, into: &hasher)
    return hasher.finalize().description
  }

  nonisolated static func openClawThreadDisplayItemsRenderSignature(
    for items: [OpenClawChatThreadDisplayItem]
  ) -> String {
    guard !items.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(items.count)
    for item in items {
      hasher.combine(item.id)
      hasher.combine(item.title)
      hasher.combine(item.updatedAt)
      hasher.combine(item.relativeUpdatedAtText)
      hasher.combine(item.isPinned)
      hasher.combine(item.isArchived)
      hasher.combine(item.unreadMessageCount)
    }
    return "\(items.count):\(hasher.finalize())"
  }

  nonisolated private static func combineOpenClawMessageRenderSignature(
    _ message: OpenClawChatMessage,
    into hasher: inout Hasher
  ) {
    hasher.combine(message.id)
    hasher.combine(message.role)
    combineBoundedOpenClawContentSignature(message.content, into: &hasher)
    hasher.combine(message.attachments.count)
    for attachment in message.attachments {
      hasher.combine(attachment.id)
      hasher.combine(attachment.fileName)
      hasher.combine(attachment.mimeType)
      hasher.combine(attachment.byteCount)
    }
    hasher.combine(message.sendFailure)
    if let summary = message.changeSummary {
      hasher.combine(summary.files.count)
      for file in summary.files {
        hasher.combine(file.relativePath)
        hasher.combine(file.status)
        hasher.combine(file.insertions)
        hasher.combine(file.deletions)
      }
    } else {
      hasher.combine(0)
    }
  }

  nonisolated private static func combineBoundedOpenClawContentSignature(
    _ content: String,
    into hasher: inout Hasher
  ) {
    hasher.combine(content.utf8.count)
    let prefix = content.prefix(openClawMessageRenderSignatureContentSampleLimit)
    hasher.combine(String(prefix))
    let includesFullContent = prefix.endIndex == content.endIndex
    hasher.combine(includesFullContent)
    if !includesFullContent {
      hasher.combine(String(content.suffix(openClawMessageRenderSignatureContentSampleLimit)))
    }
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
      searchResults: searchResults,
      agentThreadDirectories: currentOpenClawAgentThreadDirectories()
    )
  }

  private func currentOpenClawAgentThreadDirectories() -> [String] {
    cachedOpenClawAgentThreadDirectories
  }

  private func refreshCachedOpenClawAgentThreadDirectories(corpusRoot: URL, directories: [URL]?) {
    let sourceDirectories = directories ?? Self.defaultOpenClawThreadDirectories(corpusRoot: corpusRoot)
    cachedOpenClawAgentThreadDirectories = sourceDirectories.map { $0.standardizedFileURL.path }
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

  nonisolated private static func prepareOpenClawImageAttachments(from urls: [URL]) async -> PreparedOpenClawAttachments {
    await Task.detached(priority: .userInitiated) {
      var attachments: [OpenClawChatAttachment] = []
      var failureFileName: String?
      var failureMessage: String?

      for url in urls {
        do {
          attachments.append(try openClawImageAttachment(from: url))
        } catch {
          failureFileName = url.lastPathComponent
          failureMessage = error.localizedDescription
        }
      }

      return PreparedOpenClawAttachments(
        attachments: attachments,
        failureFileName: failureFileName,
        failureMessage: failureMessage
      )
    }.value
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
      return OpenClawTranscriptState(
        threads: threads,
        selectedThreadID: payload.selectedThreadID
      )
    }
    return openClawTranscriptState(fromLegacyMessages: payload.messages ?? [])
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
      setIfChanged(\.selectedAgendaItemID, nil)
      if !preserveSelection, case .agenda = selectedLocation {
        selectedLocation = nil
        setIfChanged(\.backlinks, nil)
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
    let visibleIDs = visibleItems.map { Set($0.map(\.id)) } ?? visibleAgendaItemIDs
    let prunedIDs = bulkSelectedAgendaItemIDs.intersection(visibleIDs)
    if prunedIDs != bulkSelectedAgendaItemIDs {
      bulkSelectedAgendaItemIDs = prunedIDs
    }
  }

  private func updateAgendaBulkSelectionStatusText() {
    let count = bulkAgendaSelectionCount
    setIfChanged(\.statusText, count == 1 ? "1 agenda item selected" : "\(count) agenda items selected")
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
      return visibleAgendaItemsByID[selectedAgendaItemID]
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

    if let item = visibleAgendaItemsByID[agendaItemID] {
      preserveAgendaItemSelectionWithoutActivatingEntry(item)
    } else if selectedAgendaItemID == agendaItemID {
      selectedAgendaItemID = nil
    }
  }

  private func preserveAgendaItemSelectionWithoutActivatingEntry(_ item: AgendaItem) {
    setIfChanged(\.selectedSurface, .agenda)
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

  nonisolated private static func loadedEntrySource(
    file: String,
    line: Int,
    mode: EntrySourceMode
  ) throws -> LoadedEntrySource {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let normalized = normalizeLineEndings(raw)
    let source: EntrySource
    switch mode {
    case .entry:
      source = entrySource(file: file, line: line, normalized: normalized)
    case .page:
      source = pageSource(file: file, normalized: normalized)
    }
    return LoadedEntrySource(source: source, fullFileText: normalized)
  }

  nonisolated private static func entrySource(file: String, line: Int) throws -> EntrySource {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let normalized = normalizeLineEndings(raw)
    return entrySource(file: file, line: line, normalized: normalized)
  }

  nonisolated private static func entrySource(file: String, line: Int, normalized: String) -> EntrySource {
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
    return pageSource(file: file, normalized: normalized)
  }

  nonisolated private static func pageSource(file: String, normalized: String) -> EntrySource {
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
      replacement: replacement,
      expectedOriginal: source.text
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
    expectedOriginal: String? = nil
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
    if raw.hasSuffix("\n"), !output.hasSuffix("\n") {
      output += "\n"
    }
    try output.write(to: url, atomically: true, encoding: .utf8)
  }

  nonisolated private static func replaceSourceRangeOffMain(
    file: String,
    startLine: Int,
    endLineExclusive: Int,
    replacement: String,
    expectedOriginal: String? = nil
  ) async throws {
    try await Task.detached(priority: .userInitiated) {
      try replaceSourceRange(
        file: file,
        startLine: startLine,
        endLineExclusive: endLineExclusive,
        replacement: replacement,
        expectedOriginal: expectedOriginal
      )
    }.value
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
       let meeting = meetingsByID[selectedMeetingID] {
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
    setIfChanged(\.meetingInputMeterLevels, MeetingInputMeterLevels())
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
    let current = meetingInputMeterLevels
    let next = MeetingInputMeterLevels(
      microphoneAverageLevel: publishedMeetingMeterLevel(
        current: current.microphoneAverageLevel,
        next: microphone.averageLevel,
        force: force
      ),
      microphonePeakLevel: publishedMeetingMeterLevel(
        current: current.microphonePeakLevel,
        next: microphone.peakLevel,
        force: force
      ),
      systemAverageLevel: publishedMeetingMeterLevel(
        current: current.systemAverageLevel,
        next: systemAudio.averageLevel,
        force: force
      ),
      systemPeakLevel: publishedMeetingMeterLevel(
        current: current.systemPeakLevel,
        next: systemAudio.peakLevel,
        force: force
      )
    )
    setIfChanged(\.meetingInputMeterLevels, next)
  }

  private func publishedMeetingMeterLevel(current: Double, next: Double, force: Bool) -> Double {
    guard force || Self.shouldPublishMeetingMeterLevelChange(current: current, next: next) else {
      return current
    }
    return next
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
    setIfChanged(\.openClawVoiceMeterLevels, VoiceInputMeterLevels())
  }

  private func updateOpenClawVoiceMeter() {
    let snapshot = openClawVoiceRecorder.inputMeterSnapshot
    let current = openClawVoiceMeterLevels
    let next = VoiceInputMeterLevels(
      averageLevel: publishedMeetingMeterLevel(
        current: current.averageLevel,
        next: snapshot.averageLevel,
        force: false
      ),
      peakLevel: publishedMeetingMeterLevel(
        current: current.peakLevel,
        next: snapshot.peakLevel,
        force: false
      )
    )
    setIfChanged(\.openClawVoiceMeterLevels, next)
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
    setIfChanged(\.meetingTranscriptionState, TranscriptionProgressState())
  }

  private func updateMeetingTranscriptionProgress() {
    let elapsed = meetingTranscriptionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    let progress = Self.meetingTranscriptionProgress(
      elapsed: elapsed,
      estimatedDuration: meetingTranscriptionEstimatedDuration
    )
    setIfChanged(
      \.meetingTranscriptionState,
      TranscriptionProgressState(
        progress: progress,
        elapsedText: Self.openClawVoiceTranscriptionElapsedText(elapsed: elapsed)
      )
    )
    guard !meetingTranscriptionProgressTitle.isEmpty, !isRecordingMeeting else { return }
    setIfChanged(
      \.meetingStatusText,
      "Transcribing \(meetingTranscriptionProgressTitle) locally... \(Int(progress * 100))%"
    )
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
    setIfChanged(\.openClawVoiceTranscriptionState, TranscriptionProgressState())
  }

  private func updateOpenClawVoiceTranscriptionProgress() {
    let elapsed = openClawVoiceTranscriptionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    let progress = Self.openClawVoiceTranscriptionProgress(
      elapsed: elapsed,
      estimatedDuration: openClawVoiceTranscriptionEstimatedDuration
    )
    setIfChanged(
      \.openClawVoiceTranscriptionState,
      TranscriptionProgressState(
        progress: progress,
        elapsedText: Self.openClawVoiceTranscriptionElapsedText(elapsed: elapsed)
      )
    )
    let statusText = "Transcribing OpenClaw dictation locally... \(Int(progress * 100))%"
    setIfChanged(\.openClawVoiceStatusText, statusText)
    setIfChanged(\.openClawStatusText, statusText)
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
    Task { await refreshOpenClawThreads() }
  }

  private func beginMeetingProcessing(title: String, status: String) {
    activeMeetingProcessingTitles.insert(Self.normalizedMeetingProcessingTitle(title))
    activeMeetingProcessingCount += 1
    if !isRecordingMeeting {
      meetingStatusText = status
    }
    statusText = status
  }

  private func endMeetingProcessing(title: String) {
    activeMeetingProcessingTitles.remove(Self.normalizedMeetingProcessingTitle(title))
    activeMeetingProcessingCount = max(0, activeMeetingProcessingCount - 1)
  }

  private func reconcileMeetingProcessingState(with items: [MeetingWorkspaceItem]) {
    guard isProcessingMeeting else { return }

    let completedTitles = Set(items.compactMap { item -> String? in
      guard item.transcriptionStatus?.lowercased() == MeetingTranscriptionStatus.complete.rawValue else {
        return nil
      }
      return Self.normalizedMeetingProcessingTitle(item.title)
    })

    if !activeMeetingProcessingTitles.isEmpty {
      activeMeetingProcessingTitles.subtract(completedTitles)
      if activeMeetingProcessingTitles.isEmpty {
        clearMeetingProcessingState()
      }
    } else if let staleTitle = Self.transcribingMeetingTitle(fromStatus: meetingStatusText),
              completedTitles.contains(Self.normalizedMeetingProcessingTitle(staleTitle)) {
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

  private func clearMeetingProcessingState() {
    activeMeetingProcessingTitles = []
    activeMeetingProcessingCount = 0
    setIfChanged(\.isProcessingMeeting, false)
    stopMeetingTranscriptionProgress(id: nil)
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

  nonisolated private static func scanOpenClawThreads(corpusRoot: URL) throws -> OpenClawThreadScanResult {
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

    let sortedThreads = threads
      .sorted {
        let left = $0.modifiedAt ?? .distantPast
        let right = $1.modifiedAt ?? .distantPast
        if left != right { return left > right }
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
      .prefix(250)
      .map { $0 }
    return OpenClawThreadScanResult(threads: sortedThreads, directories: directories)
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
    let snapshotRoots = openClawChangeSnapshotRoots(corpusRoot: root)
    guard !snapshotRoots.isEmpty else {
      return OpenClawCorpusSnapshot(rootPath: rootPath, files: [:])
    }

    var files: [String: OpenClawSnapshotFile] = [:]
    var scannedRoots = Set<String>()
    for snapshotRoot in snapshotRoots {
      let rootKey = snapshotRoot.url.path
      guard scannedRoots.insert(rootKey).inserted else { continue }
      scanOpenClawSnapshotFiles(
        corpusRootPath: rootPath,
        snapshotRoot: snapshotRoot.url,
        recursive: snapshotRoot.recursive,
        files: &files
      )
    }

    return OpenClawCorpusSnapshot(rootPath: rootPath, files: files)
  }

  nonisolated private static func openClawChangeSnapshotRoots(
    corpusRoot: URL
  ) -> [(url: URL, recursive: Bool)] {
    var roots: [(url: URL, recursive: Bool)] = [(corpusRoot.standardizedFileURL, false)]
    for directory in openClawThreadDirectories(corpusRoot: corpusRoot) where isDirectoryURL(directory) {
      roots.append((directory.standardizedFileURL, true))
    }
    return roots
  }

  nonisolated private static func scanOpenClawSnapshotFiles(
    corpusRootPath rootPath: String,
    snapshotRoot: URL,
    recursive: Bool,
    files: inout [String: OpenClawSnapshotFile]
  ) {
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
    let skippedDirectories = Set([".git", ".hg", ".svn", ".trash", "node_modules", "dist", "build", ".build", "DerivedData"])
    guard let enumerator = FileManager.default.enumerator(
      at: snapshotRoot,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return
    }

    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
        continue
      }
      if values.isDirectory == true {
        if !recursive || skippedDirectories.contains(url.lastPathComponent) {
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

  nonisolated private static func scanCorpusFileDisplayState(corpusRoot: URL) throws -> CorpusFileDisplayState {
    corpusFileDisplayState(files: try scanCorpusFiles(corpusRoot: corpusRoot))
  }

  nonisolated private static func scanCorpusFiles(corpusRoot: URL) throws -> [CorpusFile] {
    let root = corpusRoot.standardizedFileURL
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
    let skippedDirectories = Set([".git", ".hg", ".svn", ".trash", ".org2", "node_modules", "dist", "build", ".build", "DerivedData", "sync-conflicts"])
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

  nonisolated private static func isDefaultIgnoredSyncArtifactPath(_ path: String) -> Bool {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.hasPrefix(".syncthing.")
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

    return openClawThreadDirectories(corpusRoot: corpusRoot, rawDirectories: rawDirectories)
  }

  nonisolated private static func defaultOpenClawThreadDirectories(corpusRoot: URL) -> [URL] {
    openClawThreadDirectories(
      corpusRoot: corpusRoot,
      rawDirectories: ["agents", "meetings", "notes/openclaw", "raw/openclaw", "views/openclaw"]
    )
  }

  nonisolated private static func openClawThreadDirectories(corpusRoot: URL, rawDirectories: [String]) -> [URL] {
    let root = corpusRoot.standardizedFileURL

    return rawDirectories.map { raw in
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if NSString(string: trimmed).isAbsolutePath {
        return URL(fileURLWithPath: trimmed).standardizedFileURL
      }
      return root.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
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

  nonisolated private static func upsertHeadlinePropertiesOffMain(
    file: String,
    line: Int,
    properties: [String: String]
  ) async throws {
    try await Task.detached(priority: .userInitiated) {
      try upsertHeadlineProperties(file: file, line: line, properties: properties)
    }.value
  }

  nonisolated private static func upsertHeadlineProperties(file: String, line: Int, properties: [String: String]) throws {
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

  nonisolated private static func nestedParentSendHeadingOffMain(
    for target: HeadlineMutationTarget
  ) async throws -> (line: Int, id: String?)? {
    try await Task.detached(priority: .userInitiated) {
      try nestedParentSendHeading(for: target)
    }.value
  }

  nonisolated private static func nestedParentSendHeading(for target: HeadlineMutationTarget) throws -> (line: Int, id: String?)? {
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

  nonisolated private static func updateHeadlinePriorityOffMain(file: String, line: Int, priority: String?) async throws {
    try await Task.detached(priority: .userInitiated) {
      try updateHeadlinePriority(file: file, line: line, priority: priority)
    }.value
  }

  nonisolated private static func updateHeadlinePriority(file: String, line: Int, priority: String?) throws {
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
    Self.dailyNotePath(corpusRoot: corpusRoot, date: Date())
  }

  nonisolated private static func dailyNotePath(corpusRoot: URL, date: Date) -> URL {
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

  nonisolated private static func createDailyNote(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let title = url.deletingPathExtension().lastPathComponent
    try "#+TITLE: \(title)\n\n".write(to: url, atomically: true, encoding: .utf8)
  }

  nonisolated private static func corpusFile(for url: URL, corpusRoot: URL) -> CorpusFile {
    let standardizedURL = url.standardizedFileURL
    let relativePath = Self.relativePath(for: standardizedURL.path, root: corpusRoot.standardizedFileURL)
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

  nonisolated private static func knowledgeNodePath(corpusRoot: URL, title: String) -> URL {
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

  nonisolated private static func ensureKnowledgeNode(
    corpusRoot: URL,
    title: String,
    sourceLocation: WorkspaceLocation?
  ) throws -> CreatedKnowledgeNode {
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
        let relativeSourcePath = Self.relativePath(
          for: sourceLocation.file,
          root: corpusRoot.standardizedFileURL
        )
        sourceLink = "\nOrigin: [[file:\(relativeSourcePath)][\(sourceLocation.title)]]"
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

  nonisolated private static func ensureKnowledgeNodeOffMain(
    corpusRoot: URL,
    title: String,
    sourceLocation: WorkspaceLocation?
  ) async throws -> CreatedKnowledgeNode {
    try await Task.detached(priority: .userInitiated) {
      try ensureKnowledgeNode(corpusRoot: corpusRoot, title: title, sourceLocation: sourceLocation)
    }.value
  }

  public func createKnowledgeNode(title: String) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    let cleanTitle = Org2Display.cleanInline(title).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else {
      statusText = "Knowledge node creation canceled"
      return
    }

    do {
      let node = try await Self.ensureKnowledgeNodeOffMain(
        corpusRoot: corpusRoot,
        title: cleanTitle,
        sourceLocation: selectedLocation
      )
      statusText = "Knowledge node ready -> \(relativePath(node.file))"
      invalidateCanonicalDocumentCache(for: node.file)
      await refreshCorpusFiles()
      searchQuery = "id:\(node.id)"
      setIfChanged(\.selectedSurface, .search)
      await runSearch()
    } catch {
      errorText = error.localizedDescription
      statusText = "Knowledge node creation failed"
    }
  }

  nonisolated public static func selectedText(in text: String, range: NSRange) -> String? {
    guard range.length > 0,
          let swiftRange = Range(range, in: text)
    else {
      return nil
    }
    let selected = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    return selected.isEmpty ? nil : selected
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
    guard let selected = selectedText(in: text, range: range) else { return nil }
    return replacingSelection(in: text, range: range, with: "[[\(selected)]]")
  }

  nonisolated public static func nodeLinkReplacementForSelectedText(
    in text: String,
    range: NSRange,
    id: String,
    title: String
  ) -> InlineSelectionReplacement? {
    let cleanTitle = Org2Display.cleanInline(title).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { return nil }
    return replacingSelection(in: text, range: range, with: "[[id:\(id)][\(cleanTitle)]]")
  }

  public func createKnowledgeNodeFromSelection(text: String, range: NSRange) async -> InlineSelectionReplacement? {
    guard let title = Self.selectedText(in: text, range: range) else {
      statusText = "Select text first"
      return nil
    }

    do {
      guard let corpusRoot else {
        throw WorkspaceEditError.noCorpusRoot
      }
      let node = try await Self.ensureKnowledgeNodeOffMain(
        corpusRoot: corpusRoot,
        title: title,
        sourceLocation: selectedLocation
      )
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
      guard let corpusRoot else {
        throw WorkspaceEditError.noCorpusRoot
      }
      let node = try await Self.ensureKnowledgeNodeOffMain(
        corpusRoot: corpusRoot,
        title: title,
        sourceLocation: selectedLocation
      )
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

  nonisolated private static func appendCaptureOffMain(
    draft: WorkspaceCaptureDraft,
    corpusRoot: URL,
    assignee: String
  ) async throws -> URL {
    try await Task.detached(priority: .userInitiated) {
      let target = dailyNotePath(corpusRoot: corpusRoot, date: Date())
      try appendCapture(draft: draft, to: target, corpusRoot: corpusRoot, assignee: assignee)
      return target
    }.value
  }

  nonisolated private static func appendCapture(
    draft: WorkspaceCaptureDraft,
    to target: URL,
    corpusRoot: URL,
    assignee: String
  ) throws {
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let entry = try captureEntryText(draft: draft, corpusRoot: corpusRoot, assignee: assignee)
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

  nonisolated private static func captureEntryText(
    draft: WorkspaceCaptureDraft,
    corpusRoot: URL,
    assignee: String
  ) throws -> String {
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
      properties["ASSIGNEE"] = assignee
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

  nonisolated private static func materializeCaptureAttachment(
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

  nonisolated private static func captureTagsSuffix(_ raw: String) -> String {
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

  nonisolated private static func orgLink(target: String, label: String) -> String {
    let cleanTarget = target.replacingOccurrences(of: "]", with: "%5D")
    let cleanLabel = label
      .replacingOccurrences(of: "[", with: "(")
      .replacingOccurrences(of: "]", with: ")")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return "[[\(cleanTarget)][\(cleanLabel.isEmpty ? cleanTarget : cleanLabel)]]"
  }

  nonisolated private static func captureAttachmentFileName(for attachment: WorkspaceCaptureAttachmentDraft) -> String {
    let ext = captureAttachmentExtension(for: attachment)
    let baseName = URL(fileURLWithPath: attachment.name).deletingPathExtension().lastPathComponent
    let slug = Self.slug(baseName.isEmpty ? attachment.kind.rawValue : baseName)
    return ext.isEmpty ? slug : "\(slug).\(ext)"
  }

  nonisolated private static func captureAttachmentExtension(for attachment: WorkspaceCaptureAttachmentDraft) -> String {
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

  nonisolated private static func uniqueAttachmentURL(in directory: URL, fileName: String) -> URL {
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

  nonisolated private static func captureFileTimestamp(_ date: Date) -> String {
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

  nonisolated private static func formatDate(_ date: Date) -> String {
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

  nonisolated private static func date(for target: DailyNoteTarget) -> Date {
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

  nonisolated private static func orgTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
    return "<\(formatter.string(from: date))>"
  }

  nonisolated private static func orgDateTimestamp(_ date: Date) -> String {
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

  nonisolated private static func normalizePriority(_ raw: String) -> String? {
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

private struct OpenClawTranscriptState: Sendable {
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
    case .meetings: "⌘5"
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
