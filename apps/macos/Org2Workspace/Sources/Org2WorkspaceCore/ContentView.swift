import AppKit
import SwiftUI

@MainActor
private func performAfterSwiftUIViewUpdate(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  Task { @MainActor in
    await Task.yield()
    guard !Task.isCancelled else { return }
    operation()
  }
}

public struct ContentView: View {
  @EnvironmentObject private var store: WorkspaceStore

  public init() {}

  public var body: some View {
    GeometryReader { proxy in
      NavigationSplitView {
        SidebarView()
          .navigationSplitViewColumnWidth(
            min: WorkspaceSidebarLayout.minimumWidth,
            ideal: WorkspaceSidebarLayout.idealWidth,
            max: WorkspaceSidebarLayout.maximumWidth(for: proxy.size.width)
          )
      } detail: {
        WorkspaceMainArea()
      }
      .toolbar {
      ToolbarItem(placement: .navigation) {
        Button {
          store.navigateBack()
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .labelStyle(.iconOnly)
        .frame(width: 28, height: 28)
        .help(store.canNavigateBack ? "Back" : "No previous location")
      }

      ToolbarItemGroup {
        Button {
          store.makeSurfacePrimary(.openClaw)
        } label: {
          Label("Open AI Chat", systemImage: "bubble.left")
        }

        Button {
          store.chooseCorpus()
        } label: {
          Label("Mount Corpus", systemImage: "folder.badge.plus")
        }

        Button {
          if store.isRefreshingWorkspace {
            store.cancelWorkspaceRefresh()
          } else {
            Task { await store.refreshWorkspace() }
          }
        } label: {
          if store.isRefreshingWorkspace {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .small)
              Text("Cancel Refresh")
            }
          } else {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        }
        .disabled(store.corpusRoot == nil && !store.isRefreshingWorkspace)
        .help(store.isRefreshingWorkspace ? "Stop the current workspace refresh (⌘R)" : "Refresh the entire workspace (⌘R)")
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
      .sheet(isPresented: $store.isDataSourceConfigurationPresented) {
        DataSourceConfigurationSheet()
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
      .sheet(item: $store.editorSaveConflict, onDismiss: {
        store.keepEditingAfterSaveConflict()
      }) { conflict in
        EditorSaveConflictSheet(conflict: conflict)
          .environmentObject(store)
      }
      .alert(item: $store.slideExportNotice) { notice in
        Alert(
          title: Text(notice.title),
          message: Text(notice.message),
          dismissButton: .default(Text("OK"))
        )
      }
    }
  }
}

private struct EditorSaveConflictSheet: View {
  @EnvironmentObject private var store: WorkspaceStore
  let conflict: Org2EditorSaveConflict

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("File Changed on Disk", systemImage: "exclamationmark.triangle.fill")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.orange)

      Text("A newer version of this file was written after the editor loaded it. Your unsaved changes are still safe in the editor.")
        .fixedSize(horizontal: false, vertical: true)

      Text(store.relativePath(conflict.file))
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      if conflict.canOverwrite {
        Text("Reloading keeps the newer disk version and discards your editor draft. Overwriting saves your draft and first places the newer disk version in .org2-recovery.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Keep editing to copy anything you need, or reload the latest disk version. Overwrite is unavailable for a partial-file edit because it could replace unrelated changes.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        Button("Keep Editing") {
          store.keepEditingAfterSaveConflict()
        }
        Button("Reload from Disk", role: .destructive) {
          Task { await store.reloadAfterSaveConflict() }
        }
        if conflict.canOverwrite {
          Button("Overwrite with My Version", role: .destructive) {
            Task { await store.overwriteAfterSaveConflict() }
          }
        }
      }
    }
    .padding(20)
    .frame(width: 520)
  }
}

private struct WorkspaceMainArea: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    if store.corpusRoot == nil {
      CorpusOnboardingView()
    } else {
      HSplitView {
        if !store.isWorkspaceSurfacePaneClosed || !store.hasWorkspaceDetailContent {
          WorkspaceSurfaceCacheView(selectedSurface: store.selectedSurface)
            .frame(minWidth: 320, idealWidth: 460)
        }

        if store.hasWorkspaceDetailContent && !store.isWorkspaceDetailPaneClosed {
          WorkspaceDetailArea()
            .frame(minWidth: 520, idealWidth: 720)
        }
      }
    }
  }
}

private struct CorpusOnboardingView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    ScrollView {
      VStack(spacing: 26) {
        VStack(spacing: 12) {
          WorkspaceIconBadge(systemImage: "text.book.closed", tint: .accentColor, fill: Color.accentColor.opacity(0.12))
            .scaleEffect(1.45)
            .padding(.bottom, 4)
          Text("Welcome to Org2")
            .font(.largeTitle.weight(.semibold))
          Text("Connect a folder of Org or Org2 files, or create a small starter corpus. Your files stay ordinary plain text on disk.")
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 650)
        }

        HStack(alignment: .top, spacing: 18) {
          onboardingCard(
            title: "Open an existing corpus",
            detail: "Choose any folder containing .org2 or .org files. Org2 will scan it and derive agenda, search, graph, and workspace views.",
            systemImage: "folder",
            actionTitle: "Choose Folder"
          ) {
            store.chooseCorpus()
          }

          onboardingCard(
            title: "Create a new corpus",
            detail: "Choose or create an empty folder. Org2 will add a starter config, inbox, welcome note, daily notes folder, and reviewable output zones.",
            systemImage: "sparkles.rectangle.stack",
            actionTitle: "Create Starter Corpus"
          ) {
            store.createCorpus()
          }
        }
        .frame(maxWidth: 820)

        Button {
          store.createSharedCorpus()
        } label: {
          Label("Create a shared team corpus", systemImage: "person.2")
        }
        .help("Create an identified corpus intended to be mounted by multiple collaborators")

        VStack(spacing: 5) {
          Text("Already use Org Mode?")
            .font(.callout.weight(.semibold))
          Text("No migration is required. Open the folder you already have and adopt .org2 gradually if you want to.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        if !store.statusText.isEmpty && store.statusText != "No corpus selected" {
          Text(store.statusText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
        }
      }
      .padding(.horizontal, 36)
      .padding(.vertical, 56)
      .frame(maxWidth: .infinity)
    }
    .background(WorkspaceDesign.appBackground)
  }

  private func onboardingCard(
    title: String,
    detail: String,
    systemImage: String,
    actionTitle: String,
    perform: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      WorkspaceIconBadge(systemImage: systemImage, tint: .accentColor, fill: Color.accentColor.opacity(0.10))
      Text(title)
        .font(.title3.weight(.semibold))
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Button(actionTitle, action: perform)
        .buttonStyle(WorkspaceActionButtonStyle())
    }
    .padding(22)
    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(WorkspaceDesign.panelFill)
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(WorkspaceDesign.hairline, lineWidth: 1)
        )
    )
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
    context.coordinator.scheduleShow(surface: selectedSurface, in: view, store: store)
  }

  @MainActor
  final class Coordinator {
    private var hosts: [WorkspaceSurface: NSHostingView<AnyView>] = [:]
    private var activeSurface: WorkspaceSurface?
    private var activeConstraints: [NSLayoutConstraint] = []
    private var pendingShowTask: Task<Void, Never>?

    func scheduleShow(surface: WorkspaceSurface, in container: NSView, store: WorkspaceStore) {
      guard activeSurface != surface || hosts[surface]?.superview !== container else { return }
      pendingShowTask?.cancel()
      pendingShowTask = Task { @MainActor [weak self] in
        await Task.yield()
        guard !Task.isCancelled, let self else { return }
        self.pendingShowTask = nil
        self.show(surface: surface, in: container, store: store)
      }
    }

    private func show(surface: WorkspaceSurface, in container: NSView, store: WorkspaceStore) {
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
          .environment(\.openOrgFileReference) { reference in
            store.openChatFileReference(reference)
          }
      ))
      // The host is fully constrained to its container. Asking SwiftUI for an
      // intrinsic, minimum, and maximum size as well makes AppKit measure the
      // entire active surface during every constraint pass, which is
      // particularly expensive for corpus-scale Lists.
      host.sizingOptions = []
      host.translatesAutoresizingMaskIntoConstraints = false
      hosts[surface] = host
      return host
    }
  }
}

private struct WorkspaceSurfaceView: View {
  let surface: WorkspaceSurface

  var body: some View {
    GeometryReader { proxy in
      Group {
        switch surface {
        case .home:
          HomeView()
        case .agenda:
          AgendaView()
        case .approvals:
          RunsAndReviewView()
        case .files:
          FilesView()
        case .search:
          SearchView()
        case .meetings:
          MeetingsView()
        case .sources:
          SourcesView()
        case .openClaw:
          OpenClawChatView()
        }
      }
      // Some surface controls and rows have a useful minimum content width.
      // When the split pane becomes narrower, pin that overflow to the leading
      // edge so navigation and primary actions stay visible; any unavoidable
      // clipping then happens only at the trailing edge.
      .frame(
        width: max(0, proxy.size.width),
        height: max(0, proxy.size.height),
        alignment: .topLeading
      )
      .clipped()
    }
    .foregroundStyle(WorkspaceDesign.primaryText)
  }
}

private struct HomeView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    OpenClawChatView(presentation: .homePane, surface: .home)
      .onAppear {
        if store.selectedSurface == .home {
          store.ensureHomeDetailReady()
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
  @State private var showsCommandShortcuts = false

  var body: some View {
    let pinnedCorpusFiles = store.pinnedCorpusFiles
    VStack(spacing: 0) {
      SidebarHeader(showsCommandShortcuts: showsCommandShortcuts)

      List {
        Section("Workspace") {
          ForEach(WorkspaceSurface.sidebarCases) { surface in
            SidebarSurfaceRow(
              surface: surface,
              showsCommandShortcut: showsCommandShortcuts,
              notificationCount: surface == .approvals ? store.approvalItems.count : 0
            )
            .modifier(
              ReadableListSelectionModifier(
                isSelected: store.selectedSurface == surface,
                verticalPadding: 4
              )
            )
            .contentShape(Rectangle())
            .onTapGesture {
              guard surface != store.selectedSurface else { return }
              performAfterSwiftUIViewUpdate {
                guard surface != store.selectedSurface else { return }
                store.makeSurfacePrimary(surface)
              }
            }
            .listRowBackground(Color.clear)
            .help(surface.commandShortcutTitle.isEmpty ? surface.title : "\(surface.title) (\(surface.commandShortcutTitle))")
          }
        }

        if !pinnedCorpusFiles.isEmpty {
          Section("Pinned") {
            ForEach(pinnedCorpusFiles) { file in
              Button {
                store.openSidebarFile(file)
              } label: {
                SidebarPinnedFileRow(
                  file: file,
                  isSelected: store.selectedLocation?.file == file.path
                )
              }
              .buttonStyle(.plain)
              .contextMenu {
                CorpusFileContextMenu(file: file)
              }
              .help(file.relativePath)
            }
          }
        }

        Section("Daily") {
          ForEach(DailyNoteTarget.allCases) { target in
            Button {
              store.openDailyNoteFromSidebar(target)
            } label: {
              HStack(spacing: 8) {
                Label(target.title, systemImage: target == .today ? "sun.max" : "calendar")
                  .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                if showsCommandShortcuts {
                  KeyboardShortcutBadge(text: target.commandShortcutTitle)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(target.title) daily note (\(target.commandShortcutTitle))")
          }
        }

        Section("Chat") {
          OpenClawSidebarSurfaceGroup(showsCommandShortcut: showsCommandShortcuts)
        }
      }
      .listStyle(.sidebar)

      SidebarCorpusSwitcher()
    }
    .commandShortcutRevealMonitor($showsCommandShortcuts)
    .animation(WorkspaceMotion.quick, value: showsCommandShortcuts)
  }
}

private struct SidebarHeader: View {
  @EnvironmentObject private var store: WorkspaceStore
  let showsCommandShortcuts: Bool

  var body: some View {
    HStack(spacing: 8) {
      Text("Org2")
        .font(.headline.weight(.semibold))

      Spacer(minLength: 0)

      if showsCommandShortcuts {
        KeyboardShortcutBadge(text: WorkspaceSurface.search.commandShortcutTitle)
          .transition(.opacity.combined(with: .move(edge: .trailing)))
      }

      Button {
        store.focusSearchSurface()
      } label: {
        Label("Search", systemImage: "magnifyingglass")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .foregroundStyle(store.selectedSurface == .search ? Color.accentColor : WorkspaceDesign.secondaryText)
      .frame(width: 26, height: 26)
      .background(
        store.selectedSurface == .search ? WorkspaceDesign.selectedFill : Color.clear,
        in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
      )
      .help("Search workspace (\(WorkspaceSurface.search.commandShortcutTitle))")
    }
    .padding(.leading, 13)
    .padding(.trailing, 10)
    .padding(.top, 9)
    .padding(.bottom, 7)
  }
}

private struct SidebarCorpusSwitcher: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    Menu {
      if !store.mountedCorpora.isEmpty {
        ForEach(store.mountedCorpora) { mount in
          Button {
            store.switchCorpus(to: mount)
          } label: {
            Label(
              mount.name,
              systemImage: mount.path == store.corpusRoot?.standardizedFileURL.path
                ? "checkmark"
                : mount.kind == "shared" ? "person.2" : "folder"
            )
          }
          .disabled(mount.path == store.corpusRoot?.standardizedFileURL.path || store.isSwitchingCorpus)
        }

        Divider()

        if !forgettableCorpora.isEmpty {
          Menu {
            ForEach(forgettableCorpora) { mount in
              Button("Forget \(mount.name)", role: .destructive) {
                store.forgetCorpus(mount)
              }
            }
          } label: {
            Label("Forget Corpus", systemImage: "trash")
          }

          Divider()
        }
      }

      Button {
        store.chooseCorpus()
      } label: {
        Label("Mount Another Corpus…", systemImage: "folder.badge.plus")
      }

      if store.corpusRoot == nil {
        Button {
          store.createCorpus()
        } label: {
          Label("Create Corpus…", systemImage: "plus.square.on.folder")
        }

        Button {
          store.createSharedCorpus()
        } label: {
          Label("Create Shared Corpus…", systemImage: "person.2.fill")
        }
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: activeCorpusIcon)
          .frame(width: 16)
        Text(activeCorpusName)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
        if store.isSwitchingCorpus {
          WorkspaceActivityIndicator(size: .mini)
        } else {
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .font(.callout.weight(.medium))
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(height: 0.5)
    }
    .help(store.corpusRoot?.path ?? "Open or create a corpus")
  }

  private var activeCorpusName: String {
    if let root = store.corpusRoot {
      return store.activeCorpusIdentity?.name ?? root.lastPathComponent
    }
    return "Open Corpus"
  }

  private var activeCorpusIcon: String {
    if store.activeCorpusIdentity?.kind == "shared" {
      return "person.2"
    }
    return store.corpusRoot == nil ? "folder.badge.plus" : "folder"
  }

  private var forgettableCorpora: [WorkspaceCorpusMount] {
    store.mountedCorpora.filter { $0.path != store.corpusRoot?.standardizedFileURL.path }
  }
}

private struct SidebarPinnedFileRow: View {
  let file: CorpusFile
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text")
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(file.name)
          .font(.callout.weight(isSelected ? .medium : .regular))
          .lineLimit(1)
          .truncationMode(.tail)
        if !file.directory.isEmpty {
          Text(file.directory)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
  }
}

private struct SidebarSurfaceRow: View {
  let surface: WorkspaceSurface
  let showsCommandShortcut: Bool
  let notificationCount: Int

  var body: some View {
    HStack(spacing: 8) {
      Label(surface.title, systemImage: surface.systemImage)
        .font(.callout.weight(.medium))
      Spacer(minLength: 0)
      if notificationCount > 0 && !showsCommandShortcut {
        Text(notificationCount > 99 ? "99+" : "\(notificationCount)")
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.orange)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Color.orange.opacity(0.10), in: Capsule())
          .accessibilityLabel(notificationCount == 1 ? "1 item needs review" : "\(notificationCount) items need review")
      }
      if showsCommandShortcut && !surface.commandShortcutTitle.isEmpty {
        KeyboardShortcutBadge(text: surface.commandShortcutTitle)
          .transition(.opacity.combined(with: .move(edge: .trailing)))
      }
    }
  }
}

private struct OpenClawSidebarSurfaceGroup: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var isThreadListExpanded = true
  let showsCommandShortcut: Bool

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
          store.createAIChatThread()
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

        Button {
          withAnimation(WorkspaceMotion.disclosure) {
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

        if showsCommandShortcut && !surface.commandShortcutTitle.isEmpty {
          KeyboardShortcutBadge(text: surface.commandShortcutTitle)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
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
  @State private var showsSettledThreads = false
  @State private var isRenamePresented = false
  @State private var renamingThreadID: UUID?
  @State private var renameDraft = ""
  @State private var contextualThreadID: UUID?

  private let autoSettleTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if store.visibleOpenClawChatThreads.isEmpty && store.settledOpenClawChatThreads.isEmpty {
        Text("No chat threads")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.leading, 42)
          .padding(.vertical, 3)
      } else {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(store.visibleOpenClawChatThreads) { thread in
            let contextThread = resolvedContextThread(fallback: thread)
            OpenClawSidebarThreadRow(
              thread: thread,
              isSelected: store.selectedOpenClawChatThreadID == thread.id && store.selectedSurface == .openClaw,
              isSending: store.openClawSendingThreadIDs.contains(thread.id),
              contextThread: contextThread,
              select: {
                contextualThreadID = thread.id
                store.makeSurfacePrimary(.openClaw)
                store.selectOpenClawChatThread(thread.id)
              },
              rename: beginRenaming,
              togglePin: { store.toggleOpenClawChatThreadPin(contextThread.id) },
              settle: {
                contextualThreadID = nil
                store.settleOpenClawChatThread(thread.id)
              },
              reopen: { store.reopenOpenClawChatThread(thread.id) }
            )
            .onHover { isHovered in
              if isHovered {
                contextualThreadID = thread.id
              } else if contextualThreadID == thread.id {
                contextualThreadID = nil
              }
            }
          }

          if !store.settledOpenClawChatThreads.isEmpty {
            HStack(spacing: 4) {
              Button {
                withAnimation(WorkspaceMotion.disclosure) {
                  showsSettledThreads.toggle()
                }
              } label: {
                HStack(spacing: 5) {
                  Image(systemName: "checkmark.circle")
                  Text("Settled")
                  Text("\(store.settledOpenClawChatThreads.count)")
                    .foregroundStyle(.tertiary)
                  Spacer(minLength: 0)
                  Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(showsSettledThreads ? 0 : -90))
                }
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .padding(.vertical, 6)
              }
              .buttonStyle(.plain)
              .help(showsSettledThreads ? "Hide settled chat threads" : "Show settled chat threads")

              if store.canUndoOpenClawChatThreadArchive {
                Button {
                  withAnimation(WorkspaceMotion.disclosure) {
                    store.undoLastOpenClawChatThreadArchive()
                  }
                } label: {
                  Image(systemName: "arrow.uturn.backward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reopen last settled chat thread")
              }
            }
            .padding(.leading, 42)
            .padding(.trailing, 8)
          }

          if showsSettledThreads {
            ForEach(store.settledOpenClawChatThreads) { thread in
              let contextThread = resolvedContextThread(fallback: thread)
              OpenClawSidebarThreadRow(
                thread: thread,
                isSelected: store.selectedOpenClawChatThreadID == thread.id && store.selectedSurface == .openClaw,
                isSending: store.openClawSendingThreadIDs.contains(thread.id),
                contextThread: contextThread,
                select: {
                  contextualThreadID = thread.id
                  store.makeSurfacePrimary(.openClaw)
                  store.selectOpenClawChatThread(thread.id)
                },
                rename: beginRenaming,
                togglePin: { store.toggleOpenClawChatThreadPin(contextThread.id) },
                settle: { store.settleOpenClawChatThread(thread.id) },
                reopen: {
                  contextualThreadID = nil
                  store.reopenOpenClawChatThread(thread.id)
                }
              )
              .opacity(0.68)
              .onHover { isHovered in
                if isHovered {
                  contextualThreadID = thread.id
                } else if contextualThreadID == thread.id {
                  contextualThreadID = nil
                }
              }
            }
          }
        }
        .padding(.vertical, 1)
      }
    }
    .padding(.top, 2)
    .onAppear {
      store.autoSettleOpenClawChatThreads()
    }
    .onReceive(autoSettleTimer) { now in
      store.autoSettleOpenClawChatThreads(now: now)
    }
    .onChange(of: store.settledOpenClawChatThreads.count) {
      let nextValue = OpenClawSettledThreadDisclosure.updated(
        isExpanded: showsSettledThreads,
        settledThreadCount: store.settledOpenClawChatThreads.count
      )
      guard nextValue != showsSettledThreads else { return }
      withAnimation(WorkspaceMotion.disclosure) { showsSettledThreads = nextValue }
    }
    .alert("Rename Thread", isPresented: $isRenamePresented) {
      TextField("Thread name", text: $renameDraft)
      Button("Cancel", role: .cancel) {
        renamingThreadID = nil
      }
      Button("Rename") {
        guard let renamingThreadID else { return }
        store.renameOpenClawChatThread(renamingThreadID, title: renameDraft)
        self.renamingThreadID = nil
      }
    }
  }

  private func beginRenaming(_ thread: OpenClawChatThread) {
    renamingThreadID = thread.id
    renameDraft = thread.title
    isRenamePresented = true
  }

  private func resolvedContextThread(fallback: OpenClawChatThread) -> OpenClawChatThread {
    let id = OpenClawSidebarContextTarget.resolve(
      hoveredThreadID: contextualThreadID,
      selectedThreadID: store.selectedSurface == .openClaw ? store.selectedOpenClawChatThreadID : nil,
      fallbackThreadID: fallback.id
    )
    return store.openClawChatThreads.first(where: { $0.id == id }) ?? fallback
  }
}

enum OpenClawSidebarContextTarget {
  static func resolve(
    hoveredThreadID: UUID?,
    selectedThreadID: UUID?,
    fallbackThreadID: UUID
  ) -> UUID {
    hoveredThreadID ?? selectedThreadID ?? fallbackThreadID
  }
}

enum OpenClawSettledThreadDisclosure {
  static func updated(isExpanded: Bool, settledThreadCount: Int) -> Bool {
    settledThreadCount > 0 && isExpanded
  }
}

private struct OpenClawSidebarThreadRow: View {
  @State private var isHovered = false
  let thread: OpenClawChatThread
  let isSelected: Bool
  let isSending: Bool
  let contextThread: OpenClawChatThread
  let select: () -> Void
  let rename: (OpenClawChatThread) -> Void
  let togglePin: () -> Void
  let settle: () -> Void
  let reopen: () -> Void

  var body: some View {
    HStack(spacing: 2) {
      Button(action: select) {
        HStack(alignment: .center, spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(thread.title)
              .font(.callout.weight(isSelected ? .medium : .regular))
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.tail)
            HStack(spacing: 5) {
              Text(thread.messageCount == 1 ? "1 message" : "\(thread.messageCount) messages")
              Text("·")
              Text(thread.runtime.title)
              Text("·")
              Text(Self.relativeDate(thread.updatedAt))
              if thread.isSettled {
                Text("· Settled")
              }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          }
          Spacer(minLength: 4)
          if isSending {
            WorkspaceActivityIndicator(size: .mini)
              .help("\(thread.runtime.title) is thinking")
          }
          if thread.resource != nil {
            Image(systemName: "text.bubble.fill")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .help("Canonical resource thread")
          }
          if thread.latestDeliveryNeedsAttention {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.orange)
              .help("Latest message needs attention")
          }
          if thread.isPinned {
            Image(systemName: "pin.fill")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          if thread.unreadMessageCount > 0 {
            OpenClawUnreadBadge(count: thread.unreadMessageCount)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 42)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isHovered {
        Button {
          withAnimation(WorkspaceMotion.disclosure) {
            thread.isSettled ? reopen() : settle()
          }
        } label: {
          Image(systemName: thread.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle")
            .font(.callout)
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(thread.isSettled ? "Reopen thread" : "Settle thread")
        .transition(.opacity)
      } else {
        Color.clear.frame(width: 24, height: 28)
      }
    }
    .padding(.trailing, 6)
    .background(
      isSelected ? WorkspaceDesign.selectedFill : Color.clear,
      in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Capsule()
          .fill(Color.accentColor.opacity(0.72))
          .frame(width: 2, height: 22)
          .padding(.leading, 4)
      }
    }
    .contentShape(Rectangle())
    .onHover { hovered in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovered = hovered
      }
    }
    .contextMenu {
      Button {
        rename(contextThread)
      } label: {
        Label("Rename Thread", systemImage: "pencil")
      }

      Button {
        togglePin()
      } label: {
        Label(
          contextThread.isPinned ? "Unpin Thread" : "Pin Thread",
          systemImage: contextThread.isPinned ? "pin.slash" : "pin"
        )
      }

      if contextThread.isSettled {
        Button {
          reopen()
        } label: {
          Label("Reopen Thread", systemImage: "arrow.uturn.backward.circle")
        }
      } else {
        Button {
          settle()
        } label: {
          Label("Settle Thread", systemImage: "checkmark.circle")
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
  @FocusState private var filterFocused: Bool

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
          .focused($filterFocused)
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
        EmptyStateView(title: "No Files", detail: "No org2, org, or markdown files matched. Use the toolbar Refresh after adding files.")
      } else {
        List {
          ForEach(store.filteredCorpusFiles) { file in
            CorpusFileRow(file: file)
              .contentShape(Rectangle())
              .onTapGesture {
                if store.selectedCorpusFileID == file.id {
                  store.selectCorpusFile(file)
                } else {
                  store.selectedCorpusFileID = file.id
                }
              }
              .modifier(ReadableListSelectionModifier(isSelected: store.selectedCorpusFileID == file.id))
              .listRowBackground(Color.clear)
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
          performAfterSwiftUIViewUpdate {
            guard store.selectedCorpusFileID == id else { return }
            store.selectCorpusFile(file)
          }
        }
      }
    }
    .onChange(of: store.corpusFileFilterFocusToken) {
      filterFocused = true
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

private struct ReadableListSelectionModifier: ViewModifier {
  let isSelected: Bool
  var verticalPadding: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 10)
      .padding(.vertical, verticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected ? WorkspaceDesign.selectedFill : Color.clear,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay(alignment: .leading) {
        if isSelected {
          Capsule()
            .fill(Color.accentColor)
            .frame(width: 3)
            .padding(.vertical, 8)
        }
      }
      .accessibilityAddTraits(isSelected ? .isSelected : [])
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
      store.togglePinnedFile(file)
    } label: {
      Label(
        store.isFilePinned(path: file.path) ? "Unpin File" : "Pin File",
        systemImage: store.isFilePinned(path: file.path) ? "pin.slash" : "pin"
      )
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
      Label("Ask AI", systemImage: "sparkles")
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
      Label("Ask AI", systemImage: "sparkles")
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
        TextField("Quick open files and AI chats", text: $store.quickOpenQuery)
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
          Text(store.isScanningCorpusFiles ? "Scanning files" : "Searching")
            .foregroundStyle(.secondary)
        }
      }

      List {
        ForEach(store.quickOpenItems) { item in
          switch item {
          case .file(let file):
            CorpusFileRow(file: file)
              .contentShape(Rectangle())
              .onTapGesture {
                open(item)
              }
              .modifier(ReadableListSelectionModifier(isSelected: store.selectedQuickOpenFileID == item.id))
              .listRowBackground(Color.clear)
              .contextMenu {
                CorpusFileContextMenu(file: file) {
                  store.isQuickOpenPresented = false
                  dismiss()
                }
              }
          case .chatThread(let thread):
            QuickOpenChatThreadRow(thread: thread)
              .contentShape(Rectangle())
              .onTapGesture {
                open(item)
              }
              .modifier(ReadableListSelectionModifier(isSelected: store.selectedQuickOpenFileID == item.id))
              .listRowBackground(Color.clear)
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
    guard let item = store.selectedQuickOpenItem else { return false }
    open(item)
    return true
  }

  private func open(_ item: WorkspaceQuickOpenItem) {
    store.selectQuickOpenItem(item)
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

private struct QuickOpenChatThreadRow: View {
  let thread: OpenClawChatThread

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      WorkspaceIconBadge(
        systemImage: "bubble.left.and.bubble.right",
        tint: .accentColor,
        fill: Color.accentColor.opacity(0.10)
      )
      VStack(alignment: .leading, spacing: 3) {
        Text(thread.title)
          .font(.body.weight(.medium))
          .lineLimit(1)
        HStack(spacing: 6) {
          Text("AI Chat")
          Text("·")
          Text("\(thread.messageCount) message\(thread.messageCount == 1 ? "" : "s")")
          if thread.isSettled {
            Text("·")
            Text("Settled")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
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
          Text("Command shortcuts work globally. Agenda, document, and chat panes add local keys when focused.")
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
          ShortcutSection(title: "Workspace", shortcuts: [
            ShortcutHelpItem(keys: "⌘⇧O", action: "Open corpus"),
            ShortcutHelpItem(keys: "⌘R", action: "Refresh workspace"),
            ShortcutHelpItem(keys: "⌘S", action: "Save active edit"),
            ShortcutHelpItem(keys: "⌘P / ⌘K", action: "Quick Open"),
            ShortcutHelpItem(keys: "⌘⌃Return", action: "Capture"),
            ShortcutHelpItem(keys: "⌘? / ⌘/", action: "Show shortcuts"),
            ShortcutHelpItem(keys: "⌘Z / ⌘⇧Z", action: "Undo / redo workspace edit")
          ])

          ShortcutSection(title: "Navigation", shortcuts: [
            ShortcutHelpItem(keys: "⌘1", action: "Home"),
            ShortcutHelpItem(keys: "⌘2", action: "Agenda"),
            ShortcutHelpItem(keys: "⌘3", action: "Files"),
            ShortcutHelpItem(keys: "⌘4", action: "Agent Work"),
            ShortcutHelpItem(keys: "⌘⇧F", action: "Corpus search"),
            ShortcutHelpItem(keys: "⌘5 / ⌘M", action: "Meetings"),
            ShortcutHelpItem(keys: "⌘6", action: "AI Chat"),
            ShortcutHelpItem(keys: "⌘0", action: "Sources")
          ])

          ShortcutSection(title: "Pane Layout", shortcuts: [
            ShortcutHelpItem(keys: "⌘⌥P", action: "Make current pane primary"),
            ShortcutHelpItem(keys: "⌘⌥F", action: "Expand or restore current pane"),
            ShortcutHelpItem(keys: "⌘⌥W", action: "Close current pane")
          ])

          ShortcutSection(title: "Page", shortcuts: [
            ShortcutHelpItem(keys: "⌘F", action: "Find in current document"),
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
            ShortcutHelpItem(keys: "⌃D / ⌃U", action: "Jump down / up"),
            ShortcutHelpItem(keys: "J / K", action: "Scroll detail pane"),
            ShortcutHelpItem(keys: "gg / G", action: "First / last item"),
            ShortcutHelpItem(keys: "1 / 2 / 3 / 4", action: "Agenda mode"),
            ShortcutHelpItem(keys: "/", action: "Filter agenda"),
            ShortcutHelpItem(keys: "Esc", action: "Clear agenda filter"),
            ShortcutHelpItem(keys: "r", action: "Refresh agenda or assigned work"),
            ShortcutHelpItem(keys: "o / Return", action: "Open item"),
            ShortcutHelpItem(keys: "e", action: "Edit item source"),
            ShortcutHelpItem(keys: "c", action: "Capture task"),
            ShortcutHelpItem(keys: "⌘A / ⌘⇧A", action: "Select visible / clear bulk selection"),
            ShortcutHelpItem(keys: "⇧↑ / ⇧↓", action: "Extend bulk selection"),
            ShortcutHelpItem(keys: "Space", action: "Clear TODO status"),
            ShortcutHelpItem(keys: "t / i / d / x", action: "TODO / in-progress / done / canceled"),
            ShortcutHelpItem(keys: "A", action: "Assign to agent"),
            ShortcutHelpItem(keys: "p then a/b/c/0", action: "Set or clear priority"),
            ShortcutHelpItem(keys: "P", action: "Apply property shortcut"),
            ShortcutHelpItem(keys: "s / n / w / m", action: "Schedule today / tomorrow / week / month"),
            ShortcutHelpItem(keys: "S / N / W / M", action: "Deadline today / tomorrow / week / month"),
            ShortcutHelpItem(keys: "q", action: "Quit app")
          ])

          ShortcutSection(title: "Document", shortcuts: [
            ShortcutHelpItem(keys: "j / k / ↑ / ↓", action: "Move block selection"),
            ShortcutHelpItem(keys: "Return", action: "Edit selected block source"),
            ShortcutHelpItem(keys: "⌘Return", action: "Insert paragraph after block"),
            ShortcutHelpItem(keys: "/", action: "Insert slash-command paragraph"),
            ShortcutHelpItem(keys: "Type", action: "Start source edit at selected block"),
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

          ShortcutSection(title: "AI Chat", shortcuts: [
            ShortcutHelpItem(keys: "Return", action: "Send message"),
            ShortcutHelpItem(keys: "⌘Return", action: "Insert newline")
          ])

          ShortcutSection(title: "Meetings", shortcuts: [
            ShortcutHelpItem(keys: "⌘⇧M", action: "Record or stop meeting")
          ])
        }
        .padding(.vertical, 2)
      }
    }
    .padding(20)
    .frame(width: 820, height: 700)
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
    VStack(alignment: .leading, spacing: 0) {
      HeaderBar(title: "Agenda", subtitle: headerSubtitle, surface: .agenda) {
        if store.agendaMode == .assigned ? store.isLoadingAssignedWork : store.isLoadingAgenda {
          WorkspaceActivityIndicator(size: .small)
        }
      }

      if let error = store.errorText, store.agenda == nil {
        EmptyStateView(title: "Agenda Failed", detail: "\(error)\n\nUse the toolbar Refresh to retry.")
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
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onChange(of: store.agendaMode) {
      let mode = store.agendaMode
      performAfterSwiftUIViewUpdate {
        guard store.agendaMode == mode else { return }
        if mode == .assigned {
          Task {
            await store.refreshAssignedWork()
            store.syncAssignedAgendaSelectionAfterDisplayOptionsChange()
          }
        } else {
          store.syncAgendaSelectionAfterDisplayOptionsChange()
        }
      }
    }
    .onChange(of: store.agendaReadScope) {
      guard store.agendaMode != .assigned else { return }
      Task { await store.refreshAgenda() }
    }
    .onChange(of: store.agendaFilter) {
      let filter = store.agendaFilter
      performAfterSwiftUIViewUpdate {
        guard store.agendaFilter == filter else { return }
        store.syncAgendaSelectionAfterDisplayOptionsChange()
      }
    }
    .onChange(of: store.agendaFilterFocusToken) {
      agendaFilterFocused = true
    }
    .onChange(of: agendaFilterFocused) {
      let isFocused = agendaFilterFocused
      performAfterSwiftUIViewUpdate {
        guard store.isAgendaFilterFocused != isFocused else { return }
        store.isAgendaFilterFocused = isFocused
      }
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

        if store.agendaMode != .assigned {
          Picker("Scope", selection: $store.agendaReadScope) {
            ForEach(WorkspaceReadScope.allCases) { scope in
              Text(scope.title).tag(scope)
            }
          }
          .frame(width: 135)
          .help("Read agenda items from the active corpus or every mounted corpus")
        }

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
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
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
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous))
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

private struct RunsAndReviewView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        Picker("Agent work", selection: $store.runsAndReviewPage) {
          ForEach(RunsAndReviewPage.allCases) { page in Text(page.rawValue).tag(page) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 340)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .background(WorkspaceDesign.barBackground)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(WorkspaceDesign.hairline)
          .frame(height: 0.5)
      }

      switch store.runsAndReviewPage {
      case .runs: RunCenterView()
      case .review: ApprovalsView()
      case .workflows: WorkflowsView()
      }
    }
  }
}

private struct WorkflowsView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var runWorkflow: AgentWorkflowItem?
  @State private var scheduleWorkflow: AgentWorkflowItem?

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(
        title: "Workflows",
        subtitle: "Plain-text processes in workflows/",
        surface: .approvals
      ) {
        if store.isLoadingAgentWorkflows { WorkspaceActivityIndicator(size: .small) }
        Button {
          Task {
            do {
              await store.refreshAgentWorkflows()
              try await store.syncAgentWorkflowsWithOpenClaw()
              store.statusText = "Workflows synced with OpenClaw"
            } catch {
              store.errorText = error.localizedDescription
              store.statusText = "OpenClaw workflow sync failed"
            }
          }
        } label: {
          Label("Sync", systemImage: "arrow.triangle.2.circlepath")
        }
      }

      if store.isLoadingAgentWorkflows && store.agentWorkflows.isEmpty {
        Spacer(); WorkspaceLoadingStateView("Loading workflows"); Spacer()
      } else if store.agentWorkflows.isEmpty {
        EmptyStateView(
          title: "No Workflows",
          detail: "Complete a run and choose Create Reusable Workflow. The resulting Org2 file will appear in workflows/."
        )
      } else {
        List {
          ForEach(store.agentWorkflows) { workflow in
            WorkflowRow(workflow: workflow)
              .contentShape(Rectangle())
              .onTapGesture {
                if store.selectedAgentWorkflowID == workflow.id {
                  store.selectAgentWorkflow(workflow)
                } else {
                  store.selectedAgentWorkflowID = workflow.id
                }
              }
              .modifier(ReadableListSelectionModifier(isSelected: store.selectedAgentWorkflowID == workflow.id))
              .listRowBackground(Color.clear)
              .contextMenu {
                Button("Run Now") { runWorkflow = workflow }
                Button("Edit Source") {
                  store.selectAgentWorkflow(workflow)
                  store.beginEditingCurrentScope()
                }
                Button("Validate") { Task { await store.validateAgentWorkflow(workflow) } }
                Divider()
                Button("Schedule…") { scheduleWorkflow = workflow }
                if workflow.state == "active" {
                  Button("Pause") { Task { await store.setAgentWorkflowState(workflow, state: "paused") } }
                } else {
                  Button("Activate") { Task { await store.setAgentWorkflowState(workflow, state: "active") } }
                }
              }
          }
        }
        .listStyle(.inset)
        .onChange(of: store.selectedAgentWorkflowID) {
          guard let id = store.selectedAgentWorkflowID,
                let workflow = store.agentWorkflows.first(where: { $0.id == id }) else { return }
          performAfterSwiftUIViewUpdate {
            guard store.selectedAgentWorkflowID == id else { return }
            store.selectAgentWorkflow(workflow)
          }
        }
      }
    }
    .task {
      if store.agentWorkflows.isEmpty { await store.refreshAgentWorkflows() }
    }
    .sheet(item: $runWorkflow) { workflow in
      WorkflowRunSheet(workflow: workflow)
        .environmentObject(store)
    }
    .sheet(item: $scheduleWorkflow) { workflow in
      WorkflowScheduleSheet(workflow: workflow)
        .environmentObject(store)
    }
  }
}

private struct WorkflowRow: View {
  @EnvironmentObject private var store: WorkspaceStore
  let workflow: AgentWorkflowItem

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(workflow.title)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        if store.mutatingAgentWorkflowIDs.contains(workflow.id) {
          WorkspaceActivityIndicator(size: .mini)
        }
        StatusPill(text: workflow.state)
      }
      Text(workflow.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      HStack(spacing: 8) {
        Label("v\(workflow.version)", systemImage: "point.3.connected.trianglepath.dotted")
        Label(workflow.scheduleSummary, systemImage: workflow.scheduleTrigger?.enabled == true ? "clock" : "play")
        if workflow.legacyLocation {
          Label("Legacy location", systemImage: "exclamationmark.triangle")
        }
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .lineLimit(1)
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct WorkflowRunSheet: View {
  @EnvironmentObject private var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  let workflow: AgentWorkflowItem
  @State private var values: [String: String]

  init(workflow: AgentWorkflowItem) {
    self.workflow = workflow
    _values = State(initialValue: Dictionary(uniqueKeysWithValues: workflow.inputs.map { ($0.id, $0.default ?? "") }))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Run \(workflow.title)").font(.title2.weight(.semibold))
      Text("OpenClaw will execute this workflow from its canonical Org2 file. A durable run is created before agent work begins.")
        .foregroundStyle(.secondary)
      if workflow.inputs.isEmpty {
        Text("This workflow has no inputs.").foregroundStyle(.secondary)
      } else {
        Form {
          ForEach(workflow.inputs) { input in
            TextField(input.description, text: binding(for: input.id))
              .help(input.required ? "Required input: \(input.id)" : "Optional input: \(input.id)")
          }
        }
        .formStyle(.grouped)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Run Now") {
          let inputs = values.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
          dismiss()
          Task { await store.runAgentWorkflow(workflow, inputs: inputs) }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(hasMissingRequiredInput)
      }
    }
    .padding(24)
    .frame(width: 560, height: max(300, CGFloat(230 + workflow.inputs.count * 54)))
  }

  private var hasMissingRequiredInput: Bool {
    workflow.inputs.contains { $0.required && (values[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private func binding(for id: String) -> Binding<String> {
    Binding(get: { values[id] ?? "" }, set: { values[id] = $0 })
  }
}

private struct WorkflowScheduleSheet: View {
  @EnvironmentObject private var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  let workflow: AgentWorkflowItem
  @State private var enabled: Bool
  @State private var cron: String
  @State private var timezone: String

  init(workflow: AgentWorkflowItem) {
    self.workflow = workflow
    let trigger = workflow.scheduleTrigger
    _enabled = State(initialValue: trigger?.enabled == true)
    _cron = State(initialValue: trigger?.schedule ?? "0 9 * * 1")
    _timezone = State(initialValue: trigger?.timezone ?? TimeZone.current.identifier)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Schedule \(workflow.title)").font(.title2.weight(.semibold))
      Text("OpenClaw owns due checks and execution. The desired schedule remains in the workflow’s plain-text definition.")
        .foregroundStyle(.secondary)
      Toggle("Enable schedule", isOn: $enabled)
      TextField("Cron expression", text: $cron).disabled(!enabled)
      TextField("IANA timezone", text: $timezone).disabled(!enabled)
      Text("Example: 0 9 * * 1 runs every Monday at 9:00 in the selected timezone.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          dismiss()
          Task { await store.setAgentWorkflowSchedule(workflow, cron: cron, timezone: timezone, enabled: enabled) }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(enabled && cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

private struct RunCenterView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var scope: AgentRunScope = .active
  @FocusState private var filterFocused: Bool

  var body: some View {
    let allRuns = store.agentRuns
    let visibleEntries = scope.entries(in: allRuns).filter { store.agentRunMatchesFilter($0.run) }
    let visibleSections = RunCenterPresentation.sections(for: visibleEntries, allRuns: allRuns)
    let selectedRun = store.selectedAgentRunID.flatMap { id in
      visibleEntries.first(where: { $0.run.id == id })?.run
    } ?? visibleEntries.first?.run
    let scopeCounts = Dictionary(
      uniqueKeysWithValues: AgentRunScope.allCases.map { candidate in
        (candidate, candidate.count(in: allRuns))
      }
    )

    VStack(spacing: 0) {
      HeaderBar(title: "Runs", subtitle: "Durable delegated work", surface: .approvals) {
        if store.isLoadingAgentRuns { WorkspaceActivityIndicator(size: .small) }
      }

      HStack(spacing: 10) {
        ForEach(AgentRunScope.allCases) { candidate in
          Button {
            withAnimation(WorkspaceMotion.quick) {
              scope = candidate
            }
          } label: {
            RunCenterScopeMetric(
              title: candidate.rawValue,
              count: scopeCounts[candidate, default: 0],
              isSelected: scope == candidate
            )
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(candidate.rawValue), \(scopeCounts[candidate, default: 0]) runs")
          .accessibilityValue(scope == candidate ? "Selected" : "")
        }
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.top, 12)
      .padding(.bottom, 12)

      RunCenterSearch(filterFocused: $filterFocused)

      Divider()

      if store.isLoadingAgentRuns && store.agentRuns.isEmpty {
        Spacer(); WorkspaceLoadingStateView("Loading agent runs"); Spacer()
      } else if visibleEntries.isEmpty {
        if store.agentRunFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          EmptyStateView(title: "No \(scope.rawValue) Runs", detail: "Runs created by agents, schedules, and workflows appear here automatically.")
        } else {
          EmptyStateView(title: "No Matching Runs", detail: "No \(scope.rawValue.lowercased()) runs match this search.")
        }
      } else {
        List {
          ForEach(visibleSections) { section in
            Section {
              ForEach(section.entries) { entry in
                Button {
                  store.selectAgentRun(entry.run)
                } label: {
                  RunCenterRow(
                    run: entry.run,
                    sourceMeeting: section.sourceMeeting,
                    representedFailureCount: entry.representedFailureCount,
                    isSelected: store.selectedAgentRunID == entry.run.id
                  )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
              }
            } header: {
              if let sourceMeeting = section.sourceMeeting {
                Label(sourceMeeting.displayTitle, systemImage: "calendar")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .textCase(nil)
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .onAppear {
      if let selectedRun {
        performAfterSwiftUIViewUpdate {
          store.selectAgentRun(selectedRun)
        }
      } else if store.agentRuns.isEmpty && !store.isLoadingAgentRuns {
        Task { await store.refreshAgentRuns() }
      }
    }
    .onChange(of: store.selectedAgentRunID) {
      guard let selectedRun else { return }
      let id = selectedRun.id
      performAfterSwiftUIViewUpdate {
        guard store.selectedAgentRunID == id else { return }
        store.selectAgentRun(selectedRun)
      }
    }
    .onChange(of: scope) {
      performAfterSwiftUIViewUpdate {
        syncVisibleRunSelection(in: visibleEntries)
      }
    }
    .onChange(of: visibleEntries.map(\.id)) {
      performAfterSwiftUIViewUpdate {
        syncVisibleRunSelection(in: visibleEntries)
      }
    }
    .onChange(of: store.agentRunFilterFocusToken) {
      filterFocused = true
    }
  }

  private func syncVisibleRunSelection(in visibleEntries: [AgentRunScopeEntry]) {
    if let selected = store.selectedAgentRunID,
       !visibleEntries.contains(where: { $0.id == selected }) {
      store.selectedAgentRunID = visibleEntries.first?.id
    }
  }
}

private struct RunCenterSearch: View {
  @EnvironmentObject private var store: WorkspaceStore
  var filterFocused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.tertiary)
      TextField("Search runs", text: $store.agentRunFilter)
        .textFieldStyle(.roundedBorder)
        .focused(filterFocused)
        .onSubmit {
          filterFocused.wrappedValue = false
        }
      if !store.agentRunFilter.isEmpty {
        Button {
          store.clearAgentRunFilter()
        } label: {
          Label("Clear", systemImage: "xmark.circle.fill")
        }
        .labelStyle(.iconOnly)
        .help("Clear run search")
      }
    }
    .controlSize(.small)
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
  }
}

private struct RunCenterScopeMetric: View {
  let title: String
  let count: Int
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(count)")
        .font(.title3.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
      Text(title)
        .font(.caption.weight(.medium))
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      isSelected ? Color.accentColor.opacity(0.10) : WorkspaceDesign.panelFill,
      in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
        .stroke(isSelected ? Color.accentColor.opacity(0.45) : WorkspaceDesign.hairline)
    }
    .contentShape(Rectangle())
  }
}

private struct RunCenterRow: View {
  let run: AgentRunItem
  let sourceMeeting: AgentRunContextItem?
  let representedFailureCount: Int
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        StatusPill(text: run.status)
        if representedFailureCount > 1 {
          Text("Latest of \(representedFailureCount) failed attempts")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if run.parentRunId != nil {
          Text("Outcome")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
        if run.pendingApprovalCount > 0 {
          Label("\(run.pendingApprovalCount)", systemImage: "checkmark.seal")
            .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        }
      }
      Text(run.goal).font(.body.weight(.semibold)).lineLimit(2)
      HStack(spacing: 8) {
        Text(run.progressText)
        if let workflow = run.workflowDisplayName {
          Text("• Workflow: \(workflow)")
        }
        Text("• Updated \(AgentRunTimestampPresentation.displayText(for: run.updatedAt))")
      }
      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? Color.accentColor.opacity(0.09) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Capsule()
          .fill(Color.accentColor)
          .frame(width: 3)
          .padding(.vertical, 8)
      }
    }
    .contentShape(Rectangle())
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityHint(sourceMeeting.map { "Meeting outcome from \($0.displayTitle)" } ?? "")
  }
}

private enum RunCompletionMode {
  case run
  case external

  var title: String {
    switch self {
    case .run: "Complete Run"
    case .external: "Mark Done Elsewhere"
    }
  }

  var detail: String {
    switch self {
    case .run: "Describe what happened in plain language. This is the first thing people will see when they review the run."
    case .external: "Describe where or how the outcome was completed. The blocked workflow will close, while its pending approvals and unreviewed artifacts remain in the durable history."
    }
  }

  var actionTitle: String {
    switch self {
    case .run: "Complete Run"
    case .external: "Mark Done Elsewhere"
    }
  }
}

private struct RunCenterDetail: View {
  @EnvironmentObject private var store: WorkspaceStore
  @State private var clarificationResponse = ""
  @State private var completionSummary = ""
  @State private var isCompletionPresented = false
  @State private var completionMode: RunCompletionMode = .run
  @State private var isWorkflowConfirmationPresented = false
  @State private var revisionApproval: AgentRunApprovalItem?
  @State private var revisionFeedback = ""
  @State private var openClawApprovalDetails: OpenClawExecApprovalDetails?
  @State private var isLoadingOpenClawApprovalDetails = false
  @State private var openClawApprovalDetailsError: String?
  let run: AgentRunItem

  private var isMutating: Bool { store.mutatingAgentRunIDs.contains(run.id) }

  var body: some View {
    let sourceMeetingContexts = RunCenterPresentation.sourceMeetingContextsByRunID(in: store.agentRuns)
    let sourceMeeting = sourceMeetingContexts[run.id]
    let relatedRuns: [AgentRunItem] = if let sourceRef = sourceMeeting?.fileReference {
      store.agentRuns.filter { candidate in
        candidate.id != run.id
          && sourceMeetingContexts[candidate.id]?.fileReference == sourceRef
      }
    } else {
      []
    }

    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            StatusPill(text: run.status)
            if let workflow = run.workflowDisplayName {
              Label(
                run.workflowVersion.map { "From \(workflow) v\($0)" } ?? "From \(workflow)",
                systemImage: "clock.arrow.circlepath"
              )
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            DetailPaneControlGroup()
          }
          Text(run.goal).font(.title2.weight(.semibold)).textSelection(.enabled)
          Text("Updated \(AgentRunTimestampPresentation.displayText(for: run.updatedAt))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(AgentRunTimestampPresentation.detailText(for: run.updatedAt))
          if let sourceMeeting {
            Button {
              store.openAgentRunContext(sourceMeeting)
            } label: {
              Label("From \(sourceMeeting.displayTitle)", systemImage: "calendar")
            }
            .buttonStyle(.link)
            .help("Open \(sourceMeeting.fileReference ?? sourceMeeting.ref) in Org2")
          }
        }

        runActions

        if !relatedRuns.isEmpty {
          runSection("Related meeting outcomes") {
            ForEach(relatedRuns) { relatedRun in
              Button {
                store.selectAgentRun(relatedRun)
              } label: {
                HStack(alignment: .top, spacing: 8) {
                  StatusPill(text: relatedRun.status)
                  Text(relatedRun.goal)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.leading)
                  Spacer(minLength: 8)
                  Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                }
              }
              .buttonStyle(.plain)
            }
          }
        }

        if run.status == "blocked" {
          clarificationSection
        } else if let failure = run.failure {
          Label(failure, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }

        if run.status == "completed" {
          runSection("Outcome") {
            VStack(alignment: .leading, spacing: 10) {
              Text(run.humanOutcomeSummary)
                .font(.body)
                .textSelection(.enabled)

              if let outcome = run.outcome, !outcome.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                  Text("Highlights").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  ForEach(Array(outcome.highlights.enumerated()), id: \.offset) { _, highlight in
                    Label(highlight, systemImage: "sparkles")
                  }
                }
              }

              if let outcome = run.outcome, !outcome.nextActions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                  Text("Next actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  ForEach(Array(outcome.nextActions.enumerated()), id: \.offset) { _, action in
                    Label(action, systemImage: "arrow.right.circle")
                  }
                }
              } else if run.humanNextAction != nil {
                Label("No action required", systemImage: "checkmark.circle.fill")
                  .font(.callout.weight(.medium))
                  .foregroundStyle(.green)
              }

              if run.outcome == nil {
                Text("This older run did not record a completion summary, so this overview was assembled from its outputs and steps.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        let pending = run.actionablePendingApprovals
        if !pending.isEmpty {
          runSection("Waiting for approval") {
            Text("\(pending.count) of \(run.approvals.count) approval\(run.approvals.count == 1 ? "" : "s") still need a decision. These are the same approvals shown in Review; deciding in either place updates this run record.")
              .font(.caption)
              .foregroundStyle(.secondary)
            ForEach(pending) { approval in
              VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(approval.title).font(.body.weight(.semibold))
                  Text(approval.action).font(.callout).foregroundStyle(.secondary)
                }

                approvalReviewMaterial(approval)

                HStack {
                  Button("Approve") { Task { await store.decideAgentRunApproval(run, approval: approval, decision: "approved") } }
                    .disabled(isMutating || !canApprove(approval))
                    .help(canApprove(approval) ? "Approve the displayed action" : "Reviewable action details are required before approval")
                  Button("Request Changes…") {
                    revisionFeedback = ""
                    revisionApproval = approval
                  }
                  .disabled(isMutating)
                  .help("Describe the changes required and return the work to the agent")
                  Button("Reject") { Task { await store.decideAgentRunApproval(run, approval: approval, decision: "rejected") } }
                    .disabled(isMutating)
                  Spacer()
                  Button("Show in Review") {
                    store.showApprovalInQueue(run: run, approval: approval)
                  }
                  .buttonStyle(.link)
                }.buttonStyle(WorkspaceActionButtonStyle()).controlSize(.small)
              }
            }
          }
        }

        let retainedPending = run.retainedPendingApprovals
        if !retainedPending.isEmpty {
          runSection("Retained approval history") {
            Text("This finished run retained \(retainedPending.count) unresolved approval\(retainedPending.count == 1 ? "" : "s") for audit history. No decision is required, and \(retainedPending.count == 1 ? "it is" : "they are") not shown in Review.")
              .font(.caption)
              .foregroundStyle(.secondary)
            ForEach(retainedPending) { approval in
              VStack(alignment: .leading, spacing: 4) {
                Text(approval.title).font(.body.weight(.semibold))
                Text(approval.action).font(.callout).foregroundStyle(.secondary)
              }
            }
          }
        }

        if !run.artifacts.isEmpty {
          runSection("Outputs") {
            ForEach(run.artifacts) { artifact in
              Button { store.openAgentRunArtifact(artifact) } label: {
                HStack(alignment: .top, spacing: 9) {
                  Image(systemName: artifact.role == "export" ? "square.and.arrow.up" : "doc.text")
                  VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.displayTitle).font(.body.weight(.medium))
                    Text("\(artifact.roleDisplayText) · \(artifact.path)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
              }
              .buttonStyle(.plain)
              .help("Open \(artifact.path) in Org2")
            }
          }
        }

        let reviewRequiredArtifacts = run.artifacts.filter { $0.reviewStatus == "review-required" }
        if !run.attentionValidations.isEmpty || !reviewRequiredArtifacts.isEmpty {
          runSection(run.isFinished ? "Retained workflow history" : "Needs attention") {
            if run.isFinished {
              Text("These signals were unresolved when the run finished. They are retained for audit history and do not put the run back in the review queue.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(run.attentionValidations) { validation in
              Label(
                validation.detail ?? "\(validation.displayName): \(AgentRunItem.humanizedLabel(validation.status))",
                systemImage: "exclamationmark.triangle.fill"
              )
              .foregroundStyle(validation.status == "failed" ? .red : .orange)
            }
            ForEach(reviewRequiredArtifacts) { artifact in
              Button { store.openAgentRunArtifact(artifact) } label: {
                Label(
                  run.isFinished
                    ? "Review was still pending for \(artifact.displayTitle)"
                    : "Review \(artifact.displayTitle)",
                  systemImage: "doc.badge.ellipsis"
                )
              }
              .buttonStyle(.link)
            }
          }
        }

        technicalDetails
      }
      .padding(WorkspaceDesign.contentInset)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onChange(of: run.id) {
      clarificationResponse = ""
      completionSummary = ""
      isCompletionPresented = false
      completionMode = .run
      revisionApproval = nil
      revisionFeedback = ""
      openClawApprovalDetails = nil
      openClawApprovalDetailsError = nil
      isLoadingOpenClawApprovalDetails = false
    }
    .task(id: "\(run.id):\(run.updatedAt)") {
      await loadOpenClawApprovalDetails()
    }
    .sheet(isPresented: $isCompletionPresented) {
      RunCompletionSheet(summary: $completionSummary, mode: completionMode) { summary in
        isCompletionPresented = false
        Task {
          switch completionMode {
          case .run: await store.completeAgentRun(run, summary: summary)
          case .external: await store.completeAgentRunExternally(run, summary: summary)
          }
        }
      }
    }
    .sheet(item: $revisionApproval) { approval in
      ApprovalRevisionSheet(
        title: approval.title,
        action: approval.action,
        feedback: $revisionFeedback
      ) { feedback in
        revisionApproval = nil
        Task {
          await store.requestAgentRunChanges(run, approval: approval, feedback: feedback)
        }
      }
    }
    .alert("Create a reusable workflow?", isPresented: $isWorkflowConfirmationPresented) {
      Button("Cancel", role: .cancel) {}
      Button("Create Workflow") { Task { await store.saveAgentRunAsWorkflow(run) } }
    } message: {
      Text("This creates a new reusable workflow definition from this one-off run. It does not rerun, publish, or send anything.")
    }
  }

  @ViewBuilder
  private func approvalReviewMaterial(_ approval: AgentRunApprovalItem) -> some View {
    if let note = approval.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("Approval details").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text(note).font(.callout).textSelection(.enabled)
      }
    }

    if run.openClawExecApprovalID != nil {
      if isLoadingOpenClawApprovalDetails {
        HStack(spacing: 7) {
          WorkspaceActivityIndicator(size: .mini)
          Text("Loading the exact action from OpenClaw…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } else if let details = openClawApprovalDetails {
        VStack(alignment: .leading, spacing: 7) {
          Text("Exact action to approve")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(details.reviewText)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))

          if let preview = details.commandPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
             !preview.isEmpty,
             preview != details.commandText {
            DisclosureGroup("Raw command") {
              Text(details.commandText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.top, 5)
            }
            .font(.caption)
          }

          let metadata = [
            details.host.map { "Host: \($0)" },
            details.agentID.map { "Agent: \($0)" },
          ].compactMap { $0 }
          if !metadata.isEmpty {
            Text(metadata.joined(separator: " · "))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } else {
        Label(
          "The exact OpenClaw action is unavailable, so approval is disabled. Retry after the Gateway is reachable or reject this request.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.orange)
        if let error = openClawApprovalDetailsError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    } else if !run.artifacts.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Review outputs before approving")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(run.artifacts) { artifact in
          Button { store.openAgentRunArtifact(artifact) } label: {
            Label(artifact.displayTitle, systemImage: "doc.text")
          }
          .buttonStyle(.link)
        }
      }
    } else if requiresReviewMaterial(approval),
              approval.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
      Label(
        "No recipient, content, command, or reviewable output was attached. Approval is disabled.",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.callout)
      .foregroundStyle(.orange)
    }
  }

  private func requiresReviewMaterial(_ approval: AgentRunApprovalItem) -> Bool {
    approval.riskClass == "external-action" || approval.riskClass == "high-impact"
  }

  private func canApprove(_ approval: AgentRunApprovalItem) -> Bool {
    guard requiresReviewMaterial(approval) else { return true }
    if run.openClawExecApprovalID != nil { return openClawApprovalDetails != nil }
    if approval.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
    return !run.artifacts.isEmpty
  }

  @MainActor
  private func loadOpenClawApprovalDetails() async {
    openClawApprovalDetails = nil
    openClawApprovalDetailsError = nil
    guard run.pendingApprovalCount > 0, run.openClawExecApprovalID != nil else {
      isLoadingOpenClawApprovalDetails = false
      return
    }
    isLoadingOpenClawApprovalDetails = true
    do {
      let details = try await store.openClawExecApprovalDetails(for: run)
      guard !Task.isCancelled else { return }
      openClawApprovalDetails = details
    } catch {
      guard !Task.isCancelled else { return }
      openClawApprovalDetailsError = error.localizedDescription
    }
    isLoadingOpenClawApprovalDetails = false
  }

  private var clarificationSection: some View {
    runSection(run.clarificationPrompt == nil ? "Clarification missing" : "Clarification needed") {
      VStack(alignment: .leading, spacing: 10) {
        if let prompt = run.clarificationPrompt {
          Label(prompt, systemImage: "questionmark.bubble.fill")
            .foregroundStyle(.orange)
        } else {
          Label("The agent blocked this run without recording a specific question.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("Tell it how to proceed below. Future runs must record an actionable clarification before entering the blocked state.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        TextField("Your response or direction", text: $clarificationResponse, axis: .vertical)
          .lineLimit(2...5)

        Button {
          let response = clarificationResponse
          clarificationResponse = ""
          Task { await store.respondToAgentRunClarification(run, response: response) }
        } label: {
          Label("Reply & Resume", systemImage: "paperplane.fill")
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(
          isMutating
            || WorkspaceStore.normalizedAgentRunClarificationResponse(clarificationResponse) == nil
        )
      }
    }
  }

  private var runActions: some View {
    HStack(spacing: 7) {
      if run.status == "queued" { actionButton("Start", "play.fill", "start") }
      if run.status == "blocked" {
        actionButton("Resume", "play.fill", "resume")
        Button {
          completionMode = .external
          isCompletionPresented = true
        } label: {
          Label("Mark Done Elsewhere…", systemImage: "checkmark.circle")
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(isMutating)
        .help("Record that the outcome was completed outside this workflow")
      }
      if run.status == "failed" || run.status == "canceled" { actionButton("Retry", "arrow.clockwise", "retry") }
      if run.status == "failed" {
        Button {
          Task { await store.mutateAgentRun(run, action: "cancel") }
        } label: {
          Label("Dismiss", systemImage: "archivebox")
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(isMutating)
        .help("Keep the durable record but remove this failure from Needs attention")
      }
      if ["queued", "running", "waiting-approval", "blocked"].contains(run.status) { actionButton("Cancel", "xmark.circle", "cancel") }
      if run.status == "running" {
        Button {
          completionMode = .run
          isCompletionPresented = true
        } label: { Label("Complete…", systemImage: "checkmark.circle") }
          .buttonStyle(WorkspaceActionButtonStyle()).disabled(isMutating)
      }
      if run.status == "completed" && run.workflowId == nil {
        Button { isWorkflowConfirmationPresented = true } label: { Label("Create Reusable Workflow…", systemImage: "square.stack.3d.up") }
          .buttonStyle(WorkspaceActionButtonStyle())
          .disabled(isMutating)
          .help("Create a reusable workflow definition from this one-off run")
      }
      Button { store.askOpenClawAboutAgentRun(run) } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .help("Start a chat with this durable run record as context")
      Button { store.openAgentRunRecord(run) } label: { Label("View Record", systemImage: "doc.text") }
        .buttonStyle(WorkspaceActionButtonStyle())
        .help("Render the durable run record inside Org2")
      if isMutating { WorkspaceActivityIndicator(size: .mini) }
    }.controlSize(.small)
  }

  private func actionButton(_ title: String, _ image: String, _ action: String) -> some View {
    Button { Task { await store.mutateAgentRun(run, action: action) } } label: { Label(title, systemImage: image) }
      .buttonStyle(WorkspaceActionButtonStyle()).disabled(isMutating)
  }

  private var technicalDetails: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 16) {
        if !run.plan.isEmpty {
          technicalGroup("Plan") {
            ForEach(run.plan) { step in
              HStack(alignment: .top) {
                Image(systemName: stepIcon(step.status))
                  .foregroundStyle(stepColor(step.status))
                VStack(alignment: .leading) {
                  Text(step.title)
                  Text("\(AgentRunItem.humanizedLabel(step.kind)) · \(AgentRunItem.humanizedLabel(step.status))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }

        if !run.acceptanceCriteria.isEmpty {
          technicalGroup("Acceptance criteria") {
            ForEach(Array(run.acceptanceCriteria.enumerated()), id: \.offset) { _, criterion in
              Label(criterion, systemImage: "checkmark")
            }
          }
        }

        if !run.latestValidations.isEmpty {
          technicalGroup("Latest validation results") {
            ForEach(run.latestValidations) { validation in
              Label(
                "\(validation.displayName): \(AgentRunItem.humanizedLabel(validation.status))",
                systemImage: validation.status == "passed" ? "checkmark.seal.fill" : validation.status == "skipped" ? "minus.circle" : "exclamationmark.triangle"
              )
              .foregroundStyle(validation.status == "passed" ? .green : validation.status == "skipped" ? .secondary : .orange)
            }
          }
        }

        if !run.context.isEmpty {
          technicalGroup("Cited context") {
            ForEach(Array(run.context.enumerated()), id: \.offset) { _, item in
              Text(item.citation ?? item.ref).font(.callout.monospaced()).textSelection(.enabled)
            }
          }
        }

        if !run.comments.isEmpty {
          technicalGroup("Handoff and comments") {
            ForEach(run.comments) { comment in
              VStack(alignment: .leading) {
                Text(comment.author).font(.caption.weight(.semibold))
                Text(comment.body)
              }
            }
          }
        }

        technicalGroup("Run details") {
          Text("Risk: \(AgentRunItem.humanizedLabel(run.riskClass))")
          if let assignee = run.assignee { Text("Assignee: \(assignee)") }
          Text("Run ID: \(run.id)").textSelection(.enabled)
        }
      }
      .padding(.top, 10)
    } label: {
      Label("Technical details", systemImage: "wrench.and.screwdriver")
        .font(.headline)
    }
    .padding(12)
    .workspaceCardSurface()
  }

  private func technicalGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      content()
    }
  }

  private func stepIcon(_ status: String) -> String {
    switch status {
    case "completed": return "checkmark.circle.fill"
    case "failed": return "xmark.circle.fill"
    case "running": return "play.circle.fill"
    case "skipped": return "minus.circle"
    case "blocked": return "exclamationmark.circle.fill"
    default: return "circle"
    }
  }

  private func stepColor(_ status: String) -> Color {
    switch status {
    case "completed": return .green
    case "failed": return .red
    case "blocked": return .orange
    default: return .secondary
    }
  }

  private func runSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.headline)
      content()
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .workspaceCardSurface()
  }
}

private struct RunCompletionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var summary: String
  let mode: RunCompletionMode
  let complete: (String) -> Void

  private var normalizedSummary: String {
    summary.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(mode.title).font(.title2.weight(.semibold))
      Text(mode.detail)
        .foregroundStyle(.secondary)
      TextField("Outcome summary", text: $summary, axis: .vertical)
        .lineLimit(3...7)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(mode.actionTitle) { complete(normalizedSummary) }
          .keyboardShortcut(.defaultAction)
          .disabled(normalizedSummary.isEmpty)
      }
    }
    .padding(22)
    .frame(width: 520)
  }
}

private struct ApprovalsView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @FocusState private var filterFocused: Bool
  @State private var discussionItem: ApprovalItem?
  @State private var discussionMessage = "I need to discuss this approval item before deciding."
  @State private var revisionItem: ApprovalItem?
  @State private var revisionFeedback = ""

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
      ApprovalDiscussionSheet(
        item: item,
        message: $discussionMessage,
        discuss: { message, threadMode in
          discussionItem = nil
          Task { await store.discussApprovalInOpenClaw(item, message: message, threadMode: threadMode) }
        }
      )
        .environmentObject(store)
    }
    .sheet(item: $revisionItem) { item in
      ApprovalRevisionSheet(
        title: item.title,
        action: item.action ?? item.body,
        feedback: $revisionFeedback
      ) { feedback in
        revisionItem = nil
        Task { await store.requestChanges(item, feedback: feedback) }
      }
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
      performAfterSwiftUIViewUpdate {
        guard store.selectedApprovalItemID == id else { return }
        store.selectApprovalItem(item)
      }
    }
    .onChange(of: store.approvalFilterFocusToken) {
      filterFocused = true
    }
  }

  private var headerSubtitle: String {
    "\(store.visibleApprovalItems.count) pending approval\(store.visibleApprovalItems.count == 1 ? "" : "s")"
  }

  @ViewBuilder
  private var approvalList: some View {
    if let error = store.errorText, store.approvalItems.isEmpty {
      EmptyStateView(title: "Approvals Failed", detail: "\(error)\n\nUse the toolbar Refresh to retry.")
    } else if store.isLoadingApprovals && store.approvalItems.isEmpty {
      Spacer()
      WorkspaceLoadingStateView("Loading approvals")
      Spacer()
    } else if store.visibleApprovalItems.isEmpty {
      if store.approvalFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        EmptyStateView(title: "No Approvals", detail: "No pending approval candidates matched.")
      } else {
        EmptyStateView(title: "No Matching Approvals", detail: "No pending approvals match this search.")
      }
    } else {
      List {
        ForEach(store.visibleApprovalItems) { item in
          ApprovalRow(
            item: item,
            sourceReference: item.isRunApproval ? item.sourceLabel : "\(store.relativePath(item.file)):\(item.line)",
            isSelected: store.selectedApprovalItemID == item.id,
            isApproving: store.isApprovingApproval(item),
            isRejecting: store.isRejectingApproval(item),
            approve: { Task { await store.approve(item) } },
            requestChanges: item.isRunApproval ? {
              revisionFeedback = ""
              revisionItem = item
            } : nil,
            reject: { store.promptAndRejectApproval(item) },
            copy: { store.copyApprovalDiscussionText(item) },
            discuss: {
              discussionMessage = "I need to discuss this approval item before deciding."
              discussionItem = item
            }
          )
          .contentShape(Rectangle())
          .onTapGesture {
            store.selectApprovalItem(item)
          }
          .listRowBackground(Color.clear)
          .contextMenu {
            if item.isRunApproval {
              Button {
                store.selectApprovalItem(item)
              } label: {
                Label("Open Run", systemImage: "clock.arrow.circlepath")
              }
            } else {
              WorkspaceLocationContextMenu(
                location: .agenda(item.agendaItem()),
                showsHeadingActions: true,
                select: { store.selectApprovalItem(item) }
              ) {
                Label("Open", systemImage: "checkmark.seal")
              }
            }
            Divider()
            Button {
              Task { await store.approve(item) }
            } label: {
              Label("Approve", systemImage: "checkmark")
            }
            .disabled(store.isApprovalActionInProgress(item))
            if item.isRunApproval {
              Button {
                revisionFeedback = ""
                revisionItem = item
              } label: {
                Label("Request Changes…", systemImage: "arrow.uturn.backward")
              }
              .disabled(store.isApprovalActionInProgress(item))
            }
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
      Image(systemName: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.tertiary)
      TextField("Search approvals", text: $store.approvalFilter)
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
        .help("Clear approval search")
      }
    }
    .controlSize(.small)
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
  }
}

private struct ApprovalRow: View {
  let item: ApprovalItem
  let sourceReference: String
  let isSelected: Bool
  let isApproving: Bool
  let isRejecting: Bool
  let approve: () -> Void
  let requestChanges: (() -> Void)?
  let reject: () -> Void
  let copy: () -> Void
  let discuss: () -> Void

  private var isActionInProgress: Bool {
    isApproving || isRejecting
  }

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

      if let runGoal = item.runGoal {
        VStack(alignment: .leading, spacing: 3) {
          Label(runGoal, systemImage: "clock.arrow.circlepath")
            .font(.callout.weight(.medium))
            .lineLimit(2)
          if let dependency = item.runDependencyText {
            Text(dependency)
              .font(.caption.weight(.medium))
              .foregroundStyle(item.runPendingApprovalCount == 1 ? Color.orange : Color.secondary)
          }
        }
      }

      HStack(spacing: 8) {
        if let todo = item.todo {
          StatusPill(text: todo)
        }
        Label(sourceReference, systemImage: "doc.text")
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 6) {
        Button {
          approve()
        } label: {
          if isApproving {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .mini)
              Text("Approving")
            }
          } else {
            Label("Approve", systemImage: "checkmark")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(isActionInProgress)

        Button {
          discuss()
        } label: {
          Label("Discuss", systemImage: "paperplane")
        }
        .buttonStyle(WorkspaceActionButtonStyle())

        if let requestChanges {
          Button {
            requestChanges()
          } label: {
            Label("Request Changes…", systemImage: "arrow.uturn.backward")
          }
          .buttonStyle(WorkspaceActionButtonStyle())
          .disabled(isActionInProgress)
        }

        Button {
          reject()
        } label: {
          if isRejecting {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .mini)
              Text("Rejecting")
            }
          } else {
            Label("Reject", systemImage: "xmark.octagon")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(isActionInProgress)

        Button {
          copy()
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(WorkspaceActionButtonStyle())
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? WorkspaceDesign.selectedFill : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Capsule()
          .fill(Color.accentColor)
          .frame(width: 3)
          .padding(.vertical, 8)
      }
    }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct ApprovalRevisionSheet: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let action: String
  @Binding var feedback: String
  let requestChanges: (String) -> Void

  private var normalizedFeedback: String {
    feedback.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Request Changes")
          .font(.headline)
        Text(Org2Display.cleanInline(title))
          .font(.body.weight(.semibold))
          .lineLimit(2)
        if !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(Org2Display.cleanBlock(action).trimmedForDisplay(maxCharacters: 360))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(4)
        }
      }

      Text("What should the agent change?")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      TextEditor(text: $feedback)
        .font(.body)
        .frame(minHeight: 130)
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(WorkspaceDesign.hairline)
        )

      Text("The current material will remain unapproved. Your feedback will be saved in the run; a correlated workflow will continue by preparing replacement material for approval.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button {
          let feedback = normalizedFeedback
          dismiss()
          requestChanges(feedback)
        } label: {
          Label("Request Changes", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.borderedProminent)
        .disabled(normalizedFeedback.isEmpty)
      }
    }
    .padding(18)
    .frame(width: 480)
  }
}

private struct ApprovalDiscussionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: WorkspaceStore
  let item: ApprovalItem
  @Binding var message: String
  let discuss: (String, OpenClawThreadMode) -> Void
  @State private var threadMode: OpenClawThreadMode = .newThread

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

      Picker("Thread", selection: $threadMode) {
        ForEach(OpenClawThreadMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.radioGroup)
      .horizontalRadioGroupLayout()
      .help("Choose whether this approval discussion starts a fresh OpenClaw chat or continues the selected chat.")

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        Button {
          let message = message
          let threadMode = threadMode
          dismiss()
          discuss(message, threadMode)
        } label: {
          Label("Discuss", systemImage: "paperplane")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(18)
    .frame(width: 460)
    .onAppear {
      threadMode = .newThread
    }
  }
}

private struct AgendaItemListView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    List {
      ForEach(store.agendaDisplaySections) { section in
        Section(section.label) {
          ForEach(section.items) { item in
            AgendaRow(
              item: item,
              sourceReference: store.corpusQualifiedPath(item.file, corpus: item.corpus) + ":\(item.lineForEditor)",
              isSelected: store.selectedAgendaItemID == item.id,
              isBulkSelected: store.isAgendaItemBulkSelected(item),
              isEditable: store.isResultInActiveCorpus(item.corpus),
              isAgentAssigned: store.isAgentAssignee(item.properties["ASSIGNEE"]),
              isPersonalAssigned: store.isPersonalAssignee(item.properties["ASSIGNEE"]),
              toggleBulkSelection: { store.toggleAgendaItemBulkSelection(item) }
            )
              .contentShape(Rectangle())
              .onTapGesture {
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                performAfterSwiftUIViewUpdate {
                  store.handleAgendaItemClick(item, modifiers: modifiers)
                }
              }
              .listRowBackground(Color.clear)
              .contextMenu {
                WorkspaceLocationContextMenu(
                  location: .agenda(item),
                  showsHeadingActions: store.isResultInActiveCorpus(item.corpus),
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
      performAfterSwiftUIViewUpdate {
        guard store.selectedAgendaItemID == id else { return }
        store.selectAgendaItem(item)
      }
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
      List {
        ForEach(store.assignedWorkSections) { section in
          Section(section.label) {
            ForEach(section.items) { item in
              AssignedWorkRow(
                item: item,
                sourceReference: store.relativePath(item.file) + ":\(item.lineForEditor)",
                isSelected: store.selectedAssignedWorkItemID == item.id
              )
                .contentShape(Rectangle())
                .onTapGesture {
                  store.selectAssignedWorkItem(item)
                }
                .listRowBackground(Color.clear)
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
        performAfterSwiftUIViewUpdate {
          guard store.selectedAssignedWorkItemID == id else { return }
          store.selectAssignedWorkItem(item)
        }
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
    .buttonStyle(WorkspaceActionButtonStyle())
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.panelFill)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

private struct AgendaRow: View {
  let item: AgendaItem
  let sourceReference: String
  let isSelected: Bool
  let isBulkSelected: Bool
  let isEditable: Bool
  let isAgentAssigned: Bool
  let isPersonalAssigned: Bool
  let toggleBulkSelection: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Button {
        toggleBulkSelection()
      } label: {
        Image(systemName: isBulkSelected ? "checkmark.square.fill" : "square")
          .font(.body)
          .foregroundStyle(isBulkSelected ? Color.accentColor : Color.secondary)
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!isEditable)
      .help(isBulkSelected ? "Remove from bulk selection" : "Add to bulk selection")
      .padding(.top, 1)

      HStack(spacing: 4) {
        StatusPill(text: item.todo ?? "TASK")
        AgendaPriorityPill(priority: item.priority)
      }
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
          if let corpus = item.corpus {
            Text(corpus.name)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkspaceDesign.subtleFill, in: Capsule())
          }
        }
        HStack(spacing: 8) {
          Text([item.kind, item.time].compactMap { $0 }.joined(separator: " "))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
          Text(sourceReference)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      AgendaAssignmentIndicator(
        item: item,
        isAgentAssigned: isAgentAssigned,
        isPersonalAssigned: isPersonalAssigned
      )
    }
    .padding(.horizontal, 10)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? WorkspaceDesign.selectedFill : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Capsule()
          .fill(Color.accentColor)
          .frame(width: 3)
          .padding(.vertical, 8)
      }
    }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

struct AgendaPriorityPill: View {
  let priority: String?

  @ViewBuilder
  var body: some View {
    if let normalized = Self.normalizedPriority(priority) {
      Text(normalized)
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(tone.foreground)
        .frame(minWidth: 16)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(tone.background, in: Capsule())
        .accessibilityLabel("Priority \(normalized)")
        .help("Priority [#\(normalized)]")
    }
  }

  private var tone: AgendaPriorityTone {
    guard let normalized = Self.normalizedPriority(priority) else {
      return .neutral
    }
    return Self.tone(for: normalized)
  }

  nonisolated static func normalizedPriority(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
      return nil
    }
    value = value
      .replacingOccurrences(of: "[#", with: "")
      .replacingOccurrences(of: "]", with: "")
      .uppercased()
    guard value.range(of: #"^[A-Z0-9]$"#, options: .regularExpression) != nil else {
      return nil
    }
    return value
  }

  nonisolated static func tone(for normalizedPriority: String) -> AgendaPriorityTone {
    switch normalizedPriority {
    case "A":
      return .urgent
    case "B":
      return .elevated
    case "C":
      return .quiet
    default:
      return .neutral
    }
  }
}

enum AgendaPriorityTone: Equatable {
  case urgent
  case elevated
  case quiet
  case neutral

  var foreground: Color {
    switch self {
    case .urgent:
      return .orange
    case .elevated:
      return .indigo
    case .quiet:
      return .secondary
    case .neutral:
      return .secondary
    }
  }

  var background: Color {
    switch self {
    case .urgent:
      return Color.orange.opacity(0.13)
    case .elevated:
      return Color.indigo.opacity(0.11)
    case .quiet:
      return WorkspaceDesign.controlFill
    case .neutral:
      return WorkspaceDesign.controlFill
    }
  }
}

private struct AgendaAssignmentIndicator: View {
  let item: AgendaItem
  let isAgentAssigned: Bool
  let isPersonalAssigned: Bool

  private var assignee: String? {
    let trimmed = item.properties["ASSIGNEE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private var label: String {
    assignee ?? "Me"
  }

  private var helpText: String {
    if isAgentAssigned, let assignee {
      return "Assigned to agent: \(assignee)"
    }
    if let assignee {
      return isPersonalAssigned ? "Assigned to you: \(assignee)" : "Assigned to \(assignee)"
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

        if store.searchMode == .text {
          Picker("Scope", selection: $store.searchReadScope) {
            ForEach(WorkspaceReadScope.allCases) { scope in
              Text(scope.title).tag(scope)
            }
          }
          .frame(width: 135)
          .help("Search the active corpus or every mounted corpus")
        }

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
    .onChange(of: store.searchReadScope) {
      guard store.searchMode == .text,
            !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      Task { await store.runSearch() }
    }
  }

  @ViewBuilder
  private var searchResultsBody: some View {
    switch store.searchMode {
    case .text:
      if store.workspaceTextSearchSections.isEmpty {
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
          ForEach(store.workspaceTextSearchSections) { section in
            Section(section.category.title) {
              ForEach(section.items) { item in
                workspaceSearchRow(item)
              }
            }
          }
        }
        .listStyle(.inset)
      }
    case .nodes:
      let nodes = store.searchNodes
      if nodes.isEmpty {
        EmptyStateView(title: "No Nodes", detail: "\(nodeEmptyStateDetail) Use the toolbar Refresh to rebuild the corpus index.")
      } else {
        List(nodes) { node in
          NodeSearchRow(
            node: node,
            sourceReference: store.relativePath(node.file) + ":\(node.line)"
          )
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

  @ViewBuilder
  private func workspaceSearchRow(_ item: WorkspaceTextSearchItem) -> some View {
    switch item {
    case .activeTodo(let result), .entry(let result), .corpusText(let result):
      corpusSearchRow(result)
    case .file(let file):
      CorpusFileRow(file: file)
        .padding(.horizontal, WorkspaceDesign.contentInset)
        .contentShape(Rectangle())
        .onTapGesture {
          store.selectSearchFile(file)
        }
        .contextMenu {
          CorpusFileContextMenu(file: file)
        }
    case .chatThread(let result), .chatMessage(let result):
      ChatSearchRow(result: result)
        .contentShape(Rectangle())
        .onTapGesture {
          store.selectOpenClawChatSearchResult(result)
        }
    case .page(let node):
      NodeSearchRow(
        node: node,
        sourceReference: store.relativePath(node.file) + ":\(node.line)"
      )
        .contentShape(Rectangle())
        .onTapGesture {
          store.selectSearchNode(node)
        }
        .contextMenu {
          NodeSearchContextMenu(node: node)
        }
    }
  }

  private func corpusSearchRow(_ result: SearchResult) -> some View {
    SearchRow(
      result: result,
      sourceReference: store.corpusQualifiedPath(result.file, corpus: result.corpus) + ":\(result.lineForEditor)"
    )
      .contentShape(Rectangle())
      .onTapGesture {
        store.selectSearchResult(result)
      }
      .contextMenu {
        WorkspaceLocationContextMenu(
          location: .search(result),
          showsHeadingActions: result.todo != nil && store.isResultInActiveCorpus(result.corpus),
          select: { store.selectSearchResult(result) }
        ) {
          Label("Open", systemImage: "magnifyingglass")
        }
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
  let result: SearchResult
  let sourceReference: String
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
          if let corpus = result.corpus {
            Text(corpus.name)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkspaceDesign.subtleFill, in: Capsule())
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
          Text(sourceReference)
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
  let node: OrgRoamNodeReference
  let sourceReference: String

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
          Text(sourceReference)
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
      Label("Ask AI", systemImage: "sparkles")
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

private struct SourcesView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(
        title: "Sources",
        subtitle: "Local Slack and Notion archives staged as reviewable Org2 files",
        surface: .sources
      ) {
        if store.isLoadingSources {
          WorkspaceActivityIndicator(size: .small)
        }
        Button {
          Task { await store.refreshSourceConnections() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoadingSources)
      }

      if store.sourceProfiles.isEmpty {
        Spacer()
        EmptyStateView(
          title: "No Sources Configured",
          detail: "Declare externalSources in this corpus’s org2.json, then refresh.",
          action: "Refresh"
        ) {
          Task { await store.refreshSourceConnections() }
        }
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            Text("Sync updates each crawler’s private local archive. Stage writes bounded raw captures and review-required Org2 packets into this corpus; it never promotes them into canonical notes. Configured schedules run while Org2 Workspace is open and catch up after sleep or on the next launch.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            ForEach(store.sourceProfiles) { profile in
              SourceProfileCard(
                profile: profile,
                runtime: store.sourceRuntimeStatuses[profile.id]
              )
            }

            if let workspaceMessage = store.sourceOperationMessages["workspace"] {
              Text(workspaceMessage)
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }
          }
          .padding(WorkspaceDesign.contentInset)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .task {
      if store.sourceProfiles.isEmpty {
        await store.refreshSourceConnections()
      }
    }
    .sheet(isPresented: $store.isSourceCredentialPresented) {
      SourceCredentialSheet()
        .environmentObject(store)
    }
  }
}

private struct SourceProfileCard: View {
  @EnvironmentObject private var store: WorkspaceStore
  let profile: WorkspaceSourceProfileStatus
  let runtime: WorkspaceSourceRuntimeStatus?

  private var isRunning: Bool { store.activeSourceOperationIDs.contains(profile.id) }
  private var needsToken: Bool {
    profile.type == "notion" && profile.syncArgs.contains("api") && !store.sourceHasStoredCredential(profile)
  }
  private var canSync: Bool { profile.ready && !needsToken }
  private var statusColor: Color { canSync && runtime?.ok != false ? .green : .orange }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: profile.type == "slack" ? "number.square.fill" : "doc.text.fill")
          .foregroundStyle(profile.type == "slack" ? Color.purple : Color.black.opacity(0.72))
        VStack(alignment: .leading, spacing: 2) {
          Text(profile.id.capitalized)
            .font(.headline)
          Text(runtime?.crawlerStatus?.summary ?? "Crawler status unavailable")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Label(
          needsToken ? "Needs token" : profile.ready ? "Ready" : "Needs setup",
          systemImage: canSync ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
          .font(.caption.weight(.semibold))
          .foregroundStyle(statusColor)
      }

      if let counts = runtime?.crawlerStatus?.counts, !counts.isEmpty {
        HStack(spacing: 16) {
          ForEach(Array(counts.prefix(4))) { count in
            VStack(alignment: .leading, spacing: 1) {
              Text(count.value.formatted())
                .font(.callout.monospacedDigit().weight(.semibold))
              Text(count.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
        GridRow {
          Text("Window").foregroundStyle(.secondary)
          Text(profile.ingestionSince ?? "All available")
        }
        if let workspaceID = profile.workspaceId {
          GridRow {
            Text("Workspace").foregroundStyle(.secondary)
            Text(workspaceID).textSelection(.enabled)
          }
        }
        GridRow {
          Text("Raw").foregroundStyle(.secondary)
          Text(profile.rawZone).lineLimit(1).truncationMode(.middle)
        }
        GridRow {
          Text("Review").foregroundStyle(.secondary)
          Text(profile.reviewZone).lineLimit(1).truncationMode(.middle)
        }
        if let lastSync = runtime?.crawlerStatus?.lastSyncAt {
          GridRow {
            Text("Last sync").foregroundStyle(.secondary)
            Text(lastSync).textSelection(.enabled)
          }
        }
        if let schedule = profile.schedule {
          GridRow {
            Text("Schedule").foregroundStyle(.secondary)
            Text(schedule.summary)
          }
          if let nextRunAt = store.sourceScheduleStates[profile.id]?.nextRunAt {
            GridRow {
              Text("Next automatic").foregroundStyle(.secondary)
              Text(nextRunAt.formatted(date: .abbreviated, time: .shortened))
            }
          }
          if let lastAttemptAt = store.sourceScheduleStates[profile.id]?.lastAttemptAt {
            GridRow {
              Text("Last attempt").foregroundStyle(.secondary)
              Text(lastAttemptAt.formatted(date: .abbreviated, time: .shortened))
            }
          }
        }
      }
      .font(.caption)

      if let scheduleError = store.sourceScheduleStates[profile.id]?.lastError {
        Label(scheduleError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      if let message = store.sourceOperationMessages[profile.id] {
        Text(message)
          .font(.caption)
          .foregroundStyle(message.localizedCaseInsensitiveContains("failed") || message.localizedCaseInsensitiveContains("error") ? Color.red : Color.secondary)
          .textSelection(.enabled)
      }

      ViewThatFits(in: .horizontal) {
        sourceActions
        VStack(alignment: .leading, spacing: 8) { sourceActions }
      }
    }
    .padding(16)
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(WorkspaceDesign.hairline, lineWidth: 1)
    }
  }

  private var sourceActions: some View {
    HStack(spacing: 8) {
      Button {
        Task { await store.syncAndStageSource(profile) }
      } label: {
        Label(isRunning ? "Working" : "Sync & Stage", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(isRunning || !canSync)

      Button("Preview") {
        Task { await store.previewSourceImport(profile) }
      }
      .disabled(isRunning || !profile.ready)

      Button("Check Setup") {
        Task { await store.checkSourceSetup(profile) }
      }
      .disabled(isRunning)

      Button("Reveal Reviews") {
        store.revealSourceReviews(profile)
      }

      if profile.type == "notion" {
        Button(store.sourceHasStoredCredential(profile) ? "Replace Token" : "Add Token") {
          store.presentSourceCredential(for: profile)
        }
        if store.sourceHasStoredCredential(profile) {
          Button("Remove Token", role: .destructive) {
            store.deleteSourceCredential(profile)
          }
        }
      }
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
  }
}

private struct SourceCredentialSheet: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Connect Notion")
        .font(.title2.weight(.semibold))
      Text("Paste a Notion internal integration token. Org2 stores it in macOS Keychain and passes it only to notcrawl; it is never written to the corpus.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      SecureField("Notion token", text: $store.sourceCredentialDraft)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("Cancel") {
          store.sourceCredentialDraft = ""
          store.isSourceCredentialPresented = false
        }
        Button("Save Token") {
          store.savePresentedSourceCredential()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(store.sourceCredentialDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(22)
    .frame(width: 480)
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
        List {
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
                MeetingRow(
                  meeting: meeting,
                  isProcessing: store.isMeetingProcessing(meeting),
                  sourceReference: store.relativePath(meeting.file) + ":\(meeting.lineForEditor)"
                )
                  .contentShape(Rectangle())
                  .onTapGesture {
                    if store.selectedMeetingID == meeting.id {
                      store.selectMeeting(meeting)
                    } else {
                      store.selectedMeetingID = meeting.id
                    }
                  }
                  .modifier(ReadableListSelectionModifier(isSelected: store.selectedMeetingID == meeting.id))
                  .listRowBackground(Color.clear)
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
          performAfterSwiftUIViewUpdate {
            guard store.selectedMeetingID == id else { return }
            store.selectMeeting(meeting)
          }
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
  let meeting: MeetingWorkspaceItem
  let isProcessing: Bool
  let sourceReference: String

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

        Text(sourceReference)
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
  case homePane

  var isCompact: Bool {
    self != .fullPage
  }
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

      chatColumn
    }
    .sheet(isPresented: $isShowingConfiguration) {
      OpenClawConfigurationSheet()
        .environmentObject(store)
    }
    .task {
      await store.refreshOpenClawCommands()
    }
  }

  private var chatColumn: some View {
    VStack(spacing: 0) {
      chatTranscript

      Divider()

      OpenClawComposerView(
        focusOnAppear: presentation != .assistantPanel,
        compact: presentation.isCompact
      )
      .padding(presentation.isCompact ? 10 : 16)
    }
  }

  @ViewBuilder
  private var header: some View {
    switch presentation {
    case .fullPage:
      HeaderBar(
        title: "\(store.selectedAIChatRuntime.title) Chat",
        subtitle: store.openClawStatusText,
        surface: surface
      ) {
        headerActions
      }
    case .homePane:
      HeaderBar(title: "AI Chat", subtitle: store.openClawStatusText, surface: surface) {
        homeHeaderActions
      }
    case .assistantPanel:
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(store.selectedAIChatRuntime.title)
            .font(.headline)
          Text(store.openClawStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Spacer(minLength: 0)
        Button {
          isShowingConfiguration = true
        } label: {
          Label("Configure", systemImage: "slider.horizontal.3")
        }
        .labelStyle(.iconOnly)
        .help("Configure AI Chat")

        Button {
          store.makeSurfacePrimary(.openClaw)
        } label: {
          Label("Make Primary", systemImage: "rectangle.split.2x1")
        }
        .labelStyle(.iconOnly)
        .help("Open AI Chat")

        Button {
          store.expandSurface(.openClaw)
        } label: {
          Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .labelStyle(.iconOnly)
        .help("Show only AI Chat")

        Button {
          store.closeSurfacePane(.openClaw)
        } label: {
          Label("Close", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .help("Close AI Chat")
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
    newChatButton

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

  private var newChatButton: some View {
    Button {
      store.createAIChatThread()
    } label: {
      Label("New", systemImage: "plus")
    }
  }

  @ViewBuilder
  private var homeHeaderActions: some View {
    newChatButton

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

  private var chatTranscript: some View {
    let scrollUpdate = OpenClawChatScrollUpdate(
      threadID: store.selectedOpenClawChatThreadID,
      messageCount: store.openClawMessages.count,
      isSending: store.isSendingOpenClawMessage
    )

    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: presentation.isCompact ? 8 : 10) {
          if store.openClawMessages.isEmpty {
            EmptyChatView(statusText: store.openClawStatusText)
              .frame(maxWidth: .infinity, minHeight: presentation.isCompact ? 140 : 220)
          } else {
            ForEach(store.openClawMessages) { message in
              ChatBubbleView(
                message: message,
                runtime: store.selectedAIChatRuntime,
                compact: presentation.isCompact
              )
                .id(message.id)
            }
            if store.isSendingOpenClawMessage {
              OpenClawTypingIndicatorView(
                startedAt: store.openClawRequestStartedAt,
                runtime: store.selectedAIChatRuntime,
                connectionState: store.openClawGatewayConnectionState,
                connectionDetail: store.openClawGatewayConnectionDetail,
                runID: store.openClawActiveRunID,
                streamingReply: store.openClawStreamingReply,
                reasoning: store.openClawExposedReasoning,
                activities: store.openClawRunActivities,
                compact: presentation.isCompact,
                onStop: {
                  Task { await store.stopOpenClawRun() }
                }
              )
                .id("openclaw-typing")
            }
          }
        }
        .textSelection(.enabled)
        .padding(presentation.isCompact ? 10 : 16)
      }
      .defaultScrollAnchor(.bottom)
      .id(store.openClawChatSelectionGeneration)
      .background(OpenClawChatScrollPositionBridge(
        threadID: store.selectedOpenClawChatThreadID,
        selectionGeneration: store.openClawChatSelectionGeneration,
        initialPosition: store.openClawChatScrollPosition(isAssistantPanel: presentation.isCompact),
        onPositionChange: { position in
          store.recordOpenClawChatScrollPosition(position, isAssistantPanel: presentation.isCompact)
        }
      ))
      .onChange(of: scrollUpdate) { previous, current in
        switch current.animatedTarget(after: previous) {
        case .latestMessage:
          if let last = store.openClawMessages.last {
            withAnimation(WorkspaceMotion.quick) {
              proxy.scrollTo(last.id, anchor: .bottom)
            }
          }
        case .typingIndicator:
          withAnimation(WorkspaceMotion.quick) {
            proxy.scrollTo("openclaw-typing", anchor: .bottom)
          }
        case nil:
          break
        }
      }
    }
  }
}

enum OpenClawChatAnimatedScrollTarget: Equatable {
  case latestMessage
  case typingIndicator
}

struct OpenClawChatScrollUpdate: Equatable {
  let threadID: UUID?
  let messageCount: Int
  let isSending: Bool

  func animatedTarget(after previous: Self) -> OpenClawChatAnimatedScrollTarget? {
    guard threadID == previous.threadID else { return nil }
    if isSending && !previous.isSending {
      return .typingIndicator
    }
    if messageCount > previous.messageCount {
      return .latestMessage
    }
    return nil
  }
}

struct OpenClawChatScrollRestoration: Equatable {
  let threadID: UUID?
  let selectionGeneration: Int
  let savedPosition: Double?

  var position: Double {
    min(1, max(0, savedPosition ?? 1))
  }

  func requiresNewRestoration(after previous: Self) -> Bool {
    threadID != previous.threadID || selectionGeneration != previous.selectionGeneration
  }
}

private struct OpenClawChatScrollPositionBridge: NSViewRepresentable {
  let threadID: UUID?
  let selectionGeneration: Int
  let initialPosition: Double?
  let onPositionChange: (Double) -> Void

  private var restoration: OpenClawChatScrollRestoration {
    OpenClawChatScrollRestoration(
      threadID: threadID,
      selectionGeneration: selectionGeneration,
      savedPosition: initialPosition
    )
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.updateParent(self)
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
    private var restoration: OpenClawChatScrollRestoration

    init(parent: OpenClawChatScrollPositionBridge) {
      self.parent = parent
      restoration = parent.restoration
      super.init()
    }

    func updateParent(_ parent: OpenClawChatScrollPositionBridge) {
      let nextRestoration = parent.restoration
      self.parent = parent
      guard nextRestoration.requiresNewRestoration(after: restoration) else { return }
      restoration = nextRestoration
      didRestore = false
      isRestoring = false
      restoreAttempts = 0
      stopObserving()
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
      restore(scrollView, to: restoration.position)
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
  @State private var localEditsEnabled = false
  @State private var briefsStartNewThread = true
  @State private var autoSettleInterval = OpenClawAutoSettleInterval.never
  @State private var token = ""
  @State private var clearToken = false
  @State private var isRequestingPairing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("AI Chat")
          .font(.headline.weight(.semibold))
        Text("Use OpenClaw or local Codex with ChatGPT on a per-thread basis.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      GroupBox {
        HStack(alignment: .center, spacing: 12) {
          Image(systemName: AIChatRuntime.codex.systemImage)
            .font(.title3)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            Text("Codex")
              .font(.callout.weight(.medium))
            Text(store.codexAccountState.label)
              .font(.caption)
              .foregroundStyle(
                store.codexAccountState.isReady ? Color.secondary : Color.orange
              )
              .lineLimit(2)
          }
          Spacer(minLength: 12)
          Button {
            Task {
              await store.beginCodexChatGPTLogin()
            }
          } label: {
            if store.isCodexSigningIn {
              HStack(spacing: 6) {
                WorkspaceActivityIndicator(size: .small, style: .signal)
                Text("Signing In")
              }
            } else {
              Text("Sign In with ChatGPT")
            }
          }
          .disabled(store.isCodexSigningIn)
        }
        .padding(.vertical, 4)
      } label: {
        Text("Local Codex")
      }

      VStack(alignment: .leading, spacing: 3) {
        Text("OpenClaw Gateway")
          .font(.callout.weight(.semibold))
        Text("Configure the local or network gateway used by OpenClaw threads.")
          .font(.caption)
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
          Text("Local Edits")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            Toggle("Read and apply Org2 edits on this Mac", isOn: $localEditsEnabled)
            Text("Uses a paired, typed Org2 node with read → preview → apply. It does not expose a shell.")
              .font(.caption2)
              .foregroundStyle(.secondary)
            if localEditsEnabled || store.openClawLocalEditsEnabled {
              Text(
                "\(store.openClawLocalEditNodeState.label)"
                  + (store.openClawLocalEditNodeDetail.isEmpty ? "" : " — \(store.openClawLocalEditNodeDetail)")
              )
              .font(.caption2)
              .foregroundStyle(
                store.openClawLocalEditNodeState == .connected ? Color.green : Color.secondary
              )
              .lineLimit(3)
            }
          }
          .frame(width: 430, alignment: .leading)
        }

        GridRow {
          Text("Briefs")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Toggle("Start node briefs in a new chat thread", isOn: $briefsStartNewThread)
            .help("When enabled, Brief creates a fresh OpenClaw chat instead of adding the prompt to the current thread.")
        }

        GridRow {
          Text("Settle Threads")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            Picker("Settle inactive threads", selection: $autoSettleInterval) {
              ForEach(OpenClawAutoSettleInterval.allCases) { interval in
                Text(interval.title).tag(interval)
              }
            }
            .labelsHidden()
            .frame(width: 220)
            Text("Selected, pinned, unread, pending, or currently failed/interrupted threads stay active.")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
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
        Button {
          guard saveConfiguration() else { return }
          isRequestingPairing = true
          Task {
            await store.requestOpenClawGatewayPairing()
            isRequestingPairing = false
          }
        } label: {
          if isRequestingPairing {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .small, style: .signal)
              Text("Requesting Pairing")
            }
          } else {
            Label("Save & Request Pairing", systemImage: "lock.open")
          }
        }
        .disabled(isRequestingPairing)
        .help("Create a stable Org2 Workspace device identity and request Gateway operator access")
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        Button("Save") {
          if saveConfiguration() { dismiss() }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
    .frame(width: 640)
    .task {
      await store.refreshCodexAccount()
    }
    .onAppear {
      endpoint = store.openClawEndpointText
      agent = store.openClawAgentID
      handoffAssignee = store.agentHandoffAssignee
      personalAssigneeNames = store.personalAssigneeNamesText
      remoteCorpusPath = store.openClawRemoteCorpusPath
      localEditsEnabled = store.openClawLocalEditsEnabled
      briefsStartNewThread = store.openClawBriefsStartNewThread
      autoSettleInterval = store.openClawThreadSettlementSettings.interval
      token = ""
      clearToken = false
    }
  }

  private func saveConfiguration() -> Bool {
    store.saveOpenClawConfiguration(
      endpoint: endpoint,
      agent: agent,
      handoffAssignee: handoffAssignee,
      personalAssigneeNames: personalAssigneeNames,
      remoteCorpusPath: remoteCorpusPath,
      briefsStartNewThread: briefsStartNewThread,
      autoSettleInterval: autoSettleInterval,
      localEditsEnabled: localEditsEnabled,
      token: token,
      clearToken: clearToken
    )
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

private struct DataSourceConfigurationSheet: View {
  @EnvironmentObject private var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  @State private var apiKey = ""
  @State private var clearAPIKey = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Data Refresh Credentials")
          .font(.title3.weight(.semibold))
        Text("Used when a notebook refreshes the Scarf Metabase data source.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if let failure = store.dataNotebookRefreshFailure,
         failure.needsCredentialUpdate {
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: failure.kind == .authentication ? "key.slash.fill" : "key.fill")
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 3) {
            Text(failure.title)
              .font(.callout.weight(.semibold))
            Text(failure.message)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        }
      }

      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text("API Key")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(width: 74, alignment: .trailing)
        SecureField(
          store.dataNotebookRefreshFailure?.kind == .authentication
            ? "Paste a new Metabase API key"
            : (store.scarfMetabaseHasStoredAPIKey ? "Saved key unchanged" : "Metabase API key"),
          text: $apiKey
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 360)
      }

      Toggle("Clear saved API key", isOn: $clearAPIKey)
        .disabled(!store.scarfMetabaseHasStoredAPIKey)

      Text("The API key is stored in macOS Keychain. Non-secret data-source settings live in org2.json.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let configurationError = store.dataSourceConfigurationError {
        Label(configurationError, systemImage: "exclamationmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(store.dataNotebookRefreshFailure == nil ? "Save" : "Save & Retry") {
          let shouldRetry = store.dataNotebookRefreshFailure != nil && store.selectedFileIsDataNotebook
          if store.saveScarfMetabaseConfiguration(
            apiKey: apiKey,
            clearAPIKey: clearAPIKey
          ) {
            dismiss()
            if shouldRetry {
              Task { await store.refreshSelectedDataNotebook() }
            }
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
    .frame(width: 540)
    .onAppear {
      apiKey = ""
      clearAPIKey = false
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
  let item: AssignedWorkItem
  let sourceReference: String
  let isSelected: Bool

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
          Text(sourceReference)
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? WorkspaceDesign.selectedFill : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Capsule()
          .fill(Color.accentColor)
          .frame(width: 3)
          .padding(.vertical, 8)
      }
    }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct DetailView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let run = store.presentedAgentRun {
        RunCenterDetail(run: run)
      } else if let location = store.selectedLocation {
        DetailHeader(
          location: location,
          renderedViewportSourceLine: store.currentDocumentViewportSourceLine
        )
        Divider()
        VStack(spacing: 0) {
          if store.isLiveFileEditorSelected {
            LiveFileEditorBody(
              location: location,
              reportViewportSourceLine: { store.recordDocumentViewportSourceLine($0) }
            )
              .frame(minWidth: 420, idealWidth: 560, maxHeight: .infinity)
          } else {
            EntryBodyView(
              location: location,
              reportViewportSourceLine: { store.recordDocumentViewportSourceLine($0) }
            )
            .frame(minWidth: 420, idealWidth: 560, maxHeight: .infinity)
          }

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
  let renderedViewportSourceLine: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 16) {
          detailIdentity
            .frame(maxWidth: .infinity, alignment: .leading)
          if !headerMetadataRows.isEmpty {
            DetailMetadataGrid(rows: headerMetadataRows)
              .fixedSize(horizontal: true, vertical: false)
          }
          DetailPaneControlGroup()
        }

        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .top, spacing: 8) {
            detailIdentity
              .frame(maxWidth: .infinity, alignment: .leading)
            DetailPaneControlGroup()
          }
          if !headerMetadataRows.isEmpty {
            DetailMetadataGrid(rows: headerMetadataRows)
          }
        }
      }

      detailActionBar

      if store.selectedFileIsDataNotebook,
         let failure = store.dataNotebookRefreshFailure {
        dataNotebookRefreshFailureBanner(failure)
      }

      if store.isPageSearchPresented {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(WorkspaceDesign.secondaryText)
          TextField("Find in page", text: $store.pageSearchQuery)
            .textFieldStyle(.roundedBorder)
            .focused($isPageSearchFocused)
            .onSubmit {
              store.selectNextPageSearchOccurrence()
            }
          Text(store.pageSearchOccurrenceSummary)
            .font(.caption.monospacedDigit())
            .foregroundStyle(store.pageSearchOccurrenceCount == 0
              ? WorkspaceDesign.secondaryText
              : WorkspaceDesign.primaryText)
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
    .padding(.horizontal, WorkspaceDesign.headerHorizontalInset)
    .padding(.vertical, WorkspaceDesign.headerVerticalInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkspaceDesign.surfaceBackground)
    .onChange(of: store.pageSearchFocusToken) {
      isPageSearchFocused = true
    }
  }

  private var detailIdentity: some View {
    HStack(alignment: .top, spacing: 9) {
      WorkspaceIconBadge(systemImage: locationIcon, tint: .accentColor, fill: Color.accentColor.opacity(0.09))
      VStack(alignment: .leading, spacing: 3) {
        Text(location.title)
          .font(.title3.weight(.semibold))
          .lineLimit(nil)
        if !location.subtitle.isEmpty {
          Text(location.subtitle)
            .font(.caption)
            .foregroundStyle(WorkspaceDesign.secondaryText)
            .lineLimit(nil)
        }
        Text(store.relativePath(location.file) + ":\(location.lineForEditor)")
          .font(.caption2)
          .foregroundStyle(WorkspaceDesign.tertiaryText)
          .textSelection(.enabled)
      }
    }
  }

  private var headerMetadataRows: [(String, String)] {
    DetailMetadata.rows(for: location).filter { row in
      !(row.0 == "Zone" && row.1 == location.subtitle)
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
    .buttonStyle(WorkspaceActionButtonStyle())
  }

  private func dataNotebookRefreshFailureBanner(_ failure: DataNotebookRefreshFailure) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: failure.needsCredentialUpdate ? "key.slash.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 2) {
        Text(failure.title)
          .font(.callout.weight(.semibold))
        Text(failure.message)
          .font(.caption)
          .foregroundStyle(WorkspaceDesign.secondaryText)
          .lineLimit(3)
      }

      Spacer(minLength: 12)

      if failure.needsCredentialUpdate {
        Button("Update Credentials") {
          store.presentScarfMetabaseConfiguration()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Button {
        Task { await store.refreshSelectedDataNotebook() }
      } label: {
        Label("Retry Refresh", systemImage: "arrow.clockwise")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help("Retry data refresh")
      .disabled(store.isRefreshingDataNotebook)

      Button {
        store.dismissDataNotebookRefreshFailure()
      } label: {
        Label("Dismiss", systemImage: "xmark")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help("Dismiss refresh error")
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(Color.orange.opacity(0.24), lineWidth: 1)
    }
  }

  private var fullDetailActionBar: some View {
    HStack(spacing: 7) {
      WorkspaceControlStrip {
        detailNavigationControls
        viewAndResourceControls
      }
      Spacer(minLength: 8)
      WorkspaceControlStrip {
        primaryDocumentControls
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var compactDetailActionBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      WorkspaceControlStrip {
        detailNavigationControls
        viewAndResourceControls
      }

      HStack(spacing: 7) {
        Spacer(minLength: 0)
        WorkspaceControlStrip {
          primaryDocumentControls
        }
      }
    }
  }

  private var detailNavigationControls: some View {
    Group {
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

  private var viewAndResourceControls: some View {
    HStack(spacing: 7) {
      if !store.isLiveFileEditorSelected && !store.hasActiveEdit {
        scopePicker
      }
      if !store.hasActiveEdit {
        documentLayoutMenu
      }
      sourceMenu
      intelligenceMenu
    }
  }

  private var primaryDocumentControls: some View {
    HStack(spacing: 7) {
      if store.selectedFileIsDataNotebook {
        Button {
          Task { await store.refreshSelectedDataNotebook() }
        } label: {
          if store.isRefreshingDataNotebook {
            HStack(spacing: 5) {
              WorkspaceActivityIndicator(size: .small)
              Text("Refreshing Data")
            }
          } else {
            Label("Refresh Data", systemImage: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(!store.canRefreshSelectedDataNotebook)
        .help("Run every named data result in this notebook and update its generated tables")
      }
      editControls
      organizeMenu
    }
  }

  private var documentLayoutMenu: some View {
    Menu {
      Picker("Preview", selection: $store.documentPreviewKind) {
        Label("Document", systemImage: "doc.richtext")
          .tag(OrgDocumentPreviewKind.document)
        Label("Slides", systemImage: "rectangle.on.rectangle")
          .tag(OrgDocumentPreviewKind.slides)
          .disabled(!store.canPreviewSlides)
      }

      Divider()

      Picker("Document Width", selection: $store.renderedDocumentWidth) {
        ForEach(RenderedDocumentWidth.allCases) { width in
          Text(width.title).tag(width)
        }
      }

      Picker("Side Margins", selection: $store.renderedDocumentMargin) {
        ForEach(RenderedDocumentMargin.allCases) { margin in
          Text(margin.title).tag(margin)
        }
      }

      Divider()

      Button {
        store.openAppHTMLStylesheet()
      } label: {
        Label(
          store.hasAppHTMLStylesheet ? "Edit Custom Stylesheet" : "Create Custom Stylesheet",
          systemImage: "paintbrush"
        )
      }

      if store.hasAppHTMLStylesheet {
        Button {
          store.retrySelectedEntryRendering()
        } label: {
          Label("Reload Custom Styles", systemImage: "arrow.clockwise")
        }
      }
    } label: {
      Label("View", systemImage: store.documentPreviewKind.systemImage)
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("Document or slide preview, width, margins, and stylesheet")
  }

  private var sourceMenu: some View {
    Menu {
      Button {
        store.togglePinnedFile(path: location.file)
      } label: {
        Label(
          store.isFilePinned(path: location.file) ? "Unpin File" : "Pin File",
          systemImage: store.isFilePinned(path: location.file) ? "pin.slash" : "pin"
        )
      }

      Divider()

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
        Task { await store.exportSlides(format: .pdf) }
      } label: {
        Label("Export Slides as PDF…", systemImage: "rectangle.on.rectangle")
      }
      .disabled(!store.canExportSlides)

      Button {
        Task { await store.exportSlides(format: .latex) }
      } label: {
        Label("Export Slides as LaTeX…", systemImage: "doc.plaintext")
      }
      .disabled(!store.canExportSlides)

      Divider()

      Button {
        Task { await store.linkifyCurrentFile() }
      } label: {
        Label("Linkify File", systemImage: "link.badge.plus")
      }
      .disabled(!store.canLinkifyCurrentFile)

      if store.selectedFileIsDataNotebook {
        Divider()

        Button {
          store.presentScarfMetabaseConfiguration()
        } label: {
          Label("Metabase Credentials…", systemImage: "key")
        }
      }
    } label: {
      Label("File", systemImage: "doc.text.magnifyingglass")
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("Open, reveal, or linkify this file")
  }

  private var intelligenceMenu: some View {
    Menu {
      Button {
        store.askOpenClawAboutCurrentSelection()
      } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      .disabled(!store.canAskOpenClawAboutCurrentSelection || store.isLoadingEntrySource)

      Button {
        store.openCanonicalOpenClawResourceThread()
      } label: {
        Label(
          "AI Thread",
          systemImage: store.hasCanonicalOpenClawResourceThread ? "text.bubble.fill" : "text.bubble"
        )
      }
      .disabled(!store.canOpenCanonicalOpenClawResourceThread)

      Divider()

      Button {
        store.toggleNodeContextPane()
      } label: {
        Label(store.isNodeContextPanePresented ? "Hide Context" : "Show Context", systemImage: "sidebar.right")
      }

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

      if case .meeting = location {
        Button {
          store.askOpenClawAboutSelectedMeeting()
        } label: {
          Label("Meeting", systemImage: "waveform.and.mic")
        }
      }
    } label: {
      Label("AI", systemImage: "sparkles")
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("Ask AI, open this resource's thread, or inspect context")
  }

  private var scopePicker: some View {
    Menu {
      Picker("Document Scope", selection: entrySourceModeSelection) {
        ForEach(EntrySourceMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
    } label: {
      Label(store.selectedEntrySourceMode.title, systemImage: "doc.text")
    }
    .accessibilityLabel("Document scope")
    .fixedSize(horizontal: true, vertical: false)
    .onChange(of: store.selectedEntrySourceMode) {
      Task { await store.reloadSelectedEntrySource() }
    }
    .help("Render entry or full page scope")
  }

  private var entrySourceModeSelection: Binding<EntrySourceMode> {
    Binding(
      get: { store.selectedEntrySourceMode },
      set: { store.selectEntrySourceMode($0) }
    )
  }

  @ViewBuilder
  private var editControls: some View {
    HStack(spacing: 6) {
      editStatusIndicator

      if store.hasActiveEdit {
        Button {
          Task { await store.saveActiveEdit() }
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .disabled(!store.canSaveActiveEdit)
        .help("Save changes (Command-S)")

        Button {
          store.cancelActiveEdit()
        } label: {
          Label("Cancel", systemImage: "xmark")
        }
        .help(hasPendingEditorChanges ? "Discard changes" : "Close source editor")

        Button {
          Task { await store.saveAndFinishActiveEdit() }
        } label: {
          Label("Save & Done", systemImage: "checkmark.circle")
        }
        .disabled(isPersistingEditorChanges)
        .help(hasPendingEditorChanges ? "Save changes and close the editor" : "Close the editor")
      } else {
        Button {
          store.beginEditingCurrentScope(atSourceLine: renderedViewportSourceLine)
        } label: {
          Label("Edit", systemImage: "square.and.pencil")
        }
        .disabled(store.selectedEntrySource?.isEditable != true || store.isLoadingEntrySource)
        .help("Edit this file")
      }
    }
  }

  private var editStatusIndicator: some View {
    ZStack {
      if isPersistingEditorChanges {
        WorkspaceActivityIndicator(size: .small)
          .accessibilityLabel("Saving changes")
      } else if hasPendingEditorChanges {
        Image(systemName: "circle.fill")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.orange)
          .accessibilityLabel("Unsaved changes")
      } else {
        Color.clear
          .accessibilityHidden(true)
      }
    }
    .frame(width: 24, height: 24)
    .help(editStatusHelp)
  }

  private var isPersistingEditorChanges: Bool {
    store.isSavingEntry || store.isSavingBlock || store.isLiveFileEditorAutosaving
  }

  private var hasPendingEditorChanges: Bool {
    store.entryEditorHasUnsavedChanges
      || store.editingBlockID != nil
      || store.liveFileEditorHasUnsavedChanges
  }

  private var editStatusHelp: String {
    if isPersistingEditorChanges {
      return "Saving changes"
    }
    if hasPendingEditorChanges {
      return "Unsaved changes. Press Command-S to save."
    }
    return "No unsaved editor changes"
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

private struct LiveFileEditorBody: View {
  @EnvironmentObject private var store: WorkspaceStore
  let location: WorkspaceLocation
  let reportViewportSourceLine: @MainActor (Int?) -> Void

  var body: some View {
    Group {
      if store.isLoadingEntrySource && store.selectedEntrySource == nil {
        OrgHTMLLoadingView(label: "Loading source", onCancel: store.cancelSelectedEntryLoading)
      } else if let source = store.selectedEntrySource {
        if store.isEditingEntry {
          OrgSourceEditorWithLinkTools()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.editingBlockID != nil {
          ScrollView {
            LegacyStructuredEntryEditorView(source: source)
              .padding(16)
          }
        } else {
          OrgRenderedDocumentPreview(
            source: source,
            loadingLabel: "Rendering page",
            reportViewportSourceLine: reportViewportSourceLine
          )
        }
      } else if let error = store.selectedEntryRenderError {
        OrgHTMLRenderFailureView(message: error)
      } else {
        EmptyStateView(title: "Source Unavailable", detail: store.statusText, action: "Reveal File") {
          store.revealFile(path: location.file)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct OrgRenderedDocumentPreview: View {
  @EnvironmentObject private var store: WorkspaceStore
  let source: EntrySource
  let loadingLabel: String
  let reportViewportSourceLine: @MainActor (Int?) -> Void

  var body: some View {
    Group {
      if store.documentPreviewKind == .slides {
        OrgSlidePreviewPane(reportViewportSourceLine: reportViewportSourceLine)
          .task(id: source) {
            store.scheduleSlidePreview(text: source.text, source: source, immediate: true)
          }
      } else if let html = store.selectedEntryHTML {
        OrgHTMLDocumentView(
          html: html,
          source: source,
          corpusRoot: store.corpusRoot,
          searchQuery: store.renderedSearchHighlightQuery,
          searchOccurrenceIndex: store.pageSearchSelectedOccurrenceIndex,
          searchOccurrenceCount: store.pageSearchOccurrenceCount,
          scrollRequest: store.detailScrollRequest,
          restorationSourceLine: store.documentViewportSourceLine(for: source),
          layout: store.renderedDocumentLayout,
          askAIAboutHeading: { store.askOpenClawAboutSourceHeading(at: $0) },
          reportStatus: { store.statusText = $0 },
          reportViewportSourceLine: reportViewportSourceLine
        )
      } else if let error = store.selectedEntryRenderError {
        OrgHTMLRenderFailureView(message: error)
      } else {
        OrgHTMLLoadingView(label: loadingLabel, onCancel: store.cancelSelectedEntryLoading)
      }
    }
  }
}

private struct LegacyStructuredEntryEditorView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let source: EntrySource

  var body: some View {
    OrgRenderedEntryView(
      blocks: store.selectedRenderedBlocks,
      blocksRenderSignature: store.selectedRenderedBlocksRenderSignature,
      source: OrgRenderedEntrySourceContext(source),
      corpusRoot: store.corpusRoot,
      selectedBlockID: store.selectedBlockID,
      selectedBlockIndex: store.selectedBlockID.flatMap { store.selectedRenderedBlockIndexes[$0] },
      editingBlockID: store.editingBlockID,
      foldedBlockIDs: store.foldedRenderedBlockIDs,
      detailScrollRequest: store.detailScrollRequest,
      sourceBlockRunsRenderSignature: store.sourceBlockRunsRenderSignature,
      sourceBlockRuns: store.sourceBlockRuns,
      searchHighlightQuery: store.renderedSearchHighlightQuery
    )
    .equatable()
  }
}

private struct OrgHTMLLoadingView: View {
  let label: String
  var onCancel: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 8) {
        WorkspaceActivityIndicator(size: .small, style: .scan)
        Text(label)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let onCancel {
        Button("Stop Waiting", action: onCancel)
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private struct OrgSlidePreviewPane: View {
  @EnvironmentObject private var store: WorkspaceStore
  var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }

  var body: some View {
    ZStack(alignment: .bottom) {
      if let pdf = store.slidePreviewPDF {
        OrgPDFDocumentView(
          data: pdf,
          restorationSourceLine: store.currentDocumentViewportSourceLine,
          restorationPageIndex: store.currentDocumentSlidePageIndex,
          reportViewportSourceLine: reportViewportSourceLine,
          reportViewportPageIndex: { store.recordDocumentSlidePageIndex($0) }
        )
      } else if store.isRenderingSlidePreview {
        OrgHTMLLoadingView(label: "Compiling slides", onCancel: store.cancelSlidePreview)
      } else {
        unavailableView
      }

      if store.slidePreviewPDF != nil,
         let error = store.slidePreviewError {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .lineLimit(2)
          Spacer(minLength: 8)
          Button("Retry") {
            store.retrySlidePreview()
          }
          .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
      }
    }
    .overlay(alignment: .topTrailing) {
      if store.slidePreviewPDF != nil,
         store.isRenderingSlidePreview {
        HStack(spacing: 6) {
          WorkspaceActivityIndicator(size: .small)
          Text("Compiling")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var unavailableView: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle.slash")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Slide preview unavailable")
        .font(.headline)
      Text(unavailableMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      if store.canPreviewSlides {
        Button {
          store.retrySlidePreview()
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var unavailableMessage: String {
    if !store.canPreviewSlides {
      return "Open the full Org or Org2 page to compile its slide deck."
    }
    return store.slidePreviewError ?? "Preparing the compiled PDF."
  }
}

private struct OrgHTMLRenderFailureView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Preview unavailable")
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      HStack(spacing: 8) {
        Button {
          store.retrySelectedEntryRendering()
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
        }
        if store.selectedEntrySource?.isEditable == true {
          Button {
            store.beginEditingSelectedEntry()
          } label: {
            Label("Edit Source", systemImage: "square.and.pencil")
          }
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private struct OrgSourceEditorWithLinkTools: View {
  @EnvironmentObject private var store: WorkspaceStore
  @Environment(\.orgRoamLinkResolver) private var orgRoamLinkResolver
  @State private var sourcePreviewLine: Int?
  @State private var sourcePreviewScrollTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      sourceEditorCommandBar

      if store.sourceEditorPresentation == .split {
        HSplitView {
          sourceColumn
            .frame(minWidth: 360)
          sourcePreview
            .frame(minWidth: 320)
        }
      } else {
        sourceColumn
      }
    }
    .task {
      scheduleSourcePreviewScroll()
      if store.sourceEditorPresentation == .split {
        store.scheduleSourceEditorPreview(immediate: true)
      }
    }
    .onChange(of: store.editableEntryText) {
      scheduleSourcePreviewScroll()
      store.scheduleSourceEditorPreview()
    }
    .onChange(of: store.sourceEditorSelection) {
      scheduleSourcePreviewScroll()
    }
    .onChange(of: store.sourceEditorPresentation) { _, presentation in
      scheduleSourcePreviewScroll()
      if presentation == .split {
        store.scheduleSourceEditorPreview(immediate: true)
      }
    }
    .onChange(of: store.documentPreviewKind) {
      scheduleSourcePreviewScroll()
      store.scheduleSourceEditorPreview(immediate: true)
    }
    .onDisappear {
      sourcePreviewScrollTask?.cancel()
    }
  }

  private var sourceColumn: some View {
    VStack(alignment: .leading, spacing: 8) {
      OrgSyntaxTextEditor(
        text: $store.editableEntryText,
        monospaced: true,
        showsScrollers: true,
        textInset: NSSize(width: 12, height: 12),
        focusOnAppear: true,
        textPublishing: .deferred(milliseconds: 180),
        liveHighlighting: true,
        incrementalHighlighting: true,
        concealsSyntax: false,
        orgWritingCommands: true,
        textChecking: .spellingAndGrammar,
        caretPublishingDelayMilliseconds: 180,
        commandRequest: store.sourceEditorCommandRequest,
        semanticAnalyzer: { text in
          await store.analyzeSourceEditorText(text)
        },
        diagnostics: $store.sourceEditorDiagnostics,
        onCommandStatus: { status in
          store.statusText = status
        },
        selection: $store.sourceEditorSelection,
        onViewportSourceLine: { line in
          guard let source = store.selectedEntrySource else { return }
          store.recordDocumentViewportSourceLine(
            source.startLine + line - 1,
            for: source
          )
        },
        onGutterBacklinks: { line in
          store.showSourceEditorBacklinks(at: line)
        },
        onLocalTextChange: { text in
          store.noteSourceEditorLocalTextChanged(text)
        },
        onSaveCommand: { context in
          store.editableEntryText = context.text
          Task { await store.saveEditedEntry() }
          return true
        }
      )
      .frame(minHeight: 320, maxHeight: .infinity)
      .layoutPriority(1)
      .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(WorkspaceDesign.hairline)
      )

      if hasSelection {
        ParagraphInlineFormatBar(
          text: $store.editableEntryText,
          selectedRange: $store.sourceEditorSelection,
          insertBacklink: insertBacklinkForSelection,
          createNodeFromSelection: createNodeFromSelection
        )
      }

      if let wikiLinkCompletionMatch {
        ParagraphWikiLinkCompletionPanel(
          query: wikiLinkCompletionMatch.query,
          candidates: orgRoamLinkResolver.searchCandidates(matching: wikiLinkCompletionMatch.query, limit: 6),
          choose: { node in
            resolveWikiLinkCompletion(wikiLinkCompletionMatch, to: node)
          },
          create: {
            createNodeFromWikiLinkCompletion(wikiLinkCompletionMatch)
          }
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var sourcePreview: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Label("Preview", systemImage: store.documentPreviewKind.systemImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 8)

        if (store.documentPreviewKind == .slides
          ? store.isRenderingSlidePreview
          : store.isRenderingSourceEditorPreview) {
          WorkspaceActivityIndicator(size: .small)
            .help("Updating preview")
        }

        Picker("Preview kind", selection: $store.documentPreviewKind) {
          Image(systemName: OrgDocumentPreviewKind.document.systemImage)
            .tag(OrgDocumentPreviewKind.document)
            .help(OrgDocumentPreviewKind.document.title)
          Image(systemName: OrgDocumentPreviewKind.slides.systemImage)
            .tag(OrgDocumentPreviewKind.slides)
            .help(OrgDocumentPreviewKind.slides.title)
            .disabled(!store.canPreviewSlides)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 68)
        .help("Rendered document or compiled slide PDF")

        Button {
          store.setSourceEditorPreviewPaused(!store.isSourceEditorPreviewPaused)
        } label: {
          Image(systemName: store.isSourceEditorPreviewPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.borderless)
        .frame(width: 24, height: 22)
        .help(store.isSourceEditorPreviewPaused ? "Resume live preview" : "Pause live preview")
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(WorkspaceDesign.panelFill)

      Divider()

      if store.documentPreviewKind == .slides {
        OrgSlidePreviewPane()
      } else {
        if let html = store.sourceEditorPreviewHTML,
           let source = store.selectedEntrySource {
          OrgHTMLDocumentView(
            html: html,
            source: source,
            corpusRoot: store.corpusRoot,
            searchQuery: nil,
            searchOccurrenceIndex: nil,
            searchOccurrenceCount: 0,
            scrollRequest: sourcePreviewScrollRequest,
            restorationSourceLine: store.documentViewportSourceLine(for: source),
            layout: store.renderedDocumentLayout,
            askAIAboutHeading: { store.askOpenClawAboutSourceHeading(at: $0) },
            reportStatus: { store.statusText = $0 },
            reportViewportSourceLine: { store.recordDocumentViewportSourceLine($0, for: source) }
          )
        } else if let error = store.sourceEditorPreviewError {
          OrgHTMLRenderFailureView(message: error)
        } else {
          OrgHTMLLoadingView(label: "Preparing preview")
        }
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(width: 1)
    }
  }

  private var sourcePreviewScrollRequest: DetailScrollRequest? {
    sourcePreviewLine.map { DetailScrollRequest(id: $0, target: .sourceLine($0)) }
  }

  private func scheduleSourcePreviewScroll() {
    sourcePreviewScrollTask?.cancel()
    guard store.sourceEditorPresentation == .split,
          let source = store.selectedEntrySource
    else {
      sourcePreviewLine = nil
      return
    }
    let text = store.editableEntryText
    let offset = min(max(0, store.sourceEditorSelection.location), text.utf16.count)
    sourcePreviewScrollTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 90_000_000)
      } catch {
        return
      }
      let localLine = await Task.detached(priority: .userInitiated) {
        1 + text.utf16.prefix(offset).reduce(into: 0) { count, unit in
          if unit == 10 { count += 1 }
        }
      }.value
      guard !Task.isCancelled else { return }
      sourcePreviewLine = source.startLine + localLine - 1
    }
  }

  private var sourceEditorCommandBar: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Menu {
          Button("Heading") { store.requestSourceEditorCommand(.insertHeading) }
          Button("List Item") { store.requestSourceEditorCommand(.insertListItem) }
          Divider()
          Button("Link...") { store.requestSourceEditorCommand(.insertLink) }
          Button("Property...") { store.requestSourceEditorCommand(.insertProperty) }
        } label: {
          Label("Insert", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        Button {
          store.requestSourceEditorCommand(.cycleTodo)
        } label: {
          Label("Cycle TODO", systemImage: "arrow.triangle.2.circlepath")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(width: 26, height: 24)
        .help("Cycle TODO (Command-Option-T)")

        Menu {
          Button("Schedule Today") { store.requestSourceEditorCommand(.scheduleToday) }
          Button("Deadline Today") { store.requestSourceEditorCommand(.deadlineToday) }
          Button("Clear Planning") { store.requestSourceEditorCommand(.clearPlanning) }
        } label: {
          Label("Planning", systemImage: "calendar.badge.clock")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .frame(width: 26, height: 24)
        .fixedSize()
        .help("Planning")
      }
      .fixedSize(horizontal: true, vertical: false)

      Divider()
        .frame(height: 18)

      ControlGroup {
        Button {
          store.requestSourceEditorCommand(.promote)
        } label: {
          Label("Promote", systemImage: "decrease.indent")
        }
        .labelStyle(.iconOnly)
        .help("Promote (Command-Option-Left Arrow)")

        Button {
          store.requestSourceEditorCommand(.demote)
        } label: {
          Label("Demote", systemImage: "increase.indent")
        }
        .labelStyle(.iconOnly)
        .help("Demote (Command-Option-Right Arrow)")
      }
      .fixedSize(horizontal: true, vertical: false)

      Divider()
        .frame(height: 18)

      Menu {
        Button("Toggle Current Heading") { store.requestSourceEditorCommand(.toggleFold) }
        Button("Expand All") { store.requestSourceEditorCommand(.unfoldAll) }
        Divider()
        Button("Previous Heading") { store.requestSourceEditorCommand(.previousHeading) }
        Button("Next Heading") { store.requestSourceEditorCommand(.nextHeading) }
      } label: {
        Label("Outline", systemImage: "list.bullet.indent")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Outline and folding")

      Spacer(minLength: 8)

      if let diagnostic = store.sourceEditorDiagnostics.first {
        Label(
          store.sourceEditorDiagnostics.count == 1
            ? "Line \(diagnostic.line)"
            : "\(store.sourceEditorDiagnostics.count) issues",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .help(diagnostic.message)
      }

      Divider()
        .frame(height: 18)

      Picker("Editor presentation", selection: $store.sourceEditorPresentation) {
        ForEach(SourceEditorPresentation.allCases) { presentation in
          Image(systemName: presentation.systemImage)
            .tag(presentation)
            .help(presentation.title)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 68)
      .help("Source only or live source and HTML preview")
    }
    .controlSize(.small)
    .padding(.horizontal, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var hasSelection: Bool {
    store.sourceEditorSelection.length > 0
  }

  private var wikiLinkCompletionMatch: ParagraphWikiLinkCompletionMatch? {
    ParagraphWikiLinkCompletion.match(
      in: store.editableEntryText,
      selectedRange: store.sourceEditorSelection
    )
  }

  private func insertBacklinkForSelection() {
    guard let edit = WorkspaceStore.backlinkReplacementForSelectedText(
      in: store.editableEntryText,
      range: store.sourceEditorSelection
    ) else {
      store.statusText = "Select text first"
      return
    }
    applyInlineEdit(edit)
  }

  private func createNodeFromSelection() {
    let text = store.editableEntryText
    let range = store.sourceEditorSelection
    Task {
      guard let edit = await store.createKnowledgeNodeFromSelection(text: text, range: range) else {
        return
      }
      applyInlineEdit(edit)
    }
  }

  private func resolveWikiLinkCompletion(
    _ match: ParagraphWikiLinkCompletionMatch,
    to node: OrgRoamNodeReference
  ) {
    guard let edit = ParagraphWikiLinkCompletion.replacement(
      in: store.editableEntryText,
      match: match,
      node: node
    ) else {
      return
    }
    applyInlineEdit(edit)
  }

  private func createNodeFromWikiLinkCompletion(_ match: ParagraphWikiLinkCompletionMatch) {
    let text = store.editableEntryText
    Task {
      guard let edit = await store.createKnowledgeNodeFromWikiLinkCompletion(text: text, match: match) else {
        return
      }
      applyInlineEdit(edit)
    }
  }

  private func applyInlineEdit(_ edit: InlineSelectionReplacement) {
    store.editableEntryText = edit.text
    store.sourceEditorSelection = edit.selectedRange
  }
}

private struct EntryBodyView: View {
  @EnvironmentObject private var store: WorkspaceStore
  let location: WorkspaceLocation
  let reportViewportSourceLine: @MainActor (Int?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if store.isLoadingEntrySource && store.selectedEntrySource == nil {
        OrgHTMLLoadingView(label: "Loading source", onCancel: store.cancelSelectedEntryLoading)
      } else if let source = store.selectedEntrySource {
        if store.isEditingEntry {
          OrgSourceEditorWithLinkTools()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.editingBlockID != nil {
          ScrollView {
            LegacyStructuredEntryEditorView(source: source)
              .padding(16)
          }
        } else {
          OrgRenderedDocumentPreview(
            source: source,
            loadingLabel: "Rendering preview",
            reportViewportSourceLine: reportViewportSourceLine
          )
        }
      } else if let error = store.selectedEntryRenderError {
        OrgHTMLRenderFailureView(message: error)
      } else {
        fallbackBody(location)
          .padding(16)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

}

private enum DetailMetadata {
  static func rows(for location: WorkspaceLocation) -> [(String, String)] {
    switch location {
    case .agenda(let item):
      let planning = [item.kind, item.time].compactMap { $0 }.joined(separator: " ")
      let rows: [(String, String)] = [
        ("TODO", item.todo ?? ""),
        ("Planning", planning),
        ("Priority", item.priority.map { "[#\($0)]" } ?? ""),
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
        ("Modified", thread.modifiedAt.map(dateLabel) ?? ""),
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

  private static func nonEmptyRows(_ rows: [(String, String)]) -> [(String, String)] {
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
              .foregroundStyle(WorkspaceDesign.tertiaryText)
            Text(row.1)
              .font(.caption)
              .foregroundStyle(WorkspaceDesign.secondaryText)
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
      .help(store.openClawBriefsStartNewThread
        ? "Generate the brief in a new AI chat thread."
        : "Generate the brief in the current AI chat thread.")

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
        .help(store.openClawBriefsStartNewThread
          ? "Generate the brief in a new AI chat thread."
          : "Generate the brief in the current AI chat thread.")

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
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous))
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
      .background(WorkspaceDesign.controlFill, in: Capsule())
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
    .padding(.horizontal, WorkspaceDesign.headerHorizontalInset)
    .padding(.vertical, WorkspaceDesign.headerVerticalInset)
    .background(WorkspaceDesign.surfaceBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(height: 0.5)
    }
  }

  private func headerContent(compact: Bool) -> some View {
    HStack(alignment: .center, spacing: compact ? 8 : 12) {
      HStack(spacing: 9) {
        if let surface {
          WorkspaceIconBadge(
            systemImage: surface.systemImage,
            tint: .accentColor,
            fill: Color.accentColor.opacity(0.08)
          )
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline.weight(.semibold))
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
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .frame(minWidth: 38)
      .background(statusColor, in: Capsule())
  }

  private var statusColor: Color {
    switch text.uppercased() {
    case "TODO", "QUEUED": .blue.opacity(0.13)
    case "PROG", "IN_PROGRESS", "RUNNING": .indigo.opacity(0.14)
    case "WAIT", "HOLD", "PAUSED", "WAITING-APPROVAL", "BLOCKED": .orange.opacity(0.14)
    case "DONE", "COMPLETED": .green.opacity(0.14)
    case "FAILED": .red.opacity(0.13)
    case "CANCELLED", "CANCELED": Color.secondary.opacity(0.11)
    default: WorkspaceDesign.subtleFill
    }
  }

  private var statusForeground: Color {
    switch text.uppercased() {
    case "TODO", "QUEUED": .blue
    case "PROG", "IN_PROGRESS", "RUNNING": .indigo
    case "WAIT", "HOLD", "PAUSED", "WAITING-APPROVAL", "BLOCKED": .orange
    case "DONE", "COMPLETED": .green
    case "FAILED": .red
    case "CANCELLED", "CANCELED": .secondary
    default: .secondary
    }
  }
}

private struct EmptyStateView: View {
  let title: String
  let detail: String
  let action: String?
  let perform: (() -> Void)?

  init(
    title: String,
    detail: String,
    action: String? = nil,
    perform: (() -> Void)? = nil
  ) {
    self.title = title
    self.detail = detail
    self.action = action
    self.perform = perform
  }

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
      if let action, let perform {
        Button(action) {
          perform()
        }
        .buttonStyle(WorkspaceActionButtonStyle())
      }
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

enum CommandShortcutReveal {
  static func isActive(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
  }
}

private struct CommandShortcutRevealMonitor: ViewModifier {
  @Binding var isCommandPressed: Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        let commandPressed = $isCommandPressed
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
          commandPressed.wrappedValue = CommandShortcutReveal.isActive(for: event.modifierFlags)
          return event
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
        isCommandPressed = false
      }
      .onDisappear {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isCommandPressed = false
      }
  }
}

private struct KeyboardEventMonitor: ViewModifier {
  let handler: (NSEvent, WorkspaceKeyboardShortcutScope) -> Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          if WorkspaceKeyboardEventRouting.defersToNativeTextFind(
            event,
            sourceEditorActive: Self.isSourceEditorActive
          ) {
            return event
          }
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

  private static var isSourceEditorActive: Bool {
    NSApplication.shared.keyWindow?.firstResponder is OrgSyntaxTextView
  }
}

enum WorkspaceKeyboardEventRouting {
  static func defersToNativeTextFind(_ event: NSEvent, sourceEditorActive: Bool) -> Bool {
    guard sourceEditorActive else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let key = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()
    return modifiers == [.command] && key == "f"
  }

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
  func commandShortcutRevealMonitor(_ isCommandPressed: Binding<Bool>) -> some View {
    modifier(CommandShortcutRevealMonitor(isCommandPressed: isCommandPressed))
  }

  func keyboardEventMonitor(_ handler: @escaping (NSEvent, WorkspaceKeyboardShortcutScope) -> Bool) -> some View {
    modifier(KeyboardEventMonitor(handler: handler))
  }
}
