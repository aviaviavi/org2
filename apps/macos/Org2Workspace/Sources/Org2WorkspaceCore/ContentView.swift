import AppKit
import SwiftUI

public struct ContentView: View {
  @EnvironmentObject private var store: WorkspaceStore

  public init() {}

  public var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
    } content: {
      switch store.selectedSurface {
      case .agenda:
        AgendaView()
      case .files:
        FilesView()
      case .search:
        SearchView()
      case .meetings:
        MeetingsView()
      case .openClaw:
        OpenClawChatView()
      case .agentSpace:
        OpenClawThreadsView()
      }
    } detail: {
      WorkspaceDetailArea()
    }
    .toolbar {
      ToolbarItemGroup {
        Button {
          store.isOpenClawAssistantPresented.toggle()
        } label: {
          Label(
            store.isOpenClawAssistantPresented ? "Hide OpenClaw" : "Show OpenClaw",
            systemImage: store.isOpenClawAssistantPresented ? "sidebar.right" : "sidebar.trailing"
          )
        }

        Button {
          store.chooseCorpus()
        } label: {
          Label("Open Corpus", systemImage: "folder")
        }

        Button {
          Task { await store.refreshWorkspace() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.corpusRoot == nil || store.isLoadingAgenda)
      }
    }
    .keyboardEventMonitor { event in
      store.handleWorkspaceKeyDown(event)
    }
    .environment(\.openOrgFileReference) { reference in
      store.openChatFileReference(reference)
    }
    .environment(\.orgRoamLinkResolver, store.orgRoamLinkResolver)
    .sheet(isPresented: $store.isQuickOpenPresented) {
      QuickOpenView()
        .environmentObject(store)
    }
    .sheet(isPresented: $store.isKeyboardShortcutsPresented) {
      KeyboardShortcutsView()
        .environmentObject(store)
    }
    .sheet(isPresented: $store.isOrgCryptConfigurationPresented) {
      OrgCryptConfigurationSheet()
        .environmentObject(store)
    }
  }
}

private struct WorkspaceDetailArea: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    if store.isOpenClawAssistantPresented && store.selectedSurface != .openClaw {
      HSplitView {
        DetailView()
          .frame(minWidth: 420)

        OpenClawChatView(presentation: .assistantPanel)
          .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
      }
    } else {
      DetailView()
    }
  }
}

private struct SidebarView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    List(selection: $store.selectedSurface) {
      Section("Workspace") {
        ForEach(WorkspaceSurface.sidebarCases) { surface in
          HStack(spacing: 8) {
            Label(surface.title, systemImage: surface.systemImage)
              .font(.callout.weight(.medium))
            Spacer(minLength: 0)
            KeyboardShortcutBadge(text: surface.commandShortcutTitle)
          }
          .tag(surface)
          .help("\(surface.title) (\(surface.commandShortcutTitle))")
        }
      }

      Section("Corpus") {
        if let root = store.corpusRoot {
          VStack(alignment: .leading, spacing: 5) {
            Text(root.path)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(4)
              .textSelection(.enabled)
            HStack(spacing: 5) {
              Image(systemName: "doc.text")
              Text("\(store.corpusFiles.count) file\(store.corpusFiles.count == 1 ? "" : "s")")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
          }
        } else {
          Button {
            store.chooseCorpus()
          } label: {
            Label("Open Corpus", systemImage: "folder")
          }
        }
      }

      Section("Daily") {
        ForEach(DailyNoteTarget.allCases) { target in
          Button {
            store.openDailyNote(target)
          } label: {
            HStack(spacing: 8) {
              Label(target.title, systemImage: target == .today ? "sun.max" : "calendar")
                .font(.callout.weight(.medium))
              Spacer(minLength: 0)
              KeyboardShortcutBadge(text: target.commandShortcutTitle)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("\(target.title) daily note (\(target.commandShortcutTitle))")
        }
      }
    }
    .listStyle(.sidebar)
  }
}

private struct FilesView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Files", subtitle: store.corpusRoot?.path ?? "Corpus files") {
        if store.isScanningCorpusFiles {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          store.presentQuickOpen()
        } label: {
          Label("Quick Open", systemImage: "command")
        }

        Button {
          Task { await store.refreshCorpusFiles() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.corpusRoot == nil || store.isScanningCorpusFiles)
      }

      HStack(spacing: 8) {
        TextField("Filter files", text: $store.corpusFileFilter)
          .textFieldStyle(.roundedBorder)
        if !store.corpusFileFilter.isEmpty {
          Button {
            store.corpusFileFilter = ""
          } label: {
            Label("Clear", systemImage: "xmark.circle.fill")
          }
          .labelStyle(.iconOnly)
        }
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 12)

      if store.corpusRoot == nil {
        EmptyStateView(title: "No Corpus", detail: store.statusText, action: "Open Corpus") {
          store.chooseCorpus()
        }
      } else if store.corpusFiles.isEmpty && store.isScanningCorpusFiles {
        Spacer()
        ProgressView()
        Spacer()
      } else if store.filteredCorpusFiles.isEmpty {
        EmptyStateView(title: "No Files", detail: "No org2, org, or markdown files matched.", action: "Refresh") {
          Task { await store.refreshCorpusFiles() }
        }
      } else {
        List(selection: $store.selectedCorpusFileID) {
          ForEach(store.filteredCorpusFiles) { file in
            CorpusFileRow(file: file)
              .tag(file.id)
          }
        }
        .listStyle(.inset)
        .onChange(of: store.selectedCorpusFileID) {
          guard let id = store.selectedCorpusFileID,
                let file = store.corpusFiles.first(where: { $0.id == id })
          else {
            return
          }
          store.selectCorpusFile(file)
        }
      }
    }
  }
}

private struct CorpusFileRow: View {
  let file: CorpusFile

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      WorkspaceIconBadge(systemImage: "doc.text")
      VStack(alignment: .leading, spacing: 3) {
        Text(file.name)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(file.relativePath)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if let byteCount = file.byteCount {
        Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct QuickOpenView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  @FocusState private var queryFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Quick open file", text: $store.quickOpenQuery)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($queryFocused)
          .onSubmit {
            _ = openSelectedOrFirst()
          }
      }
      .padding(10)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(0.18))
      )

      if store.isScanningCorpusFiles {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Scanning files")
            .foregroundStyle(.secondary)
        }
      }

      List(selection: $store.selectedQuickOpenFileID) {
        ForEach(store.quickOpenFiles) { file in
          CorpusFileRow(file: file)
            .tag(file.id)
            .contentShape(Rectangle())
            .onTapGesture {
              open(file)
            }
        }
      }
      .listStyle(.plain)
      .frame(minHeight: 320)
    }
    .padding(16)
    .frame(width: 720, height: 460)
    .modifier(QuickOpenKeyboardEventMonitor(handler: handleKeyDown))
    .onAppear {
      queryFocused = true
      store.resetQuickOpenSelection()
    }
    .onChange(of: store.quickOpenQuery) {
      store.resetQuickOpenSelection()
    }
  }

  private func openSelectedOrFirst() -> Bool {
    guard let file = store.selectedQuickOpenFile else { return false }
    open(file)
    return true
  }

  private func open(_ file: CorpusFile) {
    store.selectCorpusFile(file)
    store.isQuickOpenPresented = false
    dismiss()
  }

  private func handleKeyDown(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard modifiers.isEmpty else { return false }

    switch event.keyCode {
    case 125:
      store.moveQuickOpenSelection(.down)
      return true
    case 126:
      store.moveQuickOpenSelection(.up)
      return true
    case 36, 76:
      return openSelectedOrFirst()
    case 53:
      store.isQuickOpenPresented = false
      dismiss()
      return true
    default:
      return false
    }
  }
}

private struct QuickOpenKeyboardEventMonitor: ViewModifier {
  let handler: (NSEvent) -> Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          handler(event) ? nil : event
        }
      }
      .onDisappear {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
        monitor = nil
      }
  }
}

private struct KeyboardShortcutsView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Keyboard Shortcuts")
            .font(.title2.weight(.semibold))
          Text("Global navigation uses Command keys. Agenda and document panes keep Vim-style local keys.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button {
          dismiss()
        } label: {
          Label("Close", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut(.cancelAction)
      }

      ScrollView {
        LazyVGrid(columns: [
          GridItem(.flexible(), spacing: 16),
          GridItem(.flexible(), spacing: 16)
        ], alignment: .leading, spacing: 18) {
          ShortcutSection(title: "Navigate", shortcuts: [
            ShortcutHelpItem(keys: "⌘1", action: "Agenda"),
            ShortcutHelpItem(keys: "⌘2", action: "Files"),
            ShortcutHelpItem(keys: "⌘3 / ⌘F", action: "Search"),
            ShortcutHelpItem(keys: "⌘4", action: "Meetings"),
            ShortcutHelpItem(keys: "⌘5", action: "OpenClaw Chat"),
            ShortcutHelpItem(keys: "⌘6", action: "Agent Space"),
            ShortcutHelpItem(keys: "⌘P / ⌘K", action: "Quick Open"),
            ShortcutHelpItem(keys: "⌘0", action: "Toggle OpenClaw side panel"),
            ShortcutHelpItem(keys: "⌘? / ⌘/", action: "Show shortcuts")
          ])

          ShortcutSection(title: "Daily Notes", shortcuts: [
            ShortcutHelpItem(keys: "⌘7", action: "Today"),
            ShortcutHelpItem(keys: "⌘8", action: "Yesterday"),
            ShortcutHelpItem(keys: "⌘9", action: "Tomorrow")
          ])

          ShortcutSection(title: "Agenda", shortcuts: [
            ShortcutHelpItem(keys: "j / ↓", action: "Next item"),
            ShortcutHelpItem(keys: "k / ↑", action: "Previous item"),
            ShortcutHelpItem(keys: "J / K", action: "Scroll detail pane"),
            ShortcutHelpItem(keys: "gg / G", action: "First / last item"),
            ShortcutHelpItem(keys: "1 2 3", action: "Agenda mode"),
            ShortcutHelpItem(keys: "/", action: "Filter agenda"),
            ShortcutHelpItem(keys: "o / Return", action: "Open item"),
            ShortcutHelpItem(keys: "e", action: "Edit item source"),
            ShortcutHelpItem(keys: "t i d x", action: "TODO / in-progress / done / canceled"),
            ShortcutHelpItem(keys: "A", action: "Assign to agent"),
            ShortcutHelpItem(keys: "p", action: "Priority mode"),
            ShortcutHelpItem(keys: "s n w m", action: "Schedule today / tomorrow / week / month")
          ])

          ShortcutSection(title: "Document", shortcuts: [
            ShortcutHelpItem(keys: "j / k", action: "Move block selection"),
            ShortcutHelpItem(keys: "Return", action: "Edit selected block"),
            ShortcutHelpItem(keys: "⌘Return", action: "Insert paragraph after block"),
            ShortcutHelpItem(keys: "/", action: "Insert slash-command paragraph"),
            ShortcutHelpItem(keys: "← / →", action: "Collapse / expand block"),
            ShortcutHelpItem(keys: "⌘← / ⌘→", action: "Collapse / expand all"),
            ShortcutHelpItem(keys: "Delete", action: "Delete selected block"),
            ShortcutHelpItem(keys: "⌘D", action: "Duplicate selected block"),
            ShortcutHelpItem(keys: "⌘⇧↑ / ⌘⇧↓", action: "Move block"),
            ShortcutHelpItem(keys: "Esc", action: "Clear block selection")
          ])

          ShortcutSection(title: "Editing", shortcuts: [
            ShortcutHelpItem(keys: "⌘S", action: "Save active inline editor"),
            ShortcutHelpItem(keys: "Esc", action: "Cancel active inline editor"),
            ShortcutHelpItem(keys: "⌘B / ⌘I", action: "Bold / italic selected inline text"),
            ShortcutHelpItem(keys: "⌘U", action: "Underline selected inline text"),
            ShortcutHelpItem(keys: "⌘R", action: "Run source block while editing source")
          ])
        }
        .padding(.vertical, 2)
      }
    }
    .padding(20)
    .frame(width: 760, height: 620)
  }
}

private struct ShortcutHelpItem: Identifiable {
  let keys: String
  let action: String

  var id: String {
    "\(keys):\(action)"
  }
}

private struct ShortcutSection: View {
  let title: String
  let shortcuts: [ShortcutHelpItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)

      VStack(alignment: .leading, spacing: 6) {
        ForEach(shortcuts) { shortcut in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(shortcut.keys)
              .font(.caption.monospaced().weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 92, alignment: .leading)
            Text(shortcut.action)
              .font(.callout)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
        }
      }
    }
    .padding(12)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.secondary.opacity(0.12))
    )
  }
}

private struct AgendaView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @FocusState private var agendaFilterFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Agenda", subtitle: store.agenda.map { "\($0.range.start) to \($0.range.end)" } ?? "Agenda") {
        if store.isLoadingAgenda {
          ProgressView()
            .controlSize(.small)
        }
      }

      if let error = store.errorText, store.agenda == nil {
        EmptyStateView(title: "Agenda Failed", detail: error, action: "Refresh") {
          Task { await store.refreshAgenda() }
        }
      } else if let agenda = store.agenda {
        HStack(spacing: 10) {
          Picker("Mode", selection: $store.agendaMode) {
            ForEach(AgendaMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 260)

          TextField("Filter agenda", text: $store.agendaFilter)
            .textFieldStyle(.roundedBorder)
            .focused($agendaFilterFocused)
            .onSubmit {
              agendaFilterFocused = false
            }

          Button {
            store.promptAndCaptureTodoShortcut()
          } label: {
            Label("Capture", systemImage: "square.and.pencil")
          }

          if !store.agendaFilter.isEmpty {
            Button {
              store.clearAgendaFilter()
            } label: {
              Label("Clear", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
          }
        }
        .padding(.horizontal, WorkspaceDesign.contentInset)
        .padding(.bottom, 12)

        AgendaSummaryView(agenda: agenda)
        Divider()
        AgendaListView()
      } else {
        EmptyStateView(title: "No Agenda", detail: store.statusText, action: "Open Corpus") {
          store.chooseCorpus()
        }
      }
    }
    .onChange(of: store.agendaMode) {
      store.selectFirstAgendaItem()
    }
    .onChange(of: store.agendaFilter) {
      store.selectFirstAgendaItem()
    }
    .onChange(of: store.agendaFilterFocusToken) {
      agendaFilterFocused = true
    }
  }
}

private struct AgendaSummaryView: View {
  let agenda: AgendaPayload

  var body: some View {
    HStack(spacing: 10) {
      MetricView(title: "Overdue", value: "\(agenda.overdue.reduce(0) { $0 + $1.items.count })")
      MetricView(title: "Today", value: "\(agenda.todayItemCount)")
      MetricView(title: "Upcoming", value: "\(agenda.upcomingItemCount)")
      if let workload = agenda.workload {
        MetricView(title: "Effort", value: formatMinutes(workload.totalMinutes))
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
  }

  private func formatMinutes(_ minutes: Int) -> String {
    guard minutes > 0 else { return "0m" }
    let hours = minutes / 60
    let remainder = minutes % 60
    if hours == 0 { return "\(remainder)m" }
    if remainder == 0 { return "\(hours)h" }
    return "\(hours)h \(remainder)m"
  }
}

private struct MetricView: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.title3.weight(.semibold))
        .monospacedDigit()
      Text(title)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .frame(width: 94, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
        .stroke(WorkspaceDesign.hairline)
    )
  }
}

private struct AgendaListView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    List(selection: $store.selectedAgendaItemID) {
      ForEach(store.agendaDisplaySections) { section in
        Section(section.label) {
          ForEach(section.items) { item in
            AgendaRow(item: item)
              .tag(item.id)
              .contentShape(Rectangle())
              .onTapGesture {
                store.selectAgendaItem(item)
              }
          }
        }
      }

      if store.agendaDisplaySections.isEmpty {
        Text("No agenda items")
          .foregroundStyle(.secondary)
      }
    }
    .listStyle(.inset)
    .onChange(of: store.selectedAgendaItemID) {
      guard let id = store.selectedAgendaItemID,
            let item = store.visibleAgendaItems.first(where: { $0.id == id })
      else {
        return
      }
      store.select(.agenda(item))
    }
  }
}

private struct AgendaRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let item: AgendaItem

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      StatusPill(text: item.todo ?? "TASK")
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(Org2Display.cleanInline(item.headline))
            .font(.body.weight(.medium))
            .lineLimit(1)
          if item.idValue != nil {
            Image(systemName: "link")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        HStack(spacing: 8) {
          Text([item.kind, item.time].compactMap { $0 }.joined(separator: " "))
          Text(store.relativePath(item.file) + ":\(item.lineForEditor)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if let effort = item.effort {
        Text(effort)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct SearchView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Search", subtitle: "Cited corpus lookup") {
        if store.isSearching {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          store.promptAndCreateKnowledgeNode()
        } label: {
          Label("New Node", systemImage: "plus.circle")
        }
      }

      HStack(spacing: 8) {
        TextField("Search corpus", text: $store.searchQuery)
          .textFieldStyle(.roundedBorder)
          .focused($isSearchFocused)
          .onSubmit {
            Task { await store.runSearch() }
          }

        Button {
          Task { await store.runSearch() }
        } label: {
          Label("Search", systemImage: "magnifyingglass")
        }
        .disabled(store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSearching)
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 12)

      if store.searchResults.isEmpty {
        if store.isSearching {
          Spacer()
          ProgressView()
          Spacer()
        } else {
          EmptyStateView(title: "No Results", detail: store.statusText, action: "Refresh Agenda") {
            Task { await store.refreshAgenda() }
          }
        }
      } else {
        List(store.searchResults) { result in
          SearchRow(result: result)
            .contentShape(Rectangle())
            .onTapGesture {
              store.select(.search(result))
            }
        }
        .listStyle(.inset)
      }
    }
    .onAppear {
      if store.selectedSurface == .search {
        isSearchFocused = true
      }
    }
    .onChange(of: store.searchFocusToken) {
      isSearchFocused = true
    }
  }
}

private struct SearchRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let result: SearchResult

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "magnifyingglass")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          if let todo = result.todo {
            StatusPill(text: todo)
          }
          Text(Org2Display.cleanInline(result.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          if result.idValue != nil {
            Image(systemName: "link")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(Org2Display.cleanInline(result.snippet))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(store.relativePath(result.file) + ":\(result.lineForEditor)")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct MeetingsView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Meetings", subtitle: "\(store.meetings.count) local meeting\(store.meetings.count == 1 ? "" : "s")") {
        if store.isLoadingMeetings || store.isProcessingMeeting {
          ProgressView()
            .controlSize(.small)
        }

        if store.isRecordingMeeting {
          Button {
            Task { await store.stopMeetingRecording() }
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
        } else {
          Button {
            store.promptAndStartMeetingRecording()
          } label: {
            Label("Record", systemImage: "record.circle")
          }
          .disabled(store.corpusRoot == nil || store.isProcessingMeeting)
        }

        Button {
          store.promptAndImportMeetingAudio()
        } label: {
          Label("Import", systemImage: "tray.and.arrow.down")
        }
        .disabled(store.corpusRoot == nil || store.isRecordingMeeting || store.isProcessingMeeting)

        Button {
          Task { await store.refreshMeetings() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.corpusRoot == nil || store.isLoadingMeetings)
      }

      VStack(alignment: .leading, spacing: 8) {
        TextField("Meeting title", text: $store.meetingTitleDraft)
          .textFieldStyle(.roundedBorder)
          .disabled(store.isRecordingMeeting || store.isProcessingMeeting)

        HStack(spacing: 10) {
          Text(store.meetingStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

          Spacer(minLength: 0)

          MeetingInputStatusView(
            isRecording: store.isRecordingMeeting,
            averageLevel: store.meetingInputAverageLevel,
            peakLevel: store.meetingInputPeakLevel,
            systemAverageLevel: store.meetingSystemAudioAverageLevel,
            systemPeakLevel: store.meetingSystemAudioPeakLevel,
            isCapturingSystemAudio: store.isCapturingSystemAudio,
            systemAudioStatusText: store.meetingSystemAudioStatusText,
            sourceText: store.meetingCaptureSourceText
          )
        }
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 12)

      if store.meetings.isEmpty {
        if store.isLoadingMeetings {
          Spacer()
          ProgressView()
          Spacer()
        } else {
          EmptyStateView(title: "No Meetings", detail: store.meetingStatusText, action: "Record") {
            store.promptAndStartMeetingRecording()
          }
        }
      } else {
        List(selection: $store.selectedMeetingID) {
          ForEach(store.meetingDisplaySections) { section in
            Section(section.label) {
              ForEach(section.meetings) { meeting in
                MeetingRow(meeting: meeting)
                  .tag(meeting.id)
                  .contentShape(Rectangle())
                  .onTapGesture {
                    store.selectMeeting(meeting)
                  }
              }
            }
          }
        }
        .listStyle(.inset)
        .onChange(of: store.selectedMeetingID) {
          guard let id = store.selectedMeetingID,
                let meeting = store.meetings.first(where: { $0.id == id })
          else {
            return
          }
          store.select(.meeting(meeting))
        }
      }
    }
    .onAppear {
      if store.meetings.isEmpty {
        Task { await store.refreshMeetings() }
      }
    }
  }
}

private struct MeetingInputStatusView: View {
  let isRecording: Bool
  let averageLevel: Double
  let peakLevel: Double
  let systemAverageLevel: Double
  let systemPeakLevel: Double
  let isCapturingSystemAudio: Bool
  let systemAudioStatusText: String
  let sourceText: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: isRecording ? "waveform" : "mic")
        .foregroundStyle(isRecording ? .red : .secondary)

      if isRecording {
        VStack(alignment: .leading, spacing: 4) {
          MeetingInputMeterRow(label: "Mic", averageLevel: averageLevel, peakLevel: peakLevel)
          if isCapturingSystemAudio {
            MeetingInputMeterRow(label: "System", averageLevel: systemAverageLevel, peakLevel: systemPeakLevel)
          } else {
            Text(systemAudioStatusText)
              .font(.caption2)
              .foregroundStyle(.orange)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      } else {
        Text(sourceText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(isRecording ? "Meeting audio input levels" : sourceText)
    .help(sourceText)
  }
}

private struct MeetingInputMeterRow: View {
  let label: String
  let averageLevel: Double
  let peakLevel: Double

  var body: some View {
    HStack(spacing: 6) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 42, alignment: .trailing)

      WorkspaceInputMeterView(averageLevel: averageLevel, peakLevel: peakLevel)
        .frame(width: 120, height: 7)
    }
  }
}

struct WorkspaceInputMeterView: View {
  let averageLevel: Double
  let peakLevel: Double

  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, 1)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.16))

        Capsule()
          .fill(Color.red.opacity(0.28))
          .frame(width: max(2, width * clamped(peakLevel)))

        Capsule()
          .fill(Color.red)
          .frame(width: max(2, width * clamped(averageLevel)))
      }
    }
    .frame(height: 8)
  }

  private func clamped(_ value: Double) -> Double {
    min(1, max(0, value))
  }
}

private struct MeetingRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let meeting: MeetingWorkspaceItem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "waveform.and.mic")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(Org2Display.cleanInline(meeting.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          if let status = meeting.transcriptionStatus {
            StatusPill(text: status.uppercased())
          }
        }

        HStack(spacing: 8) {
          if let recordedAt = meeting.recordedAt {
            Text(recordedAt)
          }
          if let modifiedAt = meeting.modifiedAt {
            Text(Self.relativeDate(modifiedAt))
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        Text(store.relativePath(meeting.file) + ":\(meeting.lineForEditor)")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }

  private static func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

private enum OpenClawChatPresentation {
  case fullPage
  case assistantPanel
}

private struct OpenClawChatView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var isShowingConfiguration = false
  let presentation: OpenClawChatPresentation

  init(presentation: OpenClawChatPresentation = .fullPage) {
    self.presentation = presentation
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      configurationStrip

      Divider()

      chatTranscript

      Divider()

      OpenClawComposerView(
        focusOnAppear: presentation == .fullPage,
        compact: presentation == .assistantPanel
      )
      .padding(presentation == .assistantPanel ? 10 : 16)
    }
    .sheet(isPresented: $isShowingConfiguration) {
      OpenClawConfigurationSheet()
        .environmentObject(store)
    }
  }

  @ViewBuilder
  private var header: some View {
    switch presentation {
    case .fullPage:
      HeaderBar(title: "OpenClaw Chat", subtitle: store.openClawStatusText) {
        headerActions
      }
    case .assistantPanel:
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("OpenClaw")
            .font(.headline)
          Text(store.openClawStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Spacer(minLength: 0)
        if store.isSendingOpenClawMessage {
          ProgressView()
            .controlSize(.small)
        }
        Button {
          store.selectedSurface = .openClaw
          store.isOpenClawAssistantPresented = false
        } label: {
          Label("Focus Chat", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .labelStyle(.iconOnly)
        .help("Focus OpenClaw Chat")

        Button {
          store.isOpenClawAssistantPresented = false
        } label: {
          Label("Close", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .help("Close OpenClaw panel")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(WorkspaceDesign.barBackground)
      .overlay(alignment: .bottom) {
        Divider()
      }
    }
  }

  @ViewBuilder
  private var headerActions: some View {
    if store.isSendingOpenClawMessage {
      ProgressView()
        .controlSize(.small)
    }

    Button {
      store.resetOpenClawChat()
    } label: {
      Label("New", systemImage: "plus")
    }

    Button {
      isShowingConfiguration = true
    } label: {
      Label("Configure", systemImage: "slider.horizontal.3")
    }
  }

  @ViewBuilder
  private var configurationStrip: some View {
    if presentation == .fullPage {
      HStack(spacing: 8) {
        Label("Agent", systemImage: "cpu")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        TextField("main", text: $store.openClawAgentID)
          .textFieldStyle(.roundedBorder)
          .frame(width: 180)
        Label("Org2", systemImage: "folder")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Text(store.openClawContextRootText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(store.openClawEndpointText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 10)
    } else {
      HStack(spacing: 8) {
        TextField("Agent", text: $store.openClawAgentID)
          .textFieldStyle(.roundedBorder)
        Button {
          isShowingConfiguration = true
        } label: {
          Label("Configure", systemImage: "slider.horizontal.3")
        }
        .labelStyle(.iconOnly)
        .help("Configure OpenClaw")
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 10)
    }
  }

  private var chatTranscript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: presentation == .assistantPanel ? 8 : 10) {
          if store.openClawMessages.isEmpty {
            EmptyChatView(statusText: store.openClawStatusText)
              .frame(maxWidth: .infinity, minHeight: presentation == .assistantPanel ? 140 : 220)
          } else {
            ForEach(store.openClawMessages) { message in
              ChatBubbleView(message: message, compact: presentation == .assistantPanel)
                .id(message.id)
            }
            if store.isSendingOpenClawMessage {
              OpenClawTypingIndicatorView(startedAt: store.openClawRequestStartedAt)
                .id("openclaw-typing")
            }
          }
        }
        .padding(presentation == .assistantPanel ? 10 : 16)
      }
      .background(OpenClawChatScrollPositionBridge(
        initialPosition: store.openClawChatScrollPosition,
        onPositionChange: { position in
          store.recordOpenClawChatScrollPosition(position)
        }
      ))
      .onChange(of: store.openClawMessages.count) {
        if let last = store.openClawMessages.last {
          withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
      .onChange(of: store.isSendingOpenClawMessage) {
        if store.isSendingOpenClawMessage {
          withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo("openclaw-typing", anchor: .bottom)
          }
        }
      }
    }
  }
}

private struct OpenClawChatScrollPositionBridge: NSViewRepresentable {
  let initialPosition: Double?
  let onPositionChange: (Double) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.restoreIfNeeded(from: view)
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.stopObserving()
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: OpenClawChatScrollPositionBridge
    private weak var scrollView: NSScrollView?
    private var didRestore = false
    private var isRestoring = false

    init(parent: OpenClawChatScrollPositionBridge) {
      self.parent = parent
      super.init()
    }

    func restoreIfNeeded(from view: NSView) {
      guard !didRestore else {
        startObservingIfPossible(from: view)
        return
      }

      DispatchQueue.main.async {
        DispatchQueue.main.async {
          guard !self.didRestore,
                let scrollView = view.enclosingScrollView
          else {
            self.startObservingIfPossible(from: view)
            return
          }
          self.restore(scrollView, to: self.parent.initialPosition ?? 1)
          self.didRestore = true
          self.startObserving(scrollView)
        }
      }
    }

    func stopObserving() {
      if let scrollView {
        NotificationCenter.default.removeObserver(
          self,
          name: NSView.boundsDidChangeNotification,
          object: scrollView.contentView
        )
      }
      scrollView = nil
    }

    private func startObservingIfPossible(from view: NSView) {
      guard let scrollView = view.enclosingScrollView else { return }
      startObserving(scrollView)
    }

    private func startObserving(_ scrollView: NSScrollView) {
      guard self.scrollView !== scrollView else { return }
      stopObserving()
      self.scrollView = scrollView
      scrollView.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(boundsDidChange(_:)),
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
      )
    }

    @objc private func boundsDidChange(_ notification: Notification) {
      guard !isRestoring,
            let scrollView
      else {
        return
      }
      parent.onPositionChange(Self.normalizedPosition(in: scrollView))
    }

    private func restore(_ scrollView: NSScrollView, to position: Double) {
      guard let documentView = scrollView.documentView else { return }
      let clipView = scrollView.contentView
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      guard maxY > 0 else {
        parent.onPositionChange(1)
        return
      }

      let clamped = min(1, max(0, position))
      var origin = clipView.bounds.origin
      origin.y = documentView.isFlipped ? maxY * clamped : maxY * (1 - clamped)
      isRestoring = true
      clipView.scroll(to: origin)
      scrollView.reflectScrolledClipView(clipView)
      isRestoring = false
      parent.onPositionChange(clamped)
    }

    private static func normalizedPosition(in scrollView: NSScrollView) -> Double {
      guard let documentView = scrollView.documentView else { return 1 }
      let clipView = scrollView.contentView
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      guard maxY > 0 else { return 1 }
      let raw = documentView.isFlipped
        ? clipView.bounds.origin.y / maxY
        : 1 - (clipView.bounds.origin.y / maxY)
      return min(1, max(0, raw))
    }
  }
}

private struct OpenClawConfigurationSheet: View {
  @EnvironmentObject private var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  @State private var endpoint = ""
  @State private var agent = ""
  @State private var remoteCorpusPath = ""
  @State private var token = ""
  @State private var clearToken = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("OpenClaw Gateway")
          .font(.title3.weight(.semibold))
        Text("Configure the local or network gateway used by OpenClaw Chat.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Endpoint")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextField("http://127.0.0.1:18789/v1/chat/completions", text: $endpoint)
            .textFieldStyle(.roundedBorder)
            .frame(width: 430)
        }

        GridRow {
          Text("Agent")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextField("main", text: $agent)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }

        GridRow {
          Text("Remote Org2 Root")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextField("/path/openclaw/can/read", text: $remoteCorpusPath)
            .textFieldStyle(.roundedBorder)
            .frame(width: 430)
        }

        GridRow {
          Text("Token")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          SecureField(store.openClawHasStoredToken ? "Saved token unchanged" : "Bearer token or password", text: $token)
            .textFieldStyle(.roundedBorder)
            .frame(width: 430)
        }
      }

      Toggle("Clear saved token", isOn: $clearToken)
        .disabled(!store.openClawHasStoredToken)

      if !store.openClawStatusText.isEmpty {
        Text(store.openClawStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        Button("Save") {
          let saved = store.saveOpenClawConfiguration(
            endpoint: endpoint,
            agent: agent,
            remoteCorpusPath: remoteCorpusPath,
            token: token,
            clearToken: clearToken
          )
          if saved {
            dismiss()
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
    .frame(width: 620)
    .onAppear {
      endpoint = store.openClawEndpointText
      agent = store.openClawAgentID
      remoteCorpusPath = store.openClawRemoteCorpusPath
      token = ""
      clearToken = false
    }
  }
}

private struct OrgCryptConfigurationSheet: View {
  @EnvironmentObject private var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  @State private var encryptOnSave = true
  @State private var recipientsText = ""
  @State private var recipientFilesText = ""
  @State private var selectedManagedRecipientFilePaths = Set<String>()
  @State private var useDefaultGpgKey = true
  @State private var gpgProgram = "gpg"
  @State private var passphrase = ""
  @State private var clearPassphrase = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Encryption")
          .font(.title3.weight(.semibold))
        Text("Encrypt :crypt: subtrees with GPG.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Toggle("Encrypt plaintext :crypt: subtrees on explicit save", isOn: $encryptOnSave)
      Toggle("Use default GPG key as recipient", isOn: $useDefaultGpgKey)

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Recipients")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextEditor(text: $recipientsText)
            .font(.system(.body, design: .monospaced))
            .frame(width: 430, height: 72)
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(WorkspaceDesign.hairline)
            )
        }

        GridRow {
          Text("Agent Keys")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(store.orgCryptPublicKeysDirectoryURL?.path ?? "Choose a corpus to use public-keys")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 0)
              Button {
                if let imported = store.chooseOrgCryptAgentPublicKey() {
                  selectedManagedRecipientFilePaths.insert(imported.path)
                }
              } label: {
                Label("Add Agent Public Key", systemImage: "plus")
              }
              .disabled(store.corpusRoot == nil)
            }

            if store.orgCryptManagedRecipientFiles.isEmpty {
              Text("No public keys in public-keys")
                .font(.callout)
                .foregroundStyle(.tertiary)
            } else {
              ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                  ForEach(store.orgCryptManagedRecipientFiles) { file in
                    Toggle(isOn: managedRecipientFileBinding(file.path)) {
                      VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                          .font(.callout)
                        Text(file.relativePath)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                    }
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(maxHeight: 140)
            }
          }
          .frame(width: 430, alignment: .leading)
        }

        GridRow {
          Text("Other Files")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextEditor(text: $recipientFilesText)
            .font(.system(.body, design: .monospaced))
            .frame(width: 430, height: 58)
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(WorkspaceDesign.hairline)
            )
        }

        GridRow {
          Text("GPG")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextField("gpg", text: $gpgProgram)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }

        GridRow {
          Text("Passphrase")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          SecureField(store.orgCryptHasStoredPassphrase ? "Saved passphrase unchanged" : "Optional symmetric passphrase", text: $passphrase)
            .textFieldStyle(.roundedBorder)
            .frame(width: 430)
        }
      }

      Toggle("Clear saved passphrase", isOn: $clearPassphrase)
        .disabled(!store.orgCryptHasStoredPassphrase)

      if !store.orgCryptStatusText.isEmpty {
        Text(store.orgCryptStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        Button("Save") {
          let combinedRecipientFilesText = store.combinedOrgCryptRecipientFilesText(
            manualText: recipientFilesText,
            selectedManagedPaths: selectedManagedRecipientFilePaths
          )
          let saved = store.saveOrgCryptConfiguration(
            encryptOnSave: encryptOnSave,
            recipientsText: recipientsText,
            recipientFilesText: combinedRecipientFilesText,
            useDefaultGpgKey: useDefaultGpgKey,
            gpgProgram: gpgProgram,
            passphrase: passphrase,
            clearPassphrase: clearPassphrase
          )
          if saved {
            dismiss()
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
    .frame(width: 620)
    .onAppear {
      store.refreshOrgCryptManagedRecipientFiles()
      encryptOnSave = store.orgCryptEncryptOnSave
      recipientsText = store.orgCryptRecipientsText
      selectedManagedRecipientFilePaths = store.selectedManagedOrgCryptRecipientFilePaths(in: store.orgCryptRecipientFilesText)
      recipientFilesText = store.manualOrgCryptRecipientFilesText(from: store.orgCryptRecipientFilesText)
      useDefaultGpgKey = store.orgCryptUseDefaultGpgKey
      gpgProgram = store.orgCryptGpgProgram
      passphrase = ""
      clearPassphrase = false
    }
  }

  private func managedRecipientFileBinding(_ path: String) -> Binding<Bool> {
    Binding {
      selectedManagedRecipientFilePaths.contains(path)
    } set: { isSelected in
      if isSelected {
        selectedManagedRecipientFilePaths.insert(path)
      } else {
        selectedManagedRecipientFilePaths.remove(path)
      }
    }
  }
}

private struct EmptyChatView: View {
  let statusText: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "sparkles")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(statusText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }
}

private struct OpenClawThreadsView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Agent Space", subtitle: "\(store.openClawThreads.count) local item\(store.openClawThreads.count == 1 ? "" : "s")") {
        if store.isLoadingOpenClawThreads {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          Task { await store.refreshOpenClawThreads() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.corpusRoot == nil || store.isLoadingOpenClawThreads)
      }

      if store.openClawThreads.isEmpty {
        if store.isLoadingOpenClawThreads {
          Spacer()
          ProgressView()
          Spacer()
        } else {
          EmptyStateView(title: "No Agent Items", detail: store.statusText, action: "Refresh") {
            Task { await store.refreshOpenClawThreads() }
          }
        }
      } else {
        List(selection: $store.selectedOpenClawThreadID) {
          ForEach(store.openClawDisplaySections) { section in
            Section(section.label) {
              ForEach(section.threads) { thread in
                OpenClawThreadRow(thread: thread)
                  .tag(thread.id)
                  .contentShape(Rectangle())
                  .onTapGesture {
                    store.selectOpenClawThread(thread)
                  }
              }
            }
          }
        }
        .listStyle(.inset)
        .onChange(of: store.selectedOpenClawThreadID) {
          guard let id = store.selectedOpenClawThreadID,
                let thread = store.openClawThreads.first(where: { $0.id == id })
          else {
            return
          }
          store.select(.openClaw(thread))
        }
      }
    }
    .onAppear {
      if store.openClawThreads.isEmpty {
        Task { await store.refreshOpenClawThreads() }
      }
    }
  }
}

private struct OpenClawThreadRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let thread: OpenClawThread

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: thread.idValue == nil ? "doc.text" : "link")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(Org2Display.cleanInline(thread.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          if thread.idValue != nil {
            Image(systemName: "link")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        HStack(spacing: 8) {
          Text(thread.zone)
          if let modifiedAt = thread.modifiedAt {
            Text(Self.relativeDate(modifiedAt))
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        Text(store.relativePath(thread.file) + ":\(thread.lineForEditor)")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }

  private static func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

private struct DetailView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let location = store.selectedLocation {
        DetailHeader(location: location)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            EntryBodyView(location: location)
            Divider()
            BacklinksView()
          }
          .background(DetailScrollCommandBridge(request: store.detailScrollRequest))
        }
      } else {
        EmptyStateView(title: "No Selection", detail: store.statusText, action: "Open Corpus") {
          store.chooseCorpus()
        }
      }
    }
  }
}

private struct DetailScrollCommandBridge: NSViewRepresentable {
  let request: DetailScrollRequest?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let request, context.coordinator.lastRequestID != request.id else { return }
    context.coordinator.lastRequestID = request.id

    DispatchQueue.main.async {
      guard let scrollView = view.enclosingScrollView,
            let documentView = scrollView.documentView
      else { return }

      let clipView = scrollView.contentView
      let visibleHeight = clipView.bounds.height
      guard visibleHeight > 0 else { return }

      let distance = max(120, visibleHeight * 0.8)
      let direction: CGFloat = request.direction == .down ? 1 : -1
      let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
      let maxY = max(0, documentView.bounds.height - visibleHeight)
      var origin = clipView.bounds.origin
      origin.y = min(max(0, origin.y + distance * direction * flippedMultiplier), maxY)
      clipView.scroll(to: origin)
      scrollView.reflectScrolledClipView(clipView)
    }
  }

  final class Coordinator {
    var lastRequestID: Int?
  }
}

private struct DetailHeader: View {
  @EnvironmentObject private var store: WorkspaceStore
  let location: WorkspaceLocation

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        WorkspaceIconBadge(systemImage: locationIcon, tint: .accentColor, fill: Color.accentColor.opacity(0.12))
        VStack(alignment: .leading, spacing: 6) {
          Text(location.title)
            .font(.title3.weight(.semibold))
            .lineLimit(nil)
          if !location.subtitle.isEmpty {
            Text(location.subtitle)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(nil)
          }
          Text(store.relativePath(location.file) + ":\(location.lineForEditor)")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
      }

      HStack(spacing: 8) {
        Button {
          store.navigateBackInDetail()
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .disabled(!store.canNavigateBackInDetail)

        Button {
          store.open(location)
        } label: {
          Label("Open Source", systemImage: "arrow.up.forward.square")
        }

        Button {
          store.revealSelectedLocation()
        } label: {
          Label("Reveal", systemImage: "folder")
        }

        Button {
          store.askOpenClawAboutCurrentSelection()
        } label: {
          Label("Ask AI", systemImage: "sparkles")
        }
        .disabled(!store.canAskOpenClawAboutCurrentSelection || store.isLoadingEntrySource)
        .help("Ask OpenClaw about this page or entry")

        Picker("Scope", selection: $store.selectedEntrySourceMode) {
          ForEach(EntrySourceMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 150)
        .onChange(of: store.selectedEntrySourceMode) {
          Task { await store.reloadSelectedEntrySource() }
        }

        if store.hasActiveEdit {
          Button {
            Task { await store.saveActiveEdit() }
          } label: {
            Label("Save", systemImage: "checkmark")
          }
          .disabled(!store.canSaveActiveEdit)

          Button {
            store.cancelActiveEdit()
          } label: {
            Label("Cancel", systemImage: "xmark")
          }
        } else {
          Button {
            store.beginEditingCurrentScope()
          } label: {
            Label("Edit", systemImage: "square.and.pencil")
          }
          .disabled(store.selectedEntrySource?.isEditable != true || store.isLoadingEntrySource)
        }

        if case .agenda = location {
          Button {
            Task { await store.applyAgentHandoffShortcut() }
          } label: {
            Label("Agent", systemImage: "person.crop.circle.badge.checkmark")
          }

          Menu {
            Button("A") {
              Task { await store.applyPriorityShortcut("A") }
            }
            Button("B") {
              Task { await store.applyPriorityShortcut("B") }
            }
            Button("C") {
              Task { await store.applyPriorityShortcut("C") }
            }
            Divider()
            Button("Clear") {
              Task { await store.applyPriorityShortcut(nil) }
            }
          } label: {
            Label("Priority", systemImage: "flag")
          }

          Button {
            store.promptAndApplyPropertyShortcut()
          } label: {
            Label("Property", systemImage: "tag")
          }
        }

        if case .meeting = location {
          Button {
            store.askOpenClawAboutSelectedMeeting()
          } label: {
            Label("Ask", systemImage: "sparkles")
          }
        }
      }
    }
    .padding(WorkspaceDesign.contentInset)
    .background(WorkspaceDesign.barBackground)
  }

  private var locationIcon: String {
    switch location {
    case .agenda:
      return "calendar"
    case .search:
      return "magnifyingglass"
    case .backlink:
      return "link"
    case .openClaw:
      return "doc.text"
    case .meeting:
      return "waveform.and.mic"
    }
  }
}

private struct EntryBodyView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let location: WorkspaceLocation

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      DetailMetadataGrid(rows: metadataRows(location))

      if store.isLoadingEntrySource && store.selectedEntrySource == nil {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading source")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } else if let source = store.selectedEntrySource {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            WorkspaceIconBadge(systemImage: "doc.richtext")
            VStack(alignment: .leading, spacing: 2) {
              Text(store.selectedEntrySourceMode.title)
                .font(.headline)
              Text(store.relativePath(source.file) + ":\(source.displayRange)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
        }
        if store.isEditingEntry {
          OrgSyntaxTextEditor(
            text: $store.editableEntryText,
            monospaced: true,
            showsScrollers: true,
            textInset: NSSize(width: 12, height: 12),
            focusOnAppear: true
          )
          .frame(minHeight: 520)
          .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.secondary.opacity(0.16))
          )
        } else if store.isRenderingEntrySource && store.selectedRenderedBlocks.isEmpty {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Rendering preview")
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        } else {
          OrgRenderedEntryView(
            blocks: store.selectedRenderedBlocks,
            blocksRenderSignature: store.selectedRenderedBlocksRenderSignature,
            source: store.selectedEntrySource.map(OrgRenderedEntrySourceContext.init),
            corpusRoot: store.corpusRoot,
            selectedBlockID: store.selectedBlockID,
            selectedBlockIndex: store.selectedBlockID.flatMap { store.selectedRenderedBlockIndexes[$0] },
            editingBlockID: store.editingBlockID,
            foldedBlockIDs: store.foldedRenderedBlockIDs,
            sourceBlockRunsRenderSignature: store.sourceBlockRunsRenderSignature,
            sourceBlockRuns: store.sourceBlockRuns
          )
          .equatable()
        }
      } else {
        fallbackBody(location)
      }
    }
    .padding(16)
  }

  @ViewBuilder
  private func fallbackBody(_ location: WorkspaceLocation) -> some View {
    switch location {
    case .agenda(let item):
      Text(Org2Display.cleanBlock(item.body ?? ""))
        .font(.body)
        .textSelection(.enabled)
    case .search(let result):
      Text(Org2Display.cleanInline(result.snippet))
        .font(.body)
        .textSelection(.enabled)
    case .backlink(let backlink):
      Text(Org2Display.cleanInline(backlink.context))
        .font(.body)
        .textSelection(.enabled)
    case .openClaw:
      Text("Source unavailable")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .meeting:
      Text("Meeting source unavailable")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func metadataRows(_ location: WorkspaceLocation) -> [(String, String)] {
    switch location {
    case .agenda(let item):
      let planning = [item.kind, item.time].compactMap { $0 }.joined(separator: " ")
      let rows: [(String, String)] = [
        ("TODO", item.todo ?? ""),
        ("Planning", planning),
        ("Priority", item.priority.map { "[#\($0)]" } ?? ""),
        ("Effort", item.effort ?? ""),
        ("Tags", item.tags.joined(separator: ", ")),
        ("ID", item.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    case .search(let result):
      let rows: [(String, String)] = [
        ("TODO", result.todo ?? ""),
        ("Heading", result.heading.map(Org2Display.cleanInline) ?? ""),
        ("Date", result.date ?? ""),
        ("Tags", result.tags.joined(separator: ", ")),
        ("ID", result.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    case .backlink(let backlink):
      return [
        ("Source", Org2Display.cleanInline(backlink.srcTitle)),
        ("Line", "\(backlink.lineForEditor)")
      ]
    case .openClaw(let thread):
      let rows: [(String, String)] = [
        ("Zone", thread.zone),
        ("Modified", thread.modifiedAt.map(Self.dateLabel) ?? ""),
        ("ID", thread.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    case .meeting(let meeting):
      let rows: [(String, String)] = [
        ("Recorded", meeting.recordedAt ?? ""),
        ("Audio", meeting.audioArtifact ?? ""),
        ("System Audio", meeting.systemAudioArtifact ?? ""),
        ("Transcript", meeting.transcriptArtifact ?? ""),
        ("Transcription", meeting.transcriptionStatus ?? ""),
        ("ID", meeting.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    }
  }

  private func nonEmptyRows(_ rows: [(String, String)]) -> [(String, String)] {
    rows.filter { !$0.1.isEmpty }
  }

  private static func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

private struct DetailMetadataGrid: View {
  let rows: [(String, String)]

  var body: some View {
    if !rows.isEmpty {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
        ForEach(rows, id: \.0) { row in
          GridRow {
            Text(row.0)
              .font(.caption2.weight(.medium))
              .foregroundStyle(.tertiary)
            Text(row.1)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
      .padding(.vertical, 2)
    }
  }
}

private struct BacklinksView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Backlinks", systemImage: "link")
          .font(.headline)
        Spacer()
        if store.isLoadingBacklinks {
          ProgressView()
            .controlSize(.small)
        } else if let count = store.backlinks?.backlinks.count {
          Text("\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.vertical, 12)

      if let backlinks = store.backlinks {
        if backlinks.backlinks.isEmpty {
          Text("No backlinks")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, WorkspaceDesign.contentInset)
        } else {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(backlinks.backlinks) { backlink in
              BacklinkRow(backlink: backlink)
                .contentShape(Rectangle())
                .onTapGesture {
                  store.select(.backlink(backlink))
                }
              Divider()
                .padding(.leading, 16)
            }
          }
          .padding(.bottom, 8)
        }
      } else {
        Text("No ID on selection")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, WorkspaceDesign.contentInset)
      }
    }
  }
}

private struct BacklinkRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let backlink: BacklinkItem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "link")
      VStack(alignment: .leading, spacing: 5) {
        Text(Org2Display.cleanInline(backlink.srcTitle))
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(Org2Display.cleanInline(backlink.context))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(store.relativePath(backlink.file) + ":\(backlink.lineForEditor)")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct HeaderBar<Trailing: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title2.weight(.semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      trailing
        .controlSize(.small)
        .buttonStyle(WorkspaceActionButtonStyle())
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .background(WorkspaceDesign.barBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

struct StatusPill: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .bold, design: .rounded))
      .foregroundStyle(statusForeground)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .frame(minWidth: 38)
      .background(statusColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(statusForeground.opacity(0.08))
      )
  }

  private var statusColor: Color {
    switch text.uppercased() {
    case "TODO": .blue.opacity(0.15)
    case "PROG", "IN_PROGRESS": .indigo.opacity(0.16)
    case "WAIT", "HOLD", "PAUSED": .orange.opacity(0.16)
    case "DONE": .green.opacity(0.16)
    case "CANCELLED", "CANCELED": .red.opacity(0.15)
    default: WorkspaceDesign.subtleFill
    }
  }

  private var statusForeground: Color {
    switch text.uppercased() {
    case "TODO": .blue
    case "PROG", "IN_PROGRESS": .indigo
    case "WAIT", "HOLD", "PAUSED": .orange
    case "DONE": .green
    case "CANCELLED", "CANCELED": .red
    default: .secondary
    }
  }
}

private struct EmptyStateView: View {
  let title: String
  let detail: String
  let action: String
  let perform: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      WorkspaceIconBadge(systemImage: emptyStateIcon, tint: .secondary, fill: WorkspaceDesign.subtleFill)
        .scaleEffect(1.25)
      Text(title)
        .font(.headline)
      if !detail.isEmpty {
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .padding(.horizontal, 24)
      }
      Button(action) {
        perform()
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateIcon: String {
    if title.localizedCaseInsensitiveContains("agenda") { return "calendar" }
    if title.localizedCaseInsensitiveContains("meeting") { return "waveform.and.mic" }
    if title.localizedCaseInsensitiveContains("result") { return "magnifyingglass" }
    if title.localizedCaseInsensitiveContains("agent") { return "tray" }
    if title.localizedCaseInsensitiveContains("selection") { return "cursorarrow" }
    return "doc.text"
  }
}

private struct KeyboardEventMonitor: ViewModifier {
  let handler: (NSEvent) -> Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          if Self.isTextInputActive {
            return event
          }
          return handler(event) ? nil : event
        }
      }
      .onDisappear {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
        monitor = nil
      }
  }

  private static var isTextInputActive: Bool {
    guard let responder = NSApplication.shared.keyWindow?.firstResponder else {
      return false
    }
    return responder is NSTextView || responder is NSTextField
  }
}

private extension View {
  func keyboardEventMonitor(_ handler: @escaping (NSEvent) -> Bool) -> some View {
    modifier(KeyboardEventMonitor(handler: handler))
  }
}
