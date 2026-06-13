import AppKit
import AVKit
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
      case .openClaw:
        OpenClawChatView()
      case .agentSpace:
        OpenClawThreadsView()
      }
    } detail: {
      DetailView()
    }
    .toolbar {
      ToolbarItemGroup {
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
    .sheet(isPresented: $store.isQuickOpenPresented) {
      QuickOpenView()
        .environmentObject(store)
    }
  }
}

private struct SidebarView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    List(selection: $store.selectedSurface) {
      Section("Workspace") {
        ForEach(WorkspaceSurface.allCases) { surface in
          Label(surface.title, systemImage: surface.systemImage)
            .tag(surface)
        }
      }

      Section("Corpus") {
        if let root = store.corpusRoot {
          VStack(alignment: .leading, spacing: 3) {
            Text(root.path)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(4)
              .textSelection(.enabled)
            Text("\(store.corpusFiles.count) file\(store.corpusFiles.count == 1 ? "" : "s")")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        } else {
          Button("Open Corpus...") {
            store.chooseCorpus()
          }
        }
      }

      Section("Daily") {
        ForEach(DailyNoteTarget.allCases) { target in
          Button {
            store.openDailyNote(target)
          } label: {
            Label(target.title, systemImage: target == .today ? "sun.max" : "calendar")
          }
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
      .padding(.horizontal, 16)
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
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "doc.text")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(file.name)
          .font(.body)
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
    .padding(.vertical, 4)
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
            openFirstMatch()
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

      List(store.quickOpenFiles) { file in
        Button {
          open(file)
        } label: {
          CorpusFileRow(file: file)
        }
        .buttonStyle(.plain)
      }
      .listStyle(.plain)
      .frame(minHeight: 320)
    }
    .padding(16)
    .frame(width: 720, height: 460)
    .onAppear {
      queryFocused = true
    }
  }

  private func openFirstMatch() {
    guard let file = store.quickOpenFiles.first else { return }
    open(file)
  }

  private func open(_ file: CorpusFile) {
    store.selectCorpusFile(file)
    store.isQuickOpenPresented = false
    dismiss()
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
        .padding(.horizontal, 16)
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
    .padding(.horizontal, 16)
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
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(width: 94, alignment: .leading)
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
            .font(.body)
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
      }
    }
    .padding(.vertical, 3)
  }
}

private struct SearchView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Search", subtitle: "Cited corpus lookup") {
        if store.isSearching {
          ProgressView()
            .controlSize(.small)
        }
      }

      HStack(spacing: 8) {
        TextField("Search corpus", text: $store.searchQuery)
          .textFieldStyle(.roundedBorder)
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
      .padding(.horizontal, 16)
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
  }
}

private struct SearchRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let result: SearchResult

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        if let todo = result.todo {
          StatusPill(text: todo)
        }
        Text(Org2Display.cleanInline(result.title))
          .font(.body)
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
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
  }
}

private struct OpenClawChatView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @FocusState private var inputFocused: Bool
  @State private var isShowingConfiguration = false

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "OpenClaw Chat", subtitle: store.openClawStatusText) {
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

      HStack(spacing: 8) {
        Text("Agent")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        TextField("main", text: $store.openClawAgentID)
          .textFieldStyle(.roundedBorder)
          .frame(width: 180)
        Text("Org2")
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
      .padding(.horizontal, 16)
      .padding(.bottom, 10)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            if store.openClawMessages.isEmpty {
              EmptyChatView(statusText: store.openClawStatusText)
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
              ForEach(store.openClawMessages) { message in
                ChatBubbleView(message: message)
                  .id(message.id)
              }
              if store.isSendingOpenClawMessage {
                OpenClawTypingIndicatorView(startedAt: store.openClawRequestStartedAt)
                  .id("openclaw-typing")
              }
            }
          }
          .padding(16)
        }
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

      Divider()

      VStack(alignment: .trailing, spacing: 8) {
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.22))
            )

          if store.openClawDraft.isEmpty {
            Text("Message OpenClaw")
              .font(.body)
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 8)
              .padding(.vertical, 9)
          }

          TextEditor(text: $store.openClawDraft)
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused($inputFocused)
            .padding(4)
            .frame(minHeight: 112, maxHeight: 180)
        }

        Button {
          Task { await store.sendOpenClawMessage() }
        } label: {
          Label("Send", systemImage: "paperplane.fill")
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(store.openClawDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSendingOpenClawMessage)
      }
      .padding(16)
    }
    .onAppear {
      inputFocused = true
    }
    .sheet(isPresented: $isShowingConfiguration) {
      OpenClawConfigurationSheet()
        .environmentObject(store)
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
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(Org2Display.cleanInline(thread.title))
          .font(.body)
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
    .padding(.vertical, 4)
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
        if store.isEditingEntry {
          EntryEditorView()
          Divider()
          BacklinksView()
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              EntryBodyView(location: location)
              Divider()
              BacklinksView()
            }
          }
        }
      } else {
        EmptyStateView(title: "No Selection", detail: store.statusText, action: "Open Corpus") {
          store.chooseCorpus()
        }
      }
    }
  }
}

private struct EntryEditorView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let source = store.selectedEntrySource {
        Text(store.relativePath(source.file) + ":\(source.displayRange)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      OrgSyntaxTextEditor(text: $store.editableEntryText, monospaced: true)
        .frame(minHeight: 360)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.secondary.opacity(0.25))
        )

      HStack {
        Button {
          Task { await store.saveEditedEntry() }
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingEntry)

        Button {
          store.cancelEditingSelectedEntry()
        } label: {
          Label("Cancel", systemImage: "xmark")
        }
        .keyboardShortcut(.cancelAction)

        if store.isSavingEntry {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .padding(16)
  }
}

private struct DetailHeader: View {
  @EnvironmentObject private var store: WorkspaceStore
  let location: WorkspaceLocation

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
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

      HStack {
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

        if store.isEditingEntry {
          Button {
            Task { await store.saveEditedEntry() }
          } label: {
            Label("Save", systemImage: "checkmark")
          }
          .disabled(store.isSavingEntry)

          Button {
            store.cancelEditingSelectedEntry()
          } label: {
            Label("Cancel", systemImage: "xmark")
          }
        } else {
          Button {
            store.beginEditingSelectedEntry()
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
      }
    }
    .padding(16)
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
          Text(store.selectedEntrySourceMode.title)
            .font(.headline)
          Text(store.relativePath(source.file) + ":\(source.displayRange)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        if store.isRenderingEntrySource && store.selectedRenderedBlocks.isEmpty {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Rendering preview")
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        } else {
          if store.isLoadingEntrySource || store.isRenderingEntrySource {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text(store.isLoadingEntrySource ? "Updating source" : "Updating preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          OrgRenderedEntryView(blocks: store.selectedRenderedBlocks)
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
      return rows.filter { !$0.1.isEmpty }
    case .search(let result):
      let rows: [(String, String)] = [
        ("TODO", result.todo ?? ""),
        ("Heading", result.heading.map(Org2Display.cleanInline) ?? ""),
        ("Date", result.date ?? ""),
        ("Tags", result.tags.joined(separator: ", ")),
        ("ID", result.idValue.map(Org2Display.shortID) ?? "")
      ]
      return rows.filter { !$0.1.isEmpty }
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
      return rows.filter { !$0.1.isEmpty }
    }
  }

  private static func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

private struct OrgRenderedEntryView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let blocks: [OrgEditableBlock]

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 8) {
      ForEach(blocks) { block in
        if store.editingBlockID == block.id {
          InlineBlockEditorView(block: block)
        } else {
          EditableRenderedBlockView(block: block) {
            RenderedBlockView(block: block.rendered, rawText: block.rawText, editableBlock: block)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct EditableRenderedBlockView<Content: View>: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @ViewBuilder let content: Content
  @State private var isHovered = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      content
        .padding(.trailing, store.selectedEntrySource?.isEditable == true ? 92 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)

      if store.selectedEntrySource?.isEditable == true {
        HStack(spacing: 3) {
          Menu {
            ForEach(OrgInsertBlockKind.allCases) { kind in
              Button {
                Task { await store.insertBlock(after: block, kind: kind) }
              } label: {
                Label(kind.title, systemImage: kind.systemImage)
              }
            }
          } label: {
            Image(systemName: "plus")
              .font(.caption.weight(.semibold))
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .controlSize(.small)
          .help("Add block after line \(block.displayRange)")

          if block.isEditable {
            Button {
              store.beginEditingBlock(block)
            } label: {
              Image(systemName: "pencil")
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Edit line \(block.displayRange)")

            Menu {
              Button {
                Task { await store.moveBlock(block, direction: .up) }
              } label: {
                Label("Move Up", systemImage: "arrow.up")
              }
              .disabled(!store.canMoveBlock(block, direction: .up))

              Button {
                Task { await store.moveBlock(block, direction: .down) }
              } label: {
                Label("Move Down", systemImage: "arrow.down")
              }
              .disabled(!store.canMoveBlock(block, direction: .down))

              Divider()

              Button {
                Task { await store.duplicateBlock(block) }
              } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
              }

              Button(role: .destructive) {
                Task { await store.deleteBlock(block) }
              } label: {
                Label("Delete", systemImage: "trash")
              }
            } label: {
              Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .help("Block actions")
          }
        }
        .opacity(isHovered || isSelected ? 1 : 0)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(isSelected ? Color.accentColor.opacity(0.32) : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(count: 1) {
      store.selectBlock(block)
    }
    .onTapGesture(count: 2) {
      if block.isEditable {
        store.beginEditingBlock(block)
      }
    }
  }

  private var isSelected: Bool {
    store.selectedBlockID == block.id
  }

  private var backgroundColor: Color {
    guard store.selectedEntrySource?.isEditable == true else { return .clear }
    if isSelected {
      return Color.accentColor.opacity(0.075)
    }
    if isHovered {
      return Color.secondary.opacity(0.08)
    }
    return .clear
  }
}

private struct InlineBlockEditorView: View {
  let block: OrgEditableBlock

  var body: some View {
    switch block.rendered {
    case .heading(let heading):
      HeadingBlockEditor(block: block, heading: heading)
    case .planning(let planning):
      PlanningBlockEditor(block: block, planning: planning)
    case .quote:
      QuoteBlockEditor(block: block)
    case .listItem(let indent, let marker, let checkbox, let text):
      ListItemBlockEditor(block: block, indent: indent, marker: marker, checkbox: checkbox, text: text)
    case .keyword(let key, let value):
      KeywordBlockEditor(block: block, key: key, value: value)
    case .paragraph(let text):
      ParagraphBlockEditor(block: block, text: text)
    case .properties(let rows):
      PropertyDrawerBlockEditor(block: block, rows: rows)
    case .source(let language, let lines):
      SourceBlockEditor(block: block, language: language, lines: lines)
    case .table(let table):
      TableBlockEditor(block: block, table: table)
    case .blank:
      EmptyView()
    }
  }
}

private struct HeadingBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  private let level: Int
  @State private var todo: String
  @State private var priority: String
  @State private var title: String
  @State private var tags: String
  @FocusState private var titleFocused: Bool

  init(block: OrgEditableBlock, heading: OrgHeadingBlock) {
    self.block = block
    let raw = Self.rawHeadingParts(from: block.rawText, fallback: heading)
    self.level = raw.level
    _todo = State(initialValue: raw.todo)
    _priority = State(initialValue: raw.priority)
    _title = State(initialValue: raw.title)
    _tags = State(initialValue: raw.tags)
  }

  var body: some View {
    BlockEditorContainer(
      block: block,
      title: "Heading",
      previewText: rawHeading,
      onSave: { store.editableBlockText = rawHeading }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Picker("Status", selection: $todo) {
            Text("None").tag("")
            ForEach(Self.todoKeywords, id: \.self) { keyword in
              Text(keyword).tag(keyword)
            }
          }
          .frame(width: 150)

          Picker("Priority", selection: $priority) {
            Text("None").tag("")
            ForEach(["A", "B", "C"], id: \.self) { value in
              Text(value).tag(value)
            }
          }
          .frame(width: 120)

          TextField("Title", text: $title)
            .textFieldStyle(.roundedBorder)
            .focused($titleFocused)
            .onSubmit {
              saveHeading()
            }
        }

        HStack(spacing: 8) {
          Text("Level \(level)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          TextField("Tags", text: $tags)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              saveHeading()
            }
        }
      }
    }
    .onAppear {
      titleFocused = true
    }
  }

  private var rawHeading: String {
    var parts = [String(repeating: "*", count: max(1, level))]
    let normalizedTodo = todo.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if !normalizedTodo.isEmpty {
      parts.append(normalizedTodo)
    }
    let normalizedPriority = priority.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if !normalizedPriority.isEmpty {
      parts.append("[#\(normalizedPriority)]")
    }
    parts.append(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title.trimmingCharacters(in: .whitespacesAndNewlines))
    var line = parts.joined(separator: " ")
    let normalizedTags = tags
      .split { $0.isWhitespace || $0 == "," }
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#:")) }
      .filter { !$0.isEmpty }
    if !normalizedTags.isEmpty {
      line += " :\(normalizedTags.joined(separator: ":")):"
    }
    return line
  }

  private func saveHeading() {
    store.editableBlockText = rawHeading
    Task { await store.saveEditedBlock(block) }
  }

  private static let todoKeywords = ["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED"]

  private static func rawHeadingParts(
    from rawText: String,
    fallback: OrgHeadingBlock
  ) -> (level: Int, todo: String, priority: String, title: String, tags: String) {
    let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else {
      return (
        fallback.level,
        fallback.todo ?? "",
        fallback.priority ?? "",
        fallback.title,
        fallback.tags.joined(separator: " ")
      )
    }

    var rest = String(line.dropFirst(stars.count)).trimmingCharacters(in: .whitespaces)
    var tags = fallback.tags.joined(separator: " ")
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      tags = String(rest[tagRange])
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    var todo = ""
    var priority = ""
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if let first = tokens.first, todoKeywords.contains(first.uppercased()) {
      todo = first.uppercased()
      tokens.removeFirst()
    }
    if let first = tokens.first,
       first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      priority = first
        .replacingOccurrences(of: "[#", with: "")
        .replacingOccurrences(of: "]", with: "")
        .uppercased()
      tokens.removeFirst()
    }

    return (
      stars.count,
      todo,
      priority,
      tokens.joined(separator: " "),
      tags
    )
  }
}

private struct PlanningBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var kind: String
  @State private var value: String
  @FocusState private var valueFocused: Bool

  init(block: OrgEditableBlock, planning: OrgPlanningBlock) {
    self.block = block
    _kind = State(initialValue: planning.kind)
    _value = State(initialValue: planning.value)
  }

  var body: some View {
    BlockEditorContainer(
      block: block,
      title: "Planning",
      previewText: rawPlanning,
      onSave: { store.editableBlockText = rawPlanning }
    ) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Picker("Kind", selection: $kind) {
          ForEach(["SCHEDULED", "DEADLINE", "CLOSED"], id: \.self) { value in
            Text(value.capitalized).tag(value)
          }
        }
        .frame(width: 160)

        TextField("Timestamp", text: $value)
          .textFieldStyle(.roundedBorder)
          .focused($valueFocused)
          .onSubmit {
            savePlanning()
          }
      }
    }
    .onAppear {
      valueFocused = true
    }
  }

  private var rawPlanning: String {
    "\(kind): \(value.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private func savePlanning() {
    store.editableBlockText = rawPlanning
    Task { await store.saveEditedBlock(block) }
  }
}

private struct ListItemBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  let leadingWhitespace: String
  @State private var marker: String
  @State private var checkbox: OrgListCheckbox?
  @State private var text: String
  @FocusState private var textFocused: Bool

  init(block: OrgEditableBlock, indent: Int, marker: String, checkbox: OrgListCheckbox?, text: String) {
    self.block = block
    let raw = Self.rawListItemParts(
      from: block.rawText,
      fallbackIndent: indent,
      fallbackMarker: marker,
      fallbackCheckbox: checkbox,
      fallbackText: text
    )
    self.leadingWhitespace = raw.leadingWhitespace
    _marker = State(initialValue: raw.marker)
    _checkbox = State(initialValue: raw.checkbox)
    _text = State(initialValue: raw.text)
  }

  var body: some View {
    BlockEditorContainer(
      block: block,
      title: "List Item",
      previewText: rawListItem,
      onSave: { store.editableBlockText = rawListItem }
    ) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        TextField("Marker", text: $marker)
          .textFieldStyle(.roundedBorder)
          .frame(width: 76)

        Toggle("Task", isOn: checkboxEnabledBinding)
          .toggleStyle(.checkbox)
          .frame(width: 72, alignment: .leading)

        if checkbox != nil {
          Toggle("Done", isOn: checkboxCheckedBinding)
            .toggleStyle(.checkbox)
            .frame(width: 76, alignment: .leading)
        }

        TextField("Text", text: $text)
          .textFieldStyle(.roundedBorder)
          .focused($textFocused)
          .onSubmit {
            continueListItem()
          }
      }
    }
    .onAppear {
      textFocused = true
    }
  }

  private var rawListItem: String {
    let markerValue = marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "-"
      : marker.trimmingCharacters(in: .whitespacesAndNewlines)
    let checkboxPrefix = checkbox.map { "\($0.rawMarker) " } ?? ""
    return "\(leadingWhitespace)\(markerValue) \(checkboxPrefix)\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private var checkboxEnabledBinding: Binding<Bool> {
    Binding(
      get: { checkbox != nil },
      set: { checkbox = $0 ? .unchecked : nil }
    )
  }

  private var checkboxCheckedBinding: Binding<Bool> {
    Binding(
      get: { checkbox == .checked },
      set: { checkbox = $0 ? .checked : .unchecked }
    )
  }

  private func saveListItem() {
    store.editableBlockText = rawListItem
    Task { await store.saveEditedBlock(block) }
  }

  private func continueListItem() {
    store.editableBlockText = rawListItem
    Task { await store.splitEditingBlock(block, atUTF16Offset: (rawListItem as NSString).length) }
  }

  private static func rawListItemParts(
    from rawText: String,
    fallbackIndent: Int,
    fallbackMarker: String,
    fallbackCheckbox: OrgListCheckbox?,
    fallbackText: String
  ) -> (leadingWhitespace: String, marker: String, checkbox: OrgListCheckbox?, text: String) {
    let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let leadingWhitespace = String(line.prefix { $0 == " " || $0 == "\t" })
    let rest = String(line.dropFirst(leadingWhitespace.count))
    guard let separator = rest.firstIndex(where: { $0.isWhitespace }) else {
      return (String(repeating: " ", count: max(0, fallbackIndent) * 2), fallbackMarker, fallbackCheckbox, fallbackText)
    }
    let marker = String(rest[..<separator])
    let textStart = rest[separator...].firstIndex { !$0.isWhitespace } ?? rest.endIndex
    let parsed = Self.parseCheckbox(String(rest[textStart...]))
    return (leadingWhitespace, marker, parsed.checkbox ?? fallbackCheckbox, parsed.text)
  }

  private static func parseCheckbox(_ text: String) -> (checkbox: OrgListCheckbox?, text: String) {
    if text.hasPrefix("[ ] ") {
      return (.unchecked, String(text.dropFirst(4)))
    }
    if text.hasPrefix("[X] ") || text.hasPrefix("[x] ") {
      return (.checked, String(text.dropFirst(4)))
    }
    if text.hasPrefix("[-] ") {
      return (.mixed, String(text.dropFirst(4)))
    }
    return (nil, text)
  }
}

private struct KeywordBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var key: String
  @State private var value: String
  @FocusState private var valueFocused: Bool

  init(block: OrgEditableBlock, key: String, value: String) {
    self.block = block
    let raw = Self.rawKeywordParts(from: block.rawText, fallbackKey: key, fallbackValue: value)
    _key = State(initialValue: raw.key)
    _value = State(initialValue: raw.value)
  }

  var body: some View {
    BlockEditorContainer(
      block: block,
      title: "Keyword",
      previewText: rawKeyword,
      onSave: { store.editableBlockText = rawKeyword }
    ) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        TextField("Key", text: $key)
          .textFieldStyle(.roundedBorder)
          .frame(width: 140)
        TextField("Value", text: $value)
          .textFieldStyle(.roundedBorder)
          .focused($valueFocused)
          .onSubmit {
            saveKeyword()
          }
      }
    }
    .onAppear {
      valueFocused = true
    }
  }

  private var rawKeyword: String {
    let normalizedKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "#+: \n\t")).uppercased()
    return "#+\(normalizedKey.isEmpty ? "KEYWORD" : normalizedKey): \(value.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private func saveKeyword() {
    store.editableBlockText = rawKeyword
    Task { await store.saveEditedBlock(block) }
  }

  private static func rawKeywordParts(
    from rawText: String,
    fallbackKey: String,
    fallbackValue: String
  ) -> (key: String, value: String) {
    let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#+"),
          let separator = trimmed.firstIndex(of: ":")
    else {
      return (fallbackKey, fallbackValue)
    }
    let keyStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
    let key = String(trimmed[keyStart..<separator])
    let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    return (key, value)
  }
}

private struct PropertyDrawerBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var drawer: OrgEditablePropertyDrawer
  @FocusState private var focusedProperty: PropertyFocus?

  private enum PropertyFocus: Hashable {
    case key(Int)
    case value(Int)
  }

  init(block: OrgEditableBlock, rows: [OrgPropertyRow]) {
    self.block = block
    _drawer = State(initialValue: OrgEditablePropertyDrawer(rawText: block.rawText, fallbackRows: rows))
  }

  var body: some View {
    BlockEditorContainer(
      block: block,
      title: "Properties",
      previewText: drawer.formattedRawText,
      onSave: { store.editableBlockText = drawer.formattedRawText }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if drawer.rows.isEmpty {
          HStack(spacing: 8) {
            Image(systemName: "tag")
              .foregroundStyle(.secondary)
            Text("No properties")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(drawer.rows.enumerated()), id: \.offset) { index, row in
              propertyRow(index: index, row: row)
            }
          }
        }

        Button {
          drawer.addProperty()
          focusedProperty = .key(max(0, drawer.rows.count - 1))
        } label: {
          Label("Add Property", systemImage: "plus")
        }
        .controlSize(.small)
      }
    }
    .onAppear {
      if focusedProperty == nil, !drawer.rows.isEmpty {
        focusedProperty = .value(0)
      }
    }
  }

  private func propertyRow(index: Int, row: OrgEditablePropertyRow) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      TextField("Key", text: propertyKeyBinding(index))
        .textFieldStyle(.roundedBorder)
        .font(.callout.monospaced())
        .frame(width: 150)
        .focused($focusedProperty, equals: .key(index))
        .onSubmit {
          focusedProperty = .value(index)
        }

      TextField("Value", text: propertyValueBinding(index))
        .textFieldStyle(.roundedBorder)
        .font(.callout)
        .focused($focusedProperty, equals: .value(index))
        .onSubmit {
          saveProperties()
        }

      Button {
        drawer.removeProperty(at: index)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Delete \(row.normalizedKey.isEmpty ? "property" : row.normalizedKey)")
    }
  }

  private func propertyKeyBinding(_ index: Int) -> Binding<String> {
    Binding(
      get: {
        guard drawer.rows.indices.contains(index) else { return "" }
        return drawer.rows[index].key
      },
      set: { drawer.setKey(at: index, value: $0) }
    )
  }

  private func propertyValueBinding(_ index: Int) -> Binding<String> {
    Binding(
      get: {
        guard drawer.rows.indices.contains(index) else { return "" }
        return drawer.rows[index].value
      },
      set: { drawer.setValue(at: index, value: $0) }
    )
  }

  private func saveProperties() {
    store.editableBlockText = drawer.formattedRawText
    Task { await store.saveEditedBlock(block) }
  }
}

private struct ParagraphBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      OrgSyntaxTextEditor(
        text: $store.editableBlockText,
        showsScrollers: false,
        textInset: NSSize(width: 2, height: 4),
        focusOnAppear: true,
        onSubmitContext: submitParagraph
      )
      .frame(minHeight: editorHeight, maxHeight: editorHeight)

      if !slashCommandKinds.isEmpty {
        HStack(spacing: 8) {
          Text("Turn into")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

          ForEach(slashCommandKinds) { kind in
            Button {
              Task { await store.convertEditingBlock(block, to: kind) }
            } label: {
              Label("/\(kind.slashCommand)", systemImage: kind.systemImage)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Convert to \(kind.title)")
          }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }

      HStack(spacing: 8) {
        Text("line \(block.displayRange)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }
        Button {
          Task { await store.saveEditedBlock(block) }
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command])
        .help("Save")
        .disabled(store.isSavingBlock)

        Button {
          store.cancelEditingBlock()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .help("Cancel")
        .disabled(store.isSavingBlock)
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.accentColor.opacity(0.2))
    )
  }

  private var editorHeight: CGFloat {
    let lineCount = max(1, store.editableBlockText.split(separator: "\n", omittingEmptySubsequences: false).count)
    return min(320, max(38, CGFloat(lineCount) * 23 + 12))
  }

  private var slashCommandKinds: [OrgInsertBlockKind] {
    guard let query = slashCommandQuery else { return [] }
    return OrgInsertBlockKind.allCases.filter { kind in
      query.isEmpty
        || kind.slashCommand.localizedCaseInsensitiveContains(query)
        || kind.title.localizedCaseInsensitiveContains(query)
    }
  }

  private var primarySlashCommandKind: OrgInsertBlockKind? {
    guard let query = slashCommandQuery,
          !query.isEmpty
    else {
      return nil
    }
    return slashCommandKinds.first
  }

  private var slashCommandQuery: String? {
    let trimmed = store.editableBlockText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }

    let command = trimmed
      .dropFirst()
      .prefix { !$0.isWhitespace }
    return String(command)
  }

  private func submitParagraph(_ context: OrgSyntaxTextEditorSubmitContext) -> Bool {
    store.editableBlockText = context.text
    if let kind = primarySlashCommandKind {
      Task { await store.convertEditingBlock(block, to: kind) }
      return true
    }

    Task { await store.splitEditingBlock(block, atUTF16Offset: context.selectedRange.location) }
    return true
  }
}

private struct QuoteBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  private let beginLine: String
  private let endLine: String
  @State private var quoteText: String

  init(block: OrgEditableBlock) {
    self.block = block
    let lines = block.rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    self.beginLine = lines.first ?? "#+begin_quote"
    self.endLine = lines.last ?? "#+end_quote"
    let body = lines.count >= 2 ? Array(lines.dropFirst().dropLast()).joined(separator: "\n") : ""
    _quoteText = State(initialValue: body)
  }

  var body: some View {
    BlockEditorContainer(
      block: block,
      title: "Quote",
      previewText: rawQuote,
      onSave: { store.editableBlockText = rawQuote }
    ) {
      OrgSyntaxTextEditor(text: $quoteText, showsScrollers: false, focusOnAppear: true)
        .frame(minHeight: editorHeight, maxHeight: editorHeight)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.secondary.opacity(0.22))
        )
    }
  }

  private var rawQuote: String {
    "\(beginLine)\n\(quoteText)\n\(endLine)"
  }

  private var editorHeight: CGFloat {
    let lineCount = max(2, quoteText.split(separator: "\n", omittingEmptySubsequences: false).count)
    return min(260, max(76, CGFloat(lineCount) * 22 + 32))
  }
}

private struct SourceBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var source: OrgEditableSourceBlock

  init(block: OrgEditableBlock, language: String?, lines: [String]) {
    self.block = block
    _source = State(initialValue: OrgEditableSourceBlock(
      rawText: block.rawText,
      fallbackLanguage: language,
      fallbackLines: lines
    ))
  }

  var body: some View {
    BlockEditorContainer(
      block: block,
      title: "Source",
      previewText: source.formattedRawText,
      onSave: { store.editableBlockText = source.formattedRawText }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Picker("Kind", selection: kindBinding) {
            Text("Source").tag("#+begin_src")
            Text("Example").tag("#+begin_example")
            Text("Org2").tag("#+begin_org2")
          }
          .frame(width: 150)

          TextField("Language", text: languageBinding)
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)
            .disabled(source.beginKeyword.lowercased().hasSuffix("begin_example"))

          TextField("Parameters", text: parametersBinding)
            .textFieldStyle(.roundedBorder)
        }

        OrgSyntaxTextEditor(text: bodyBinding, monospaced: true, focusOnAppear: true)
          .frame(minHeight: editorHeight, maxHeight: editorHeight)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.secondary.opacity(0.22))
          )
      }
    }
  }

  private var kindBinding: Binding<String> {
    Binding(
      get: { source.beginKeyword },
      set: { source.setBeginKeyword($0) }
    )
  }

  private var languageBinding: Binding<String> {
    Binding(
      get: { source.language },
      set: { source.language = $0 }
    )
  }

  private var parametersBinding: Binding<String> {
    Binding(
      get: { source.parameters },
      set: { source.parameters = $0 }
    )
  }

  private var bodyBinding: Binding<String> {
    Binding(
      get: { source.body },
      set: { source.body = $0 }
    )
  }

  private var editorHeight: CGFloat {
    let lineCount = max(3, source.body.split(separator: "\n", omittingEmptySubsequences: false).count)
    return min(360, max(96, CGFloat(lineCount) * 22 + 34))
  }
}

private struct TableBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  @State private var table: OrgEditableTable
  @FocusState private var focusedCell: TableCellFocus?

  private struct TableCellFocus: Hashable {
    let row: Int
    let column: Int
  }

  init(block: OrgEditableBlock, table: OrgTableBlock) {
    self.block = block
    _table = State(initialValue: OrgEditableTable(rawText: block.rawText, fallback: table))
  }

  var body: some View {
    BlockEditorContainer(
      block: block,
      title: "Table",
      previewText: table.formattedRawText,
      onSave: { store.editableBlockText = table.formattedRawText }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Button {
            table.addRow()
          } label: {
            Label("Row", systemImage: "plus")
          }
          .help("Add row")

          Button {
            table.addColumn()
          } label: {
            Label("Column", systemImage: "rectangle.split.3x1")
          }
          .help("Add column")

          Button {
            table.addSeparator()
          } label: {
            Label("Separator", systemImage: "minus")
          }
          .help("Add separator")

          Spacer(minLength: 0)
        }
        .controlSize(.small)

        ScrollView(.horizontal) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
              switch row {
              case .cells:
                editableRow(rowIndex: rowIndex)
              case .separator:
                separatorRow(rowIndex: rowIndex)
              }
            }
          }
          .padding(1)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.secondary.opacity(0.2))
          )
        }
      }
    }
    .onAppear {
      focusedCell = firstEditableCellFocus
    }
  }

  private func editableRow(rowIndex: Int) -> some View {
    HStack(spacing: 0) {
      ForEach(0..<table.columnCount, id: \.self) { columnIndex in
        TextField("", text: cellBinding(row: rowIndex, column: columnIndex))
          .textFieldStyle(.plain)
          .font(.callout)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .frame(width: 150, alignment: .leading)
          .background(Color(nsColor: .controlBackgroundColor))
          .focused($focusedCell, equals: TableCellFocus(row: rowIndex, column: columnIndex))
          .onSubmit {
            advanceCellFocus(from: TableCellFocus(row: rowIndex, column: columnIndex))
          }
          .overlay(alignment: .trailing) {
            Divider()
          }
      }

      rowMenu(rowIndex: rowIndex)
        .frame(width: 34)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func separatorRow(rowIndex: Int) -> some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(Color.secondary.opacity(0.28))
        .frame(width: CGFloat(table.columnCount) * 150, height: 1)
        .padding(.vertical, 12)
      rowMenu(rowIndex: rowIndex)
        .frame(width: 34)
    }
    .background(Color.secondary.opacity(0.05))
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func rowMenu(rowIndex: Int) -> some View {
    Menu {
      Button("Add Row Below") {
        table.addRow(after: rowIndex)
      }
      Button("Add Separator Below") {
        table.addSeparator(after: rowIndex)
      }
      Button("Delete Row", role: .destructive) {
        table.removeRow(rowIndex)
      }
      Divider()
      ForEach(0..<table.columnCount, id: \.self) { columnIndex in
        Button("Delete Column \(columnIndex + 1)", role: .destructive) {
          table.removeColumn(columnIndex)
        }
        .disabled(table.columnCount <= 1)
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.caption.weight(.semibold))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help("Table row actions")
  }

  private func cellBinding(row rowIndex: Int, column columnIndex: Int) -> Binding<String> {
    Binding(
      get: { table.cell(row: rowIndex, column: columnIndex) },
      set: { table.setCell(row: rowIndex, column: columnIndex, value: $0) }
    )
  }

  private var firstEditableCellFocus: TableCellFocus? {
    guard let rowIndex = table.rows.firstIndex(where: { row in
      if case .cells = row { return true }
      return false
    }) else {
      return nil
    }
    return TableCellFocus(row: rowIndex, column: 0)
  }

  private func advanceCellFocus(from current: TableCellFocus) {
    if current.column + 1 < table.columnCount {
      focusedCell = TableCellFocus(row: current.row, column: current.column + 1)
      return
    }

    let nextRow = table.rows.indices
      .filter { $0 > current.row }
      .first { rowIndex in
        if case .cells = table.rows[rowIndex] { return true }
        return false
      }

    if let nextRow {
      focusedCell = TableCellFocus(row: nextRow, column: 0)
    } else {
      table.addRow(after: current.row)
      focusedCell = TableCellFocus(row: min(current.row + 1, table.rows.count - 1), column: 0)
    }
  }
}

private struct RawInlineBlockEditor: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  let title: String
  let monospaced: Bool

  var body: some View {
    BlockEditorContainer(
      block: block,
      title: title,
      previewText: store.editableBlockText,
      onSave: {}
    ) {
      OrgSyntaxTextEditor(text: $store.editableBlockText, monospaced: monospaced, focusOnAppear: true)
        .frame(minHeight: editorHeight, maxHeight: editorHeight)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.secondary.opacity(0.22))
        )
    }
  }

  private var editorHeight: CGFloat {
    let lineCount = max(2, store.editableBlockText.split(separator: "\n", omittingEmptySubsequences: false).count)
    return min(300, max(72, CGFloat(lineCount) * 22 + 32))
  }
}

private struct BlockEditorContainer<Content: View>: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgEditableBlock
  let title: String
  let previewText: String?
  let onSave: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text(title)
          .font(.caption.weight(.medium))
        Text("line \(block.displayRange)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if store.isSavingBlock {
          ProgressView()
            .controlSize(.small)
        }
        Button {
          onSave()
          Task { await store.saveEditedBlock(block) }
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(store.isSavingBlock)

        Button {
          store.cancelEditingBlock()
        } label: {
          Label("Cancel", systemImage: "xmark")
        }
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSavingBlock)
      }

      content

      if !previewBlocks.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          Text("Preview")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(previewBlocks.enumerated()), id: \.offset) { _, previewBlock in
              RenderedBlockView(block: previewBlock.rendered, rawText: previewBlock.rawText)
            }
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
      }
    }
    .padding(10)
    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.accentColor.opacity(0.22))
    )
  }

  private var previewBlocks: [OrgEditableBlock] {
    guard let previewText else { return [] }
    return OrgEntryRenderer.parseEditable(previewText)
      .filter {
        if case .blank = $0.rendered { return false }
        return true
      }
  }
}

private struct RenderedBlockView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let block: OrgRenderedBlock
  let rawText: String?
  let editableBlock: OrgEditableBlock?

  init(block: OrgRenderedBlock, rawText: String? = nil, editableBlock: OrgEditableBlock? = nil) {
    self.block = block
    self.rawText = rawText
    self.editableBlock = editableBlock
  }

  var body: some View {
    switch block {
    case .heading(let heading):
      RenderedHeadingView(heading: heading, rawText: rawText)
    case .planning(let planning):
      RenderedPlanningView(planning: planning)
    case .properties(let rows):
      RenderedPropertiesView(rows: rows, rawText: rawText)
    case .quote(let lines):
      RenderedQuoteView(lines: lines, rawText: rawText)
    case .source(let language, let lines):
      RenderedSourceView(language: language, lines: lines, editableBlock: editableBlock)
    case .table(let table):
      RenderedTableView(table: table)
    case .listItem(let indent, let marker, let checkbox, let text):
      RenderedListItemView(
        indent: indent,
        marker: marker,
        checkbox: checkbox,
        text: text,
        rawText: rawText,
        editableBlock: editableBlock
      )
    case .paragraph(let text):
      if let attachment = OrgMediaAttachment.standalone(
        raw: rawText ?? text,
        sourceFile: store.selectedEntrySource?.file,
        corpusRoot: store.corpusRoot
      ) {
        OrgMediaAttachmentView(attachment: attachment)
      } else {
        OrgInlineText(rawText ?? text)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    case .keyword(let key, let value):
      RenderedKeywordView(key: key, value: value, rawText: rawText)
    case .blank:
      Spacer()
        .frame(height: 4)
    }
  }
}

private struct OrgMediaAttachmentView: View {
  let attachment: OrgMediaAttachment

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch attachment.kind {
      case .image:
        OrgImageAttachmentView(attachment: attachment)
      case .video:
        OrgVideoAttachmentView(attachment: attachment)
      }

      HStack(spacing: 8) {
        Label(attachment.displayName, systemImage: attachment.kind == .image ? "photo" : "film")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        if let url = attachment.resolvedURL {
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          } label: {
            Image(systemName: "folder")
          }
          .buttonStyle(.borderless)
          .help("Reveal")

          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Image(systemName: "arrow.up.right.square")
          }
          .buttonStyle(.borderless)
          .help("Open")
        }
      }
      .controlSize(.small)
    }
    .frame(maxWidth: 760, alignment: .leading)
    .padding(.vertical, 4)
  }
}

private struct OrgImageAttachmentView: View {
  let attachment: OrgMediaAttachment
  @State private var image: NSImage?
  @State private var attemptedLoad = false

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 760, maxHeight: 460, alignment: .leading)
      } else {
        MissingMediaView(kind: attachment.kind, name: attachment.displayName, attemptedLoad: attemptedLoad)
          .frame(maxWidth: 760, minHeight: 96)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.secondary.opacity(0.16))
    )
    .task(id: attachment.resolvedPath) {
      guard let url = attachment.resolvedURL else {
        attemptedLoad = true
        image = nil
        return
      }
      attemptedLoad = false
      image = NSImage(contentsOf: url)
      attemptedLoad = true
    }
  }
}

private struct OrgVideoAttachmentView: View {
  let attachment: OrgMediaAttachment
  @State private var player: AVPlayer?

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
          .frame(maxWidth: 760, minHeight: 260, maxHeight: 420)
      } else {
        MissingMediaView(kind: attachment.kind, name: attachment.displayName, attemptedLoad: true)
          .frame(maxWidth: 760, minHeight: 120)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.secondary.opacity(0.16))
    )
    .onAppear {
      if player == nil, let url = attachment.resolvedURL {
        player = AVPlayer(url: url)
      }
    }
    .onDisappear {
      player?.pause()
    }
  }
}

private struct MissingMediaView: View {
  let kind: OrgMediaAttachment.Kind
  let name: String
  let attemptedLoad: Bool

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: kind == .image ? "photo" : "film")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(attemptedLoad ? "Media unavailable" : "Loading media")
        .font(.callout.weight(.medium))
      Text(name)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(14)
    .background(Color.secondary.opacity(0.06))
  }
}

private struct RenderedHeadingView: View {
  let heading: OrgHeadingBlock
  let rawText: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let todo = heading.todo {
        StatusPill(text: todo)
      }
      if let priority = heading.priority {
        Label(priority, systemImage: "flag.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
          .labelStyle(.titleAndIcon)
      }
      OrgInlineText(rawTitle, font: font)
      if !heading.tags.isEmpty {
        Text(heading.tags.map { "#\($0)" }.joined(separator: " "))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.top, topPadding)
    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 14)
  }

  private var font: Font {
    switch heading.level {
    case 1:
      return .title3.weight(.semibold)
    case 2:
      return .headline.weight(.semibold)
    case 3:
      return .callout.weight(.semibold)
    default:
      return .body.weight(.semibold)
    }
  }

  private var topPadding: CGFloat {
    heading.level == 1 ? 2 : 8
  }

  private var rawTitle: String {
    guard let rawText,
          let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first
    else {
      return heading.title
    }

    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return heading.title }
    var rest = String(line.dropFirst(stars.count)).trimmingCharacters(in: .whitespaces)
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if let first = tokens.first, Self.todoKeywords.contains(first.uppercased()) {
      tokens.removeFirst()
    }
    if let first = tokens.first,
       first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }
    return tokens.joined(separator: " ")
  }

  private static let todoKeywords = Set(["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"])
}

private struct RenderedPlanningView: View {
  let planning: OrgPlanningBlock

  var body: some View {
    HStack(spacing: 8) {
      Text(planning.kind.capitalized)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: 78, alignment: .leading)
      if let timestamp = OrgTimestampDisplay.parse(planning.value) {
        HStack(spacing: 6) {
          TimestampPill(systemImage: "calendar", text: timestamp.dateLabel)
          if let time = timestamp.timeLabel {
            TimestampPill(systemImage: "clock", text: time)
          }
          if let detail = timestamp.detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .textSelection(.enabled)
      } else {
        Text(planning.value)
          .font(.callout.monospacedDigit())
          .textSelection(.enabled)
      }
    }
    .padding(.leading, 2)
  }
}

private struct TimestampPill: View {
  let systemImage: String
  let text: String

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption.monospacedDigit().weight(.medium))
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color.accentColor.opacity(0.12), in: Capsule())
      .foregroundStyle(.primary)
  }
}

private struct OrgTimestampDisplay {
  let dateLabel: String
  let timeLabel: String?
  let detail: String?

  static func parse(_ raw: String) -> OrgTimestampDisplay? {
    guard let dateRange = raw.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
      return nil
    }

    let dateToken = String(raw[dateRange])
    let dateLabel = formattedDate(dateToken)
    let timeLabel = raw
      .range(of: #"\b\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?\b"#, options: .regularExpression)
      .map { String(raw[$0]) }

    let compactRaw = raw
      .replacingOccurrences(of: #"[<\[]\d{4}-\d{2}-\d{2}(?:\s+[A-Za-z]{3})?"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\b\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?\b"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"[>\]]"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = compactRaw.isEmpty ? nil : compactRaw

    return OrgTimestampDisplay(dateLabel: dateLabel, timeLabel: timeLabel, detail: detail)
  }

  private static func formattedDate(_ raw: String) -> String {
    let parts = raw.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          parts[1] >= 1,
          parts[1] <= monthNames.count
    else {
      return raw
    }
    return "\(monthNames[parts[1] - 1]) \(parts[2]), \(parts[0])"
  }

  private static let monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
  ]
}

private struct RenderedPropertiesView: View {
  let rows: [OrgPropertyRow]
  let rawText: String?

  var body: some View {
    if !rows.isEmpty {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
        ForEach(rows, id: \.key) { row in
          GridRow {
            Text(row.key)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            if row.key.uppercased() == "ID",
               row.value.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil {
              Text(Org2Display.shortID(row.value))
                .font(.callout)
                .textSelection(.enabled)
            } else {
              OrgInlineText(propertyValue(row), font: .callout)
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func propertyValue(_ row: OrgPropertyRow) -> String {
    rawPropertyValues[row.key.uppercased()] ?? row.value
  }

  private var rawPropertyValues: [String: String] {
    guard let rawText else { return [:] }
    var values: [String: String] = [:]
    for line in rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(":"),
            let secondColon = trimmed.dropFirst().firstIndex(of: ":")
      else {
        continue
      }
      let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<secondColon]).uppercased()
      let value = String(trimmed[trimmed.index(after: secondColon)...]).trimmingCharacters(in: .whitespaces)
      guard key != "PROPERTIES", key != "END" else { continue }
      values[key] = value
    }
    return values
  }
}

private struct RenderedQuoteView: View {
  let lines: [String]
  let rawText: String?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Rectangle()
        .fill(Color.accentColor.opacity(0.45))
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(displayLines.indices, id: \.self) { index in
          OrgInlineText(displayLines[index], font: .body.italic())
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 5)
    .padding(.leading, 8)
  }

  private var displayLines: [String] {
    guard let rawText else { return lines }
    let rawLines = rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard rawLines.count >= 2 else { return lines }
    return Array(rawLines.dropFirst().dropLast())
  }
}

private struct RenderedSourceView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let language: String?
  let lines: [String]
  let editableBlock: OrgEditableBlock?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if let language, !language.isEmpty {
          Text(language)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
        } else {
          Text("source")
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if let state = runState {
          SourceRunStatusLabel(state: state)
        }
        if let editableBlock {
          Button {
            Task { await store.runSourceBlock(editableBlock) }
          } label: {
            Label("Run", systemImage: "play.fill")
          }
          .controlSize(.small)
          .disabled(isRunning)
          .help(runHelp)
        }
      }

      ScrollView(.horizontal) {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(lines.indices, id: \.self) { index in
            let line = lines[index]
            Text(line.isEmpty ? " " : line)
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(color(for: line))
              .textSelection(.enabled)
          }
        }
        .padding(10)
      }
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.secondary.opacity(0.16))
      )

      if let state = runState, state.status != .running || state.message != nil {
        SourceRunOutputView(state: state)
      }
    }
    .padding(.vertical, 4)
  }

  private var runState: SourceBlockRunState? {
    guard let editableBlock else { return nil }
    return store.sourceBlockRunState(for: editableBlock)
  }

  private var isRunning: Bool {
    runState?.status == .running
  }

  private var runHelp: String {
    if SourceBlockRunPlan.plan(for: language) == nil {
      return "Unsupported source language"
    }
    return "Run source block"
  }

  private func color(for line: String) -> Color {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix("--") {
      return .secondary
    }
    if trimmed.hasPrefix("import ") || trimmed.hasPrefix("let ") || trimmed.hasPrefix("const ") || trimmed.hasPrefix("func ") {
      return .purple
    }
    return .primary
  }
}

private struct SourceRunStatusLabel: View {
  let state: SourceBlockRunState

  var body: some View {
    Label(label, systemImage: icon)
      .font(.caption.monospacedDigit())
      .foregroundStyle(color)
      .labelStyle(.titleAndIcon)
  }

  private var label: String {
    switch state.status {
    case .running:
      return "running"
    case .succeeded:
      return state.duration.map { String(format: "%.1fs", $0) } ?? "done"
    case .failed:
      return state.exitCode.map { "exit \($0)" } ?? "failed"
    case .timedOut:
      return "timed out"
    case .unsupported:
      return "unsupported"
    }
  }

  private var icon: String {
    switch state.status {
    case .running:
      return "play.circle"
    case .succeeded:
      return "checkmark.circle"
    case .failed:
      return "xmark.circle"
    case .timedOut:
      return "clock.badge.exclamationmark"
    case .unsupported:
      return "questionmark.circle"
    }
  }

  private var color: Color {
    switch state.status {
    case .running:
      return .secondary
    case .succeeded:
      return .green
    case .failed, .timedOut:
      return .red
    case .unsupported:
      return .secondary
    }
  }
}

private struct SourceRunOutputView: View {
  let state: SourceBlockRunState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("Output")
          .font(.caption.weight(.medium))
        Text(state.commandLabel)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }

      if let message = state.message, !message.isEmpty {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if !state.stdout.isEmpty {
        outputBlock(title: "stdout", text: state.stdout)
      }
      if !state.stderr.isEmpty {
        outputBlock(title: "stderr", text: state.stderr)
      }
      if state.stdout.isEmpty, state.stderr.isEmpty, state.status == .succeeded {
        Text("No output")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.14))
    )
  }

  private func outputBlock(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption2.monospaced().weight(.medium))
        .foregroundStyle(.secondary)
      outputBody(for: SourceRunOutputPresentation.make(from: text))
    }
  }

  @ViewBuilder
  private func outputBody(for presentation: SourceRunOutputPresentation) -> some View {
    switch presentation {
    case .text(let text):
      Text(text.isEmpty ? " " : text)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .table(let table):
      SourceRunTableView(table: table)
    case .bars(let bars):
      SourceRunBarsView(bars: bars)
    }
  }
}

private struct SourceRunTableView: View {
  let table: SourceRunTable

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(0..<columnCount, id: \.self) { columnIndex in
            Text(columnTitle(at: columnIndex))
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .padding(.horizontal, 9)
              .padding(.vertical, 6)
              .frame(minWidth: 92, alignment: .leading)
              .background(Color.secondary.opacity(0.08))
              .overlay(alignment: .trailing) {
                Divider()
              }
          }
        }

        ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
          GridRow {
            ForEach(0..<columnCount, id: \.self) { columnIndex in
              Text(cellText(row, at: columnIndex))
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(minWidth: 92, alignment: .leading)
                .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.04))
                .overlay(alignment: .trailing) {
                  Divider()
                }
            }
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.16))
    )
  }

  private var columnCount: Int {
    max(1, table.columns.count)
  }

  private func columnTitle(at index: Int) -> String {
    guard table.columns.indices.contains(index) else { return "Value" }
    let title = table.columns[index].trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Column \(index + 1)" : title
  }

  private func cellText(_ row: [String], at index: Int) -> String {
    guard row.indices.contains(index) else { return "" }
    return row[index]
  }
}

private struct SourceRunBarsView: View {
  let bars: [SourceRunBar]

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(bars, id: \.label) { bar in
        HStack(spacing: 8) {
          Text(bar.label)
            .font(.caption)
            .lineLimit(1)
            .frame(width: 120, alignment: .leading)
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color.secondary.opacity(0.12))
              Capsule()
                .fill(Color.accentColor.opacity(0.72))
                .frame(width: barWidth(for: bar.value, availableWidth: proxy.size.width))
            }
          }
          .frame(height: 8)
          Text(formattedValue(bar.value))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .trailing)
        }
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.14))
    )
  }

  private var maximumMagnitude: Double {
    max(1, bars.map { abs($0.value) }.max() ?? 1)
  }

  private func barWidth(for value: Double, availableWidth: CGFloat) -> CGFloat {
    guard availableWidth.isFinite, availableWidth > 0 else { return 0 }
    let fraction = min(1, abs(value) / maximumMagnitude)
    return max(value == 0 ? 0 : 2, availableWidth * CGFloat(fraction))
  }

  private func formattedValue(_ value: Double) -> String {
    if value.rounded() == value {
      return String(format: "%.0f", value)
    }
    return String(format: "%.2f", value)
  }
}

private struct RenderedTableView: View {
  let table: OrgTableBlock

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
          switch row {
          case .cells(let cells):
            GridRow {
              ForEach(0..<columnCount, id: \.self) { columnIndex in
                OrgInlineText(cellText(cells, at: columnIndex), font: .callout)
                  .padding(.horizontal, 9)
                  .padding(.vertical, 6)
                  .frame(minWidth: 88, alignment: .leading)
                  .background(Color(nsColor: .textBackgroundColor))
                  .overlay(alignment: .trailing) {
                    Divider()
                  }
              }
            }
          case .separator:
            Rectangle()
              .fill(Color.secondary.opacity(0.22))
              .frame(height: 1)
              .gridCellColumns(columnCount)
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.18))
    )
    .padding(.vertical, 4)
  }

  private var columnCount: Int {
    max(1, table.columnCount)
  }

  private func cellText(_ cells: [String], at index: Int) -> String {
    guard cells.indices.contains(index) else { return "" }
    return cells[index]
  }
}

private struct RenderedListItemView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let indent: Int
  let marker: String
  let checkbox: OrgListCheckbox?
  let text: String
  let rawText: String?
  let editableBlock: OrgEditableBlock?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(marker)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .frame(width: 28, alignment: .trailing)

      if let checkbox {
        Button {
          if let editableBlock {
            Task { await store.toggleListItemCheckbox(editableBlock) }
          }
        } label: {
          Image(systemName: checkboxImageName(checkbox))
            .font(.callout.weight(.medium))
            .foregroundStyle(checkbox == .checked ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(editableBlock == nil || store.selectedEntrySource?.isEditable != true)
        .help(checkbox == .checked ? "Mark incomplete" : "Mark complete")
      }

      OrgInlineText(rawListText)
        .strikethrough(checkbox == .checked)
        .foregroundStyle(checkbox == .checked ? .secondary : .primary)
      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(indent) * 16)
  }

  private var rawListText: String {
    guard let rawText,
          let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first
    else {
      return text
    }
    let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
    let rest = String(line.dropFirst(leadingWhitespace.count))
    guard let separator = rest.firstIndex(where: { $0.isWhitespace }) else { return text }
    let textStart = rest[separator...].firstIndex { !$0.isWhitespace } ?? rest.endIndex
    return Self.stripCheckbox(String(rest[textStart...]))
  }

  private func checkboxImageName(_ checkbox: OrgListCheckbox) -> String {
    switch checkbox {
    case .unchecked:
      return "square"
    case .checked:
      return "checkmark.square.fill"
    case .mixed:
      return "minus.square"
    }
  }

  private static func stripCheckbox(_ text: String) -> String {
    if text.hasPrefix("[ ] ") || text.hasPrefix("[X] ") || text.hasPrefix("[x] ") || text.hasPrefix("[-] ") {
      return String(text.dropFirst(4))
    }
    return text
  }
}

private struct RenderedKeywordView: View {
  let key: String
  let value: String
  let rawText: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(key)
        .font(.caption.monospaced().weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: 78, alignment: .leading)
      OrgInlineText(rawValue, font: .callout)
    }
  }

  private var rawValue: String {
    guard let rawText,
          let line = rawText.split(separator: "\n", omittingEmptySubsequences: false).first
    else {
      return value
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let separator = trimmed.firstIndex(of: ":") else { return value }
    return String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
  }
}

private struct DetailMetadataGrid: View {
  let rows: [(String, String)]

  var body: some View {
    if !rows.isEmpty {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
        ForEach(rows, id: \.0) { row in
          GridRow {
            Text(row.0)
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            Text(row.1)
              .font(.callout)
              .textSelection(.enabled)
          }
        }
      }
    }
  }
}

private struct BacklinksView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Backlinks")
          .font(.headline)
        Spacer()
        if store.isLoadingBacklinks {
          ProgressView()
            .controlSize(.small)
        } else if let count = store.backlinks?.backlinks.count {
          Text("\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      if let backlinks = store.backlinks {
        if backlinks.backlinks.isEmpty {
          Text("No backlinks")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
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
          .padding(.horizontal, 16)
      }
    }
  }
}

private struct BacklinkRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let backlink: BacklinkItem

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(Org2Display.cleanInline(backlink.srcTitle))
        .font(.body)
        .lineLimit(1)
      Text(Org2Display.cleanInline(backlink.context))
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Text(store.relativePath(backlink.file) + ":\(backlink.lineForEditor)")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
  }
}

private struct HeaderBar<Trailing: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.largeTitle.weight(.semibold))
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      trailing
    }
    .padding(16)
  }
}

private struct StatusPill: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(statusColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
  }

  private var statusColor: Color {
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
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
