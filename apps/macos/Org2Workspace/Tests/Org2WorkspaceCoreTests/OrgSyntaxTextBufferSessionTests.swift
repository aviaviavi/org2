import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class OrgSyntaxTextBufferSessionTests: XCTestCase {
  func testPieceTreeMatchesUTF16ReferenceAcrossEdits() async {
    let initial = "alpha\n😀 bravo\ncharlie\n"
    let session = OrgSyntaxTextBufferSession(text: initial)
    let reference = NSMutableString(string: initial)
    let edits: [(NSRange, String)] = [
      (NSRange(location: 0, length: 0), "START\n"),
      (NSRange(location: 12, length: 2), "🙂"),
      (NSRange(location: 6, length: 6), ""),
      (NSRange(location: reference.length, length: 0), "END")
    ]

    for (requestedRange, replacement) in edits {
      let location = min(requestedRange.location, reference.length)
      let range = NSRange(
        location: location,
        length: min(requestedRange.length, reference.length - location)
      )
      session.replaceCharacters(in: range, with: replacement)
      reference.replaceCharacters(in: range, with: replacement)
      let snapshot = await session.snapshotAsync()
      XCTAssertEqual(snapshot.text, reference as String)
      XCTAssertEqual((snapshot.text as NSString).length, session.utf16Length)
    }
  }

  func testSnapshotDoesNotRebaseOverNewerRevision() async {
    let prefix = String(repeating: "line\n", count: 100_000)
    let session = OrgSyntaxTextBufferSession(text: prefix)
    session.replaceCharacters(in: NSRange(location: 0, length: 0), with: "A")

    async let firstSnapshot = session.snapshotAsync(priority: .background)
    session.replaceCharacters(in: NSRange(location: 1, length: 0), with: "B")
    _ = await firstSnapshot

    let final = await session.snapshotAsync()
    XCTAssertEqual(final.text.prefix(2), "AB")
    XCTAssertEqual(final.revision, 2)
  }

  func testPointInTimeCaptureMaterializesExactOlderRevisionAfterLaterEdit() async {
    let session = OrgSyntaxTextBufferSession(text: "alpha")
    session.replaceCharacters(in: NSRange(location: 5, length: 0), with: " one")
    let capture = session.capture()

    session.replaceCharacters(in: NSRange(location: session.utf16Length, length: 0), with: " two")
    let capturedSnapshot = await session.snapshotAsync(from: capture)
    let currentSnapshot = await session.snapshotAsync()

    XCTAssertEqual(capturedSnapshot.text, "alpha one")
    XCTAssertEqual(capturedSnapshot.revision, 1)
    XCTAssertEqual(currentSnapshot.text, "alpha one two")
    XCTAssertEqual(currentSnapshot.revision, 2)
  }

  func testLongTypingBurstRemainsExactAfterRebases() async {
    let session = OrgSyntaxTextBufferSession(text: "")
    let reference = NSMutableString()
    for index in 0..<2_000 {
      let replacement = "\(index % 10)"
      let location = reference.length / 2
      session.replaceCharacters(
        in: NSRange(location: location, length: 0),
        with: replacement
      )
      reference.insert(replacement, at: location)
      if index.isMultiple(of: 100) {
        _ = await session.snapshotAsync()
      }
    }
    let final = await session.snapshotAsync()
    XCTAssertEqual(final.text, reference as String)
  }

  func testPieceTreeDifferentiallyMatchesUnicodeReferenceWithoutIntermediateRebase() async {
    let initial = "ASCII\r\nemoji 😀 family 👨‍👩‍👧‍👦\r\ncombining cafe\u{301}\r\n"
    let session = OrgSyntaxTextBufferSession(text: initial)
    let reference = NSMutableString(string: initial)
    let replacements = ["x", "🙂", "e\u{301}", "\r\n", "👩🏽‍💻", "", "終"]

    // Keep every range on a Unicode-scalar boundary while deliberately using
    // emoji, ZWJ sequences, combining marks, and CRLF in both source and edits.
    // No snapshot occurs in the loop, so this exercises a continuously growing
    // piece tree rather than repeatedly rebasing to one piece.
    for index in 0..<750 {
      let referenceText = reference as String
      let boundaries = utf16ScalarBoundaries(in: referenceText)
      let startBoundaryIndex = (index &* 37) % boundaries.count
      let availableScalars = boundaries.count - startBoundaryIndex - 1
      let removedScalars = min((index &* 11) % 4, availableScalars)
      let range = NSRange(
        location: boundaries[startBoundaryIndex],
        length: boundaries[startBoundaryIndex + removedScalars] - boundaries[startBoundaryIndex]
      )
      let replacement = replacements[(index &* 17) % replacements.count]

      session.replaceCharacters(in: range, with: replacement)
      reference.replaceCharacters(in: range, with: replacement)
    }

    let snapshot = await session.snapshotAsync()
    XCTAssertEqual(snapshot.text, reference as String)
    XCTAssertEqual((snapshot.text as NSString).length, session.utf16Length)
    XCTAssertEqual(snapshot.revision, 750)
  }

  func testTenThousandUninterruptedCharactersStayExactAndLateEditsRemainBounded() async {
    let session = OrgSyntaxTextBufferSession(text: "")
    let sampleSize = 1_000
    var earlyNanoseconds: UInt64 = 0
    var lateNanoseconds: UInt64 = 0

    for index in 0..<10_000 {
      let start = DispatchTime.now().uptimeNanoseconds
      session.replaceCharacters(
        in: NSRange(location: session.utf16Length, length: 0),
        with: "x"
      )
      let elapsed = DispatchTime.now().uptimeNanoseconds - start
      if index < sampleSize {
        earlyNanoseconds &+= elapsed
      } else if index >= 10_000 - sampleSize {
        lateNanoseconds &+= elapsed
      }
    }

    let snapshot = await session.snapshotAsync()
    XCTAssertEqual(snapshot.text, String(repeating: "x", count: 10_000))
    XCTAssertEqual(snapshot.revision, 10_000)

    // A linear piece array makes the final window dramatically slower than
    // the first. Allow ample headroom for noisy shared CI while still catching
    // that pathological growth, and retain an independent absolute ceiling.
    let relativeCeiling = max(earlyNanoseconds &* 12, 250_000_000)
    XCTAssertLessThan(
      lateNanoseconds,
      relativeCeiling,
      "Late edits took \(lateNanoseconds)ns versus \(earlyNanoseconds)ns early"
    )
    XCTAssertLessThan(lateNanoseconds, 1_000_000_000)
  }

  private func utf16ScalarBoundaries(in text: String) -> [Int] {
    var boundaries = [0]
    boundaries.reserveCapacity(text.unicodeScalars.count + 1)
    var offset = 0
    for scalar in text.unicodeScalars {
      offset += String(scalar).utf16.count
      boundaries.append(offset)
    }
    return boundaries
  }
}
