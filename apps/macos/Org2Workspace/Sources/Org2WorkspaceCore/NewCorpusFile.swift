import Foundation
import SwiftUI

/// A validated plan for creating one new document inside the active corpus.
///
/// The plan is pure so the sidebar sheet can preview the exact destination
/// while the user types, and so the store and tests share one set of rules:
///
/// - A name without a supported extension becomes a slugged `.org` file whose
///   `#+TITLE:` keeps the name as typed (`Launch Post` → `launch-post.org`).
/// - A name that already ends in `.org`, `.org2`, `.md`, or `.txt` is used as
///   the file name verbatim.
/// - The folder is corpus-relative. Absolute paths and `..` components are
///   rejected so a new file can never land outside the corpus.
public struct NewCorpusFilePlan: Equatable, Sendable {
  public static let defaultFolder = "notes"
  public static let supportedExtensions = ["org", "org2", "md", "txt"]

  public enum Failure: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case invalidFolder
    case alreadyExists(String)

    public var errorDescription: String? {
      switch self {
      case .emptyName: "Enter a name for the new file."
      case .invalidName: "File names cannot contain path separators, start with a dot, or use .. segments."
      case .invalidFolder: "Choose a folder inside the corpus (no absolute paths or .. segments)."
      case .alreadyExists(let path): "\(path) already exists."
      }
    }
  }

  public let url: URL
  public let relativePath: String
  public let title: String
  public let folder: String

  public static func plan(
    name rawName: String,
    folder rawFolder: String,
    corpusRoot: URL
  ) throws -> NewCorpusFilePlan {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw Failure.emptyName }
    guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."), name != ".." else {
      throw Failure.invalidName
    }

    let folder = try normalizedFolder(rawFolder)
    let typedExtension = (name as NSString).pathExtension.lowercased()
    let fileName: String
    let title: String
    if supportedExtensions.contains(typedExtension),
       !(name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces).isEmpty {
      fileName = name
      title = (name as NSString).deletingPathExtension
    } else {
      fileName = "\(WorkspaceStore.slug(name)).\(OrgDocumentDefaults.preferredExtension)"
      title = name
    }

    let relativePath = folder.isEmpty ? fileName : "\(folder)/\(fileName)"
    let root = corpusRoot.standardizedFileURL
    let url = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
    guard url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else {
      throw Failure.invalidFolder
    }
    return NewCorpusFilePlan(url: url, relativePath: relativePath, title: title, folder: folder)
  }

  /// Initial document text. Org documents get a stable `:ID:` so the new note
  /// is immediately linkable, plus a creation timestamp that saved views can
  /// filter on.
  public func initialContent(id: String = UUID().uuidString, createdAt: Date = Date()) -> String {
    switch url.pathExtension.lowercased() {
    case "org", "org2":
      return """
      :PROPERTIES:
      :ID: \(id)
      :CREATED: \(Self.inactiveTimestamp(createdAt))
      :END:
      #+TITLE: \(title)


      """
    case "md":
      return "# \(title)\n\n"
    default:
      return ""
    }
  }

  static func normalizedFolder(_ rawFolder: String) throws -> String {
    let trimmed = rawFolder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { throw Failure.invalidFolder }
    let components = trimmed
      .split(separator: "/", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && $0 != "." }
    guard !components.contains("..") else { throw Failure.invalidFolder }
    return components.joined(separator: "/")
  }

  static func inactiveTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
    return "[\(formatter.string(from: date))]"
  }
}

/// Menu and sidebar presentation for the New File command.
public enum NewCorpusFileCommand {
  public static let shortcutTitle = "⌘⇧N"
}

/// Sheet that asks for a file name and a corpus-relative folder, previews the
/// resulting path, and creates the document.
struct NewCorpusFileSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var name = ""
  @State private var folder = ""
  @State private var isCreating = false
  @FocusState private var focusesName: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New File")
          .font(.title2.weight(.semibold))
        Text("Create a note, draft, or scratch file in this corpus. Names without an extension become an .org file titled with the name you type.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Form {
        TextField("Name", text: $name, prompt: Text("Launch blog post"))
          .focused($focusesName)
        HStack(spacing: 6) {
          TextField("Folder", text: $folder, prompt: Text("corpus root"))
          Menu {
            ForEach(store.newCorpusFileFolderSuggestions, id: \.self) { suggestion in
              Button(suggestion) { folder = suggestion }
            }
            Divider()
            Button("Corpus root") { folder = "" }
          } label: {
            Image(systemName: "folder")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("Choose an existing folder")
        }
      }

      Group {
        switch preview {
        case .success(let plan):
          Label(plan.relativePath, systemImage: "doc.badge.plus")
            .foregroundStyle(.secondary)
        case .failure(let failure):
          if failure != .emptyName {
            Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        case nil:
          EmptyView()
        }
        if let error = store.newCorpusFileError {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
      .font(.callout)
      .lineLimit(2)

      HStack {
        Spacer()
        Button("Cancel") {
          store.isNewCorpusFileSheetPresented = false
        }
        .keyboardShortcut(.cancelAction)
        Button("Create") {
          create()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isCreating || !canCreate)
      }
    }
    .padding(20)
    .frame(width: 440)
    .onAppear {
      folder = store.newCorpusFileDefaultFolder
      focusesName = true
    }
    .onChange(of: name) { store.newCorpusFileError = nil }
    .onChange(of: folder) { store.newCorpusFileError = nil }
  }

  private var preview: Result<NewCorpusFilePlan, NewCorpusFilePlan.Failure>? {
    guard let corpusRoot = store.corpusRoot else { return nil }
    do {
      return .success(try NewCorpusFilePlan.plan(name: name, folder: folder, corpusRoot: corpusRoot))
    } catch let failure as NewCorpusFilePlan.Failure {
      return .failure(failure)
    } catch {
      return nil
    }
  }

  private var canCreate: Bool {
    if case .success = preview { return true }
    return false
  }

  private func create() {
    guard canCreate, !isCreating else { return }
    isCreating = true
    Task {
      await store.createNewCorpusFile(name: name, folder: folder)
      isCreating = false
    }
  }
}
