import AppKit
import Foundation
import SwiftUI

@MainActor
public final class WorkspaceStore: ObservableObject {
  @Published public var selectedSurface: WorkspaceSurface = .agenda
  @Published public var agendaMode: AgendaMode = .range
  @Published public var agendaFilter = ""
  @Published public var agendaFilterFocusToken = 0
  @Published public var selectedAgendaItemID: String?
  @Published public var corpusRoot: URL?
  @Published public var agenda: AgendaPayload?
  @Published public var searchQuery = ""
  @Published public var searchResults: [SearchResult] = []
  @Published public var openClawMessages: [OpenClawChatMessage] = []
  @Published public var openClawDraft = ""
  @Published public var openClawAgentID = "main"
  @Published public var openClawEndpointText = ""
  @Published public var openClawRemoteCorpusPath = ""
  @Published public var openClawHasStoredToken = false
  @Published public var openClawStatusText = WorkspaceStore.defaultOpenClawStatusText()
  @Published public var isSendingOpenClawMessage = false
  @Published public var openClawThreads: [OpenClawThread] = []
  @Published public var selectedOpenClawThreadID: String?
  @Published public var selectedLocation: WorkspaceLocation?
  @Published public var selectedEntrySource: EntrySource?
  @Published public var selectedEntrySourceMode: EntrySourceMode = .entry
  @Published public var editableEntryText = ""
  @Published public var backlinks: BacklinksPayload?
  @Published public var isLoadingAgenda = false
  @Published public var isSearching = false
  @Published public var isLoadingOpenClawThreads = false
  @Published public var isLoadingEntrySource = false
  @Published public var isEditingEntry = false
  @Published public var isSavingEntry = false
  @Published public var isLoadingBacklinks = false
  @Published public var priorityModeActive = false
  @Published public var statusText = ""
  @Published public var errorText: String?

  public let cli: Org2CLI
  private let defaults: UserDefaults
  private let corpusKey = "Org2Workspace.corpusRoot"
  private let openClawEndpointKey = "Org2Workspace.openClawEndpoint"
  private let openClawAgentKey = "Org2Workspace.openClawAgent"
  private let openClawRemoteCorpusPathKey = "Org2Workspace.openClawRemoteCorpusPath"
  private let openClawSessionKey = "org2-workspace:\(UUID().uuidString)"
  private var pendingG = false

  public init(cli: Org2CLI? = nil, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.cli = cli ?? (try? Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())) ?? Org2CLI(repoRoot: URL(fileURLWithPath: "/Users/avi/dev/org2"))
    let settings = OpenClawGatewaySettings.resolve()
    openClawEndpointText = defaults.string(forKey: openClawEndpointKey) ?? settings.endpoint.absoluteString
    openClawAgentID = defaults.string(forKey: openClawAgentKey) ?? "main"
    openClawRemoteCorpusPath = defaults.string(forKey: openClawRemoteCorpusPathKey) ?? ""
    openClawHasStoredToken = OpenClawKeychain.readToken() != nil
    openClawStatusText = Self.openClawStatusText(settings: currentOpenClawSettings())
  }

  public func bootstrap() async {
    if corpusRoot == nil {
      corpusRoot = restoreCorpusRoot()
    }

    if corpusRoot != nil {
      await refreshAgenda()
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
    searchResults = []
    openClawThreads = []
    selectedOpenClawThreadID = nil
    selectedLocation = nil
    selectedEntrySource = nil
    editableEntryText = ""
    isEditingEntry = false
    backlinks = nil
    errorText = nil
  }

  public func refreshWorkspace() async {
    await refreshAgenda()
    Task { await refreshOpenClawThreads() }
  }

  public func refreshAgenda() async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
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
      syncAgendaSelectionAfterRefresh()
      statusText = "\(payload.totalItemCount) agenda item\(payload.totalItemCount == 1 ? "" : "s")"
    } catch {
      errorText = error.localizedDescription
      statusText = "Agenda failed"
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

  public func select(_ location: WorkspaceLocation) {
    if case .agenda(let item) = location {
      selectedAgendaItemID = item.id
    }
    if case .openClaw(let thread) = location {
      selectedOpenClawThreadID = thread.id
    }
    selectedLocation = location
    isEditingEntry = false
    editableEntryText = ""
    selectedEntrySourceMode = .entry
    selectedEntrySource = nil
    Task { await loadBacklinks(for: location) }
    Task { await loadEntrySource(for: location) }
  }

  public func loadEntrySource(for location: WorkspaceLocation) async {
    isLoadingEntrySource = true
    defer { isLoadingEntrySource = false }

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
      guard selectedLocation == nil || selectedLocation == location else { return }
      selectedEntrySource = source
      if isEditingEntry {
        editableEntryText = source.text
      }
    } catch {
      guard selectedLocation == nil || selectedLocation == location else { return }
      selectedEntrySource = nil
      errorText = error.localizedDescription
    }
  }

  public func reloadSelectedEntrySource() async {
    isEditingEntry = false
    editableEntryText = ""
    guard let selectedLocation else { return }
    await loadEntrySource(for: selectedLocation)
  }

  public func beginEditingSelectedEntry() {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    editableEntryText = source.text
    isEditingEntry = true
  }

  public func cancelEditingSelectedEntry() {
    editableEntryText = selectedEntrySource?.text ?? ""
    isEditingEntry = false
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

    do {
      let replacement = editableEntryText
      try await Task.detached(priority: .userInitiated) {
        try Self.replaceEntrySource(source, with: replacement)
      }.value
      statusText = "Saved \(relativePath(source.file)):\(source.displayRange)"
      isEditingEntry = false
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      await refreshAgenda()
    } catch {
      errorText = error.localizedDescription
      statusText = "Save failed"
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

  public func openDailyNote(_ target: DailyNoteTarget) {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    let url = dailyNotePath(corpusRoot: corpusRoot, date: Self.date(for: target))
    if FileManager.default.fileExists(atPath: url.path) {
      let thread = OpenClawThread(title: url.deletingPathExtension().lastPathComponent, file: url.path, zone: "daily", modifiedAt: nil)
      selectedSurface = .agentSpace
      selectedLocation = .openClaw(thread)
      selectedOpenClawThreadID = thread.id
      selectedEntrySourceMode = .page
      selectedEntrySource = nil
      editableEntryText = ""
      isEditingEntry = false
      Task { await loadBacklinks(for: .openClaw(thread)) }
      Task { await loadEntrySource(for: .openClaw(thread)) }
    } else {
      statusText = "Daily note not found: \(url.lastPathComponent)"
      NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
    }
  }

  public func sendOpenClawMessage() async {
    let text = openClawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    let userMessage = OpenClawChatMessage(role: .user, content: text)
    openClawMessages.append(userMessage)
    openClawDraft = ""
    isSendingOpenClawMessage = true
    openClawStatusText = "Sending to OpenClaw..."
    defer { isSendingOpenClawMessage = false }

    do {
      let client = OpenClawChatClient(settings: currentOpenClawSettings())
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
    openClawMessages = []
    openClawDraft = ""
    openClawStatusText = Self.openClawStatusText(settings: currentOpenClawSettings())
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
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      defaults.set(normalizedEndpoint, forKey: openClawEndpointKey)
      defaults.set(agent, forKey: openClawAgentKey)
      defaults.set(remoteCorpusPath, forKey: openClawRemoteCorpusPathKey)
      openClawEndpointText = normalizedEndpoint
      openClawAgentID = agent
      openClawRemoteCorpusPath = remoteCorpusPath

      if clearToken {
        try OpenClawKeychain.deleteToken()
      } else if !token.isEmpty {
        try OpenClawKeychain.saveToken(token)
      }

      openClawHasStoredToken = OpenClawKeychain.readToken() != nil
      openClawStatusText = Self.openClawStatusText(settings: currentOpenClawSettings())
      return true
    } catch {
      openClawStatusText = error.localizedDescription
      return false
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
      }
      await refreshAgenda()
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
      await refreshAgenda()
    } catch {
      errorText = error.localizedDescription
      statusText = "Property update failed"
    }
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
      beginEditingSelectedEntry()
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
    guard let id = location.idValue, !id.isEmpty else {
      backlinks = nil
      return
    }
    guard let corpusRoot else { return }

    isLoadingBacklinks = true
    defer { isLoadingBacklinks = false }

    do {
      backlinks = try await cli.runJSON([
        "backlinks",
        "--id", id,
        "--dir", corpusRoot.path,
        "--recursive",
        "--format", "json"
      ])
    } catch {
      backlinks = nil
      errorText = error.localizedDescription
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

  private func currentOpenClawSettings() -> OpenClawGatewaySettings {
    OpenClawGatewaySettings.resolve(
      userEndpoint: openClawEndpointText,
      userBearerToken: OpenClawKeychain.readToken()
    )
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

  private static func defaultOpenClawStatusText() -> String {
    openClawStatusText(settings: OpenClawGatewaySettings.resolve())
  }

  private static func openClawStatusText(settings: OpenClawGatewaySettings) -> String {
    if settings.chatCompletionsEnabled != true {
      return "OpenClaw chat endpoint may need enabling in the local gateway config"
    }
    return "OpenClaw gateway: \(settings.endpoint.host ?? settings.endpoint.absoluteString)"
  }

  private func syncAgendaSelectionAfterRefresh() {
    let items = visibleAgendaItems
    guard !items.isEmpty else {
      selectedAgendaItemID = nil
      if case .agenda = selectedLocation {
        selectedLocation = nil
        backlinks = nil
      }
      return
    }

    if let selectedAgendaItemID, let item = items.first(where: { $0.id == selectedAgendaItemID }) {
      if case .agenda = selectedLocation {
        select(.agenda(item))
      }
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
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let endLineExclusive = max(2, lines.count + 1)
    return EntrySource(
      file: file,
      startLine: 1,
      endLineExclusive: endLineExclusive,
      text: normalized,
      isSubtree: false,
      isEditable: true
    )
  }

  nonisolated private static func replaceEntrySource(_ source: EntrySource, with replacement: String) throws {
    let url = URL(fileURLWithPath: source.file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    var lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let startIndex = source.startLine - 1
    let endIndex = source.endLineExclusive - 1
    guard startIndex >= 0, startIndex <= lines.count, endIndex >= startIndex, endIndex <= lines.count else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: source.startLine)
    }

    let replacementLines = normalizeLineEndings(replacement)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    lines.replaceSubrange(startIndex..<endIndex, with: replacementLines)

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
      ? ["agents", "notes/openclaw", "raw/openclaw", "views/openclaw"]
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

public enum WorkspaceSurface: String, CaseIterable, Identifiable, Sendable {
  case agenda
  case search
  case openClaw
  case agentSpace

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .agenda: "Today"
    case .search: "Search"
    case .openClaw: "OpenClaw Chat"
    case .agentSpace: "Agent Space"
    }
  }

  public var systemImage: String {
    switch self {
    case .agenda: "calendar"
    case .search: "magnifyingglass"
    case .openClaw: "sparkles"
    case .agentSpace: "bubble.left.and.bubble.right"
    }
  }
}
