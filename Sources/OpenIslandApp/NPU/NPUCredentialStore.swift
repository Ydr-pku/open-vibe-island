import Darwin
import Foundation
import Security

/// The password is stored only in the user's login Keychain. The account
/// binds it to a normalized SSH user, host and port.
protocol NPUCredentialStore {
    func password(for endpoint: SSHEndpoint) throws -> String?
    func save(_ password: String, for endpoint: SSHEndpoint) throws
    func retainOnly(for endpoint: SSHEndpoint) throws
}

/// A small adapter keeps tests from reading or changing the real Keychain.
protocol NPUKeychainBackend {
    func read(service: String, account: String) -> (OSStatus, Data?)
    func update(service: String, account: String, data: Data) -> OSStatus
    func add(service: String, account: String, data: Data) -> OSStatus
    func accounts(service: String) -> (OSStatus, [String])
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

    /// Prune older endpoints only after successfully saving the new one.
    /// Query account attributes, never the passwords being removed.
    func retainOnly(for endpoint: SSHEndpoint) throws {
        let keep = Self.account(for: endpoint)
        let (status, accounts) = backend.accounts(service: Self.service)
        guard status == errSecSuccess else { throw NPUCredentialError(status: status) }
        guard accounts.contains(keep) else { throw NPUCredentialError(status: errSecItemNotFound) }
        for account in Set(accounts) where account != keep {
            let status = backend.remove(service: Self.service, account: account)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NPUCredentialError(status: status)
            }
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

    func accounts(service: String) -> (OSStatus, [String]) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, []) }
        guard let entries = result as? [[String: Any]] else { return (errSecDecode, []) }
        let accounts = entries.compactMap { $0[kSecAttrAccount as String] as? String }
        guard accounts.count == entries.count else { return (errSecDecode, []) }
        return (errSecSuccess, accounts)
    }

    func remove(service: String, account: String) -> OSStatus {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}
