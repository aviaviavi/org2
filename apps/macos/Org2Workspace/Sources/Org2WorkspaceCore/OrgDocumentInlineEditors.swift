import SwiftUI

struct ParagraphInlineLinkEditor: View {
  @Binding var text: String

  var body: some View {
    let links = inlineLinkSet.links
    if !links.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(links) { link in
          HStack(spacing: 8) {
            Image(systemName: linkIcon(for: link))
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 18)

            TextField("label", text: linkLabelBinding(link))
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 120)

            TextField("target", text: linkTargetBinding(link))
              .textFieldStyle(.roundedBorder)
              .font(.caption.monospaced())
              .frame(minWidth: 220)
          }
          .controlSize(.small)
        }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
  }

  private var inlineLinkSet: OrgEditableInlineLinkSet {
    OrgEditableInlineLinkSet(rawText: text)
  }

  private func linkIcon(for link: OrgEditableInlineLink) -> String {
    switch link.kind {
    case .orgBracket, .markdown, .plainURL:
      return "link"
    case .fileReference:
      return "doc.text.magnifyingglass"
    }
  }

  private func linkLabelBinding(_ link: OrgEditableInlineLink) -> Binding<String> {
    Binding(
      get: { currentLink(matching: link)?.label ?? link.label },
      set: { updateInlineLink(link, label: $0) }
    )
  }

  private func linkTargetBinding(_ link: OrgEditableInlineLink) -> Binding<String> {
    Binding(
      get: { currentLink(matching: link)?.target ?? link.target },
      set: { updateInlineLink(link, target: $0) }
    )
  }

  private func currentLink(matching link: OrgEditableInlineLink) -> OrgEditableInlineLink? {
    OrgEditableInlineLinkSet(rawText: text)
      .links
      .first { $0.id == link.id }
  }

  private func updateInlineLink(_ link: OrgEditableInlineLink, label: String? = nil, target: String? = nil) {
    let set = OrgEditableInlineLinkSet(rawText: text)
    guard let current = set.links.first(where: { $0.id == link.id }) else { return }
    text = set.replacing(link: current, label: label, target: target)
  }
}

struct ParagraphInlineTimestampEditor: View {
  @Binding var text: String

  var body: some View {
    let timestamps = inlineTimestampSet.timestamps
    if !timestamps.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(timestamps) { timestamp in
          HStack(spacing: 8) {
            Toggle("", isOn: timestampActiveBinding(timestamp))
              .toggleStyle(.checkbox)
              .labelsHidden()
              .help("Active timestamp")

            Image(systemName: timestamp.isActive ? "calendar" : "calendar.badge.clock")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 18)

            TextField("YYYY-MM-DD", text: timestampDateBinding(timestamp))
              .textFieldStyle(.roundedBorder)
              .font(.caption.monospacedDigit())
              .frame(width: 108)

            TextField("time", text: timestampTimeBinding(timestamp))
              .textFieldStyle(.roundedBorder)
              .font(.caption.monospacedDigit())
              .frame(width: 92)

            TextField("repeat/note", text: timestampDetailBinding(timestamp))
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 120)
          }
          .controlSize(.small)
        }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
  }

  private var inlineTimestampSet: OrgEditableInlineTimestampSet {
    OrgEditableInlineTimestampSet(rawText: text)
  }

  private func timestampActiveBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<Bool> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.isActive ?? timestamp.isActive },
      set: { updateInlineTimestamp(timestamp, isActive: $0) }
    )
  }

  private func timestampDateBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<String> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.date ?? timestamp.date },
      set: { updateInlineTimestamp(timestamp, date: $0) }
    )
  }

  private func timestampTimeBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<String> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.time ?? timestamp.time },
      set: { updateInlineTimestamp(timestamp, time: $0) }
    )
  }

  private func timestampDetailBinding(_ timestamp: OrgEditableInlineTimestamp) -> Binding<String> {
    Binding(
      get: { currentTimestamp(matching: timestamp)?.detail ?? timestamp.detail },
      set: { updateInlineTimestamp(timestamp, detail: $0) }
    )
  }

  private func currentTimestamp(matching timestamp: OrgEditableInlineTimestamp) -> OrgEditableInlineTimestamp? {
    OrgEditableInlineTimestampSet(rawText: text)
      .timestamps
      .first { $0.id == timestamp.id }
  }

  private func updateInlineTimestamp(
    _ timestamp: OrgEditableInlineTimestamp,
    date: String? = nil,
    time: String? = nil,
    detail: String? = nil,
    isActive: Bool? = nil
  ) {
    let set = OrgEditableInlineTimestampSet(rawText: text)
    guard let current = set.timestamps.first(where: { $0.id == timestamp.id }) else { return }
    text = set.replacing(
      timestamp: current,
      date: date,
      time: time,
      detail: detail,
      isActive: isActive
    )
  }
}
