import AppKit
import SwiftUI

public struct ContentView: View {
  @EnvironmentObject private var store: WorkspaceStore

  public init() {}

  public var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
    } detail: {
      WorkspaceMainArea()
    }
    .toolbar {
      ToolbarItemGroup {
        Button {
          store.makeSurfacePrimary(.openClaw)
        } label: {
          Label("Open OpenClaw", systemImage: "bubble.left.and.sparkles")
        }

        Button {
          store.chooseCorpus()
        } label: {
          Label("Open Corpus", systemImage: "folder")
        }

        Button {
          Task { await store.refreshWorkspace() }
        } label: {
          if store.isLoadingAgenda {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .small)
              Text("Refresh")
            }
          } else {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        }
        .disabled(store.corpusRoot == nil || store.isLoadingAgenda)
      }
    }
    .keyboardEventMonitor { event, scope in
      store.handleWorkspaceKeyDown(event, scope: scope)
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
    .sheet(isPresented: $store.isCapturePanelPresented) {
      GlobalCaptureView()
        .environmentObject(store)
    }
    .sheet(isPresented: $store.isSimilarTodoAssignmentPresented) {
      SimilarTodoAssignmentView()
        .environmentObject(store)
    }
  }
}

private struct WorkspaceMainArea: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    if store.isWorkspaceSurfacePaneClosed && store.hasWorkspaceDetailContent {
      WorkspaceDetailArea()
    } else if store.isWorkspaceDetailPaneClosed || !store.hasWorkspaceDetailContent {
      WorkspaceSurfaceCacheView(selectedSurface: store.selectedSurface)
    } else {
      HSplitView {
        WorkspaceSurfaceCacheView(selectedSurface: store.selectedSurface)
          .frame(minWidth: 320, idealWidth: 460)

        WorkspaceDetailArea()
          .frame(minWidth: 520, idealWidth: 720)
      }
    }
  }
}

private struct WorkspaceSurfaceCacheView: NSViewRepresentable {
  @EnvironmentObject private var store: WorkspaceStore
  let selectedSurface: WorkspaceSurface

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.show(surface: selectedSurface, in: view, store: store)
  }

  @MainActor
  final class Coordinator {
    private var hosts: [WorkspaceSurface: NSHostingView<AnyView>] = [:]
    private var activeSurface: WorkspaceSurface?
    private var activeConstraints: [NSLayoutConstraint] = []

    func show(surface: WorkspaceSurface, in container: NSView, store: WorkspaceStore) {
      guard activeSurface != surface || hosts[surface]?.superview !== container else { return }

      NSLayoutConstraint.deactivate(activeConstraints)
      activeConstraints = []
      if let activeSurface, let activeHost = hosts[activeSurface] {
        activeHost.removeFromSuperview()
      }

      let host = hostView(for: surface, store: store)
      if host.superview !== container {
        container.addSubview(host)
      }
      activeConstraints = [
        host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        host.topAnchor.constraint(equalTo: container.topAnchor),
        host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
      ]
      NSLayoutConstraint.activate(activeConstraints)
      activeSurface = surface
    }

    private func hostView(for surface: WorkspaceSurface, store: WorkspaceStore) -> NSHostingView<AnyView> {
      if let host = hosts[surface] {
        return host
      }

      let host = NSHostingView(rootView: AnyView(
        WorkspaceSurfaceView(surface: surface)
          .environmentObject(store)
      ))
      host.translatesAutoresizingMaskIntoConstraints = false
      hosts[surface] = host
      return host
    }
  }
}

private struct WorkspaceSurfaceView: View {
  let surface: WorkspaceSurface

  var body: some View {
    Group {
      switch surface {
      case .home:
        HomeView()
      case .agenda:
        AgendaView()
      case .approvals:
        ApprovalsView()
      case .files:
        FilesView()
      case .search:
        SearchView()
      case .meetings:
        MeetingsView()
      case .openClaw:
        OpenClawChatView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct HomeView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    OpenClawChatView(presentation: .fullPage, surface: .home)
      .onAppear {
        if store.selectedSurface == .home {
          store.openHome()
        }
      }
  }
}

private struct WorkspaceDetailArea: View {
  var body: some View {
    DetailView()
  }
}

private struct SidebarView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    List(selection: $store.selectedSurface) {
      Section("Workspace") {
        ForEach(WorkspaceSurface.sidebarCases) { surface in
          if surface == .openClaw {
            OpenClawSidebarSurfaceGroup()
              .tag(surface)
          } else {
            SidebarSurfaceRow(surface: surface)
              .tag(surface)
              .contentShape(Rectangle())
              .onTapGesture {
                store.makeSurfacePrimary(surface)
              }
              .help(surface.commandShortcutTitle.isEmpty ? surface.title : "\(surface.title) (\(surface.commandShortcutTitle))")
          }
        }
      }

      Section("Corpus") {
        if let root = store.corpusRoot {
          VStack(alignment: .leading, spacing: 5) {
            Text(root.lastPathComponent)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
            Text(root.deletingLastPathComponent().path)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
            HStack(spacing: 5) {
              Image(systemName: "doc.text")
              Text("\(store.corpusFiles.count) file\(store.corpusFiles.count == 1 ? "" : "s")")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            if store.isBuildingSearchIndex || !store.searchIndexStatusText.isEmpty {
              HStack(spacing: 5) {
                if store.isBuildingSearchIndex {
                  WorkspaceActivityIndicator(size: .mini)
                } else {
                  Image(systemName: "magnifyingglass")
                }
                Text(store.searchIndexStatusText)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }
              .font(.caption2.weight(.medium))
              .foregroundStyle(.tertiary)
            }
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

private struct SidebarSurfaceRow: View {
  let surface: WorkspaceSurface

  var body: some View {
    HStack(spacing: 8) {
      Label(surface.title, systemImage: surface.systemImage)
        .font(.callout.weight(.medium))
      Spacer(minLength: 0)
      if !surface.commandShortcutTitle.isEmpty {
        KeyboardShortcutBadge(text: surface.commandShortcutTitle)
      }
    }
  }
}

private struct OpenClawSidebarSurfaceGroup: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var isThreadListExpanded = true

  private let surface = WorkspaceSurface.openClaw

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Button {
          store.makeSurfacePrimary(surface)
        } label: {
          HStack(spacing: 6) {
            Label(surface.title, systemImage: surface.systemImage)
              .font(.callout.weight(.medium))
            if store.openClawUnreadMessageCount > 0 {
              OpenClawUnreadBadge(count: store.openClawUnreadMessageCount, compact: true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(surface.commandShortcutTitle.isEmpty ? surface.title : "\(surface.title) (\(surface.commandShortcutTitle))")

        Button {
          store.createOpenClawChatThread()
          store.makeSurfacePrimary(.openClaw)
          isThreadListExpanded = true
        } label: {
          Image(systemName: "plus")
            .font(.caption.weight(.semibold))
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New chat thread")
        .disabled(store.isSendingOpenClawMessage)

        Button {
          withAnimation(.easeInOut(duration: 0.16)) {
            isThreadListExpanded.toggle()
          }
        } label: {
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(isThreadListExpanded ? 0 : -90))
            .frame(width: 16, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isThreadListExpanded ? "Hide chat threads" : "Show chat threads")

        if !surface.commandShortcutTitle.isEmpty {
          KeyboardShortcutBadge(text: surface.commandShortcutTitle)
        }
      }

      if isThreadListExpanded {
        OpenClawSidebarThreadList()
      }
    }
  }
}

private struct OpenClawSidebarThreadList: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var showsAllThreads = false
  @State private var showsArchivedThreads = false

  private let maxHeight: CGFloat = 220
  private let initialLimit = 5

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if store.visibleOpenClawChatThreads.isEmpty && store.archivedOpenClawChatThreads.isEmpty {
        Text("No chat threads")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.leading, 42)
          .padding(.vertical, 3)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(visibleThreads) { thread in
              OpenClawSidebarThreadRow(
                thread: thread,
                isSelected: store.selectedOpenClawChatThreadID == thread.id && store.selectedSurface == .openClaw
              ) {
                store.makeSurfacePrimary(.openClaw)
                store.selectOpenClawChatThread(thread.id)
              }
            }

            if store.visibleOpenClawChatThreads.count > initialLimit {
              Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                  showsAllThreads.toggle()
                }
              } label: {
                Text(showsAllThreads ? "Show less" : "Show more")
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.leading, 42)
                  .padding(.vertical, 6)
              }
              .buttonStyle(.plain)
              .help(showsAllThreads ? "Collapse chat threads" : "Show more chat threads")
            }

            if !store.archivedOpenClawChatThreads.isEmpty {
              Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                  showsArchivedThreads.toggle()
                }
              } label: {
                Text(showsArchivedThreads ? "Hide archived" : "Show archived")
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.leading, 42)
                  .padding(.vertical, 6)
              }
              .buttonStyle(.plain)
              .help(showsArchivedThreads ? "Hide archived chat threads" : "Show archived chat threads")
            }

            if showsArchivedThreads {
              ForEach(store.archivedOpenClawChatThreads) { thread in
                OpenClawSidebarThreadRow(
                  thread: thread,
                  isSelected: store.selectedOpenClawChatThreadID == thread.id && store.selectedSurface == .openClaw
                ) {
                  store.makeSurfacePrimary(.openClaw)
                  store.selectOpenClawChatThread(thread.id)
                }
              }
            }
          }
          .padding(.vertical, 1)
        }
        .frame(maxHeight: showsAllThreads || showsArchivedThreads ? maxHeight : nil)
        .scrollIndicators(showsAllThreads || showsArchivedThreads ? .visible : .hidden)
      }
    }
    .padding(.top, 2)
  }

  private var visibleThreads: [OpenClawChatThread] {
    if showsAllThreads {
      return store.visibleOpenClawChatThreads
    }
    return Array(store.visibleOpenClawChatThreads.prefix(initialLimit))
  }
}

private struct OpenClawSidebarThreadRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let thread: OpenClawChatThread
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: 8) {
        Text(thread.title)
          .font(.callout.weight(isSelected ? .medium : .regular))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 8)
        if thread.isPinned {
          Image(systemName: "pin.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        if thread.isArchived {
          Image(systemName: "archivebox")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        if thread.unreadMessageCount > 0 {
          OpenClawUnreadBadge(count: thread.unreadMessageCount)
        }
        Text(Self.relativeDate(thread.updatedAt))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, 42)
      .padding(.trailing, 8)
      .padding(.vertical, 7)
      .background(
        isSelected ? Color.secondary.opacity(0.14) : Color.clear,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(false)
    .contextMenu {
      Button {
        store.toggleOpenClawChatThreadPin(thread.id)
      } label: {
        Label(thread.isPinned ? "Unpin Thread" : "Pin Thread", systemImage: thread.isPinned ? "pin.slash" : "pin")
      }

      if thread.isArchived {
        Button {
          store.restoreOpenClawChatThread(thread.id)
        } label: {
          Label("Unarchive Thread", systemImage: "tray.and.arrow.up")
        }
      } else {
        Button {
          store.archiveOpenClawChatThread(thread.id)
        } label: {
          Label("Archive Thread", systemImage: "archivebox")
        }
      }
    }
  }

  private static func relativeDate(_ date: Date) -> String {
    let elapsed = max(0, Date().timeIntervalSince(date))
    if elapsed < 60 { return "now" }
    if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
    if elapsed < 86_400 { return "\(Int(elapsed / 3600))h" }
    if elapsed < 604_800 { return "\(Int(elapsed / 86_400))d" }
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter.string(from: date)
  }
}

private struct OpenClawUnreadBadge: View {
  let count: Int
  var compact = false

  var body: some View {
    ZStack {
      Circle()
        .fill(Color.red)
      if !compact {
        Text(count > 9 ? "9+" : "\(count)")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .minimumScaleFactor(0.75)
      }
    }
    .frame(width: compact ? 8 : 16, height: compact ? 8 : 16)
    .accessibilityLabel(count == 1 ? "1 unread message" : "\(count) unread messages")
  }
}

private struct FilesView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Files", subtitle: store.corpusRoot?.path ?? "Corpus files", surface: .files) {
        if store.isScanningCorpusFiles {
          WorkspaceActivityIndicator(size: .small)
        }

        Button {
          store.presentQuickOpen()
        } label: {
          Label("Quick Open", systemImage: "command")
        }
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
        WorkspaceLoadingStateView("Scanning files")
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
              .contextMenu {
                CorpusFileContextMenu(file: file)
              }
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

private struct CorpusFileContextMenu: View {
  @EnvironmentObject private var store: WorkspaceStore
  let file: CorpusFile
  var afterOpen: (() -> Void)? = nil

  var body: some View {
    Button {
      store.selectCorpusFile(file)
      afterOpen?()
    } label: {
      Label("Open", systemImage: "doc.text")
    }

    Button {
      store.openFileInEditor(path: file.path)
    } label: {
      Label("Open in Editor", systemImage: "arrow.up.forward.app")
    }

    Button {
      store.revealFile(path: file.path)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }

    Button {
      store.copyFileReference(path: file.path)
    } label: {
      Label("Copy File Path", systemImage: "doc.on.doc")
    }

    Divider()

    Button {
      store.selectCorpusFile(file)
      store.askOpenClawAboutCurrentSelection()
      afterOpen?()
    } label: {
      Label("Ask OpenClaw", systemImage: "sparkles")
    }

    Button {
      store.selectCorpusFile(file)
      afterOpen?()
      Task { await store.linkifyCurrentFile() }
    } label: {
      Label("Linkify File", systemImage: "link")
    }
  }
}

private struct WorkspaceLocationContextMenu<OpenLabel: View>: View {
  @EnvironmentObject private var store: WorkspaceStore
  let location: WorkspaceLocation
  let select: () -> Void
  let showsHeadingActions: Bool
  @ViewBuilder let openLabel: () -> OpenLabel

  init(
    location: WorkspaceLocation,
    showsHeadingActions: Bool = false,
    select: @escaping () -> Void,
    @ViewBuilder openLabel: @escaping () -> OpenLabel
  ) {
    self.location = location
    self.showsHeadingActions = showsHeadingActions
    self.select = select
    self.openLabel = openLabel
  }

  var body: some View {
    Button {
      select()
    } label: {
      openLabel()
    }

    Button {
      store.open(location)
    } label: {
      Label("Open in Editor", systemImage: "arrow.up.forward.app")
    }

    Button {
      store.revealFile(path: location.file)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }

    Button {
      store.copyFileReference(path: location.file, line: location.lineForEditor)
    } label: {
      Label("Copy Reference", systemImage: "doc.on.doc")
    }

    Divider()

    Button {
      select()
      store.askOpenClawAboutCurrentSelection()
    } label: {
      Label("Ask OpenClaw", systemImage: "sparkles")
    }

    Button {
      select()
      Task { await store.linkifyCurrentFile() }
    } label: {
      Label("Linkify File", systemImage: "link")
    }

    if showsHeadingActions {
      Divider()
      HeadingActionsContextMenu(location: location, select: select)
    }
  }
}

private struct HeadingActionsContextMenu: View {
  @EnvironmentObject private var store: WorkspaceStore
  let location: WorkspaceLocation
  let select: () -> Void

  var body: some View {
    Menu {
      todoButton("TODO", status: .todo)
      todoButton("In Progress", status: .inProgress)
      todoButton("Done", status: .done)
      todoButton("Canceled", status: .canceled)
      Divider()
      Button {
        select()
        Task { await store.applyTodoShortcut(nil, to: location) }
      } label: {
        Label("Toggle", systemImage: "arrow.triangle.2.circlepath")
      }
    } label: {
      Label("Status", systemImage: "checkmark.circle")
    }

    Menu {
      planningButton("Today", kind: .scheduled, target: .today)
      planningButton("Tomorrow", kind: .scheduled, target: .tomorrow)
      planningButton("Next Monday", kind: .scheduled, target: .upcomingMonday)
      planningButton("Next Month", kind: .scheduled, target: .nextMonth)
    } label: {
      Label("Schedule", systemImage: "calendar")
    }

    Menu {
      planningButton("Today", kind: .deadline, target: .today)
      planningButton("Tomorrow", kind: .deadline, target: .tomorrow)
      planningButton("Next Monday", kind: .deadline, target: .upcomingMonday)
      planningButton("Next Month", kind: .deadline, target: .nextMonth)
    } label: {
      Label("Deadline", systemImage: "calendar.badge.clock")
    }

    Menu {
      priorityButton("A", priority: "A")
      priorityButton("B", priority: "B")
      priorityButton("C", priority: "C")
      Divider()
      priorityButton("Clear", priority: nil)
    } label: {
      Label("Priority", systemImage: "flag")
    }

    Button {
      select()
      Task { await store.applyAgentHandoffShortcut(to: location) }
    } label: {
      Label("Pass to Agent", systemImage: "person.crop.circle.badge.checkmark")
    }

    Button {
      select()
      Task { await store.applyApproveAndAgentHandoffShortcut(to: location) }
    } label: {
      Label("Approve & Hand Off", systemImage: "checkmark.seal")
    }

    Button {
      select()
      store.promptAndApplyRejectApprovalShortcut(to: location)
    } label: {
      Label("Reject", systemImage: "xmark.octagon")
    }
  }

  private func todoButton(_ title: String, status: TodoEditStatus) -> some View {
    Button(title) {
      select()
      Task { await store.applyTodoShortcut(status, to: location) }
    }
  }

  private func planningButton(_ title: String, kind: PlanningEditKind, target: PlanningDateTarget) -> some View {
    Button(title) {
      select()
      Task { await store.applyPlanningShortcut(kind: kind, target: target, to: location) }
    }
  }

  private func priorityButton(_ title: String, priority: String?) -> some View {
    Button(title) {
      select()
      Task { await store.applyPriorityShortcut(priority, to: location) }
    }
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

      if store.isScanningCorpusFiles || store.isFilteringQuickOpenFiles {
        HStack(spacing: 8) {
          WorkspaceActivityIndicator(size: .small)
          Text(store.isScanningCorpusFiles ? "Scanning files" : "Searching files")
            .foregroundStyle(.secondary)
            .workspaceShimmer()
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
            .contextMenu {
              CorpusFileContextMenu(file: file) {
                store.isQuickOpenPresented = false
                dismiss()
              }
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

private struct SimilarTodoAssignmentView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  @FocusState private var assigneeFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Assign Similar TODOs")
            .font(.title2.weight(.semibold))
          Text("\(store.selectedSimilarTodoCandidateIDs.count) of \(store.similarTodoCandidates.count) selected")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button {
          store.isSimilarTodoAssignmentPresented = false
          dismiss()
        } label: {
          Label("Close", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut(.cancelAction)
      }

      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
        GridRow {
          Text("Pattern")
            .foregroundStyle(.secondary)
          TextField("find valid contact for {{target}}", text: $store.similarTodoPattern)
            .textFieldStyle(.roundedBorder)
        }
        GridRow {
          Text("Assignee")
            .foregroundStyle(.secondary)
          TextField("contact-finder", text: $store.similarTodoAssignee)
            .textFieldStyle(.roundedBorder)
            .focused($assigneeFocused)
        }
        GridRow {
          Text("Status")
            .foregroundStyle(.secondary)
          TextField("ready", text: $store.similarTodoStatus)
            .textFieldStyle(.roundedBorder)
        }
      }

      List {
        ForEach(store.similarTodoCandidates) { candidate in
          SimilarTodoCandidateRow(candidate: candidate)
            .contentShape(Rectangle())
            .onTapGesture {
              store.toggleSimilarTodoCandidateSelection(candidate)
            }
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 300)

      HStack(spacing: 8) {
        Button {
          store.selectedSimilarTodoCandidateIDs = Set(store.similarTodoCandidates.map(\.id))
        } label: {
          Label("All", systemImage: "checkmark.square")
        }

        Button {
          store.selectedSimilarTodoCandidateIDs = []
        } label: {
          Label("None", systemImage: "square")
        }

        Spacer(minLength: 0)

        Button {
          Task { await store.assignSimilarTodos(askOpenClaw: false) }
        } label: {
          Label("Assign", systemImage: "person.crop.circle.badge.checkmark")
        }
        .disabled(store.selectedSimilarTodoCandidateIDs.isEmpty)

        Button {
          Task { await store.assignSimilarTodos(askOpenClaw: true) }
        } label: {
          Label("Assign & Ask OpenClaw", systemImage: "sparkles")
        }
        .keyboardShortcut(.defaultAction)
        .disabled(store.selectedSimilarTodoCandidateIDs.isEmpty)
      }
    }
    .padding(18)
    .frame(width: 760, height: 560)
    .onAppear {
      assigneeFocused = store.similarTodoAssignee.isEmpty
    }
  }
}

private struct SimilarTodoCandidateRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let candidate: SimilarTodoCandidate

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: store.selectedSimilarTodoCandidateIDs.contains(candidate.id) ? "checkmark.square.fill" : "square")
        .foregroundStyle(store.selectedSimilarTodoCandidateIDs.contains(candidate.id) ? Color.accentColor : Color.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          if let todo = candidate.todo {
            Text(todo)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text(Org2Display.cleanInline(candidate.headline))
            .font(.body.weight(.medium))
            .lineLimit(1)
        }
        HStack(spacing: 8) {
          Text(store.relativePath(candidate.file) + ":\(candidate.line)")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Text("\(Int(candidate.score * 100))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
          if let assignee = candidate.properties["ASSIGNEE"], !assignee.isEmpty {
            Text("assigned: \(assignee)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
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
            ShortcutHelpItem(keys: "⌘1", action: "Home"),
            ShortcutHelpItem(keys: "⌘2", action: "Agenda"),
            ShortcutHelpItem(keys: "⌘3", action: "Files"),
            ShortcutHelpItem(keys: "⌘4", action: "Approvals"),
            ShortcutHelpItem(keys: "⌘⇧F", action: "Corpus search"),
            ShortcutHelpItem(keys: "⌘5", action: "Meetings"),
            ShortcutHelpItem(keys: "⌘6", action: "OpenClaw Chat"),
            ShortcutHelpItem(keys: "⌘P / ⌘K", action: "Quick Open"),
            ShortcutHelpItem(keys: "⌘0", action: "Open OpenClaw Chat"),
            ShortcutHelpItem(keys: "⌘? / ⌘/", action: "Show shortcuts")
          ])

          ShortcutSection(title: "Page", shortcuts: [
            ShortcutHelpItem(keys: "⌘F", action: "Find in current page"),
            ShortcutHelpItem(keys: "Esc", action: "Clear selected block")
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
            ShortcutHelpItem(keys: "1 2 3 4", action: "Agenda mode"),
            ShortcutHelpItem(keys: "/", action: "Filter agenda"),
            ShortcutHelpItem(keys: "o / Return", action: "Open item"),
            ShortcutHelpItem(keys: "e", action: "Edit item source"),
            ShortcutHelpItem(keys: "⌘A / ⌘⇧A", action: "Select visible / clear bulk selection"),
            ShortcutHelpItem(keys: "⇧↑ / ⇧↓", action: "Bulk select previous / next"),
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
      HeaderBar(title: "Agenda", subtitle: headerSubtitle, surface: .agenda) {
        if store.agendaMode == .assigned ? store.isLoadingAssignedWork : store.isLoadingAgenda {
          WorkspaceActivityIndicator(size: .small)
        }
      }

      if let error = store.errorText, store.agenda == nil {
        EmptyStateView(title: "Agenda Failed", detail: error, action: "Refresh") {
          Task { await store.refreshAgenda() }
        }
      } else if let agenda = store.agenda {
        AgendaControls(agendaFilterFocused: $agendaFilterFocused)

        if store.agendaMode == .assigned {
          AssignedAgendaSummaryView(count: store.visibleAssignedWorkItems.count)
        } else {
          AgendaSummaryView(agenda: agenda)
        }
        Divider()
        AgendaListView()
      } else {
        EmptyStateView(title: "No Agenda", detail: store.statusText, action: "Open Corpus") {
          store.chooseCorpus()
        }
      }
    }
    .onChange(of: store.agendaMode) {
      if store.agendaMode == .assigned {
        Task {
          await store.refreshAssignedWork()
          store.syncAssignedAgendaSelectionAfterDisplayOptionsChange()
        }
      } else {
        store.syncAgendaSelectionAfterDisplayOptionsChange()
      }
    }
    .onChange(of: store.agendaFilter) {
      store.syncAgendaSelectionAfterDisplayOptionsChange()
    }
    .onChange(of: store.agendaFilterFocusToken) {
      agendaFilterFocused = true
    }
    .onChange(of: agendaFilterFocused) {
      store.isAgendaFilterFocused = agendaFilterFocused
    }
    .onChange(of: store.isAgendaFilterFocused) {
      agendaFilterFocused = store.isAgendaFilterFocused
    }
    .onDisappear {
      store.isAgendaFilterFocused = false
    }
  }

  private var headerSubtitle: String {
    if store.agendaMode == .assigned {
      return "\(store.visibleAssignedWorkItems.count) all-time item\(store.visibleAssignedWorkItems.count == 1 ? "" : "s")"
    }
    return store.agenda.map { "\($0.range.start) to \($0.range.end)" } ?? "Agenda"
  }
}

private struct AgendaControls: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var isShowingOpenClawConfiguration = false
  var agendaFilterFocused: FocusState<Bool>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Picker("Mode", selection: $store.agendaMode) {
          ForEach(AgendaMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)

        Spacer(minLength: 0)

        if store.agendaMode == .assigned {
          Button {
            isShowingOpenClawConfiguration = true
          } label: {
            Label("Assignees", systemImage: "person.2")
          }
          .buttonStyle(WorkspaceActionButtonStyle())
          .help("Configure which ASSIGNEE names count as you")
        }

        Button {
          store.promptAndCaptureTodoShortcut()
        } label: {
          Label("Capture", systemImage: "square.and.pencil")
        }
        .buttonStyle(WorkspaceActionButtonStyle())
      }

      HStack(spacing: 8) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .font(.caption)
          .foregroundStyle(.tertiary)
        TextField("Filter agenda", text: $store.agendaFilter)
          .textFieldStyle(.roundedBorder)
          .focused(agendaFilterFocused)
          .onSubmit {
            agendaFilterFocused.wrappedValue = false
          }

        if !store.agendaFilter.isEmpty {
          Button {
            store.clearAgendaFilter()
          } label: {
            Label("Clear", systemImage: "xmark.circle.fill")
          }
          .labelStyle(.iconOnly)
          .help("Clear agenda filter")
        }
      }
    }
    .controlSize(.small)
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
    .sheet(isPresented: $isShowingOpenClawConfiguration) {
      OpenClawConfigurationSheet()
        .environmentObject(store)
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

private struct AssignedAgendaSummaryView: View {
  let count: Int

  var body: some View {
    HStack(spacing: 10) {
      MetricView(title: "All Time", value: "\(count)")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
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
        .lineLimit(1)
      Text(title)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
    VStack(spacing: 0) {
      if store.agendaMode != .assigned, store.hasBulkAgendaSelection {
        AgendaBulkActionBar()
      }

      if store.agendaMode == .assigned {
        AssignedAgendaListView()
      } else {
        AgendaItemListView()
      }
    }
  }
}

private struct ApprovalsView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @FocusState private var filterFocused: Bool
  @State private var discussionItem: ApprovalItem?
  @State private var discussionMessage = "I need to discuss this approval item before deciding."

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Approvals", subtitle: headerSubtitle, surface: .approvals) {
        if store.isLoadingApprovals {
          WorkspaceActivityIndicator(size: .small)
        }
      }

      ApprovalControls(filterFocused: $filterFocused)

      HStack(spacing: 10) {
        MetricView(title: "Visible", value: "\(store.visibleApprovalItems.count)")
        MetricView(title: "Total", value: "\(store.approvalItems.count)")
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 12)

      Divider()

      approvalList
    }
    .sheet(item: $discussionItem) { item in
      ApprovalDiscussionSheet(item: item, message: $discussionMessage)
        .environmentObject(store)
    }
    .onAppear {
      if store.approvalItems.isEmpty && !store.isLoadingApprovals {
        Task { await store.refreshApprovals() }
      }
    }
    .onChange(of: store.selectedApprovalItemID) {
      guard let id = store.selectedApprovalItemID,
            let item = store.visibleApprovalItems.first(where: { $0.id == id })
      else {
        return
      }
      store.selectApprovalItem(item)
    }
  }

  private var headerSubtitle: String {
    "\(store.visibleApprovalItems.count) pending approval\(store.visibleApprovalItems.count == 1 ? "" : "s")"
  }

  @ViewBuilder
  private var approvalList: some View {
    if let error = store.errorText, store.approvalItems.isEmpty {
      EmptyStateView(title: "Approvals Failed", detail: error, action: "Refresh") {
        Task { await store.refreshApprovals(updatesStatus: true) }
      }
    } else if store.isLoadingApprovals && store.approvalItems.isEmpty {
      Spacer()
      WorkspaceLoadingStateView("Loading approvals")
      Spacer()
    } else if store.visibleApprovalItems.isEmpty {
      EmptyStateView(title: "No Approvals", detail: "No pending approval candidates matched.", action: "Refresh") {
        Task { await store.refreshApprovals(updatesStatus: true) }
      }
    } else {
      List(selection: $store.selectedApprovalItemID) {
        ForEach(store.visibleApprovalItems) { item in
          ApprovalRow(item: item) {
            discussionMessage = "I need to discuss this approval item before deciding."
            discussionItem = item
          }
          .tag(item.id)
          .contentShape(Rectangle())
          .onTapGesture {
            store.selectApprovalItem(item)
          }
          .contextMenu {
            WorkspaceLocationContextMenu(
              location: .agenda(item.agendaItem()),
              showsHeadingActions: true,
              select: { store.selectApprovalItem(item) }
            ) {
              Label("Open", systemImage: "checkmark.seal")
            }
            Divider()
            Button {
              Task { await store.approve(item) }
            } label: {
              Label("Approve", systemImage: "checkmark")
            }
            .disabled(store.isApprovalActionInProgress(item))
            Button {
              discussionMessage = "I need to discuss this approval item before deciding."
              discussionItem = item
            } label: {
              Label("Discuss via OpenClaw", systemImage: "paperplane")
            }
            Button {
              store.copyApprovalDiscussionText(item)
            } label: {
              Label("Copy Discussion Text", systemImage: "doc.on.doc")
            }
          }
        }
      }
      .listStyle(.inset)
    }
  }
}

private struct ApprovalControls: View {
  @EnvironmentObject private var store: WorkspaceStore
  var filterFocused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .font(.caption)
        .foregroundStyle(.tertiary)
      TextField("Filter approvals", text: $store.approvalFilter)
        .textFieldStyle(.roundedBorder)
        .focused(filterFocused)
        .onSubmit {
          filterFocused.wrappedValue = false
        }
      if !store.approvalFilter.isEmpty {
        Button {
          store.clearApprovalFilter()
        } label: {
          Label("Clear", systemImage: "xmark.circle.fill")
        }
        .labelStyle(.iconOnly)
        .help("Clear approval filter")
      }
    }
    .controlSize(.small)
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
  }
}

private struct ApprovalRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let item: ApprovalItem
  let discuss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        StatusPill(text: item.status)
        Text(Org2Display.cleanInline(item.title))
          .font(.body.weight(.semibold))
          .lineLimit(2)
      }

      if !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(Org2Display.cleanBlock(item.body).trimmedForDisplay(maxCharacters: 220))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      HStack(spacing: 8) {
        if let todo = item.todo {
          StatusPill(text: todo)
        }
        Label("\(store.relativePath(item.file)):\(item.line)", systemImage: "doc.text")
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 6) {
        Button {
          Task { await store.approve(item) }
        } label: {
          if store.isApprovingApproval(item) {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .mini)
              Text("Approving")
            }
          } else {
            Label("Approve", systemImage: "checkmark")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(store.isApprovalActionInProgress(item))

        Button {
          discuss()
        } label: {
          Label("Discuss", systemImage: "paperplane")
        }
        .buttonStyle(WorkspaceActionButtonStyle())

        Button {
          store.promptAndRejectApproval(item)
        } label: {
          if store.isRejectingApproval(item) {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .mini)
              Text("Rejecting")
            }
          } else {
            Label("Reject", systemImage: "xmark.octagon")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(store.isApprovalActionInProgress(item))

        Button {
          store.copyApprovalDiscussionText(item)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(WorkspaceActionButtonStyle())
      }
      .controlSize(.small)
    }
    .padding(.vertical, 6)
  }
}

private struct ApprovalDiscussionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: WorkspaceStore
  let item: ApprovalItem
  @Binding var message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        StatusPill(text: item.status)
        Text(Org2Display.cleanInline(item.title))
          .font(.headline)
          .lineLimit(2)
        Text("\(store.relativePath(item.file)):\(item.line)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Text("Message to OpenClaw")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      TextEditor(text: $message)
        .font(.body)
        .frame(minHeight: 120)
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(WorkspaceDesign.hairline)
        )

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        Button {
          Task {
            await store.discussApprovalInOpenClaw(item, message: message)
            dismiss()
          }
        } label: {
          Label("Discuss", systemImage: "paperplane")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(18)
    .frame(width: 460)
  }
}

private struct AgendaItemListView: View {
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
                store.handleAgendaItemClick(item, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
              }
              .contextMenu {
                WorkspaceLocationContextMenu(
                  location: .agenda(item),
                  showsHeadingActions: true,
                  select: { store.selectAgendaItem(item) }
                ) {
                  Label("Open", systemImage: "calendar")
                }

                Divider()

                Button {
                  store.toggleAgendaItemBulkSelection(item)
                } label: {
                  Label(
                    store.isAgendaItemBulkSelected(item) ? "Remove from Bulk Selection" : "Add to Bulk Selection",
                    systemImage: store.isAgendaItemBulkSelected(item) ? "minus.square" : "checkmark.square"
                  )
                }
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
      guard !store.consumeAgendaSelectionActivationSuppression() else {
        return
      }
      guard let id = store.selectedAgendaItemID,
            let item = store.visibleAgendaItems.first(where: { $0.id == id })
      else {
        return
      }
      store.selectAgendaItem(item)
    }
  }
}

private struct AssignedAgendaListView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    if store.isLoadingAssignedWork {
      Spacer()
      WorkspaceLoadingStateView("Loading assigned work")
      Spacer()
    } else {
      List(selection: $store.selectedAssignedWorkItemID) {
        ForEach(store.assignedWorkSections) { section in
          Section(section.label) {
            ForEach(section.items) { item in
              AssignedWorkRow(item: item)
                .tag(item.id)
                .contentShape(Rectangle())
                .onTapGesture {
                  store.selectAssignedWorkItem(item)
                }
                .contextMenu {
                  WorkspaceLocationContextMenu(
                    location: .assigned(item),
                    showsHeadingActions: true,
                    select: { store.selectAssignedWorkItem(item) }
                  ) {
                    Label("Open", systemImage: "person.crop.circle.badge.checkmark")
                  }
                }
            }
          }
        }

        if store.assignedWorkSections.isEmpty {
          Text("No all-time agenda items")
            .foregroundStyle(.secondary)
        }
      }
      .listStyle(.inset)
      .onChange(of: store.selectedAssignedWorkItemID) {
        guard let id = store.selectedAssignedWorkItemID,
              let item = store.assignedWorkItems.first(where: { $0.id == id })
        else {
          return
        }
        store.selectAssignedWorkItem(item)
      }
      .onAppear {
        if store.assignedWorkItems.isEmpty {
          Task {
            await store.refreshAssignedWork()
            store.syncAssignedAgendaSelectionAfterDisplayOptionsChange()
          }
        }
      }
    }
  }
}

private struct AgendaBulkActionBar: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    HStack(spacing: 8) {
      Label("\(store.bulkAgendaSelectionCount) selected", systemImage: "checkmark.square")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
        .monospacedDigit()

      Spacer(minLength: 0)

      Button {
        store.selectAllVisibleAgendaItemsForBulkAction()
      } label: {
        Label("Select Visible", systemImage: "checkmark.square")
      }
      .disabled(store.visibleAgendaItemCount == 0)

      Menu {
        Button("TODO") {
          Task { await store.applyTodoShortcut(.todo) }
        }
        Button("In Progress") {
          Task { await store.applyTodoShortcut(.inProgress) }
        }
        Button("Done") {
          Task { await store.applyTodoShortcut(.done) }
        }
        Button("Canceled") {
          Task { await store.applyTodoShortcut(.canceled) }
        }
      } label: {
        Label("Status", systemImage: "tag")
      }

      Button {
        Task { await store.applyTodoShortcut(.done) }
      } label: {
        Label("Done", systemImage: "checkmark.circle")
      }

      Button {
        Task { await store.applyAgentHandoffShortcut() }
      } label: {
        Label("Pass to Agent", systemImage: "paperplane")
      }

      Button {
        Task { await store.applyApproveAndAgentHandoffShortcut() }
      } label: {
        Label("Approve & Hand Off", systemImage: "checkmark.seal")
      }

      Button {
        store.promptAndApplyRejectApprovalShortcut()
      } label: {
        Label("Reject", systemImage: "xmark.octagon")
      }

      Button {
        store.clearAgendaBulkSelection()
      } label: {
        Label("Clear", systemImage: "xmark.circle")
      }
    }
    .controlSize(.small)
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.subtleFill)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

private struct AgendaRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let item: AgendaItem

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Button {
        store.toggleAgendaItemBulkSelection(item)
      } label: {
        Image(systemName: store.isAgendaItemBulkSelected(item) ? "checkmark.square.fill" : "square")
          .font(.body)
          .foregroundStyle(store.isAgendaItemBulkSelected(item) ? Color.accentColor : Color.secondary)
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(store.isAgendaItemBulkSelected(item) ? "Remove from bulk selection" : "Add to bulk selection")
      .padding(.top, 1)

      StatusPill(text: item.todo ?? "TASK")
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(Org2Display.cleanInline(item.headline))
            .font(.body.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
          if item.idValue != nil {
            Image(systemName: "link")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        HStack(spacing: 8) {
          Text([item.kind, item.time].compactMap { $0 }.joined(separator: " "))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
          Text(store.relativePath(item.file) + ":\(item.lineForEditor)")
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      AgendaAssignmentIndicator(item: item)
      if let effort = item.effort {
        Text(effort)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct AgendaAssignmentIndicator: View {
  @EnvironmentObject private var store: WorkspaceStore
  let item: AgendaItem

  private var assignee: String? {
    let trimmed = item.properties["ASSIGNEE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private var isAgentAssigned: Bool {
    store.isAgentAssignee(assignee)
  }

  private var label: String {
    assignee ?? "Me"
  }

  private var helpText: String {
    if isAgentAssigned, let assignee {
      return "Assigned to agent: \(assignee)"
    }
    if let assignee {
      return store.isPersonalAssignee(assignee) ? "Assigned to you: \(assignee)" : "Assigned to \(assignee)"
    }
    return "Assigned to you"
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: isAgentAssigned ? "sparkles" : "person")
        .font(.caption2.weight(.semibold))
      Text(label)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .foregroundStyle(isAgentAssigned ? Color.accentColor : Color.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(
      (isAgentAssigned ? Color.accentColor.opacity(0.12) : WorkspaceDesign.subtleFill),
      in: Capsule()
    )
    .help(helpText)
  }
}

private struct SearchView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @FocusState private var isSearchFocused: Bool
  @State private var expandedCorpusSearchFileIDs: Set<String> = []

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Search", subtitle: store.searchMode.subtitle, surface: .search) {
        if store.isSearching {
          WorkspaceActivityIndicator(size: .small)
        }

        Button {
          store.promptAndCreateKnowledgeNode()
        } label: {
          Label("New Node", systemImage: "plus.circle")
        }
      }

      HStack(spacing: 8) {
        Picker("Search mode", selection: $store.searchMode) {
          ForEach(WorkspaceSearchMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)

        TextField(store.searchMode.placeholder, text: $store.searchQuery)
          .textFieldStyle(.roundedBorder)
          .focused($isSearchFocused)
          .onSubmit {
            runSearchIfNeeded()
          }

        if store.searchMode == .text {
          Button {
            Task { await store.runSearch() }
          } label: {
            Label("Search", systemImage: "magnifyingglass")
          }
          .disabled(store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSearching)
        }
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)

      Text(store.searchMode.helpText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceDesign.contentInset)
        .padding(.top, 4)
        .padding(.bottom, 12)

      searchResultsBody
    }
    .onAppear {
      if store.selectedSurface == .search {
        isSearchFocused = true
      }
    }
    .onChange(of: store.searchFocusToken) {
      isSearchFocused = true
    }
    .onChange(of: store.searchResults.map(\.id)) {
      expandedCorpusSearchFileIDs = []
    }
  }

  @ViewBuilder
  private var searchResultsBody: some View {
    switch store.searchMode {
    case .text:
      if store.searchResults.isEmpty && store.openClawChatSearchResults.isEmpty {
        if store.isSearching {
          Spacer()
          WorkspaceLoadingStateView("Searching")
          Spacer()
        } else {
          EmptyStateView(title: "No Results", detail: searchEmptyStateDetail, action: "Search") {
            Task { await store.runSearch() }
          }
        }
      } else {
        List {
          if !store.openClawChatSearchResults.isEmpty {
            Section("Chat Threads") {
              ForEach(store.openClawChatSearchResults) { result in
                ChatSearchRow(result: result)
                  .contentShape(Rectangle())
                  .onTapGesture {
                    store.selectOpenClawChatSearchResult(result)
                  }
              }
            }
          }

          if !store.searchResults.isEmpty {
            Section("Corpus") {
              ForEach(store.corpusSearchResultGroups) { group in
                let representative = group.representative
                SearchRow(
                  result: representative,
                  matchCount: group.results.count > 1 ? group.results.count : nil,
                  isExpanded: group.results.count > 1 ? expandedCorpusSearchFileIDs.contains(group.id) : nil,
                  toggleExpansion: {
                    toggleCorpusSearchGroup(group)
                  }
                )
                  .contentShape(Rectangle())
                  .onTapGesture {
                    store.select(.search(representative))
                  }
                  .contextMenu {
                    WorkspaceLocationContextMenu(
                      location: .search(representative),
                      showsHeadingActions: representative.todo != nil,
                      select: { store.select(.search(representative)) }
                    ) {
                      Label("Open", systemImage: "magnifyingglass")
                    }
                  }

                if expandedCorpusSearchFileIDs.contains(group.id) {
                  ForEach(Array(group.results.dropFirst())) { result in
                    SearchRow(result: result, isNested: true)
                      .contentShape(Rectangle())
                      .onTapGesture {
                        store.select(.search(result))
                      }
                      .contextMenu {
                        WorkspaceLocationContextMenu(
                          location: .search(result),
                          showsHeadingActions: result.todo != nil,
                          select: { store.select(.search(result)) }
                        ) {
                          Label("Open", systemImage: "magnifyingglass")
                        }
                      }
                  }
                }
              }
            }
          }
        }
        .listStyle(.inset)
      }
    case .nodes:
      let nodes = store.searchNodes
      if nodes.isEmpty {
        EmptyStateView(title: "No Nodes", detail: nodeEmptyStateDetail, action: "Refresh Index") {
          Task { await store.refreshCorpusFiles() }
        }
      } else {
        List(nodes) { node in
          NodeSearchRow(node: node)
            .contentShape(Rectangle())
            .onTapGesture {
              store.selectSearchNode(node)
            }
            .contextMenu {
              NodeSearchContextMenu(node: node)
            }
        }
        .listStyle(.inset)
      }
    }
  }

  private var searchEmptyStateDetail: String {
    if store.corpusRoot == nil { return "Open a corpus to search its org files." }
    if store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Enter text to search the corpus."
    }
    return store.statusText
  }

  private var nodeEmptyStateDetail: String {
    if store.corpusRoot == nil { return "Open a corpus to search node titles, aliases, and IDs." }
    if store.orgRoamLinkResolver.nodes.isEmpty {
      return "No nodes are indexed yet. Add org files with file-level titles, IDs, or aliases."
    }
    return "No indexed node matched this query."
  }

  private func runSearchIfNeeded() {
    guard store.searchMode == .text else { return }
    Task { await store.runSearch() }
  }

  private func toggleCorpusSearchGroup(_ group: SearchResultGroup) {
    if expandedCorpusSearchFileIDs.contains(group.id) {
      expandedCorpusSearchFileIDs.remove(group.id)
    } else {
      expandedCorpusSearchFileIDs.insert(group.id)
    }
  }
}

private struct ChatSearchRow: View {
  let result: OpenClawChatSearchResult

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "bubble.left.and.bubble.right", tint: .accentColor, fill: Color.accentColor.opacity(0.10))
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(result.title)
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          Text("\(result.messageCount) message\(result.messageCount == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(result.snippet)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(Self.relativeDate(result.updatedAt))
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

private struct SearchRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let result: SearchResult
  var isNested = false
  var matchCount: Int?
  var isExpanded: Bool?
  var toggleExpansion: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if let isExpanded {
        Button {
          toggleExpansion?()
        } label: {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .frame(width: 16, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isExpanded ? "Collapse file matches" : "Show file matches")
      } else if isNested {
        Spacer()
          .frame(width: 16)
      }
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
          if let matchCount {
            Text("\(matchCount) matches")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkspaceDesign.subtleFill, in: Capsule())
          }
        }
        Text(Org2Display.cleanInline(result.snippet))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          Text(store.relativePath(result.file) + ":\(result.lineForEditor)")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
      }
    }
    .padding(.leading, WorkspaceDesign.contentInset + (isNested ? 24 : 0))
    .padding(.trailing, WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct NodeSearchRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let node: OrgRoamNodeReference

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "link")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(Org2Display.cleanInline(node.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          if node.idValue != nil {
            Image(systemName: "number")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }

        if !node.aliases.isEmpty {
          Text(node.aliases.joined(separator: ", "))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        HStack(spacing: 8) {
          Text(store.relativePath(node.file) + ":\(node.line)")
            .lineLimit(1)
            .truncationMode(.middle)
          if let idValue = node.idValue {
            Text(shortID(idValue))
              .fixedSize(horizontal: true, vertical: false)
          }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }

  private func shortID(_ idValue: String) -> String {
    idValue.count > 12 ? String(idValue.prefix(12)) + "..." : idValue
  }
}

private struct NodeSearchContextMenu: View {
  @EnvironmentObject private var store: WorkspaceStore
  let node: OrgRoamNodeReference

  var body: some View {
    Button {
      store.selectSearchNode(node)
    } label: {
      Label("Open", systemImage: "link")
    }

    Button {
      store.openFileInEditor(path: node.file, line: node.line)
    } label: {
      Label("Open in Editor", systemImage: "arrow.up.forward.app")
    }

    Button {
      store.revealFile(path: node.file)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }

    Button {
      store.copyFileReference(path: node.file, line: node.line)
    } label: {
      Label("Copy Reference", systemImage: "doc.on.doc")
    }

    Divider()

    Button {
      store.selectSearchNode(node)
      store.askOpenClawAboutCurrentSelection()
    } label: {
      Label("Ask OpenClaw", systemImage: "sparkles")
    }

    Button {
      store.selectSearchNode(node)
      Task { await store.briefCurrentNodeInOpenClaw() }
    } label: {
      Label("Brief Node", systemImage: "doc.text.magnifyingglass")
    }

    Button {
      store.selectSearchNode(node)
      Task { await store.linkifyCurrentFile() }
    } label: {
      Label("Linkify File", systemImage: "link")
    }
  }
}

private struct MeetingsView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Meetings", subtitle: "\(store.meetings.count) local meeting\(store.meetings.count == 1 ? "" : "s")", surface: .meetings) {
        if store.isLoadingMeetings || store.isProcessingMeeting {
          WorkspaceActivityIndicator(size: .small)
        }

        if store.isRecordingMeeting {
          Button {
            Task {
              if store.isMeetingRecordingPaused {
                await store.resumeMeetingRecording()
              } else {
                await store.pauseMeetingRecording()
              }
            }
          } label: {
            Label(
              store.isMeetingRecordingPaused ? "Resume" : "Pause",
              systemImage: store.isMeetingRecordingPaused ? "play.fill" : "pause.fill"
            )
          }

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
          .disabled(store.corpusRoot == nil)
        }

        Button {
          store.promptAndImportMeetingAudio()
        } label: {
          Label("Import", systemImage: "tray.and.arrow.down")
        }
        .disabled(store.corpusRoot == nil || store.isRecordingMeeting)
      }

      VStack(alignment: .leading, spacing: 8) {
        TextField("Meeting title", text: $store.meetingTitleDraft)
          .textFieldStyle(.roundedBorder)
          .disabled(store.isRecordingMeeting)

        HStack(spacing: 10) {
          Text(store.meetingStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)

          Spacer(minLength: 0)

          MeetingInputStatusView(
            isRecording: store.isRecordingMeeting,
            isPaused: store.isMeetingRecordingPaused,
            averageLevel: store.meetingInputAverageLevel,
            peakLevel: store.meetingInputPeakLevel,
            systemAverageLevel: store.meetingSystemAudioAverageLevel,
            systemPeakLevel: store.meetingSystemAudioPeakLevel,
            isCapturingSystemAudio: store.isCapturingSystemAudio,
            systemAudioStatusText: store.meetingSystemAudioStatusText,
            sourceText: store.meetingCaptureSourceText
          )
        }

        if store.isProcessingMeeting {
          MeetingTranscriptionProgressView(
            progress: store.meetingTranscriptionProgress,
            elapsedText: store.meetingTranscriptionElapsedText,
            backendText: LocalWhisperTranscriber.resolvedBackendDescription()
          )
        }

        AudioSettingsSection()
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 12)

      if store.meetings.isEmpty && store.pendingMeetingProcessingItems.isEmpty {
        if store.isLoadingMeetings {
          Spacer()
          WorkspaceLoadingStateView("Loading meetings")
          Spacer()
        } else {
          EmptyStateView(title: "No Meetings", detail: store.meetingStatusText, action: "Record") {
            store.promptAndStartMeetingRecording()
          }
        }
      } else {
        List(selection: $store.selectedMeetingID) {
          if !store.pendingMeetingProcessingItems.isEmpty {
            Section("Processing") {
              ForEach(store.pendingMeetingProcessingItems) { item in
                MeetingProcessingRow(item: item)
              }
            }
          }

          ForEach(store.meetingDisplaySections) { section in
            Section(section.label) {
              ForEach(section.meetings) { meeting in
                MeetingRow(meeting: meeting, isProcessing: store.isMeetingProcessing(meeting))
                  .tag(meeting.id)
                  .contentShape(Rectangle())
                  .onTapGesture {
                    store.selectMeeting(meeting)
                  }
                  .contextMenu {
                    WorkspaceLocationContextMenu(
                      location: .meeting(meeting),
                      select: { store.selectMeeting(meeting) }
                    ) {
                      Label("Open", systemImage: "waveform.and.mic")
                    }
                    Divider()
                    Button(role: .destructive) {
                      store.confirmAndDeleteMeeting(meeting)
                    } label: {
                      Label("Delete Meeting", systemImage: "trash")
                    }
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

private struct AudioSettingsSection: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    DisclosureGroup(isExpanded: $store.isAudioSettingsExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        audioSettingsHeader

        Text(store.audioSettingsStatusText.isEmpty ? store.audioSettingsStatus.detailText : store.audioSettingsStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)

        HStack(alignment: .top, spacing: 8) {
          Image(systemName: store.workspaceRuntimeIdentity.isAppBundle ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(store.workspaceRuntimeIdentity.isAppBundle ? Color.green : Color.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(store.workspaceRuntimeIdentity.audioPermissionStatusLabel)
              .font(.caption.weight(.semibold))
            Text(store.workspaceRuntimeIdentity.audioPermissionDetailText)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          audioSettingRow("Active", store.audioSettingsStatus.backendDescription)
          audioSettingRow("App path", store.workspaceRuntimeIdentity.bundlePath)
          audioSettingRow("whisper.cpp", store.audioSettingsStatus.whisperCppExecutablePath ?? "Not installed")
          audioSettingRow("GGML model", store.audioSettingsStatus.whisperCppModelPath ?? "Missing")
          if let openAIWhisper = store.audioSettingsStatus.openAIWhisperExecutablePath {
            audioSettingRow("Python Whisper", openAIWhisper)
          }
          if let overrideCommand = store.audioSettingsStatus.overrideCommand {
            audioSettingRow("Override", overrideCommand)
          }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.top, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack(spacing: 8) {
        Label("Audio Settings", systemImage: "waveform")
        Text(store.audioSettingsStatus.statusLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  private var audioSettingsHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        audioSettingsStatusLabel
        Spacer(minLength: 8)
        audioSettingsActions
      }

      VStack(alignment: .leading, spacing: 8) {
        audioSettingsStatusLabel
        audioSettingsActions
      }
    }
  }

  private var audioSettingsStatusLabel: some View {
    HStack(spacing: 8) {
      Image(systemName: store.audioSettingsStatus.isWhisperCppReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(store.audioSettingsStatus.isWhisperCppReady ? Color.green : Color.orange)
      Text(store.audioSettingsStatus.statusLabel)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  private var audioSettingsActions: some View {
    HStack(spacing: 8) {
      Button {
        Task { await store.installFastMeetingTranscriber() }
      } label: {
        if store.isInstallingFastTranscriber {
          Label("Installing", systemImage: "arrow.down.circle")
        } else {
          Label("Install Fast Transcriber", systemImage: "bolt.fill")
        }
      }
      .disabled(store.isInstallingFastTranscriber || store.audioSettingsStatus.isWhisperCppReady)
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
  }

  private func audioSettingRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 78, alignment: .leading)
      Text(value)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MeetingTranscriptionProgressView: View {
  let progress: Double
  let elapsedText: String
  let backendText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ProgressView(value: progress)
        .progressViewStyle(.linear)
      HStack(spacing: 8) {
        Text("\(Int(progress * 100))%")
          .fontWeight(.semibold)
        if !elapsedText.isEmpty {
          Text("elapsed \(elapsedText)")
        }
        Text(backendText)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Meeting transcription progress")
    .help("Estimated local transcription progress. The bar caps at 95% until the local transcriber finishes.")
  }
}

private struct MeetingInputStatusView: View {
  let isRecording: Bool
  let isPaused: Bool
  let averageLevel: Double
  let peakLevel: Double
  let systemAverageLevel: Double
  let systemPeakLevel: Double
  let isCapturingSystemAudio: Bool
  let systemAudioStatusText: String
  let sourceText: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: isPaused ? "pause.fill" : (isRecording ? "waveform" : "mic"))
        .foregroundStyle(isPaused ? .orange : (isRecording ? .red : .secondary))

      if isRecording {
        VStack(alignment: .leading, spacing: 4) {
          MeetingInputMeterRow(
            label: isPaused ? "Paused" : "Mic",
            averageLevel: isPaused ? 0 : averageLevel,
            peakLevel: isPaused ? 0 : peakLevel
          )
          if isCapturingSystemAudio {
            MeetingInputMeterRow(
              label: "System",
              averageLevel: isPaused ? 0 : systemAverageLevel,
              peakLevel: isPaused ? 0 : systemPeakLevel
            )
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
          .truncationMode(.tail)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(isRecording ? (isPaused ? "Meeting recording paused" : "Meeting audio input levels") : sourceText)
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
        .frame(width: 48, alignment: .trailing)

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
  let isProcessing: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "waveform.and.mic")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(Org2Display.cleanInline(meeting.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          if isProcessing {
            HStack(spacing: 5) {
              WorkspaceActivityIndicator(size: .mini)
              StatusPill(text: "PROCESSING")
            }
          } else if let status = meeting.transcriptionStatus {
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

private struct MeetingProcessingRow: View {
  let item: MeetingProcessingItem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "waveform.and.mic", tint: .accentColor, fill: Color.accentColor.opacity(0.1))
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(Org2Display.cleanInline(item.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          HStack(spacing: 5) {
            WorkspaceActivityIndicator(size: .mini)
            StatusPill(text: "PROCESSING")
          }
        }

        Text(item.status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Processing \(item.title)")
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
  let surface: WorkspaceSurface?

  init(presentation: OpenClawChatPresentation = .fullPage, surface: WorkspaceSurface? = .openClaw) {
    self.presentation = presentation
    self.surface = surface
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      configurationStrip

      Divider()

      chatColumn
    }
    .sheet(isPresented: $isShowingConfiguration) {
      OpenClawConfigurationSheet()
        .environmentObject(store)
    }
  }

  private var chatColumn: some View {
    VStack(spacing: 0) {
      chatTranscript

      Divider()

      OpenClawComposerView(
        focusOnAppear: presentation == .fullPage,
        compact: presentation == .assistantPanel
      )
      .padding(presentation == .assistantPanel ? 10 : 16)
    }
  }

  @ViewBuilder
  private var header: some View {
    switch presentation {
    case .fullPage:
      HeaderBar(title: "OpenClaw Chat", subtitle: store.openClawStatusText, surface: surface) {
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
          WorkspaceActivityIndicator(size: .small)
        }
        Button {
          store.makeSurfacePrimary(.openClaw)
        } label: {
          Label("Make Primary", systemImage: "rectangle.split.2x1")
        }
        .labelStyle(.iconOnly)
        .help("Open OpenClaw Chat")

        Button {
          store.expandSurface(.openClaw)
        } label: {
          Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .labelStyle(.iconOnly)
        .help("Show only OpenClaw Chat")

        Button {
          store.closeSurfacePane(.openClaw)
        } label: {
          Label("Close", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .help("Close OpenClaw Chat")
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
      WorkspaceActivityIndicator(size: .small)
    }

    Button {
      store.createOpenClawChatThread()
    } label: {
      Label("New", systemImage: "plus")
    }
    .disabled(store.isSendingOpenClawMessage)

    Button {
      store.resetOpenClawChat()
    } label: {
      Label("Clear", systemImage: "trash")
    }
    .disabled(store.isSendingOpenClawMessage || store.openClawMessages.isEmpty)

    Button {
      isShowingConfiguration = true
    } label: {
      Label("Configure", systemImage: "slider.horizontal.3")
    }
  }

  @ViewBuilder
  private var configurationStrip: some View {
    if presentation == .fullPage {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Label("Chat", systemImage: "cpu")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
          TextField("main", text: $store.openClawAgentID)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
          Spacer(minLength: 0)
          Label(store.agentHandoffAssignee, systemImage: "person.crop.circle.badge.checkmark")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help("Handoff assignee")
        }

        HStack(spacing: 10) {
          configCaption(systemImage: "folder", text: store.openClawContextRootText)
          configCaption(systemImage: "network", text: store.openClawEndpointText)
        }
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 10)
    } else {
      HStack(spacing: 8) {
        TextField("Chat Agent", text: $store.openClawAgentID)
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

  private func configCaption(systemImage: String, text: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage)
        .font(.caption2.weight(.semibold))
      Text(text)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.caption)
    .foregroundStyle(.tertiary)
    .help(text)
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
        initialPosition: store.openClawChatScrollPosition(isAssistantPanel: presentation == .assistantPanel),
        onPositionChange: { position in
          store.recordOpenClawChatScrollPosition(position, isAssistantPanel: presentation == .assistantPanel)
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
    coordinator.recordCurrentPosition()
    coordinator.stopObserving()
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: OpenClawChatScrollPositionBridge
    private weak var scrollView: NSScrollView?
    private weak var observedClipView: NSClipView?
    private weak var observedDocumentView: NSView?
    private var didRestore = false
    private var isRestoring = false
    private var restoreAttempts = 0

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
          self.attemptRestore(from: view)
        }
      }
    }

    private func attemptRestore(from view: NSView) {
      guard !didRestore else {
        startObservingIfPossible(from: view)
        return
      }
      guard let scrollView = view.enclosingScrollView else {
        scheduleRestoreRetry(from: view)
        return
      }
      startObserving(scrollView)
      if restoreIfPossible(in: scrollView) {
        didRestore = true
      } else {
        scheduleRestoreRetry(from: view)
      }
    }

    private func scheduleRestoreRetry(from view: NSView) {
      restoreAttempts += 1
      guard restoreAttempts < 80 else {
        if let scrollView = view.enclosingScrollView {
          didRestore = true
          startObserving(scrollView)
        } else {
          self.startObservingIfPossible(from: view)
        }
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        self.attemptRestore(from: view)
      }
    }

    func recordCurrentPosition() {
      guard didRestore,
            !isRestoring,
            let scrollView
      else {
        return
      }
      parent.onPositionChange(Self.normalizedPosition(in: scrollView))
    }

    func stopObserving() {
      if let observedClipView {
        NotificationCenter.default.removeObserver(
          self,
          name: NSView.boundsDidChangeNotification,
          object: observedClipView
        )
        NotificationCenter.default.removeObserver(
          self,
          name: NSView.frameDidChangeNotification,
          object: observedClipView
        )
      }
      if let observedDocumentView {
        NotificationCenter.default.removeObserver(
          self,
          name: NSView.frameDidChangeNotification,
          object: observedDocumentView
        )
      }
      scrollView = nil
      observedClipView = nil
      observedDocumentView = nil
    }

    private func startObservingIfPossible(from view: NSView) {
      guard let scrollView = view.enclosingScrollView else { return }
      startObserving(scrollView)
    }

    private func startObserving(_ scrollView: NSScrollView) {
      let documentView = scrollView.documentView
      guard self.scrollView !== scrollView || observedDocumentView !== documentView else { return }
      stopObserving()
      self.scrollView = scrollView
      let clipView = scrollView.contentView
      observedClipView = clipView
      observedDocumentView = documentView
      clipView.postsBoundsChangedNotifications = true
      clipView.postsFrameChangedNotifications = true
      documentView?.postsFrameChangedNotifications = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(boundsDidChange(_:)),
        name: NSView.boundsDidChangeNotification,
        object: clipView
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(layoutDidChange(_:)),
        name: NSView.frameDidChangeNotification,
        object: clipView
      )
      if let documentView {
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(layoutDidChange(_:)),
          name: NSView.frameDidChangeNotification,
          object: documentView
        )
      }
    }

    @objc private func boundsDidChange(_ notification: Notification) {
      guard !isRestoring, let scrollView else { return }
      guard didRestore else {
        if restoreIfPossible(in: scrollView) {
          didRestore = true
        }
        return
      }
      parent.onPositionChange(Self.normalizedPosition(in: scrollView))
    }

    @objc private func layoutDidChange(_ notification: Notification) {
      guard !didRestore,
            !isRestoring,
            let scrollView,
            restoreIfPossible(in: scrollView)
      else {
        return
      }
      didRestore = true
    }

    private func restoreIfPossible(in scrollView: NSScrollView) -> Bool {
      restore(scrollView, to: parent.initialPosition ?? 1)
    }

    private func restore(_ scrollView: NSScrollView, to position: Double) -> Bool {
      guard let documentView = scrollView.documentView else { return false }
      let clipView = scrollView.contentView
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      guard maxY > 0 else { return false }

      let clamped = min(1, max(0, position))
      var origin = clipView.bounds.origin
      origin.y = documentView.isFlipped ? maxY * clamped : maxY * (1 - clamped)
      isRestoring = true
      clipView.scroll(to: origin)
      scrollView.reflectScrolledClipView(clipView)
      isRestoring = false
      parent.onPositionChange(clamped)
      return true
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
  @State private var handoffAssignee = ""
  @State private var personalAssigneeNames = ""
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
          Text("Chat Agent")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextField("main", text: $agent)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }

        GridRow {
          Text("Handoff Assignee")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextField("OpenClaw", text: $handoffAssignee)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }

        GridRow {
          Text("My Assignee Names")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            TextField("Avi, avi@example.com", text: $personalAssigneeNames)
              .textFieldStyle(.roundedBorder)
              .frame(width: 430)
            Text("Blank ASSIGNEE always counts as you. Separate aliases with commas, semicolons, or new lines.")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
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
            handoffAssignee: handoffAssignee,
            personalAssigneeNames: personalAssigneeNames,
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
      handoffAssignee = store.agentHandoffAssignee
      personalAssigneeNames = store.personalAssigneeNamesText
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

private struct AssignedWorkRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let item: AssignedWorkItem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "person.crop.circle.badge.checkmark")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          if let todo = item.todo, !todo.isEmpty {
            Text(todo)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text(Org2Display.cleanInline(item.headline))
            .font(.body.weight(.medium))
            .lineLimit(1)
        }
        HStack(spacing: 6) {
          Text(item.status)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
          Text(store.relativePath(item.file) + ":\(item.lineForEditor)")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let last = item.lastAgentUpdate ?? item.assignedAt {
            Text(last)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct DetailView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let location = store.selectedLocation {
        DetailHeader(location: location)
        Divider()
        VStack(spacing: 0) {
          ScrollViewReader { proxy in
            ScrollView {
              EntryBodyView(location: location)
                .background(DetailScrollCommandBridge(request: pageScrollRequest))
            }
            .onChange(of: store.detailScrollRequest) { _, request in
              scrollToBlockTarget(request, proxy: proxy)
            }
          }
          .frame(minWidth: 420, idealWidth: 560, maxHeight: .infinity)

          if store.isNodeContextPanePresented {
            Divider()
            NodeContextPane()
              .frame(minWidth: 280, idealHeight: 260, maxHeight: 360)
          }
        }
      } else {
        EmptyStateView(title: "No Selection", detail: store.statusText, action: "Open Corpus") {
          store.chooseCorpus()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var pageScrollRequest: DetailScrollRequest? {
    guard let request = store.detailScrollRequest,
          case .page = request.target
    else { return nil }
    return request
  }

  private func scrollToBlockTarget(_ request: DetailScrollRequest?, proxy: ScrollViewProxy) {
    guard case .block(let blockID) = request?.target else { return }
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 0.12)) {
        proxy.scrollTo(blockID, anchor: .center)
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
    guard case .page(let requestDirection) = request.target else { return }
    context.coordinator.lastRequestID = request.id

    DispatchQueue.main.async {
      guard let scrollView = view.enclosingScrollView,
            let documentView = scrollView.documentView
      else { return }

      let clipView = scrollView.contentView
      let visibleHeight = clipView.bounds.height
      guard visibleHeight > 0 else { return }

      let distance = max(120, visibleHeight * 0.8)
      let direction: CGFloat = requestDirection == .down ? 1 : -1
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
  @FocusState private var isPageSearchFocused: Bool
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

      detailActionBar

      if store.isPageSearchPresented {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Find in page", text: $store.pageSearchQuery)
            .textFieldStyle(.roundedBorder)
            .focused($isPageSearchFocused)
            .onSubmit {
              store.selectNextPageSearchOccurrence()
            }
          Text(store.pageSearchOccurrenceSummary)
            .font(.caption.monospacedDigit())
            .foregroundStyle(store.pageSearchOccurrenceCount == 0 ? .secondary : .primary)
            .frame(minWidth: 72, alignment: .trailing)
          Button {
            store.selectPreviousPageSearchOccurrence()
          } label: {
            Label("Previous Occurrence", systemImage: "chevron.up")
          }
          .labelStyle(.iconOnly)
          .help("Previous occurrence")
          .disabled(!store.canNavigatePageSearchOccurrences)
          Button {
            store.selectNextPageSearchOccurrence()
          } label: {
            Label("Next Occurrence", systemImage: "chevron.down")
          }
          .labelStyle(.iconOnly)
          .help("Next occurrence")
          .disabled(!store.canNavigatePageSearchOccurrences)
          if !store.pageSearchQuery.isEmpty {
            Button {
              store.clearRenderedSearchHighlight()
            } label: {
              Label("Clear Page Search", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .help("Clear page search")
          }
        }
        .frame(maxWidth: 560)
        .onAppear {
          isPageSearchFocused = true
        }
      }
    }
    .padding(WorkspaceDesign.contentInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkspaceDesign.barBackground)
    .onChange(of: store.pageSearchFocusToken) {
      isPageSearchFocused = true
    }
  }

  private var locationIcon: String {
    switch location {
    case .agenda:
      return "calendar"
    case .assigned:
      return "person.crop.circle.badge.checkmark"
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

  private var detailActionBar: some View {
    ViewThatFits(in: .horizontal) {
      fullDetailActionBar
      compactDetailActionBar
    }
    .controlSize(.small)
  }

  private var fullDetailActionBar: some View {
    HStack(spacing: 7) {
      detailNavigationControls
      Spacer(minLength: 8)
      scopeAndEditControls
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var compactDetailActionBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        detailNavigationControls
        Spacer(minLength: 0)
      }

      HStack(spacing: 7) {
        scopeAndEditControls
        Spacer(minLength: 0)
      }
    }
  }

  private var detailNavigationControls: some View {
    HStack(spacing: 7) {
      Button {
        store.navigateBackInDetail()
      } label: {
        Label("Back", systemImage: "chevron.left")
      }
      .labelStyle(.iconOnly)
      .disabled(!store.canNavigateBackInDetail)
      .help("Back")

      DetailPaneControlGroup()

      Divider()
        .frame(height: 18)

      sourceMenu
      intelligenceControls

      if store.hasRenderedSearchHighlight {
        Button {
          store.clearRenderedSearchHighlight()
        } label: {
          Label("Clear Highlight", systemImage: "xmark.circle")
        }
        .labelStyle(.iconOnly)
        .help("Clear search match highlights")
      }
    }
  }

  private var scopeAndEditControls: some View {
    HStack(spacing: 7) {
      scopePicker
      editControls
      organizeMenu
    }
  }

  private var sourceMenu: some View {
    Menu {
      Button {
        store.open(location)
      } label: {
        Label("Open Source", systemImage: "arrow.up.forward.square")
      }

      Button {
        store.revealSelectedLocation()
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }

      Divider()

      Button {
        Task { await store.linkifyCurrentFile() }
      } label: {
        Label("Linkify File", systemImage: "link.badge.plus")
      }
      .disabled(!store.canLinkifyCurrentFile)
    } label: {
      Label("Source", systemImage: "doc.text.magnifyingglass")
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("Open, reveal, or linkify this file")
  }

  private var intelligenceControls: some View {
    HStack(spacing: 6) {
      Button {
        store.askOpenClawAboutCurrentSelection()
      } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      .disabled(!store.canAskOpenClawAboutCurrentSelection || store.isLoadingEntrySource)
      .help("Ask OpenClaw about this page or entry")

      Button {
        store.toggleNodeContextPane()
      } label: {
        Label("Context", systemImage: "sidebar.right")
      }
      .help("Show or hide node context")

      Button {
        Task { await store.briefCurrentNodeInOpenClaw() }
      } label: {
        if store.isBuildingNodeBrief {
          Label("Brief", systemImage: "hourglass")
        } else {
          Label("Brief", systemImage: "text.bubble")
        }
      }
      .disabled(!store.canBriefCurrentNodeInOpenClaw)
      .help("Generate or open the cached node brief")

      if case .meeting = location {
        Button {
          store.askOpenClawAboutSelectedMeeting()
        } label: {
          Label("Meeting", systemImage: "waveform.and.mic")
        }
        .help("Ask OpenClaw about this meeting")
      }
    }
  }

  private var scopePicker: some View {
    Picker("Scope", selection: $store.selectedEntrySourceMode) {
      ForEach(EntrySourceMode.allCases) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 136)
    .fixedSize(horizontal: true, vertical: false)
    .onChange(of: store.selectedEntrySourceMode) {
      Task { await store.reloadSelectedEntrySource() }
    }
    .help("Render entry or full page scope")
  }

  @ViewBuilder
  private var editControls: some View {
    if store.hasActiveEdit {
      HStack(spacing: 6) {
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
      }
    } else {
      Button {
        store.beginEditingCurrentScope()
      } label: {
        Label("Edit", systemImage: "square.and.pencil")
      }
      .disabled(store.selectedEntrySource?.isEditable != true || store.isLoadingEntrySource)
    }
  }

  @ViewBuilder
  private var organizeMenu: some View {
    Menu {
      Menu {
        Button("TODO") {
          Task { await store.applyTodoShortcut(.todo) }
        }
        Button("In Progress") {
          Task { await store.applyTodoShortcut(.inProgress) }
        }
        Button("Done") {
          Task { await store.applyTodoShortcut(.done) }
        }
        Button("Canceled") {
          Task { await store.applyTodoShortcut(.canceled) }
        }
        Divider()
        Button {
          Task { await store.applyTodoShortcut(nil) }
        } label: {
          Label("Toggle", systemImage: "arrow.triangle.2.circlepath")
        }
      } label: {
        Label("Status", systemImage: "checkmark.circle")
      }

      Menu {
        planningButton("Today", kind: .scheduled, target: .today)
        planningButton("Tomorrow", kind: .scheduled, target: .tomorrow)
        planningButton("Next Monday", kind: .scheduled, target: .upcomingMonday)
        planningButton("Next Month", kind: .scheduled, target: .nextMonth)
      } label: {
        Label("Schedule", systemImage: "calendar")
      }

      Menu {
        planningButton("Today", kind: .deadline, target: .today)
        planningButton("Tomorrow", kind: .deadline, target: .tomorrow)
        planningButton("Next Monday", kind: .deadline, target: .upcomingMonday)
        planningButton("Next Month", kind: .deadline, target: .nextMonth)
      } label: {
        Label("Deadline", systemImage: "calendar.badge.exclamationmark")
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

      Divider()

      Button {
        store.presentSimilarTodoAssignment()
      } label: {
        Label("Find Similar TODOs...", systemImage: "rectangle.stack.badge.plus")
      }

      Button {
        Task { await store.applyAgentHandoffShortcut() }
      } label: {
        Label("Pass to Agent", systemImage: "person.crop.circle.badge.checkmark")
      }

      Button {
        Task { await store.applyApproveAndAgentHandoffShortcut() }
      } label: {
        Label("Approve & Hand Off", systemImage: "checkmark.seal")
      }

      Button {
        store.promptAndApplyRejectApprovalShortcut()
      } label: {
        Label("Reject", systemImage: "xmark.octagon")
      }

      Button {
        store.promptAndApplyPropertyShortcut()
      } label: {
        Label("Set Property", systemImage: "tag")
      }
    } label: {
      Label("Organize", systemImage: "ellipsis.circle")
    }
    .disabled(!store.canOrganizeCurrentHeadline)
    .help("Status, schedule, deadline, priority, agent handoff, and properties")
  }

  private func planningButton(_ title: String, kind: PlanningEditKind, target: PlanningDateTarget) -> some View {
    Button(title) {
      Task { await store.applyPlanningShortcut(kind: kind, target: target) }
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
          WorkspaceActivityIndicator(size: .small)
          Text("Loading source")
            .font(.callout)
            .foregroundStyle(.secondary)
            .workspaceShimmer()
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
            WorkspaceActivityIndicator(size: .small)
            Text("Rendering preview")
            .font(.callout)
            .foregroundStyle(.secondary)
            .workspaceShimmer()
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
            sourceBlockRuns: store.sourceBlockRuns,
            searchHighlightQuery: store.renderedSearchHighlightQuery
          )
          .equatable()
        }
      } else {
        fallbackBody(location)
      }
    }
    .padding(16)
    .contextMenu {
      Button {
        store.askOpenClawAboutCurrentSelection()
      } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      .disabled(!store.canAskOpenClawAboutCurrentSelection || store.isLoadingEntrySource)
    }
  }

  @ViewBuilder
  private func fallbackBody(_ location: WorkspaceLocation) -> some View {
    switch location {
    case .agenda(let item):
      Text(Org2Display.cleanBlock(item.body ?? ""))
        .font(.body)
        .textSelection(.enabled)
    case .assigned(let item):
      Text(Org2Display.cleanInline(item.headline))
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
    case .assigned(let item):
      let rows: [(String, String)] = [
        ("TODO", item.todo ?? ""),
        ("Assignee", item.assignee),
        ("Status", item.status),
        ("Assigned", item.assignedAt ?? ""),
        ("Last Update", item.lastAgentUpdate ?? ""),
        ("Tags", item.tags.joined(separator: ", "))
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

private struct NodeContextPane: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Label("Context", systemImage: "sidebar.right")
          .font(.headline)
        Spacer()
        if store.isLoadingBacklinks {
          WorkspaceActivityIndicator(size: .small)
        }
        Button {
          store.toggleNodeContextPane()
        } label: {
          Label("Hide Context", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .help("Hide context")
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.top, 12)
      .padding(.bottom, 8)

      Picker("Context view", selection: $store.nodeContextTab) {
        ForEach(NodeContextTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Context view")
      .frame(maxWidth: .infinity)
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 10)

      Divider()

      ScrollView {
        switch store.nodeContextTab {
        case .overview:
          NodeContextOverview()
        case .references:
          NodeContextReferences()
        case .related:
          NodeContextRelated()
        case .brief:
          NodeContextBrief()
        }
      }
    }
    .background(WorkspaceDesign.barBackground)
    .overlay(alignment: .leading) {
      Divider()
    }
  }
}

private struct NodeContextOverview: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      NodeContextStats()

      Button {
        Task { await store.briefCurrentNodeInOpenClaw() }
      } label: {
        if store.isBuildingNodeBrief {
          Label("Building Brief", systemImage: "hourglass")
        } else {
          Label("Brief This Node", systemImage: "text.bubble")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .disabled(!store.canBriefCurrentNodeInOpenClaw)

      if store.backlinkFileGroups.isEmpty {
        NodeContextEmptyText()
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("Top Referencing Files")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(store.backlinkFileGroups.prefix(8)) { group in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(group.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
              Spacer(minLength: 0)
              CountPill(count: group.count)
            }
            Text(group.relativePath)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
      }
    }
    .padding(WorkspaceDesign.contentInset)
  }
}

private struct NodeContextReferences: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    if store.backlinkFileGroups.isEmpty {
      NodeContextEmptyText()
        .padding(WorkspaceDesign.contentInset)
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(store.backlinkFileGroups) { group in
          BacklinkFileGroupRow(group: group)
          Divider()
            .padding(.leading, WorkspaceDesign.contentInset)
        }
      }
      .padding(.bottom, 8)
    }
  }
}

private struct NodeContextRelated: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    let items = store.relatedBacklinkNodes
    if items.isEmpty {
      Text("No high-signal related nodes yet. Generic sections like Summary, Details, and Raw transcript are hidden from this list.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(WorkspaceDesign.contentInset)
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
              WorkspaceIconBadge(systemImage: "link")
              VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                  .font(.callout.weight(.medium))
                  .lineLimit(2)
                Text(item.primaryPath)
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                ForEach(item.examples, id: \.self) { example in
                  Text(example)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
              Spacer(minLength: 0)
              VStack(alignment: .trailing, spacing: 4) {
                CountPill(count: item.referenceCount)
                Text(item.fileCount == 1 ? "1 file" : "\(item.fileCount) files")
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .monospacedDigit()
              }
            }
            if let idValue = item.idValue {
              Text(Org2Display.shortID(idValue))
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
          .padding(.horizontal, WorkspaceDesign.contentInset)
          .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
          Divider()
            .padding(.leading, WorkspaceDesign.contentInset)
        }
      }
    }
  }
}

private struct NodeContextBrief: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let artifact = store.currentNodeBriefArtifact {
        HStack(alignment: .top, spacing: 8) {
          WorkspaceIconBadge(systemImage: "doc.text")
          VStack(alignment: .leading, spacing: 3) {
            Text(artifact.title)
              .font(.headline)
            Text(artifact.relativePath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          Spacer(minLength: 0)
        }

        Button {
          store.openCurrentNodeBriefArtifact()
        } label: {
          Label("Open Full Brief", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(WorkspaceActionButtonStyle())

        Divider()

        NodeBriefRenderedPreview(
          artifact: artifact,
          corpusRoot: store.corpusRoot
        )
      } else {
        Text("Generate a source-cited brief for this node, save it into views/openclaw, and show it here.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button {
          Task { await store.briefCurrentNodeInOpenClaw() }
        } label: {
          if store.isBuildingNodeBrief {
            Label("Building Brief", systemImage: "hourglass")
          } else {
            Label("Brief This Node", systemImage: "text.bubble")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(!store.canBriefCurrentNodeInOpenClaw)

        Text("Generated briefs live as review-required org2 view artifacts.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(WorkspaceDesign.contentInset)
  }
}

private struct NodeBriefRenderedPreview: View {
  let artifact: NodeBriefArtifact
  let corpusRoot: URL?

  private var blocks: [OrgEditableBlock] {
    OrgEntryRenderer
      .parseEditable(artifact.body)
      .filter(OrgRenderedBlockDisplayPolicy.isVisible)
  }

  var body: some View {
    if artifact.body.isEmpty {
      Text("Brief artifact is present but has no body after metadata.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if blocks.isEmpty {
      OrgInlineText(artifact.body, font: .callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      LazyVStack(alignment: .leading, spacing: 5) {
        ForEach(blocks) { block in
          NodeBriefCompactBlockView(
            block: block,
            sourceFile: artifact.file,
            corpusRoot: corpusRoot
          )
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct NodeBriefCompactBlockView: View {
  let block: OrgEditableBlock
  let sourceFile: String
  let corpusRoot: URL?

  var body: some View {
    switch block.rendered {
    case .heading(let heading):
      Text(Org2Display.cleanInline(heading.title))
        .font(headingFont(level: heading.level))
        .fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, heading.level <= 1 ? 8 : 5)
    case .paragraph(let text):
      compactInlineText(block.rawText.isEmpty ? text : block.rawText)
        .font(.callout)
        .padding(.vertical, 1)
    case .listItem(let indent, let marker, let checkbox, let text):
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(listMarker(marker: marker, checkbox: checkbox))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(width: 20, alignment: .trailing)
        compactInlineText(text)
          .font(.callout)
      }
      .padding(.leading, CGFloat(max(0, indent)) * 12)
      .padding(.vertical, 2)
    case .quote(let lines):
      compactInlineText(lines.joined(separator: "\n"))
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 2)
        }
        .padding(.vertical, 4)
    case .planning(let planning):
      HStack(spacing: 6) {
        Text(planning.kind.capitalized)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(planning.value)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 1)
    case .keyword(let key, let value):
      if key.uppercased() != "TITLE" {
        HStack(spacing: 6) {
          Text(key.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
          Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    case .properties:
      EmptyView()
    case .horizontalRule:
      Divider()
        .padding(.vertical, 8)
    case .blank:
      Spacer()
        .frame(height: 3)
    case .source, .table:
      RenderedBlockView(
        block: block.rendered,
        rawText: block.rawText,
        editableBlock: nil,
        sourceFile: sourceFile,
        corpusRoot: corpusRoot,
        inlineActions: .readOnly
      )
      .font(.callout)
      .padding(.vertical, 4)
    }
  }

  private func compactInlineText(_ raw: String) -> some View {
    OrgInlineText(raw, font: .callout)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
  }

  private func headingFont(level: Int) -> Font {
    switch level {
    case ...1:
      return .headline
    case 2:
      return .callout
    default:
      return .caption.weight(.semibold)
    }
  }

  private func listMarker(marker: String, checkbox: OrgListCheckbox?) -> String {
    if let checkbox {
      return checkbox.rawMarker
    }
    if marker.range(of: #"^\d+[.)]$"#, options: .regularExpression) != nil {
      return marker
    }
    return "-"
  }
}

private struct NodeContextStats: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    HStack(spacing: 8) {
      StatTile(label: "Files", value: "\(store.backlinkFileCount)")
      StatTile(label: "Refs", value: "\(store.backlinkReferenceCount)")
      StatTile(label: "Related", value: "\(relatedCount)")
    }
  }

  private var relatedCount: Int {
    store.relatedBacklinkNodes.count
  }
}

private struct StatTile: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value)
        .font(.headline.monospacedDigit())
      Text(label)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

private struct CountPill: View {
  let count: Int

  var body: some View {
    Text("\(count)")
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}

private struct NodeContextEmptyText: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    Text(emptyText)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var emptyText: String {
    if store.isLoadingBacklinks { return "Loading backlinks..." }
    if store.backlinks == nil { return "No ID is available for this selection yet." }
    return "No backlinks found for this node."
  }
}

private struct BacklinkFileGroupRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let group: BacklinkFileGroup

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        store.toggleBacklinkFileGroup(group)
      } label: {
        HStack(alignment: .center, spacing: 8) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14)
          VStack(alignment: .leading, spacing: 3) {
            Text(group.displayTitle)
              .font(.callout.weight(.medium))
              .lineLimit(1)
            Text(group.relativePath)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
          CountPill(count: group.count)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.vertical, WorkspaceDesign.rowVerticalPadding)

      if isExpanded {
        ForEach(group.backlinks) { backlink in
          BacklinkRow(backlink: backlink, compact: true)
            .contentShape(Rectangle())
            .onTapGesture {
              store.selectBacklink(backlink)
            }
            .contextMenu {
              WorkspaceLocationContextMenu(
                location: .backlink(backlink),
                select: { store.selectBacklink(backlink) }
              ) {
                Label("Open", systemImage: "link")
              }
            }
          Divider()
            .padding(.leading, WorkspaceDesign.contentInset * 2)
        }
      } else if let first = group.backlinks.first {
        Text(Org2Display.cleanInline(first.context))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .padding(.horizontal, WorkspaceDesign.contentInset + 22)
          .padding(.bottom, 8)
      }
    }
  }

  private var isExpanded: Bool {
    store.expandedBacklinkFileIDs.contains(group.id)
  }
}

private struct BacklinkRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let backlink: BacklinkItem
  var compact = false

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
    .padding(.horizontal, compact ? WorkspaceDesign.contentInset + 22 : WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct HeaderBar<Trailing: View>: View {
  let title: String
  let subtitle: String
  let surface: WorkspaceSurface?
  @ViewBuilder let trailing: Trailing

  init(
    title: String,
    subtitle: String,
    surface: WorkspaceSurface? = nil,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.surface = surface
    self.trailing = trailing()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      headerContent(compact: false)
      headerContent(compact: true)
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .background(WorkspaceDesign.barBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func headerContent(compact: Bool) -> some View {
    HStack(alignment: .center, spacing: compact ? 8 : 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(compact ? .headline.weight(.semibold) : .title2.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)
          .allowsTightening(true)
          .layoutPriority(1)
        if !compact {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .frame(minWidth: compact ? 56 : 92, alignment: .leading)

      Spacer(minLength: compact ? 4 : 0)

      if compact {
        trailing
          .labelStyle(.iconOnly)
      } else {
        trailing
          .labelStyle(.titleAndIcon)
      }

    }
  }
}

private struct DetailPaneControlGroup: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    HStack(spacing: 6) {
      Button {
        store.toggleDetailPaneExpansion()
      } label: {
        Label(
          store.isWorkspaceSurfacePaneClosed ? "Restore Document" : "Expand Document",
          systemImage: store.isWorkspaceSurfacePaneClosed
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        )
      }
      .labelStyle(.iconOnly)
      .help(store.isWorkspaceSurfacePaneClosed ? "Restore document pane" : "Expand document pane")

      Button {
        store.closeDetailPane()
      } label: {
        Label("Close Document", systemImage: "xmark")
      }
      .labelStyle(.iconOnly)
      .help("Close document pane")
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
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
  let handler: (NSEvent, WorkspaceKeyboardShortcutScope) -> Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          let scope = WorkspaceKeyboardEventRouting.scope(
            for: event,
            textInputActive: Self.isTextInputActive
          )
          guard let scope else {
            return event
          }
          return handler(event, scope) ? nil : event
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

enum WorkspaceKeyboardEventRouting {
  static func scope(for event: NSEvent, textInputActive: Bool) -> WorkspaceKeyboardShortcutScope? {
    guard textInputActive else { return .all }
    return isCommandShortcut(event) ? .globalOnly : nil
  }

  static func isCommandShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    return modifiers == [.command] || modifiers == [.command, .shift] || modifiers == [.command, .option]
  }
}

private extension View {
  func keyboardEventMonitor(_ handler: @escaping (NSEvent, WorkspaceKeyboardShortcutScope) -> Bool) -> some View {
    modifier(KeyboardEventMonitor(handler: handler))
  }
}
