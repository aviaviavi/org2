import Darwin
import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class HeadlessControlInputTests: XCTestCase {
  func testNonblockingPipeSurvivesIdleReadsAndSplitUTF8UntilEOF() async throws {
    let pipe = Pipe()
    let input = pipe.fileHandleForReading
    let output = pipe.fileHandleForWriting
    defer { try? input.close(); try? output.close() }
    XCTAssertEqual(fcntl(input.fileDescriptor, F_SETFL, O_NONBLOCK), 0)
    var iterator = HeadlessControlInput.lines(descriptor: input.fileDescriptor).makeAsyncIterator()
    try output.write(contentsOf: Data("status\n".utf8))
    let first = try await iterator.next()
    XCTAssertEqual(first, "status")
    // A direct read here reports EAGAIN; the control reader must keep waiting.
    try await Task.sleep(for: .milliseconds(150))
    let unicode = Array("pair 🌍\nstop\n".utf8)
    try output.write(contentsOf: Data(unicode.prefix(7)))
    try await Task.sleep(for: .milliseconds(150))
    try output.write(contentsOf: Data(unicode.dropFirst(7)))
    try output.close()
    let second = try await iterator.next()
    let third = try await iterator.next()
    let end = try await iterator.next()
    XCTAssertEqual(second, "pair 🌍")
    XCTAssertEqual(third, "stop")
    XCTAssertNil(end)
  }
}
