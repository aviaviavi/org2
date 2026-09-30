import SwiftUI

/// Grouped `Form` footers are trailing-aligned on macOS; settings prose reads
/// better as leading-aligned paragraphs. Use this for every settings footer.
public struct SettingsFooterText: View {
  private let text: Text

  public init(_ content: LocalizedStringKey) {
    text = Text(content)
  }

  public var body: some View {
    text
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
