import Foundation
import Testing
@testable import OpenIslandApp

@MainActor
struct NPUConnectionPersistenceTests {
    @Test
    func visibleWindowAutofillsAfterDisconnectOrFailureWithoutOverwritingEdits() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        let endpoint = SSHEndpoint(host: "node.example", port: 22, user: "user")
        try credentials.save("saved-secret", for: endpoint)
        let store = MonitorStore(defaults: defaults, startsTimer: false)
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        store.connectionInput = "user@node.example"
        store.state = .connected
        persistence.prepareForDisplay()
        #expect(store.password.isEmpty)

        store.state = .disconnected
        persistence.connectionStateDidChange(from: .connected, to: .disconnected, windowVisible: true)
        #expect(store.password == "saved-secret")
        persistence.updatePassword("user-edited-secret")
        persistence.connectionStateDidChange(from: .connecting, to: .disconnected, windowVisible: true)
        #expect(store.password == "user-edited-secret")

        persistence.updateAddress("user@other.example")
        #expect(store.password.isEmpty)
        store.state = .failed
        persistence.connectionStateDidChange(from: .connecting, to: .failed, windowVisible: true)
        #expect(store.password.isEmpty)
        store.connectionInput = "user@node.example"
        persistence.connectionStateDidChange(from: .connecting, to: .failed, windowVisible: false)
        #expect(store.password.isEmpty)
        persistence.connectionStateDidChange(from: .connecting, to: .failed, windowVisible: true)
        #expect(store.password == "saved-secret")
    }

    @Test
    func savesOnlyAfterSuccessfulSamplingAndRestoresAfterShutdown() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        let olderEndpoint = SSHEndpoint(host: "older.example", port: 22, user: "user")
        try credentials.save("older-test-secret", for: olderEndpoint)
        let transport = PersistenceTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        store.connectionInput = "ssh -p 2200 user@node.example"
        store.password = "local-test-secret"
        persistence.connect()
        #expect(try credentials.password(for: olderEndpoint) == "older-test-secret")
        #expect(credentials.saved.count == 1)
        #expect(!defaults.bool(forKey: NPUConnectionPersistence.resumeMonitoringKey))

        transport.onOutput?(NPUParsingTests.fixture + "\nuser@node:~$ ")
        for _ in 0..<150 where store.state != .connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        let endpoint = SSHEndpoint(host: "node.example", port: 2200, user: "user")
        #expect(store.state == .connected)
        #expect(try credentials.password(for: endpoint) == "local-test-secret")
        #expect(try credentials.password(for: olderEndpoint) == nil)
        #expect(credentials.saved.count == 1)
        #expect(defaults.bool(forKey: NPUConnectionPersistence.resumeMonitoringKey))
        #expect(!String(describing: defaults.persistentDomain(forName: suite) ?? [:]).contains("local-test-secret"))

        store.shutdown()
        #expect(defaults.bool(forKey: NPUConnectionPersistence.resumeMonitoringKey))
        let nextTransport = PersistenceTransport()
        let nextStore = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { nextTransport })
        let nextPersistence = NPUConnectionPersistence(monitor: nextStore, credentials: credentials, defaults: defaults)
        nextPersistence.restoreIfNeeded()
        #expect(nextTransport.endpoint == endpoint)
        #expect(nextTransport.password == "local-test-secret")
        #expect(nextStore.state == .connecting)
        nextStore.disconnect()
        #expect(!defaults.bool(forKey: NPUConnectionPersistence.resumeMonitoringKey))
        #expect(try credentials.password(for: endpoint) == "local-test-secret")
    }

    @Test
    func addressEditsCannotCarryAutofilledSecretsToAnotherHost() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        let endpoint = SSHEndpoint(host: "node.example", port: 22, user: "user")
        try credentials.save("local-test-secret", for: endpoint)
        let store = MonitorStore(defaults: defaults, startsTimer: false)
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        store.connectionInput = "user@node.example"
        persistence.prepareForDisplay()
        #expect(store.password == "local-test-secret")
        store.connectionInput = "user@other.example"
        persistence.addressDidChange(store.connectionInput)
        #expect(store.password.isEmpty)
        #expect(try credentials.password(for: endpoint) == "local-test-secret")
    }

    @Test
    func changingAddressClearsEvenAnEditedAutofilledPassword() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        try credentials.save("original-secret", for: SSHEndpoint(host: "node.example", port: 22, user: "user"))
        let store = MonitorStore(defaults: defaults, startsTimer: false)
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        store.connectionInput = "user@node.example"
        persistence.prepareForDisplay()
        persistence.updatePassword("edited-secret")
        persistence.updateAddress("user@other.example")
        #expect(store.password.isEmpty)
    }

    @Test
    func connectingChecksTheHostEvenIfTheViewCallbackDidNotRun() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        try credentials.save("original-secret", for: SSHEndpoint(host: "node.example", port: 22, user: "user"))
        let transport = PersistenceTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        store.connectionInput = "user@node.example"
        persistence.prepareForDisplay()
        store.connectionInput = "user@other.example" // Simulate a delayed UI notification.
        persistence.connect()
        #expect(transport.endpoint == nil)
        #expect(store.password.isEmpty)
        #expect(store.errorMessage != nil)
    }

    @Test
    func repeatedPresentationDoesNotOverwriteEditedPassword() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        try credentials.save("old-secret", for: SSHEndpoint(host: "node.example", port: 22, user: "user"))
        let store = MonitorStore(defaults: defaults, startsTimer: false)
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        store.connectionInput = "user@node.example"
        persistence.prepareForDisplay()
        persistence.updatePassword("new-secret")
        persistence.prepareForDisplay()
        #expect(store.password == "new-secret")
    }

    @Test
    func keychainErrorsAreVisibleAndNeverEnableFalseRecovery() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        let store = MonitorStore(defaults: defaults, startsTimer: false)
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        credentials.failReads = true
        store.connectionInput = "user@node.example"
        persistence.prepareForDisplay()
        #expect(persistence.credentialNoticeKey == "npu.credentials.readFailed")
        credentials.failReads = false
        credentials.failWrites = true
        store.onConnectionEstablished?(SSHEndpoint(host: "node.example", port: 22, user: "user"), "local-test-secret")
        #expect(persistence.credentialNoticeKey == "npu.credentials.saveFailed")
        #expect(!defaults.bool(forKey: NPUConnectionPersistence.resumeMonitoringKey))
    }

    @Test
    func cleanupFailureDoesNotDisableResumeWithNewPassword() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        credentials.failCleanup = true
        let store = MonitorStore(defaults: defaults, startsTimer: false)
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        let endpoint = SSHEndpoint(host: "node.example", port: 22, user: "user")
        store.connectionInput = "user@node.example"
        store.onConnectionEstablished?(endpoint, "local-test-secret")
        #expect(try credentials.password(for: endpoint) == "local-test-secret")
        #expect(defaults.bool(forKey: NPUConnectionPersistence.resumeMonitoringKey))
        #expect(persistence.credentialNoticeKey == "npu.credentials.cleanupFailed")
    }

    @Test
    func startupDoesNotConnectToPreviousAddressAfterItChangedInAnOlderBuild() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        let endpoint = SSHEndpoint(host: "node.example", port: 22, user: "user")
        try credentials.save("local-test-secret", for: endpoint)
        defaults.set("user@other.example", forKey: MonitorStore.savedEndpointKey)
        defaults.set("user@node.example", forKey: NPUConnectionPersistence.successfulAddressKey)
        defaults.set(true, forKey: NPUConnectionPersistence.resumeMonitoringKey)
        let transport = PersistenceTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        persistence.restoreIfNeeded()
        #expect(transport.endpoint == nil)
        #expect(store.connectionInput == "user@other.example")
        #expect(try credentials.password(for: endpoint) == "local-test-secret")
    }

    @Test
    func rejectedPasswordDoesNotOverwritePreviouslySavedCredential() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        let endpoint = SSHEndpoint(host: "node.example", port: 22, user: "user")
        try credentials.save("previous-valid-secret", for: endpoint)
        let transport = PersistenceTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        store.connectionInput = "user@node.example"
        persistence.prepareForDisplay()
        store.password = "incorrect-new-secret"
        persistence.connect()
        transport.onExit?(255, "Permission denied, please try again.")
        for _ in 0..<100 where store.state != .failed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.state == .failed)
        #expect(try credentials.password(for: endpoint) == "previous-valid-secret")
        #expect(!defaults.bool(forKey: NPUConnectionPersistence.resumeMonitoringKey))
    }

    @Test
    func restoredSessionStopsAfterAuthenticationFailure() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentials()
        let endpoint = SSHEndpoint(host: "node.example", port: 22, user: "user")
        try credentials.save("saved-secret", for: endpoint)
        defaults.set(true, forKey: NPUConnectionPersistence.resumeMonitoringKey)
        defaults.set("user@node.example", forKey: NPUConnectionPersistence.successfulAddressKey)
        let transport = PersistenceTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        let persistence = NPUConnectionPersistence(monitor: store, credentials: credentials, defaults: defaults)
        persistence.restoreIfNeeded()
        transport.onExit?(255, "Permission denied")
        for _ in 0..<100 where store.state != .failed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.state == .failed)
        #expect(!defaults.bool(forKey: NPUConnectionPersistence.resumeMonitoringKey))
        #expect(try credentials.password(for: endpoint) == "saved-secret")
    }

    @Test
    func aTrustRequestIsPresentedWithoutBeingAcceptedAutomatically() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, startsTimer: false)
        let persistence = NPUConnectionPersistence(monitor: store, credentials: FakeCredentials(), defaults: defaults)
        var presented = false
        persistence.onHostTrustRequired = { presented = true }
        store.hostTrustRequest = HostTrustRequest(prompt: "local test fingerprint")
        for _ in 0..<50 where !presented { try await Task.sleep(for: .milliseconds(10)) }
        #expect(presented)
        #expect(store.hostTrustRequest != nil)
    }

    @Test
    func cancelledTrustRequestCannotOpenAStalePrompt() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, startsTimer: false)
        let persistence = NPUConnectionPersistence(monitor: store, credentials: FakeCredentials(), defaults: defaults)
        var presented = false
        persistence.onHostTrustRequired = { presented = true }
        store.hostTrustRequest = HostTrustRequest(prompt: "test fingerprint")
        store.hostTrustRequest = nil
        try await Task.sleep(for: .milliseconds(25))
        #expect(!presented)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "NPUConnectionPersistenceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private final class FakeCredentials: NPUCredentialStore {
    var saved: [String: String] = [:]
    var failReads = false
    var failWrites = false
    var failCleanup = false
    private enum Failure: Error { case simulated }

    func password(for endpoint: SSHEndpoint) throws -> String? {
        if failReads { throw Failure.simulated }
        return saved[endpoint.displayName]
    }
    func save(_ password: String, for endpoint: SSHEndpoint) throws {
        if failWrites { throw Failure.simulated }
        saved[endpoint.displayName] = password
    }
    func retainOnly(for endpoint: SSHEndpoint) throws {
        if failCleanup { throw Failure.simulated }
        saved = saved.filter { $0.key == endpoint.displayName }
    }
}

private final class PersistenceTransport: NPUTransport {
    var onOutput: ((String) -> Void)?
    var onErrorOutput: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    var onTrust: ((String, @escaping (Bool) -> Void) -> Void)?
    var endpoint: SSHEndpoint?
    var password: String?
    func start(endpoint: SSHEndpoint, password: String) throws { self.endpoint = endpoint; self.password = password }
    func requestSample() throws { }
    func stop() { }
}
