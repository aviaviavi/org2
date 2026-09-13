import Foundation
import SwiftUI

struct CanvasEditorDraft: Identifiable {
  let id = UUID()
  let type: String
  var nodeID: String?
  var content = ""
  var color = "5"
  var fromSide = "right"
  var toSide = "left"
  var fromEnd = "none"
  var toEnd = "arrow"

  init(type: String) { self.type = type }
  init(node: JSONCanvasNode) {
    type = node.type; nodeID = node.id
    content = node.text ?? node.url ?? node.label ?? ""
    color = node.color ?? "5"
  }
  init(edge: JSONCanvasEdge) {
    type = "edge"; nodeID = edge.id; content = edge.label ?? ""
    color = edge.color ?? "5"
    fromSide = edge.fromSide ?? "right"; toSide = edge.toSide ?? "left"
    fromEnd = edge.fromEnd ?? "none"; toEnd = edge.toEnd ?? "arrow"
  }
}

struct CanvasNodeEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State var draft: CanvasEditorDraft
  let busy: Bool
  let errorMessage: String?
  let reload: () -> Void
  let save: ([String: Any]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(draft.type == "edge" ? "Edit connection" : draft.nodeID == nil ? "Add \(draft.type) card" : "Edit \(draft.type) card")
        .font(.title2)
      if draft.type == "text" {
        Text("Text is stored as Markdown in the open Canvas file.").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $draft.content).font(.body).frame(minHeight: 180)
          .border(.secondary.opacity(0.3))
      } else {
        TextField(draft.type == "link" ? "URL (https://…)" : "Label", text: $draft.content)
          .textFieldStyle(.roundedBorder)
      }
      HStack {
        Text("Color")
        Picker("Color", selection: $draft.color) {
          ForEach(1...6, id: \.self) { value in
            Text(["Red", "Orange", "Yellow", "Green", "Cyan", "Purple"][value - 1]).tag("\(value)")
          }
          if draft.color.hasPrefix("#") { Text("Custom \(draft.color)").tag(draft.color) }
        }.labelsHidden()
      }
      if draft.type == "edge" {
        HStack {
          sidePicker("From side", value: $draft.fromSide)
          sidePicker("To side", value: $draft.toSide)
        }
        HStack {
          endPicker("From end", value: $draft.fromEnd)
          endPicker("To end", value: $draft.toEnd)
        }
      }
      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        Button("Reload board and keep draft", action: reload)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
        Button("Save") {
          var fields: [String: Any] = ["color": draft.color]
          fields[draft.type == "text" ? "text" : draft.type == "link" ? "url" : "label"] = draft.content
          if draft.type == "edge" {
            fields["fromSide"] = draft.fromSide; fields["toSide"] = draft.toSide
            fields["fromEnd"] = draft.fromEnd; fields["toEnd"] = draft.toEnd
          }
          save(fields)
        }.keyboardShortcut(.defaultAction)
          .disabled(busy || (draft.type == "link" && draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
      }
    }.padding(22).frame(width: 470)
      .disabled(busy)
      .interactiveDismissDisabled(busy)
  }

  private func sidePicker(_ title: String, value: Binding<String>) -> some View {
    Picker(title, selection: value) {
      ForEach(["top", "right", "bottom", "left"], id: \.self) { Text($0.capitalized).tag($0) }
    }
  }
  private func endPicker(_ title: String, value: Binding<String>) -> some View {
    Picker(title, selection: value) {
      Text("None").tag("none")
      Text("Arrow").tag("arrow")
    }
  }
}

struct CanvasTargetPicker: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var payload: JSONCanvasTargetsPayload?
  @State private var error: String?
  @State private var loading = false
  let choose: (JSONCanvasTarget) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a note or stable-ID heading").font(.title2)
      TextField("Find a note, heading, file, or ID", text: $query).textFieldStyle(.roundedBorder)
      if loading { ProgressView().controlSize(.small) }
      if let error { Text(error).foregroundStyle(.red) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(payload?.targets ?? []) { target in
            Button {
              choose(target); dismiss()
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(target.title).font(.headline)
                Text("\(target.file):\(target.line)").font(.caption).foregroundStyle(.secondary)
                if target.org2Ref != nil { Text("Stable source link").font(.caption2).foregroundStyle(.secondary) }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.buttonStyle(.plain)
          }
        }
      }.frame(minHeight: 300)
      if payload?.truncated == true { Text("Showing 200 results. Refine your search.").font(.caption) }
      HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
    }.padding(22).frame(width: 520)
      .task(id: query) { await load() }
  }

  @MainActor private func load() async {
    guard let root = store.corpusRoot?.path else { return }
    let requested = query
    loading = true; error = nil
    defer { if requested == query { loading = false } }
    do {
      try await Task.sleep(nanoseconds: 180_000_000)
      let result: JSONCanvasTargetsPayload = try await store.cli.runJSON(["canvas", "targets", "--dir", root, "--query", requested.isEmpty ? " " : requested, "--json"])
      guard !Task.isCancelled, requested == query else { return }
      payload = result
    } catch {
      guard !Task.isCancelled, requested == query else { return }
      self.error = error.localizedDescription
    }
  }
}
