import Foundation
import LocalAuthentication
import Security

public enum DataSourceCredentialsKeychain {
  public static let service = "Org2Workspace.DataSources"
  public static let scarfMetabaseAPIKeyAccount = "SCARF_METABASE_API_KEY"

  public static func containsScarfMetabaseAPIKey() -> Bool {
    var query = baseQuery(account: scarfMetabaseAPIKeyAccount)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  public static func readScarfMetabaseAPIKey() -> String? {
    var query = baseQuery(account: scarfMetabaseAPIKeyAccount)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8),
          !value.isEmpty
    else {
      return nil
    }
    return value
  }

  public static func saveScarfMetabaseAPIKey(_ value: String) throws {
    let data = Data(value.utf8)
    let query = baseQuery(account: scarfMetabaseAPIKeyAccount)
    var addQuery = query
    addQuery[kSecValueData as String] = data
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecDuplicateItem {
      var updateQuery = query
      updateQuery[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
      let updateStatus = SecItemUpdate(
        updateQuery as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      guard updateStatus == errSecSuccess else { throw DataSourceCredentialsKeychainError.status(updateStatus) }
      return
    }
    guard status == errSecSuccess else { throw DataSourceCredentialsKeychainError.status(status) }
  }

  public static func deleteScarfMetabaseAPIKey() throws {
    let status = SecItemDelete(baseQuery(account: scarfMetabaseAPIKeyAccount) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw DataSourceCredentialsKeychainError.status(status)
    }
  }

  private static func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }

  private static func noninteractiveAuthenticationContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
  }
}

public enum DataSourceCredentialsKeychainError: LocalizedError, Equatable {
  case status(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .status(let status):
      "Data source keychain operation failed with status \(status)."
    }
  }
}
