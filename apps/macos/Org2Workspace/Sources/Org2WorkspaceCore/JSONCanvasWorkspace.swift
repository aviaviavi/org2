import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct JSONCanvasWorkspaceView: View {
  @Environment(WorkspaceStore.self) private var store
  let file: String
  @State private var payload: JSONCanvasPayload?
  @State private var error: String?
  @State private var busy = false
  @State private var selectedNode: String?
  @State private var selectedEdge: String?
  @State private var connectingFrom: String?
  @State private var zoom: CGFloat = 1
  @State private var pan = CGSize(width: 40, height: 40)
  @State private var isPanning = false
  @State private var panStart: CGSize?
  @State private var viewport = CGSize(width: 800, height: 600)
  @State private var previews: [String: CGRect] = [:]
  @State private var editor: CanvasEditorDraft?
  @State private var showsTargets = false

  private var nodes: [JSONCanvasNode] { payload?.document.nodes ?? [] }
  private var edges: [JSONCanvasEdge] { payload?.document.edges ?? [] }
  private var selected: JSONCanvasNode? { nodes.first { $0.id == selectedNode } }

  var body: some View {
    let layers = JSONCanvasLayers(nodes: nodes)
    VStack(spacing: 0) {
      toolbar
      if let error {
        HStack(alignment: .top) {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Spacer()
          Button("Reload") { Task { await reload() } }.disabled(busy)
        }.font(.callout).padding(10)
      }
      if let connectingFrom {
        HStack {
          Text("Choose a destination card to connect from \(nodes.first { $0.id == connectingFrom }?.displayTitle ?? "this card").")
          Spacer()
          Button("Cancel") { self.connectingFrom = nil }
        }.font(.callout).padding(10).background(Color.accentColor.opacity(0.12))
      }
      GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
          Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
              if panStart == nil { panStart = pan }
              pan = CGSize(width: (panStart?.width ?? 0) + value.translation.width, height: (panStart?.height ?? 0) + value.translation.height)
            }.onEnded { _ in panStart = nil })
            .onTapGesture { selectedNode = nil; selectedEdge = nil }
          ForEach(layers.groups) { node in
            card(node).allowsHitTesting(!isPanning)
          }
          Canvas { context, _ in drawEdges(context: &context) }
            .allowsHitTesting(false)
          ForEach(layers.cards) { node in
            card(node).allowsHitTesting(!isPanning)
          }
          if nodes.isEmpty && !busy {
            VStack(spacing: 8) {
              Text("Build a spatial workspace").font(.title2)
              Text("Add text, notes, images, or links using the toolbar. Drag card headers to move them and the corner handle to resize.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }.frame(width: 340).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
          }
        }
        .coordinateSpace(name: "canvas-board")
        .clipped()
        .onAppear { viewport = geometry.size }
        .onChange(of: geometry.size) { _, size in viewport = size }
      }
      inspector
    }
    .task(id: file) { await reload(fit: true) }
    .sheet(item: $editor) { draft in
      CanvasNodeEditor(draft: draft, busy: busy, errorMessage: error, reload: {
        Task { await reload() }
      }) { fields in
        if let id = draft.nodeID { mutate([["action": draft.type == "edge" ? "update-edge" : "update-node", "id": id, "patch": fields]], closeEditor: true) }
        else { addNode(type: draft.type, fields: fields, closeEditor: true) }
      }
    }
    .sheet(isPresented: $showsTargets) {
      CanvasTargetPicker { target in
        var fields: [String: Any] = ["file": target.file]
        if let ref = target.org2Ref { fields["org2Ref"] = ref }
        if let subpath = target.subpath { fields["subpath"] = subpath }
        addNode(type: "file", fields: fields)
      }
      .environment(store)
    }
  }

  private var toolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { addControls; Spacer(); viewControls }
      VStack(alignment: .leading, spacing: 8) {
        HStack { addControls; Spacer() }
        HStack { viewControls; Spacer() }
      }
    }
    .controlSize(.small).padding(10).background(.bar)
  }

  private var addControls: some View {
    HStack(spacing: 8) {
      Menu {
        Button("Text", systemImage: "text.alignleft") { editor = CanvasEditorDraft(type: "text") }
        Button("Note or heading…", systemImage: "doc.text") { showsTargets = true }
        Button("Image or attachment…", systemImage: "photo") { chooseFile() }
        Button("Web link", systemImage: "link") { editor = CanvasEditorDraft(type: "link") }
        Button("Group", systemImage: "rectangle.3.group") { editor = CanvasEditorDraft(type: "group") }
      } label: { Label("Add card", systemImage: "plus") }
      .disabled(busy || payload == nil)
      Button("Connect", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
        isPanning = false
        connectingFrom = selectedNode
      }.disabled(busy || selected == nil || nodes.count < 2)
      if busy { ProgressView().controlSize(.small) }
      else { Text(payload == nil ? "Not loaded" : "Saved locally").font(.caption).foregroundStyle(.secondary) }
    }
  }

  private var viewControls: some View {
    HStack(spacing: 8) {
      Button { changeZoom(zoom / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
      Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 42)
      Button { changeZoom(zoom * 1.2) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
      Button { isPanning.toggle() } label: { Image(systemName: isPanning ? "hand.draw.fill" : "hand.draw") }
        .help(isPanning ? "Return to card selection" : "Pan across cards and groups")
      Button("Fit") { fitBoard() }
      Menu {
        Button("Reload from disk") { Task { await reload() } }
        Button("Export Canvas…") { export() }
        if !edges.isEmpty {
          Divider()
          ForEach(edges) { edge in
            Button(edge.label?.isEmpty == false ? edge.label! : "\(nodeTitle(edge.fromNode)) → \(nodeTitle(edge.toNode))") {
              selectedEdge = edge.id; selectedNode = nil
            }
          }
        }
      } label: { Image(systemName: "ellipsis.circle") }
      .help("Reload, export, and select connections").disabled(busy)
    }
  }

  private func card(_ node: JSONCanvasNode) -> some View {
    let rect = previews[node.id] ?? node.rectangle
    let resource = payload?.resources[node.id]
    let tint = JSONCanvasGeometry.color(node.color)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 5) {
        Image(systemName: node.type == "file" ? "doc" : node.type == "link" ? "link" : "square")
        Text(resource?.title ?? node.displayTitle).lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
      }
      .font(.caption.weight(.semibold))
      .padding(8).frame(maxWidth: .infinity).background(tint.opacity(0.16))
      .contentShape(Rectangle())
      .onTapGesture { choose(node) }
      .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("canvas-board"))
        .onChanged { drag in
          guard !busy, connectingFrom == nil else { return }
          selectedNode = node.id
          previews[node.id] = CGRect(x: node.x + drag.translation.width / zoom, y: node.y + drag.translation.height / zoom, width: node.width, height: node.height)
        }
        .onEnded { _ in
          guard let changed = previews[node.id], !busy else { return }
          mutate([["action": "update-node", "id": node.id, "patch": ["x": Int(changed.minX.rounded()), "y": Int(changed.minY.rounded())]]])
        })
      CanvasCardContent(node: node, resource: resource)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle()).onTapGesture { choose(node) }
      HStack {
        if resource?.file != nil || resource?.url != nil {
          Button("Open source") { open(resource) }.font(.caption).buttonStyle(.plain)
        }
        Spacer()
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.caption).padding(5).contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas-board"))
            .onChanged { drag in
              guard !busy else { return }
              previews[node.id] = CGRect(x: node.x, y: node.y, width: max(120, node.width + drag.translation.width / zoom), height: max(90, node.height + drag.translation.height / zoom))
            }
            .onEnded { _ in
              guard let changed = previews[node.id], !busy else { return }
              mutate([["action": "update-node", "id": node.id, "patch": ["width": Int(changed.width.rounded()), "height": Int(changed.height.rounded())]]])
            })
      }.padding(.horizontal, 8).padding(.bottom, 4)
    }
    .frame(width: rect.width, height: rect.height)
    .background(node.type == "group" ? Color(nsColor: .controlBackgroundColor).opacity(0.22) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedNode == node.id || connectingFrom == node.id ? Color.accentColor : tint.opacity(0.6), lineWidth: selectedNode == node.id ? 3 : 1))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .scaleEffect(zoom)
    .position(x: rect.midX * zoom + pan.width, y: rect.midY * zoom + pan.height)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(resource?.title ?? node.displayTitle)
  }

  @ViewBuilder private var inspector: some View {
    HStack(spacing: 10) {
      if let node = selected {
        Text(payload?.resources[node.id]?.title ?? node.displayTitle).lineLimit(1)
        if ["text", "link", "group"].contains(node.type) {
          Button("Edit") { editor = CanvasEditorDraft(node: node) }.disabled(busy)
        }
        Menu("Color") {
          ForEach(1...6, id: \.self) { value in
            Button(["Red", "Orange", "Yellow", "Green", "Cyan", "Purple"][value - 1]) {
              mutate([["action": "update-node", "id": node.id, "patch": ["color": "\(value)"]]])
            }
          }
        }.disabled(busy)
        Spacer()
        Button("Delete card", role: .destructive) {
          mutate([["action": "remove-node", "id": node.id]])
          selectedNode = nil; connectingFrom = nil
        }.disabled(busy)
      } else if let edge = edges.first(where: { $0.id == selectedEdge }) {
        Text("\(nodeTitle(edge.fromNode)) → \(nodeTitle(edge.toNode))").lineLimit(1)
        Button("Edit connection") { editor = CanvasEditorDraft(edge: edge) }.disabled(busy)
        Spacer()
        Button("Delete connection", role: .destructive) {
          mutate([["action": "remove-edge", "id": edge.id]])
          selectedEdge = nil
        }.disabled(busy)
      } else {
        Text("\(nodes.count) cards · \(edges.count) connections. Drag empty space to pan.").foregroundStyle(.secondary)
        Spacer()
      }
    }.font(.caption).controlSize(.small).padding(10).background(.bar)
  }

  private func choose(_ node: JSONCanvasNode) {
    if let from = connectingFrom, from != node.id {
      mutate([["action": "add-edge", "edge": ["id": UUID().uuidString.lowercased(), "fromNode": from, "toNode": node.id, "fromSide": "right", "toSide": "left"]]])
      connectingFrom = nil
    } else { selectedNode = node.id; selectedEdge = nil }
  }

  private func nodeTitle(_ id: String) -> String { payload?.resources[id]?.title ?? nodes.first { $0.id == id }?.displayTitle ?? id }

  private func addNode(type: String, fields: [String: Any], closeEditor: Bool = false) {
    var node = fields
    node["id"] = UUID().uuidString.lowercased(); node["type"] = type
    node["x"] = Int(((viewport.width / 2 - pan.width) / zoom - 150).rounded())
    node["y"] = Int(((viewport.height / 2 - pan.height) / zoom - 100).rounded())
    node["width"] = type == "group" ? 560 : 300
    node["height"] = type == "group" ? 380 : 220
    mutate([["action": "add-node", "node": node]], closeEditor: closeEditor)
  }

  private func mutate(_ operations: [[String: Any]], closeEditor: Bool = false) {
    guard let payload, let root = store.corpusRoot?.path, !busy else { return }
    do {
      let data = try JSONSerialization.data(withJSONObject: operations)
      busy = true; error = nil
      Task { @MainActor in
        defer { busy = false; previews = [:] }
        do {
          _ = try await store.mutateJSONCanvas(file: file, root: root, revision: payload.revision, operations: data)
          self.payload = try await store.cli.runJSON(["canvas", "show", "--dir", root, "--file", file, "--json"])
          if closeEditor { editor = nil }
        } catch { self.error = error.localizedDescription }
      }
    } catch { self.error = error.localizedDescription }
  }

  @MainActor private func reload(fit: Bool = false) async {
    guard let root = store.corpusRoot?.path, !busy else { return }
    busy = true; error = nil
    defer { busy = false; previews = [:] }
    do {
      let loaded: JSONCanvasPayload = try await store.cli.runJSON(["canvas", "show", "--dir", root, "--file", file, "--json"])
      guard !Task.isCancelled else { return }
      payload = loaded
      if fit { fitBoard() }
    } catch { self.error = error.localizedDescription }
  }

  private func fitBoard() {
    let bounds = JSONCanvasGeometry.bounds(nodes)
    guard !bounds.isNull else { zoom = 1; pan = CGSize(width: 40, height: 40); return }
    zoom = min(1.5, max(0.05, min((viewport.width - 70) / bounds.width, (viewport.height - 70) / bounds.height)))
    pan = CGSize(width: viewport.width / 2 - bounds.midX * zoom, height: viewport.height / 2 - bounds.midY * zoom)
  }

  private func changeZoom(_ value: CGFloat) {
    let next = min(3, max(0.05, value))
    pan = CGSize(width: viewport.width / 2 - (viewport.width / 2 - pan.width) * next / zoom, height: viewport.height / 2 - (viewport.height / 2 - pan.height) * next / zoom)
    zoom = next
  }

  private func chooseFile() {
    guard let root = store.corpusRoot else { return }
    let panel = NSOpenPanel()
    panel.title = "Add an image or attachment from this corpus"
    panel.directoryURL = root; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let relativePath = WorkspaceStore.jsonCanvasRelativeResourcePath(file: url.path, root: root.path) else {
      error = "Choose a file already inside this corpus."; return
    }
    addNode(type: "file", fields: ["file": relativePath])
  }

  private func open(_ resource: JSONCanvasResource?) {
    guard let resource, resource.status == "ready" else { return }
    if let url = resource.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url); return }
    if let file = resource.file, ["org", "org2", "canvas"].contains(URL(fileURLWithPath: file).pathExtension.lowercased()), let location = resource.location {
      store.select(location, surface: .files)
    } else if let file = resource.file { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
  }

  private func export() {
    guard let root = store.corpusRoot?.path else { return }
    let panel = NSSavePanel()
    panel.title = "Export JSON Canvas"
    panel.nameFieldStringValue = "\(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)-copy.canvas"
    panel.allowedContentTypes = [UTType(filenameExtension: "canvas") ?? .data]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { @MainActor in
      do {
        let _: JSONCanvasMutationPayload = try await store.cli.runJSON(["canvas", "export", "--dir", root, "--file", file, "--out", url.path, "--apply", "--json"])
        store.statusText = "Exported \(url.lastPathComponent)"
      } catch { self.error = error.localizedDescription }
    }
  }

  private func drawEdges(context: inout GraphicsContext) {
    let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, previews[$0.id] ?? $0.rectangle) })
    for edge in edges {
      guard let from = byID[edge.fromNode], let to = byID[edge.toNode] else { continue }
      let a = JSONCanvasGeometry.anchor(from, side: edge.fromSide ?? "right")
      let b = JSONCanvasGeometry.anchor(to, side: edge.toSide ?? "left")
      let start = CGPoint(x: a.x * zoom + pan.width, y: a.y * zoom + pan.height)
      let end = CGPoint(x: b.x * zoom + pan.width, y: b.y * zoom + pan.height)
      var path = Path(); path.move(to: start); path.addLine(to: end)
      func arrow(_ tip: CGPoint, _ base: CGPoint) {
        let angle = atan2(tip.y - base.y, tip.x - base.x)
        path.move(to: CGPoint(x: tip.x - cos(angle - 0.5) * 12, y: tip.y - sin(angle - 0.5) * 12))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - cos(angle + 0.5) * 12, y: tip.y - sin(angle + 0.5) * 12))
      }
      if edge.fromEnd == "arrow" { arrow(start, end) }
      if edge.toEnd != "none" { arrow(end, start) }
      context.stroke(path, with: .color(JSONCanvasGeometry.color(edge.color)), lineWidth: selectedEdge == edge.id ? 3 : 1.8)
      if let label = edge.label, !label.isEmpty {
        context.draw(Text(label).font(.caption).foregroundColor(.primary), at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 9))
      }
    }
  }
}

private struct CanvasCardContent: View {
  let node: JSONCanvasNode
  let resource: JSONCanvasResource?

  private var previewImage: NSImage? {
    guard let encoded = resource?.imageData, let data = Data(base64Encoded: encoded) else { return nil }
    return NSImage(data: data)
  }

  private var sourceUnavailable: Bool {
    ["missing", "ambiguous", "unsupported"].contains(resource?.status ?? "")
  }

  private var fallbackText: String {
    if let text = resource?.text { return text }
    if let url = resource?.url { return url }
    if let message = resource?.message { return message }
    return node.file ?? ""
  }

  var body: some View {
    Group {
      if let image = previewImage {
        Image(nsImage: image).resizable().scaledToFit()
      } else if sourceUnavailable {
        VStack(alignment: .leading, spacing: 6) {
          Label(resource?.status.capitalized ?? "Unavailable", systemImage: "exclamationmark.triangle")
          Text(resource?.message ?? "Source unavailable").font(.caption)
        }.foregroundStyle(.secondary)
      } else if node.type == "text" {
        Text(node.text ?? "").font(.body).lineLimit(nil)
      } else if node.type == "group" {
        Text(node.label ?? "Group").font(.title2).foregroundStyle(.secondary)
      } else {
        Text(fallbackText).font(.callout)
      }
    }.padding(10).clipped()
  }
}
