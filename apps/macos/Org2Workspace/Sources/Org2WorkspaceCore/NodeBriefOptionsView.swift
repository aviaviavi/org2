import SwiftUI

/// Compact summary button that opens the brief harness/model/reasoning picker.
struct NodeBriefOptionsButton: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    Button {
      store.isNodeBriefOptionsPresented = true
    } label: {
      Label(summary, systemImage: "slider.horizontal.3")
        .font(.caption)
        .lineLimit(1)
    }
    .buttonStyle(.link)
    .help("Choose the harness, model, and reasoning effort used to generate briefs.")
  }

  private var summary: String {
    let configuration = store.nodeBriefConfiguration
    guard !configuration.isDefault else { return "Brief with current chat settings" }
    var parts = [store.nodeBriefDestination.title]
    if let model = configuration.model { parts.append(model) }
    if let reasoning = configuration.reasoningEffort { parts.append(reasoning) }
    return "Brief with " + parts.joined(separator: " · ")
  }
}

/// Lets the user pick which harness (AI destination), model, and reasoning
/// effort generate node briefs. Choices persist across launches.
struct NodeBriefOptionsView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  @State private var destinationID: String = ""
  @State private var model: String = ""
  @State private var reasoningEffort: String = ""
  @State private var modelOptions: [AIChatModelOption] = []
  @State private var isLoadingModels = false

  static let currentChatTag = ""
  static let standardReasoningEfforts = ["minimal", "low", "medium", "high", "xhigh"]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Brief Options")
        .font(.title3.weight(.semibold))
      Text("Choose what generates node briefs. A custom choice always starts a new brief chat.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Form {
        Picker("Harness", selection: $destinationID) {
          Text("Current chat (\(store.selectedAIChatDestination.title))")
            .tag(Self.currentChatTag)
          Divider()
          ForEach(store.enabledAIChatDestinations) { destination in
            Label(destination.title, systemImage: destination.systemImage)
              .tag(destination.id)
          }
        }

        HStack {
          TextField("Model", text: $model, prompt: Text("Harness default"))
          Menu {
            Button("Harness default") { model = "" }
            if !modelOptions.isEmpty { Divider() }
            ForEach(modelOptions) { option in
              Button(option.isDefault ? "\(option.label) (default)" : option.label) {
                model = option.id
              }
            }
          } label: {
            if isLoadingModels {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "chevron.up.chevron.down")
            }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("Choose from the harness's available models")
        }

        Picker("Reasoning", selection: $reasoningEffort) {
          Text("Harness default").tag("")
          Divider()
          ForEach(reasoningChoices, id: \.id) { option in
            Text(option.label).tag(option.id)
          }
        }
      }
      .formStyle(.grouped)

      HStack {
        Button("Reset to Defaults") {
          destinationID = Self.currentChatTag
          model = ""
          reasoningEffort = ""
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          store.nodeBriefConfiguration = NodeBriefAIConfiguration(
            destinationID: destinationID,
            model: model,
            reasoningEffort: reasoningEffort
          )
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 440)
    .onAppear {
      let configuration = store.nodeBriefConfiguration
      destinationID = configuration.destinationID ?? Self.currentChatTag
      model = configuration.model ?? ""
      reasoningEffort = configuration.reasoningEffort ?? ""
    }
    .task(id: destinationID) {
      let resolvedID = destinationID.isEmpty ? store.selectedAIChatDestination.id : destinationID
      isLoadingModels = true
      modelOptions = await store.nodeBriefModelOptions(forDestinationID: resolvedID)
      isLoadingModels = false
    }
  }

  /// Reasoning levels offered by the chosen model when known, otherwise the
  /// standard effort ladder. A saved non-standard value stays selectable.
  private var reasoningChoices: [AIChatReasoningOption] {
    let selectedModel = modelOptions.first(where: { $0.id == model })
      ?? (model.isEmpty ? modelOptions.first(where: \.isDefault) : nil)
    var choices = selectedModel?.reasoningOptions ?? []
    if choices.isEmpty {
      choices = Self.standardReasoningEfforts.map {
        AIChatReasoningOption(id: $0, label: $0 == "xhigh" ? "Extra high" : $0.capitalized)
      }
    }
    if !reasoningEffort.isEmpty, !choices.contains(where: { $0.id == reasoningEffort }) {
      choices.append(AIChatReasoningOption(id: reasoningEffort, label: reasoningEffort.capitalized))
    }
    return choices
  }
}
