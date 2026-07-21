import Foundation
import LocalAuthentication
import Security

public enum SourceCredentialsKeychain {
  public static let service = "org.org2.workspace.external-sources"

  public static func containsToken(profileID: String) -> Bool {
    var query = baseQuery(profileID: profileID)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  public static func readToken(profileID: String) -> String? {
    var query = baseQuery(profileID: profileID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8),
          !value.isEmpty
    else { return nil }
    return value
  }

  public static func saveToken(_ value: String, profileID: String) throws {
    let query = baseQuery(profileID: profileID)
    let data = Data(value.utf8)
    var addQuery = query
    addQuery[kSecValueData as String] = data
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecDuplicateItem {
      var updateQuery = query
      updateQuery[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
      let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard updateStatus == errSecSuccess else { throw SourceCredentialsKeychainError.status(updateStatus) }
      return
    }
    guard status == errSecSuccess else { throw SourceCredentialsKeychainError.status(status) }
  }

  public static func deleteToken(profileID: String) throws {
    let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SourceCredentialsKeychainError.status(status)
    }
  }

  private static func baseQuery(profileID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: profileID
    ]
  }

  private static func noninteractiveAuthenticationContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
  }
}

public enum SourceCredentialsKeychainError: LocalizedError, Equatable {
  case status(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .status(let status): "Source credential keychain operation failed with status \(status)."
    }
  }
}
