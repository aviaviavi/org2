import Foundation
import SwiftUI

/// Left-navigation sections that can be collapsed from their header.
public enum SidebarSectionID: String, CaseIterable, Sendable {
  case workspace
  case pinned
  case daily
  case projects
  case chat
}

/// Which sidebar sections are collapsed, stored as a comma-separated list of
/// section IDs in user defaults so it survives relaunch. Every section starts
/// expanded; unknown IDs from older or newer builds are ignored.
public struct SidebarSectionCollapseState: Equatable, Sendable {
  public static let defaultsKey = "sidebarCollapsedSections"

  public private(set) var collapsed: Set<SidebarSectionID>

  public init(collapsed: Set<SidebarSectionID> = []) {
    self.collapsed = collapsed
  }

  public init(storage: String) {
    collapsed = Set(
      storage
        .split(separator: ",")
        .compactMap { SidebarSectionID(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    )
  }

  public var storage: String {
    SidebarSectionID.allCases
      .filter(collapsed.contains)
      .map(\.rawValue)
      .joined(separator: ",")
  }

  public func isCollapsed(_ section: SidebarSectionID) -> Bool {
    collapsed.contains(section)
  }

  public mutating func toggle(_ section: SidebarSectionID) {
    if collapsed.contains(section) {
      collapsed.remove(section)
    } else {
      collapsed.insert(section)
    }
  }

  /// Toggles `section` in a stored value and returns the new stored value.
  public static func toggling(_ section: SidebarSectionID, in storage: String) -> String {
    var state = SidebarSectionCollapseState(storage: storage)
    state.toggle(section)
    return state.storage
  }
}

/// A sidebar section title that collapses or expands its section. The state
/// is shared through user defaults with the views that hide the section rows.
struct SidebarCollapsibleSectionHeader<Accessory: View>: View {
  @AppStorage(SidebarSectionCollapseState.defaultsKey) private var collapsedStorage = ""
  let title: String
  let section: SidebarSectionID
  /// Uses the sidebar's monospaced uppercase label style; Projects keeps its
  /// plain section-header text.
  var usesSidebarLabelStyle = true
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    let isCollapsed = SidebarSectionCollapseState(storage: collapsedStorage).isCollapsed(section)
    HStack(spacing: 2) {
      Button {
        withAnimation(WorkspaceMotion.disclosure) {
          collapsedStorage = SidebarSectionCollapseState.toggling(section, in: collapsedStorage)
        }
      } label: {
        HStack(spacing: 5) {
          if usesSidebarLabelStyle {
            Text(title.uppercased())
              .font(.system(size: 10, weight: .semibold, design: .monospaced))
              .tracking(0.7)
          } else {
            Text(title)
          }
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          Spacer(minLength: 0)
        }
        .foregroundStyle(usesSidebarLabelStyle ? AnyShapeStyle(WorkspaceDesign.tertiaryText) : AnyShapeStyle(.secondary))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isCollapsed ? "Show \(title)" : "Hide \(title)")
      .accessibilityLabel(title)
      .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
      accessory()
    }
  }
}

extension SidebarCollapsibleSectionHeader where Accessory == EmptyView {
  init(title: String, section: SidebarSectionID) {
    self.init(title: title, section: section, accessory: { EmptyView() })
  }
}
