import SwiftUI

/// Small pill showing a heading's agent-work state, shared by agenda rows and
/// the Activity list.
struct HeadingWorkStateBadge: View {
  let state: HeadingWorkState

  var body: some View {
    HStack(spacing: 4) {
      if state == .working {
        CoreAnimationActivityDot(animates: true)
          .frame(width: 6, height: 6)
      } else {
        Image(systemName: state.systemImage)
          .font(.caption2.weight(.semibold))
      }
      Text(state.label)
        .font(.caption2.weight(.semibold))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 7)
    .padding(.vertical, 2)
    .background(tint.opacity(0.13), in: Capsule())
    .help(OrgHTMLHeadingWorkScript.help(for: state))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Agent work: \(state.label)")
  }

  private var tint: Color {
    switch state {
    case .working: .accentColor
    case .queued: .secondary
    case .yourTurn, .needsYou: .orange
    case .failed: .red
    case .done: .green
    }
  }
}

/// "What is happening across my corpus": a list of work that needs you, live
/// agent work, schedules, and recent changes, plus a zoomable map of the same
/// signals laid out by folder.
struct WorkspaceActivityView: View {
  enum Mode: String, CaseIterable, Identifiable {
    case now = "Now"
    case map = "Map"
    var id: String { rawValue }
  }

  @Environment(WorkspaceStore.self) private var store
  @AppStorage("workspaceActivityMode") private var modeRawValue = Mode.now.rawValue
  @State private var mapPrefix = ""

  private var mode: Mode { Mode(rawValue: modeRawValue) ?? .now }

  var body: some View {
    let snapshot = store.activitySnapshot()
    VStack(spacing: 0) {
      header(snapshot)
      Divider()
      if store.corpusRoot == nil {
        ContentUnavailableView("No Corpus", systemImage: "folder", description: Text("Open a corpus to see its activity."))
      } else {
        switch mode {
        case .now:
          ActivityNowList(snapshot: snapshot)
        case .map:
          ActivityMapView(snapshot: snapshot, prefix: $mapPrefix)
        }
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
  }

  private func header(_ snapshot: WorkspaceActivitySnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Activity")
            .font(.title2.weight(.semibold))
          Text(summary(snapshot))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 12)
        Picker("View", selection: $modeRawValue) {
          ForEach(Mode.allCases) { mode in
            Text(mode.rawValue).tag(mode.rawValue)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        Button {
          Task { await store.refreshActivitySources() }
        } label: {
          Label("Refresh Activity", systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .help("Refresh runs, approvals, and automations")
      }
      let agents = snapshot.activeAgents
      if !agents.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(agents, id: \.name) { agent in
              HStack(spacing: 5) {
                CoreAnimationActivityDot(animates: true)
                  .frame(width: 6, height: 6)
                Text(agent.name)
                  .font(.caption.weight(.semibold))
                if agent.count > 1 {
                  Text("\(agent.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(WorkspaceDesign.subtleFill, in: Capsule())
              .help("\(agent.name) is working in \(agent.count) place\(agent.count == 1 ? "" : "s")")
            }
          }
        }
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
  }

  private func summary(_ snapshot: WorkspaceActivitySnapshot) -> String {
    var parts: [String] = []
    if !snapshot.needsYou.isEmpty { parts.append("\(snapshot.needsYou.count) need you") }
    if !snapshot.working.isEmpty { parts.append("\(snapshot.working.count) in progress") }
    if !snapshot.scheduled.isEmpty { parts.append("\(snapshot.scheduled.count) scheduled") }
    if !snapshot.changed.isEmpty { parts.append("\(snapshot.changed.count) changed today") }
    return parts.isEmpty ? "Nothing in flight right now" : parts.joined(separator: " · ")
  }
}

private struct ActivityNowList: View {
  @Environment(WorkspaceStore.self) private var store
  let snapshot: WorkspaceActivitySnapshot

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        section("Needs you", systemImage: "exclamationmark.circle", items: snapshot.needsYou,
                empty: "Nothing is waiting on you.")
        section("Working now", systemImage: "bolt.horizontal", items: snapshot.working,
                empty: "No agent is working right now. Start work from a TODO with ▶ Start work.")
        section("Scheduled", systemImage: "clock", items: snapshot.scheduled,
                empty: "No active scheduled automations.")
        section("Changed today", systemImage: "pencil", items: snapshot.changed,
                empty: "No files changed in the last 24 hours.")
        recentlyOpened
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
    }
  }

  @ViewBuilder
  private func section(_ title: String, systemImage: String, items: [WorkspaceActivityItem], empty: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionHeader(title, systemImage: systemImage, count: items.count)
      if items.isEmpty {
        Text(empty)
          .font(.callout)
          .foregroundStyle(.tertiary)
          .padding(.leading, 2)
      } else {
        ForEach(items) { item in
          ActivityRow(item: item) { store.openActivityItem(item) }
        }
      }
    }
  }

  private func sectionHeader(_ title: String, systemImage: String, count: Int) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      if count > 0 {
        Text("\(count)")
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(WorkspaceDesign.subtleFill, in: Capsule())
      }
    }
  }

  @ViewBuilder
  private var recentlyOpened: some View {
    let files = store.recentCorpusFiles(limit: 8)
    if !files.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        sectionHeader("You were recently in", systemImage: "clock.arrow.circlepath", count: 0)
        ForEach(files) { file in
          Button {
            store.openActivityItem(WorkspaceActivityItem(
              id: "recent:\(file.relativePath)",
              kind: .changed,
              title: file.name,
              detail: "",
              target: .file(path: file.path, line: nil)
            ))
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
              Text(file.name)
                .lineLimit(1)
              Text(file.directory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }
}

private struct ActivityRow: View {
  let item: WorkspaceActivityItem
  let open: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: open) {
      HStack(alignment: .top, spacing: 10) {
        icon
          .frame(width: 18, height: 18)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(item.title)
              .font(.body.weight(.medium))
              .lineLimit(1)
            if let state = item.state, item.kind != .working || state != .working {
              HeadingWorkStateBadge(state: state)
            }
          }
          HStack(spacing: 6) {
            Text(item.detail)
              .lineLimit(1)
            if let path = item.relativePath, item.kind != .changed {
              Text("·")
              Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 3) {
          if let agent = item.agent {
            Text(agent)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          if let date = item.date {
            Text(date, style: .relative)
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
          .fill(isHovered ? WorkspaceDesign.controlHoverFill : WorkspaceDesign.panelFill)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityLabel("\(item.title), \(item.detail)")
  }

  @ViewBuilder
  private var icon: some View {
    switch item.kind {
    case .working:
      CoreAnimationActivityDot(animates: true)
        .frame(width: 8, height: 8)
    case .needsYou:
      Image(systemName: item.state?.systemImage ?? "exclamationmark.circle")
        .foregroundStyle(.orange)
    case .scheduled:
      Image(systemName: "clock")
        .foregroundStyle(.secondary)
    case .changed:
      Image(systemName: "pencil")
        .foregroundStyle(.secondary)
    }
  }
}

/// A folder treemap of the corpus. Tiles are sized by (compressed) file count
/// plus live signals and carry badges for attention, live work, schedules,
/// and recent edits. Click a folder to zoom in, a file to open it.
private struct ActivityMapView: View {
  @Environment(WorkspaceStore.self) private var store
  let snapshot: WorkspaceActivitySnapshot
  @Binding var prefix: String

  var body: some View {
    let areas = store.activityMapAreas(prefix: prefix, snapshot: snapshot)
    VStack(spacing: 0) {
      breadcrumbs
      Divider()
      if areas.isEmpty {
        ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("No files here."))
      } else {
        GeometryReader { proxy in
          let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 10, dy: 10)
          let rects = WorkspaceActivityMap.treemap(weights: areas.map(\.weight), in: bounds)
          ZStack(alignment: .topLeading) {
            ForEach(Array(areas.enumerated()), id: \.element.id) { index, area in
              let rect = rects[index].insetBy(dx: 2, dy: 2)
              ActivityMapTile(area: area, size: rect.size) {
                select(area)
              }
              .frame(width: max(0, rect.width), height: max(0, rect.height))
              .offset(x: rect.minX, y: rect.minY)
            }
          }
        }
      }
      Divider()
      legend
    }
    .onChange(of: store.corpusRoot) { prefix = "" }
  }

  private var breadcrumbs: some View {
    HStack(spacing: 4) {
      Button {
        zoom(to: parentPrefix)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(prefix.isEmpty)
      .help("Up one level")
      Button("Corpus") { zoom(to: "") }
        .buttonStyle(.borderless)
        .fontWeight(prefix.isEmpty ? .semibold : .regular)
      ForEach(WorkspaceActivityMap.breadcrumbs(for: prefix), id: \.path) { crumb in
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Button(crumb.name) { zoom(to: crumb.path) }
          .buttonStyle(.borderless)
          .fontWeight(crumb.path == prefix ? .semibold : .regular)
      }
      Spacer()
    }
    .font(.callout)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private var legend: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 14) {
        legendItem(color: .orange, systemImage: "exclamationmark.circle.fill", text: "Needs you")
        legendItem(color: .accentColor, systemImage: "circle.fill", text: "Agent working")
        legendItem(color: .secondary, systemImage: "clock", text: "Scheduled")
        legendItem(color: .secondary, systemImage: "pencil", text: "Changed today")
      }
      .font(.caption)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
    }
    .help("Tiles are sized by file count and activity. Click a folder to zoom in.")
  }

  private func legendItem(color: Color, systemImage: String, text: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage).foregroundStyle(color)
      Text(text).foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .fixedSize()
  }

  private var parentPrefix: String {
    guard let slash = prefix.lastIndex(of: "/") else { return "" }
    return String(prefix[..<slash])
  }

  private func select(_ area: WorkspaceActivityArea) {
    if area.isFile {
      store.openActivityMapFile(relativePath: area.path)
    } else {
      zoom(to: area.path)
    }
  }

  private func zoom(to path: String) {
    guard path != prefix else { return }
    store.usageLog.record(.activityMapNavigate, [
      "action": path.count > prefix.count ? "zoom_in" : "zoom_out",
      "depth": .int(path.isEmpty ? 0 : path.split(separator: "/").count),
    ])
    withAnimation(ActivityMotion.zoom) { prefix = path }
  }
}

private struct ActivityMapTile: View {
  let area: WorkspaceActivityArea
  let size: CGSize
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 5) {
          Image(systemName: area.isFile ? "doc.text" : "folder")
            .foregroundStyle(.secondary)
          Text(area.name)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if size.height > 48, !area.isFile {
          Text("\(area.fileCount) file\(area.fileCount == 1 ? "" : "s")")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 0)
        if size.height > 36 {
          badges
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(fill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(stroke, lineWidth: area.needsYou > 0 ? 1.5 : 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(helpText)
    .accessibilityLabel(helpText)
  }

  private var badges: some View {
    HStack(spacing: 8) {
      if area.needsYou > 0 {
        Label("\(area.needsYou)", systemImage: "exclamationmark.circle.fill")
          .foregroundStyle(.orange)
      }
      if area.working > 0 {
        HStack(spacing: 4) {
          CoreAnimationActivityDot(animates: true)
            .frame(width: 7, height: 7)
          Text(area.agents.isEmpty ? "\(area.working)" : area.agents.prefix(2).joined(separator: ", "))
            .lineLimit(1)
        }
        .foregroundStyle(Color.accentColor)
      }
      if area.scheduled > 0 {
        Label("\(area.scheduled)", systemImage: "clock")
          .foregroundStyle(.secondary)
      }
      if area.changedRecently > 0 {
        Label("\(area.changedRecently)", systemImage: "pencil")
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption.monospacedDigit())
    .labelStyle(CompactActivityLabelStyle())
  }

  private var fill: Color {
    let base = WorkspaceDesign.panelFill
    if isHovered { return WorkspaceDesign.controlHoverFill }
    if area.needsYou > 0 { return Color.orange.opacity(0.10) }
    if area.working > 0 { return Color.accentColor.opacity(0.09) }
    return base
  }

  private var stroke: Color {
    if area.needsYou > 0 { return Color.orange.opacity(0.55) }
    if area.working > 0 { return Color.accentColor.opacity(0.45) }
    return WorkspaceDesign.hairline
  }

  private var helpText: String {
    var parts = [area.isFile ? area.path : "\(area.path) — \(area.fileCount) files"]
    if area.needsYou > 0 { parts.append("\(area.needsYou) need you") }
    if area.working > 0 {
      parts.append("\(area.working) in progress" + (area.agents.isEmpty ? "" : " (\(area.agents.joined(separator: ", ")))"))
    }
    if area.scheduled > 0 { parts.append("\(area.scheduled) scheduled") }
    if area.changedRecently > 0 { parts.append("\(area.changedRecently) changed today") }
    parts.append(area.isFile ? "Click to open" : "Click to zoom in")
    return parts.joined(separator: " · ")
  }
}

private struct CompactActivityLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
      configuration.title
    }
  }
}

private enum ActivityMotion {
  static let zoom = Animation.easeInOut(duration: 0.16)
}
