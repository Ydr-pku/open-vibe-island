import Darwin
import Foundation
import Security

/// The address is non-secret; passwords are stored only in the user's login
/// Keychain, with one item per normalized SSH user, host and port.
protocol NPUCredentialStore {
    func password(for endpoint: SSHEndpoint) throws -> String?
    func save(_ password: String, for endpoint: SSHEndpoint) throws
    func remove(for endpoint: SSHEndpoint) throws
}

/// A small adapter keeps tests from reading or changing the real Keychain.
protocol NPUKeychainBackend {
    func read(service: String, account: String) -> (OSStatus, Data?)
    func update(service: String, account: String, data: Data) -> OSStatus
    func add(service: String, account: String, data: Data) -> OSStatus
    func remove(service: String, account: String) -> OSStatus
}

struct NPUCredentialError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "无法访问系统钥匙串（状态 \(status)）。"
    }
}

struct NPUKeychainCredentialStore: NPUCredentialStore {
    static let service = "app.openisland.npu.ssh"
    private let backend: any NPUKeychainBackend

    init(backend: any NPUKeychainBackend = NPUSecurityKeychainBackend()) {
        self.backend = backend
    }

    func password(for endpoint: SSHEndpoint) throws -> String? {
        let (status, data) = backend.read(service: Self.service, account: Self.account(for: endpoint))
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NPUCredentialError(status: status) }
        guard let data, let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw NPUCredentialError(status: errSecDecode)
        }
        return password
    }

    func save(_ password: String, for endpoint: SSHEndpoint) throws {
        // A blank field never erases an existing saved password.
        guard !password.isEmpty else { return }
        let account = Self.account(for: endpoint)
        let data = Data(password.utf8)
        let status = backend.update(service: Self.service, account: account, data: data)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NPUCredentialError(status: status) }
        let addStatus = backend.add(service: Self.service, account: account, data: data)
        if addStatus == errSecSuccess { return }
        // Another writer can create the item between update and add.
        if addStatus == errSecDuplicateItem {
            let retryStatus = backend.update(service: Self.service, account: account, data: data)
            guard retryStatus == errSecSuccess else { throw NPUCredentialError(status: retryStatus) }
            return
        }
        throw NPUCredentialError(status: addStatus)
    }

    func remove(for endpoint: SSHEndpoint) throws {
        let status = backend.remove(service: Self.service, account: Self.account(for: endpoint))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NPUCredentialError(status: status)
        }
    }

    static func account(for endpoint: SSHEndpoint) -> String {
        let host = endpoint.host.lowercased()
        var address = in6_addr()
        let isIPv6 = host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        let normalizedHost: String
        if isIPv6 {
            // Expanded and compressed spellings of the same IPv6 address map
            // to the same item without conflating different hosts.
            normalizedHost = withUnsafeBytes(of: address) { bytes in
                bytes.map { String(format: "%02x", $0) }.joined()
            }
        } else {
            normalizedHost = host
        }
        return "\(endpoint.user)@[\(normalizedHost)]:\(endpoint.port)"
    }
}

/// Generic-password items default to the local login Keychain. We do not opt
/// into a shared access group or iCloud synchronization.
struct NPUSecurityKeychainBackend: NPUKeychainBackend {
    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(service: String, account: String) -> (OSStatus, Data?) {
        var attributes = query(service: service, account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        SecItemUpdate(query(service: service, account: account) as CFDictionary,
                      [kSecValueData as String: data] as CFDictionary)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var attributes = query(service: service, account: account)
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func remove(service: String, account: String) -> OSStatus {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}
