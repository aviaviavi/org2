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
    .environment(\.openOrgFileReference) { reference in
      store.openChatFileReference(reference)
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
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            EntryBodyView(location: location)
            Divider()
            BacklinksView()
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
            store.beginEditingVisibleBlock()
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
          OrgRenderedEntryView(
            blocks: store.selectedRenderedBlocks,
            blocksRenderSignature: store.selectedRenderedBlocksRenderSignature,
            source: store.selectedEntrySource,
            corpusRoot: store.corpusRoot,
            selectedBlockID: store.selectedBlockID,
            selectedBlockIndex: store.selectedBlockID.flatMap { store.selectedRenderedBlockIndexes[$0] },
            editingBlockID: store.editingBlockID,
            isSavingBlock: store.isSavingBlock,
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

struct StatusPill: View {
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
