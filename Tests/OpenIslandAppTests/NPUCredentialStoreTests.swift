import Foundation
import Security
import Testing
@testable import OpenIslandApp

struct NPUCredentialStoreTests {
    private let endpoint = SSHEndpoint(host: "Node.Example", port: 2200, user: "alice")

    @Test
    func savesUpdatesAndRemovesOnlyTheMatchingEndpoint() throws {
        let backend = FakeNPUKeychain()
        let store = NPUKeychainCredentialStore(backend: backend)
        let same = SSHEndpoint(host: "node.example", port: 2200, user: "alice")
        let otherPort = SSHEndpoint(host: "node.example", port: 22, user: "alice")
        let otherUser = SSHEndpoint(host: "node.example", port: 2200, user: "Alice")
        #expect(try store.password(for: endpoint) == nil)
        try store.save("first-test-password", for: endpoint)
        try store.save("second-test-password", for: same)
        try store.save("other-port-password", for: otherPort)
        try store.save("other-user-password", for: otherUser)
        #expect(try store.password(for: endpoint) == "second-test-password")
        #expect(try store.password(for: otherPort) == "other-port-password")
        #expect(try store.password(for: otherUser) == "other-user-password")
        #expect(backend.values.count == 3)
        try store.remove(for: same)
        #expect(try store.password(for: endpoint) == nil)
        #expect(try store.password(for: otherPort) == "other-port-password")
        try store.remove(for: endpoint) // Missing item is already removed.
    }

    @Test
    func emptyInputPreservesExistingCredential() throws {
        let backend = FakeNPUKeychain()
        let store = NPUKeychainCredentialStore(backend: backend)
        try store.save("old-password", for: endpoint)
        try store.save("", for: endpoint)
        #expect(try store.password(for: endpoint) == "old-password")
    }

    @Test
    func compressedAndExpandedIPv6AddressesShareOneCredential() throws {
        let backend = FakeNPUKeychain()
        let store = NPUKeychainCredentialStore(backend: backend)
        let compressed = try EndpointParser.parse("alice@[2001:db8::1]:2200")
        let expanded = try EndpointParser.parse("alice@[2001:0DB8:0:0:0:0:0:1]:2200")
        try store.save("ipv6-test-password", for: compressed)
        #expect(try store.password(for: expanded) == "ipv6-test-password")
        #expect(backend.values.count == 1)
    }

    @Test
    func errorsAreNotMistakenForMissingPasswordsAndNeverContainSecrets() throws {
        let backend = FakeNPUKeychain()
        let store = NPUKeychainCredentialStore(backend: backend)
        backend.readError = errSecInteractionNotAllowed
        #expect(throws: NPUCredentialError.self) { try store.password(for: endpoint) }
        backend.readError = nil
        backend.updateError = errSecAuthFailed
        do {
            try store.save("private-test-password", for: endpoint)
            Issue.record("Expected a Keychain error")
        } catch {
            #expect(error.localizedDescription.contains(String(errSecAuthFailed)))
            #expect(!error.localizedDescription.contains("private-test-password"))
        }
        backend.updateError = nil
        backend.values[NPUKeychainCredentialStore.account(for: endpoint)] = Data([0xff])
        #expect(throws: NPUCredentialError.self) { try store.password(for: endpoint) }
    }

    @Test
    func retriesUpdateIfAnotherWriterCreatesItemDuringAdd() throws {
        let backend = FakeNPUKeychain()
        backend.createRace = true
        let store = NPUKeychainCredentialStore(backend: backend)
        try store.save("new-test-password", for: endpoint)
        #expect(try store.password(for: endpoint) == "new-test-password")
        #expect(backend.updateCalls == 2)
    }
}

private final class FakeNPUKeychain: NPUKeychainBackend {
    var values: [String: Data] = [:]
    var readError: OSStatus?
    var updateError: OSStatus?
    var createRace = false
    var updateCalls = 0

    func read(service: String, account: String) -> (OSStatus, Data?) {
        #expect(service == NPUKeychainCredentialStore.service)
        if let readError { return (readError, nil) }
        guard let data = values[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        #expect(service == NPUKeychainCredentialStore.service)
        updateCalls += 1
        if let updateError { return updateError }
        guard values[account] != nil else { return errSecItemNotFound }
        values[account] = data
        return errSecSuccess
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        #expect(service == NPUKeychainCredentialStore.service)
        if createRace {
            createRace = false
            values[account] = Data("concurrent-value".utf8)
            return errSecDuplicateItem
        }
        guard values[account] == nil else { return errSecDuplicateItem }
        values[account] = data
        return errSecSuccess
    }

    func remove(service: String, account: String) -> OSStatus {
        #expect(service == NPUKeychainCredentialStore.service)
        return values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }
}
