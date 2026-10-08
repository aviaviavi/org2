import AppKit
import Org2WorkspaceCore
import SwiftUI

struct AppearanceSettingsView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    @Bindable var store = store
    Form {
      Section {
        Picker("Appearance", selection: $store.appearanceMode) {
          ForEach(WorkspaceAppearanceMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        Text("System follows macOS and switches between your light and dark themes automatically. Light and Dark keep Celorga on that theme regardless of the system setting.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("App Theme", systemImage: "paintbrush")
      }

      themeSection(for: .light, selection: $store.lightThemeID)
      themeSection(for: .dark, selection: $store.darkThemeID)

      Section {
        Text("Imported themes adapt the palettes of popular Emacs themes to Celorga's chrome, rendered documents, and Org source editor.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 640)
    .frame(minHeight: 560)
  }

  private func themeSection(
    for appearance: WorkspaceThemeAppearance,
    selection: Binding<String>
  ) -> some View {
    Section {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 136, maximum: 200), spacing: 14, alignment: .top)],
        alignment: .leading,
        spacing: 14
      ) {
        ForEach(WorkspaceThemeCatalog.themes(for: appearance)) { theme in
          WorkspaceThemePreviewCard(theme: theme, isSelected: selection.wrappedValue == theme.id) {
            selection.wrappedValue = theme.id
          }
        }
      }
      .padding(.vertical, 4)
    } header: {
      HStack(spacing: 6) {
        Label(
          appearance == .dark ? "Dark Theme" : "Light Theme",
          systemImage: appearance == .dark ? "moon" : "sun.max"
        )
        if isActive(appearance) {
          Text("In use")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
      }
    }
  }

  private func isActive(_ appearance: WorkspaceThemeAppearance) -> Bool {
    switch store.appearanceMode {
    case .light: appearance == .light
    case .dark: appearance == .dark
    case .system: appearance.colorScheme == colorScheme
    }
  }
}

struct WorkspaceThemePreviewCard: View {
  let theme: WorkspaceTheme
  let isSelected: Bool
  let select: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: select) {
      VStack(alignment: .leading, spacing: 5) {
        WorkspaceThemePreview(theme: theme)
          .frame(height: 86)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(
                isSelected ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.45 : 0.22),
                lineWidth: isSelected ? 2.5 : 1
              )
          }
        HStack(spacing: 4) {
          Text(theme.name)
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .lineLimit(1)
          Spacer(minLength: 0)
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(Color.accentColor)
              .font(.callout)
          }
        }
        Text(theme.origin)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(theme.name)
    .accessibilityLabel(theme.name)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// A miniature OpenOrg window drawn in the theme's own colors: a sidebar on
/// the canvas color and a document showing headings, a TODO, planning, a
/// link, inline code, and a comment.
struct WorkspaceThemePreview: View {
  let theme: WorkspaceTheme

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        ForEach(0..<4, id: \.self) { index in
          RoundedRectangle(cornerRadius: 1.5)
            .fill(index == 1 ? color(.structural).opacity(0.85) : color(.tertiaryText).opacity(0.55))
            .frame(width: index == 1 ? 18 : 14 + CGFloat(index % 2) * 5, height: 3)
        }
        Spacer(minLength: 0)
      }
      .padding(.top, 9)
      .padding(.leading, 7)
      .frame(width: 32, alignment: .leading)
      .frame(maxHeight: .infinity)
      .background(color(.canvas))
      .overlay(alignment: .trailing) {
        Rectangle().fill(color(.hairline)).frame(width: 1)
      }

      VStack(alignment: .leading, spacing: 3.5) {
        HStack(spacing: 3) {
          Text("*").foregroundStyle(color(.structural))
          Text("Projects").foregroundStyle(color(.heading1)).fontWeight(.bold)
        }
        HStack(spacing: 3) {
          Text("**").foregroundStyle(color(.signal))
          Text("TODO")
            .font(.system(size: 6.5, weight: .bold, design: .rounded))
            .foregroundStyle(color(.todo))
            .padding(.horizontal, 2.5)
            .background(color(.todo).opacity(0.16), in: Capsule())
          Text("Ship themes").foregroundStyle(color(.heading2)).fontWeight(.semibold)
          Text("#ui").foregroundStyle(color(.tag))
        }
        HStack(spacing: 3) {
          Text("SCHEDULED:").foregroundStyle(color(.planning))
          Text("<09-27 Sun>")
            .foregroundStyle(color(.sourceText))
            .background(color(.timestamp).opacity(0.18))
        }
        HStack(spacing: 3) {
          Text("See").foregroundStyle(color(.text))
          Text("docs").foregroundStyle(color(.link)).underline()
          Text("=celorga=")
            .foregroundStyle(color(.text))
            .background(color(.code).opacity(0.18))
        }
        HStack(spacing: 3) {
          Text("***").foregroundStyle(color(.tertiaryText))
          Text("DONE")
            .font(.system(size: 6.5, weight: .bold, design: .rounded))
            .foregroundStyle(color(.done))
            .padding(.horizontal, 2.5)
            .background(color(.done).opacity(0.16), in: Capsule())
          Text("Pick palette").foregroundStyle(color(.heading3))
        }
        Text("# keep it plain text").foregroundStyle(color(.comment))
        Spacer(minLength: 0)
      }
      .font(.system(size: 7.5, design: .monospaced))
      .lineLimit(1)
      .padding(.top, 7)
      .padding(.leading, 7)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(color(.document))
    }
    .environment(\.colorScheme, theme.appearance.colorScheme)
    .accessibilityHidden(true)
  }

  private func color(_ role: WorkspaceThemeRole) -> Color {
    Color(nsColor: theme.resolvedColor(role))
  }
}
