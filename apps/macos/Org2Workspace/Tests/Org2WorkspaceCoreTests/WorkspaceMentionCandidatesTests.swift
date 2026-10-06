import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceMentionCandidatesTests: XCTestCase {
  private let root = URL(fileURLWithPath: "/tmp/corpus", isDirectory: true)

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }

  /// Sunday, September 27, 2026 at 15:30 in New York.
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 15, minute: 30))!
  }

  private func file(_ relativePath: String) -> CorpusFile {
    CorpusFile(path: "/tmp/corpus/\(relativePath)", relativePath: relativePath, modifiedAt: nil, byteCount: nil)
  }

  private var corpus: [CorpusFile] {
    [
      file("daily/2026-09-27.org"),
      file("notes/project-plan.org"),
      file("notes/projects/roadmap.org"),
      file("notes/reading_list.md"),
      file("people/alice.org"),
      file("reports/quarterly.pdf"),
    ]
  }

  private func chatFilePaths(_ text: String, corpus: [CorpusFile]) -> [String] {
    AIChatComposerMentionSuggestion.suggestions(
      for: text,
      destinations: [],
      allDestinationIDs: [],
      corpusFiles: corpus,
      dailyNoteFile: { [self] candidate in
        candidate.dayKey == "2026-09-27" ? file("daily/2026-09-27.org") : nil
      },
      now: now
    ).compactMap { suggestion in
      switch suggestion {
      case .corpusFile(let file), .dailyNote(_, let file): file.path
      case .destination: nil
      }
    }
  }

  private func editorOptions(
    _ text: String,
    corpus: [CorpusFile],
    sourceFile: String? = nil,
    resolver: OrgRoamLinkResolver = .empty
  ) throws -> [WorkspaceDateMentionOption] {
    let match = try XCTUnwrap(WorkspaceDateMentions.matchAtEnd(of: text), text)
    return WorkspaceDateMentions.editorOptions(
      for: match,
      now: now,
      calendar: calendar,
      sourceFile: sourceFile,
      corpusRoot: root,
      corpusFiles: corpus,
      linkResolver: resolver,
      dailyNoteFile: { [self] candidate in
        candidate.dayKey == "2026-09-27" ? file("daily/2026-09-27.org") : nil
      }
    )
  }

  private func linkedPaths(_ options: [WorkspaceDateMentionOption]) -> [String] {
    options.compactMap { option in
      switch option.kind {
      case .dailyNote(let path, _), .corpusFile(let path, _, _): path
      case .timestamp: nil
      }
    }
  }

  func testDocumentEditorOffersTheSameFilesAsChatForTheSameQuery() throws {
    for query in ["", "proj", "plan", "alice", "reading_list", "quarterly", "today"] {
      let text = "Notes for @\(query)"
      let chat = chatFilePaths(text, corpus: corpus)
      let editor = linkedPaths(try editorOptions(text, corpus: corpus))
      XCTAssertEqual(editor, chat, "@\(query)")
    }
    XCTAssertEqual(
      Set(linkedPaths(try editorOptions("@proj", corpus: corpus))),
      ["/tmp/corpus/notes/project-plan.org", "/tmp/corpus/notes/projects/roadmap.org"]
    )
  }

  func testBareAtListsFilesWhileSpacedQueriesOnlyResolveDates() throws {
    XCTAssertEqual(WorkspaceDateMentions.matchAtEnd(of: "See @")?.query, "")
    XCTAssertEqual(WorkspaceDateMentions.matchAtEnd(of: "See @reading_list")?.query, "reading_list")
    XCTAssertNil(WorkspaceDateMentions.matchAtEnd(of: "a@"))
    XCTAssertNil(WorkspaceDateMentions.matchAtEnd(of: "See @ "))

    XCTAssertEqual(try editorOptions("See @", corpus: corpus).count, corpus.count)
    XCTAssertEqual(try editorOptions("Met @july 10", corpus: corpus).map(\.insertion), ["<2026-07-10 Fri>"])
    XCTAssertTrue(try editorOptions("@project plan", corpus: corpus).isEmpty)
    XCTAssertTrue(WorkspaceMentionCandidates.corpusFiles(matching: "project plan", in: corpus, limit: 10).isEmpty)
  }

  func testDateOptionsComeFirstAndTheDailyNoteIsNotRepeated() throws {
    let options = try editorOptions("@today", corpus: corpus)
    XCTAssertEqual(options.first?.insertion, "<2026-09-27 Sun>")
    XCTAssertEqual(
      linkedPaths(options).filter { $0 == "/tmp/corpus/daily/2026-09-27.org" }.count,
      1
    )
    XCTAssertEqual(options.prefix(2).map(\.isDate), [true, true])
  }

  func testEditorOptionsAreLimitedLikeChat() throws {
    let many = (0..<30).map { file("notes/note-\($0).org") }
    XCTAssertEqual(try editorOptions("@note", corpus: many).count, WorkspaceMentionCandidates.defaultLimit)
    XCTAssertEqual(chatFilePaths("@note", corpus: many).count, WorkspaceMentionCandidates.defaultLimit)
  }

  func testFileMentionsInsertIDLinksForTitledNotesAndFileLinksOtherwise() throws {
    let resolver = OrgRoamLinkResolver(nodes: [
      OrgRoamNodeReference(
        idValue: "plan-id",
        title: "Project Plan [Q4]",
        file: "/tmp/corpus/notes/project-plan.org",
        line: 1,
        isPageNode: true
      ),
      OrgRoamNodeReference(
        idValue: nil,
        title: "Alice",
        file: "/tmp/corpus/people/alice.org",
        line: 1,
        isPageNode: true
      ),
      OrgRoamNodeReference(
        idValue: "dup",
        title: "Roadmap",
        file: "/tmp/corpus/notes/projects/roadmap.org",
        line: 1,
        isPageNode: true
      ),
      OrgRoamNodeReference(idValue: "dup", title: "Elsewhere", file: "/tmp/corpus/other.org", line: 4),
    ])
    let source = "/tmp/corpus/notes/today.org"

    func insertion(_ query: String) throws -> String? {
      try editorOptions("@\(query)", corpus: corpus, sourceFile: source, resolver: resolver)
        .first { !$0.isDate }?.insertion
    }

    XCTAssertEqual(try insertion("project-plan"), "[[id:plan-id][Project Plan (Q4)]]")
    XCTAssertEqual(try insertion("alice"), "[[file:../people/alice.org][Alice]]")
    XCTAssertEqual(try insertion("roadmap"), "[[file:projects/roadmap.org][Roadmap]]")
    XCTAssertEqual(try insertion("quarterly"), "[[file:../reports/quarterly.pdf][quarterly.pdf]]")

    let options = try editorOptions("Read @alice", corpus: corpus, sourceFile: source, resolver: resolver)
    let alice = try XCTUnwrap(options.first)
    XCTAssertEqual(alice.title, "Alice")
    XCTAssertEqual(alice.detail, "people/alice.org")
    let match = try XCTUnwrap(WorkspaceDateMentions.matchAtEnd(of: "Read @alice"))
    XCTAssertEqual(
      alice.replacement(in: "Read @alice", match: match)?.text,
      "Read [[file:../people/alice.org][Alice]]"
    )
  }

  func testTheDocumentBeingEditedIsNotOfferedAsALinkToItself() throws {
    let source = "/tmp/corpus/people/alice.org"
    XCTAssertFalse(linkedPaths(try editorOptions("@alice", corpus: corpus, sourceFile: source)).contains(source))
  }
}
