import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class DocumentPublishingTests: XCTestCase {
  private actor RequestCapture {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
      self.request = request
    }
  }

  func testDestinationFormatMatrixKeepsLocalAndGoogleOutputsDistinct() {
    XCTAssertEqual(
      DocumentPublishDestination.localLink.formats,
      [.html, .pdf, .beamerSlides]
    )
    XCTAssertEqual(
      DocumentPublishDestination.googleDrive.formats,
      [.googleDocs, .googleSlides, .googleSheets, .pdf]
    )
    XCTAssertEqual(DocumentPublishFormat.googleDocs.googleCLIDestination, "google-docs")
    XCTAssertEqual(DocumentPublishFormat.googleSlides.googleCLIDestination, "google-slides")
    XCTAssertEqual(DocumentPublishFormat.googleSheets.googleCLIDestination, "google-sheets")
    XCTAssertEqual(DocumentPublishFormat.pdf.googleCLIDestination, "google-drive-pdf")
    XCTAssertNil(DocumentPublishFormat.beamerSlides.googleCLIDestination)
  }

  func testLocalPublicationRetainsSourceAndFormatForSettingsManagement() throws {
    let url = try XCTUnwrap(URL(string: "http://example.local:1234/a/secret"))
    let publication = LocalDocumentPublication(
      id: "secret",
      title: "Operating dashboard",
      url: url,
      localURL: url,
      sourcePath: "/Users/example/corpus/views/dashboard.org2",
      format: .html
    )

    XCTAssertEqual(publication.sourcePath, "/Users/example/corpus/views/dashboard.org2")
    XCTAssertEqual(publication.format, .html)
  }

  func testDecodesDisclosurePreviewAndDestinationState() throws {
    let payload = Data(
      #"""
      {
        "$schema": "org2:publish-document-command-result:v1",
        "applied": false,
        "source": {
          "file": "/private/report.org2",
          "selection": "document",
          "sourceHash": "source-hash"
        },
        "artifact": {
          "$schema": "org2:published-document:v1",
          "title": "Market Brief",
          "mediaType": "text/html",
          "selection": "document",
          "artifactHash": "artifact-hash",
          "bytes": 2048,
          "projectionHash": "projection-hash",
          "assets": [
            {
              "name": "chart.png",
              "mediaType": "image/png",
              "bytes": 512,
              "sha256": "asset-hash"
            }
          ]
        },
        "disclosure": {
          "redactions": {
            "metadata": 3,
            "comments": 2,
            "internalLinks": 0
          },
          "warnings": ["One linked file was omitted."]
        },
        "destination": {
          "destination": "google-docs",
          "webViewLink": "https://docs.google.com/document/d/doc-123/edit",
          "fileId": "doc-123",
          "version": "7"
        }
      }
      """#.utf8
    )

    let result = try JSONDecoder().decode(DocumentPublishCLIResult.self, from: payload)

    XCTAssertFalse(result.applied)
    XCTAssertEqual(result.artifact.title, "Market Brief")
    XCTAssertEqual(result.artifact.assets.map(\.name), ["chart.png"])
    XCTAssertEqual(result.redactionCount, 5)
    XCTAssertEqual(result.destinationString("fileId"), "doc-123")
    XCTAssertEqual(result.destinationString("version"), "7")
  }

  func testLocalHostRequiresTheSecretLinkAndSupportsRevocation() async throws {
    let host = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1"
    )
    defer { host.stop() }

    let html = Data("<!doctype html><title>Safe report</title><p>Published body</p>".utf8)
    let publication = try await host.publish(html: html, title: "Safe report")
    let second = try await host.publish(html: html, title: "Another report")

    XCTAssertNotEqual(publication.id, second.id)
    XCTAssertGreaterThanOrEqual(publication.id.count, 40)
    XCTAssertEqual(publication.url.host, "127.0.0.1")

    let (servedData, servedResponse) = try await URLSession.shared.data(from: publication.localURL)
    let servedHTTP = try XCTUnwrap(servedResponse as? HTTPURLResponse)
    XCTAssertEqual(servedHTTP.statusCode, 200)
    XCTAssertEqual(servedData, html)
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "Cache-Control"), "no-store")

    let unavailableURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1:\(publication.localURL.port ?? 0)/a/not-the-secret")
    )
    let (_, unavailableResponse) = try await URLSession.shared.data(from: unavailableURL)
    XCTAssertEqual((unavailableResponse as? HTTPURLResponse)?.statusCode, 404)

    host.revoke(publication.id)
    let (_, revokedResponse) = try await URLSession.shared.data(from: publication.localURL)
    XCTAssertEqual((revokedResponse as? HTTPURLResponse)?.statusCode, 404)

    let (secondData, secondResponse) = try await URLSession.shared.data(from: second.localURL)
    XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(secondData, html)
  }

  func testLocalHostServesPDFWithAProtectedInlineContentType() async throws {
    let host = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1"
    )
    defer { host.stop() }

    let pdf = Data("%PDF-1.7\nsealed\n%%EOF".utf8)
    let publication = try await host.publish(
      data: pdf,
      title: "Safe PDF",
      mediaType: "application/pdf"
    )
    let (servedData, servedResponse) = try await URLSession.shared.data(from: publication.localURL)
    let servedHTTP = try XCTUnwrap(servedResponse as? HTTPURLResponse)

    XCTAssertEqual(servedHTTP.statusCode, 200)
    XCTAssertEqual(servedData, pdf)
    XCTAssertEqual(publication.mediaType, "application/pdf")
    XCTAssertEqual(servedHTTP.mimeType, "application/pdf")
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "Content-Disposition"), "inline")
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "X-Robots-Tag"), "noindex, nofollow, noarchive")
  }

  func testGoogleAuthorizationURLUsesLoopbackPKCEAndDriveFileScope() throws {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let challenge = GoogleDriveOAuthClient.codeChallenge(for: verifier)
    XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

    let redirectURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152"))
    let url = try GoogleDriveOAuthClient.authorizationURL(
      clientID: "desktop-client.apps.googleusercontent.com",
      redirectURL: redirectURL,
      codeChallenge: challenge,
      state: "state-token"
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let values = Dictionary(
      uniqueKeysWithValues: try XCTUnwrap(components.queryItems).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "accounts.google.com")
    XCTAssertEqual(values["client_id"], "desktop-client.apps.googleusercontent.com")
    XCTAssertEqual(values["redirect_uri"], redirectURL.absoluteString)
    XCTAssertEqual(values["response_type"], "code")
    XCTAssertEqual(values["scope"], GoogleDriveOAuthClient.driveFileScope)
    XCTAssertEqual(values["code_challenge"], challenge)
    XCTAssertEqual(values["code_challenge_method"], "S256")
    XCTAssertEqual(values["state"], "state-token")
  }

  func testGoogleDesktopClientJSONImportsTheCredentialPair() throws {
    let data = Data(
      #"{"installed":{"client_id":" desktop-client.apps.googleusercontent.com ","client_secret":" desktop-secret ","redirect_uris":["http://localhost"]}}"#.utf8
    )

    let client = try GoogleDriveOAuthDesktopClient.decodeGoogleClientJSON(data)

    XCTAssertEqual(client.clientID, "desktop-client.apps.googleusercontent.com")
    XCTAssertEqual(client.clientSecret, "desktop-secret")
  }

  func testGoogleDesktopClientJSONRejectsWebApplicationCredentials() throws {
    let data = Data(
      #"{"web":{"client_id":"web-client.apps.googleusercontent.com","client_secret":"web-secret"}}"#.utf8
    )

    XCTAssertThrowsError(try GoogleDriveOAuthDesktopClient.decodeGoogleClientJSON(data)) { error in
      XCTAssertEqual(error as? GoogleDriveOAuthDesktopClientError, .webClientNotSupported)
    }
  }

  func testGoogleCredentialDecodesLegacyKeychainPayloadWithoutClientSecret() throws {
    let data = Data(
      #"{"clientID":"desktop-client.apps.googleusercontent.com","accessToken":"access","refreshToken":"refresh","expirationDate":0,"scope":"https:\/\/www.googleapis.com\/auth\/drive.file","tokenType":"Bearer"}"#.utf8
    )

    let credential = try JSONDecoder().decode(GoogleDriveOAuthCredential.self, from: data)

    XCTAssertNil(credential.clientSecret)
    XCTAssertEqual(credential.clientID, "desktop-client.apps.googleusercontent.com")
  }

  func testGoogleCredentialRefreshKeepsRefreshTokenAndScope() async throws {
    let capture = RequestCapture()
    let responseData = Data(
      #"{"access_token":"new-access","expires_in":3600,"scope":"https://www.googleapis.com/auth/drive.file","token_type":"Bearer"}"#.utf8
    )
    let client = GoogleDriveOAuthClient { request in
      await capture.record(request)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      return (responseData, response)
    }
    let original = GoogleDriveOAuthCredential(
      clientID: "desktop-client.apps.googleusercontent.com",
      clientSecret: "desktop-secret",
      accessToken: "old-access",
      refreshToken: "durable-refresh",
      expirationDate: Date(timeIntervalSince1970: 10),
      scope: GoogleDriveOAuthClient.driveFileScope
    )
    let now = Date(timeIntervalSince1970: 100)

    let refreshed = try await client.refreshingIfNeeded(original, now: now)

    XCTAssertEqual(refreshed.accessToken, "new-access")
    XCTAssertEqual(refreshed.clientSecret, "desktop-secret")
    XCTAssertEqual(refreshed.refreshToken, "durable-refresh")
    XCTAssertEqual(refreshed.expirationDate, now.addingTimeInterval(3600))
    XCTAssertTrue(refreshed.grantsDriveFileScope)
    let request = await capture.request
    XCTAssertEqual(request?.httpMethod, "POST")
    let body = String(data: try XCTUnwrap(request?.httpBody), encoding: .utf8)
    XCTAssertTrue(body?.contains("grant_type=refresh_token") == true)
    XCTAssertTrue(body?.contains("refresh_token=durable-refresh") == true)
    XCTAssertTrue(body?.contains("client_secret=desktop-secret") == true)
    XCTAssertFalse(body?.contains("old-access") == true)
  }

  func testGoogleMissingClientSecretResponseHasActionableError() async throws {
    let client = GoogleDriveOAuthClient { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 400,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      return (Data(#"{"error":"invalid_request","error_description":"client_secret is missing."}"#.utf8), response)
    }
    let credential = GoogleDriveOAuthCredential(
      clientID: "desktop-client.apps.googleusercontent.com",
      accessToken: "expired-access",
      refreshToken: "durable-refresh",
      expirationDate: Date(timeIntervalSince1970: 10),
      scope: GoogleDriveOAuthClient.driveFileScope
    )

    do {
      _ = try await client.refreshingIfNeeded(credential, now: Date(timeIntervalSince1970: 100))
      XCTFail("Expected the missing client secret response to fail")
    } catch {
      guard case GoogleDriveOAuthError.missingClientSecret = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }
}
