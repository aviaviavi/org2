import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceDateMentionsTests: XCTestCase {
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

  private func dayKeys(_ query: String) -> [String] {
    WorkspaceDateMentions.candidates(for: query, now: now, calendar: calendar).map(\.dayKey)
  }

  func testRelativeKeywordsResolveByPrefix() {
    XCTAssertEqual(dayKeys("today"), ["2026-09-27"])
    XCTAssertEqual(dayKeys("tomorrow"), ["2026-09-28"])
    XCTAssertEqual(dayKeys("yesterday"), ["2026-09-26"])
    XCTAssertEqual(dayKeys("t"), ["2026-09-27", "2026-09-28"])
    XCTAssertEqual(dayKeys("TOM"), ["2026-09-28"])
    XCTAssertEqual(
      WorkspaceDateMentions.candidates(for: "today", now: now, calendar: calendar).first?.title,
      "Today"
    )
  }

  func testAbsoluteDatesResolveInTheCurrentYearUnlessOneIsGiven() {
    XCTAssertEqual(dayKeys("july 10"), ["2026-07-10"])
    XCTAssertEqual(dayKeys("Jul 10th"), ["2026-07-10"])
    XCTAssertEqual(dayKeys("sept 3"), ["2026-09-03"])
    XCTAssertEqual(dayKeys("july 10, 2025"), ["2025-07-10"])
    XCTAssertEqual(dayKeys("10 july"), ["2026-07-10"])
    XCTAssertEqual(dayKeys("7/10"), ["2026-07-10"])
    XCTAssertEqual(dayKeys("7/10/25"), ["2025-07-10"])
    XCTAssertEqual(dayKeys("2026-07-10"), ["2026-07-10"])

    let july10 = WorkspaceDateMentions.candidates(for: "july 10", now: now, calendar: calendar).first
    XCTAssertEqual(july10?.title, "Friday, July 10, 2026")
    XCTAssertEqual(july10?.timestamp, "<2026-07-10 Fri>")
    XCTAssertEqual(
      WorkspaceDateMentions.candidates(for: "sep 28", now: now, calendar: calendar).first?.title,
      "Tomorrow"
    )
  }

  func testIncompleteOrInvalidQueriesDoNotResolve() {
    XCTAssertEqual(dayKeys(""), [])
    XCTAssertEqual(dayKeys("july"), [])
    XCTAssertEqual(dayKeys("ju 10"), [])
    XCTAssertEqual(dayKeys("ma 10"), [])
    XCTAssertEqual(dayKeys("feb 30"), [])
    XCTAssertEqual(dayKeys("codex"), [])
    XCTAssertEqual(dayKeys("13/40"), [])
  }

  func testMatchRequiresAMentionBoundaryAndAllowsSpacesInTheQuery() throws {
    let text = "Follow up @july 10"
    let match = try XCTUnwrap(WorkspaceDateMentions.matchAtEnd(of: text))
    XCTAssertEqual(match.query, "july 10")
    XCTAssertEqual(match.replacementRange, NSRange(location: 10, length: 8))
    XCTAssertEqual(WorkspaceDateMentions.removingMatch(match, in: text), "Follow up ")

    XCTAssertNil(WorkspaceDateMentions.matchAtEnd(of: "Email me@today"))
    XCTAssertNil(WorkspaceDateMentions.matchAtEnd(of: "@today\n"))
    XCTAssertNil(WorkspaceDateMentions.matchAtEnd(of: "Trailing @ today"))
    XCTAssertEqual(WorkspaceDateMentions.matchAtEnd(of: "(@today")?.query, "today")

    let middle = "See @tod and more"
    XCTAssertEqual(
      WorkspaceDateMentions.match(in: middle, selectedRange: NSRange(location: 8, length: 0))?.query,
      "tod"
    )
  }

  func testSnapshotMatchUsesAbsoluteEditorOffsets() throws {
    let localText = "Earlier context\nMeet on @tomorrow"
    let localStart = 900_000
    let length = (localText as NSString).length
    let snapshot = OrgSyntaxTextEditorSelectionSnapshot(
      selectedRange: NSRange(location: localStart + length, length: 0),
      sourceLine: 42,
      localText: localText,
      localTextRange: NSRange(location: localStart, length: length)
    )
    let match = try XCTUnwrap(WorkspaceDateMentions.match(in: snapshot))
    XCTAssertEqual(match.query, "tomorrow")
    XCTAssertEqual(match.replacementRange, NSRange(location: localStart + 24, length: 9))
  }

  func testEditorOptionsOfferADateStampAndTheExistingDailyNote() throws {
    let root = URL(fileURLWithPath: "/tmp/corpus", isDirectory: true)
    let daily = CorpusFile(
      path: "/tmp/corpus/daily/2026-09-27.org",
      relativePath: "daily/2026-09-27.org",
      modifiedAt: nil,
      byteCount: nil
    )
    let text = "Discussed @today"
    let match = try XCTUnwrap(WorkspaceDateMentions.matchAtEnd(of: text))
    let options = WorkspaceDateMentions.editorOptions(
      for: match,
      now: now,
      calendar: calendar,
      sourceFile: "/tmp/corpus/notes/projects/plan.org",
      corpusRoot: root,
      dailyNoteFile: { $0.dayKey == "2026-09-27" ? daily : nil }
    )
    XCTAssertEqual(options.map(\.insertion), [
      "<2026-09-27 Sun>",
      "[[file:../../daily/2026-09-27.org][2026-09-27]]",
    ])
    XCTAssertEqual(
      options.last?.replacement(in: text, match: match),
      InlineSelectionReplacement(
        text: "Discussed [[file:../../daily/2026-09-27.org][2026-09-27]]",
        selectedRange: NSRange(location: 57, length: 0)
      )
    )

    let tomorrowOnly = WorkspaceDateMentions.editorOptions(
      for: try XCTUnwrap(WorkspaceDateMentions.matchAtEnd(of: "@tomorrow")),
      now: now,
      calendar: calendar,
      sourceFile: nil,
      corpusRoot: root,
      dailyNoteFile: { _ in nil }
    )
    XCTAssertEqual(tomorrowOnly.map(\.insertion), ["<2026-09-28 Mon>"])

    XCTAssertEqual(
      WorkspaceDateMentions.linkPath(to: daily.path, from: nil, corpusRoot: root),
      "daily/2026-09-27.org"
    )
    XCTAssertEqual(
      WorkspaceDateMentions.linkPath(to: daily.path, from: "/tmp/corpus/daily/2026-09-26.org", corpusRoot: root),
      "2026-09-27.org"
    )
  }

  func testStaleTextIsNotReplaced() throws {
    let match = try XCTUnwrap(WorkspaceDateMentions.matchAtEnd(of: "Hi @today"))
    let option = WorkspaceDateMentionOption(
      candidate: WorkspaceDateMentions.candidate(for: now, calendar: calendar),
      kind: .timestamp,
      insertion: "<2026-09-27 Sun>"
    )
    XCTAssertNil(option.replacement(in: "Hi @tod", match: match))
  }

  func testCompletionKeysNavigateAcceptAndDismiss() throws {
    let match = try XCTUnwrap(WorkspaceDateMentions.matchAtEnd(of: "@t"))
    let options = WorkspaceDateMentions.editorOptions(
      for: match,
      now: now,
      calendar: calendar,
      sourceFile: nil,
      corpusRoot: nil,
      dailyNoteFile: { _ in nil }
    )
    XCTAssertEqual(options.count, 2)

    var state = WorkspaceDateMentionCompletionState()
    XCTAssertEqual(state.handle(.moveDown, match: match, options: options), .handled)
    XCTAssertEqual(state.selectedIndex(for: match, optionCount: options.count), 1)
    XCTAssertEqual(
      state.handle(.accept, match: match, options: options),
      .replace(range: match.replacementRange, text: "<2026-09-28 Mon>")
    )

    XCTAssertEqual(state.handle(.dismiss, match: match, options: options), .handled)
    XCTAssertTrue(state.isDismissed(match))
    XCTAssertEqual(state.handle(.accept, match: match, options: options), .ignored)

    let longer = try XCTUnwrap(WorkspaceDateMentions.matchAtEnd(of: "@to"))
    XCTAssertFalse(state.isDismissed(longer))
    XCTAssertEqual(state.handle(.accept, match: longer, options: []), .ignored)
  }

  func testExistingDailyNoteLookupPrefersOrgAndIgnoresOtherDirectories() {
    let directory = URL(fileURLWithPath: "/tmp/corpus/daily", isDirectory: true)
    let org2 = CorpusFile(path: "/tmp/corpus/daily/2026-07-10.org2", relativePath: "daily/2026-07-10.org2", modifiedAt: nil, byteCount: nil)
    let org = CorpusFile(path: "/tmp/corpus/daily/2026-07-10.org", relativePath: "daily/2026-07-10.org", modifiedAt: nil, byteCount: nil)
    let elsewhere = CorpusFile(path: "/tmp/corpus/meetings/2026-07-11.org", relativePath: "meetings/2026-07-11.org", modifiedAt: nil, byteCount: nil)

    XCTAssertEqual(
      WorkspaceStore.existingDailyNoteFile(
        baseName: "2026-07-10",
        in: directory,
        filesByPath: [:],
        corpusFiles: [org2, org, elsewhere]
      ),
      org
    )
    XCTAssertEqual(
      WorkspaceStore.existingDailyNoteFile(
        baseName: "2026-07-10",
        in: directory,
        filesByPath: [org2.path: org2],
        corpusFiles: []
      ),
      org2
    )
    XCTAssertNil(
      WorkspaceStore.existingDailyNoteFile(
        baseName: "2026-07-11",
        in: directory,
        filesByPath: [:],
        corpusFiles: [elsewhere]
      )
    )
  }

  func testChatComposerSuggestsExistingDailyNotesForDateMentions() {
    let daily = CorpusFile(
      path: "/tmp/corpus/daily/2026-07-10.org",
      relativePath: "daily/2026-07-10.org",
      modifiedAt: nil,
      byteCount: nil
    )
    let lookup: (WorkspaceDateMentionCandidate) -> CorpusFile? = { $0.dayKey == "2026-07-10" ? daily : nil }

    let suggestions = AIChatComposerMentionSuggestion.suggestions(
      for: "Summarize @july 10",
      destinations: AIChatDestinationConfiguration.defaults,
      allDestinationIDs: AIChatDestinationConfiguration.defaults.map(\.id),
      corpusFiles: [daily],
      dailyNoteFile: lookup,
      now: now
    )
    XCTAssertEqual(suggestions.map(\.id), ["daily:/tmp/corpus/daily/2026-07-10.org"])
    XCTAssertEqual(suggestions.first?.detail, "Daily note · daily/2026-07-10.org")
    XCTAssertEqual(
      AIChatComposerMentionSuggestion.removingActiveDateMention(in: "Summarize @july 10"),
      "Summarize "
    )

    // A day without a daily note contributes nothing.
    XCTAssertTrue(AIChatComposerMentionSuggestion.suggestions(
      for: "Summarize @yesterday",
      destinations: AIChatDestinationConfiguration.defaults,
      allDestinationIDs: AIChatDestinationConfiguration.defaults.map(\.id),
      corpusFiles: [daily],
      dailyNoteFile: lookup,
      now: now
    ).isEmpty)
  }
}
