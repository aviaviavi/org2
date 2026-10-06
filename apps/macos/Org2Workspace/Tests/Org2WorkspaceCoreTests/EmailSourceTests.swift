import XCTest
@testable import Org2WorkspaceCore

final class EmailSourceTests: XCTestCase {
  func testEmailProfileStatusDecodesAccountSummary() throws {
    let json = #"""
    [{"id":"mail","type":"email","enabled":true,"scopes":[],"rawZone":"raw/connectors/email/mail","reviewZone":"views/connectors/email/mail",
      "ingestionLimit":5000,"syncArgs":[],"media":"metadata-only","bindingPath":"/x","binary":"org2 (built-in IMAP)","binaryAvailable":true,
      "configAvailable":true,"ready":true,"credentialAvailable":false,
      "email":{"host":"imap.example.com","port":993,"security":"tls","username":"avi@example.com","mailboxes":["INBOX"],"smtp":{"host":"smtp.example.com","port":587}}}]
    """#
    let profiles = try JSONDecoder().decode([WorkspaceSourceProfileStatus].self, from: Data(json.utf8))
    let mail = try XCTUnwrap(profiles.first)
    XCTAssertTrue(mail.usesStoredCredential)
    XCTAssertEqual(mail.email?.smtp?.host, "smtp.example.com")
    XCTAssertEqual(mail.credentialAvailable, false)
  }
}
