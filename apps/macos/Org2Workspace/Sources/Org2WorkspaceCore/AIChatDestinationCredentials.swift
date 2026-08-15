import Foundation
import LocalAuthentication
import Security

public enum AIChatDestinationCredentials {
  public static let service = "Org2Workspace.AIChatDestinations"

  public static func containsToken(destinationID: String) -> Bool {
    SecItemCopyMatching(baseQuery(destinationID: destinationID) as CFDictionary, nil) == errSecSuccess
  }

  public static func readToken(destinationID: String, allowUserInteraction: Bool = false) -> String? {
    var query = baseQuery(destinationID: destinationID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = !allowUserInteraction
    query[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func saveToken(_ token: String, destinationID: String) throws {
    let data = Data(token.utf8)
    var addition = baseQuery(destinationID: destinationID)
    addition[kSecValueData as String] = data
    addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(addition as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update = SecItemUpdate(
        baseQuery(destinationID: destinationID) as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      guard update == errSecSuccess else { throw AIChatDestinationCredentialError.status(update) }
      return
    }
    guard status == errSecSuccess else { throw AIChatDestinationCredentialError.status(status) }
  }

  public static func deleteToken(destinationID: String) throws {
    let status = SecItemDelete(baseQuery(destinationID: destinationID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AIChatDestinationCredentialError.status(status)
    }
  }

  private static func baseQuery(destinationID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: destinationID
    ]
  }
}

public enum AIChatDestinationCredentialError: LocalizedError, Equatable {
  case status(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .status(let status): "Could not update the destination credential (Keychain status \(status))."
    }
  }
}
