import Foundation
import Testing
@testable import OpenIslandApp

@MainActor
struct NPUMonitorStoreTests {
    @Test
    func liveTransportWaitsForNetworkTerminatorButNetworkReadIsOptional() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        transport.requiresNetworkSection = true
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        store.connectionInput = "root@node.example"
        store.password = "secret"
        store.connect()
        transport.onOutput?(NPUParsingTests.fixture + "\nroot@node:~# printf '__OPEN_ISLAND_NET_END_V1__'\nroot@node:~# ")
        try await Task.sleep(for: .milliseconds(450))
        #expect(store.state == .connecting)
        transport.onOutput?("\n" + NetworkTrafficParser.endMarker + "\nroot@node:~# ")
        try await waitUntil { store.state == .connected }
        #expect(store.snapshot?.devices.count == 4)
        #expect(store.networkRates.isEmpty)
        store.disconnect()
    }

    @Test
    func networkRatesAreIndependentAndResetOnDisconnect() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        store.connectionInput = "root@node.example"
        store.password = "secret"
        store.connect()
        transport.onOutput?(NPUParsingTests.fixture + NetworkTrafficTests.section() + "\nroot@node:~# ")
        try await waitUntil { store.state == .connected }
        #expect(store.networkRates.first?.name == "eth0")
        #expect(store.networkRates.first?.receivedPerSecond == nil)

        store.refreshNow()
        transport.onOutput?(NPUParsingTests.fixture + NetworkTrafficTests.section(rx: 4000, tx: 3000) + "\nroot@node:~# ")
        try await waitUntil { store.networkRates.first?.receivedPerSecond != nil }
        #expect((store.networkRates.first?.receivedPerSecond ?? 0) > 0)
        #expect(store.networkLastUpdated != nil)

        store.refreshNow()
        transport.onOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        try await waitUntil { store.networkRates.isEmpty }
        #expect(store.state == .connected)
        #expect(store.networkLastUpdated == nil)

        store.disconnect()
        #expect(store.networkRates.isEmpty)
        #expect(store.networkLastUpdated == nil)
    }

    @Test
    func onlyMarksConnectedAfterACompleteSampleAndPreservesStaleDataOnDisconnect() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        store.connectionInput = "ssh -p 2200 alice@node.example"
        store.password = "test-secret-never-persist"
        store.connect()
        #expect(store.state == .connecting)
        #expect(store.snapshot == nil)
        #expect(store.password.isEmpty)
        #expect(transport.sampleRequests == 1)
        #expect(transport.endpoint == SSHEndpoint(host: "node.example", port: 2200, user: "alice"))
        #expect(defaults.string(forKey: MonitorStore.savedEndpointKey) == store.connectionInput)
        #expect(!String(describing: defaults.persistentDomain(forName: suite) ?? [:]).contains("test-secret-never-persist"))

        transport.onOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        for _ in 0..<200 {
            if store.state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.state == .connected)
        #expect(store.snapshot?.devices.count == 4)
        #expect(store.lastUpdated == store.snapshot?.timestamp)
        let sampledAt = store.lastUpdated
        store.disconnect()
        #expect(store.state == .disconnected)
        #expect(store.snapshot?.devices.count == 4)
        #expect(store.lastUpdated == sampledAt)
        #expect(transport.stopCount == 1)
    }

    @Test
    func refusesMissingPasswordAndInvalidEndpointsWithoutOpeningTransport() {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        store.connectionInput = "root@node.example"
        store.connect()
        #expect(store.state == .disconnected)
        #expect(store.errorMessage != nil)
        #expect(transport.endpoint == nil)
        store.connectionInput = "ssh root@node.example touch /tmp/example"
        store.password = "secret"
        store.connect()
        #expect(transport.endpoint == nil)
        #expect(defaults.string(forKey: MonitorStore.savedEndpointKey) == nil)
    }

    @Test
    func connectionFailureStopsTransportAndCanBeRetried() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        transport.sampleError = MonitorError.transport("local test failure")
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        store.connectionInput = "alice@node.example"
        store.password = "secret"
        store.connect()
        #expect(store.state == .connecting)
        transport.onExit?(1, "local test failure")
        try await waitUntil { store.state == .failed }
        #expect(store.state == .failed)
        #expect(store.errorMessage == "local test failure")
        #expect(store.password.isEmpty)
        #expect(transport.stopCount == 1)
        transport.sampleError = nil
        store.password = "replacement"
        store.connect()
        #expect(store.state == .connecting)
        #expect(store.errorMessage == nil)
    }

    @Test
    func hostTrustCanBeApprovedOrRejectedThroughTheStore() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        store.connectionInput = "root@node.example"
        store.password = "secret"
        store.connect()
        var decision: Bool?
        transport.onTrust?("fingerprint one") { decision = $0 }
        try await Task.sleep(for: .milliseconds(25))
        #expect(store.hostTrustRequest?.prompt == "fingerprint one")
        store.approveHost()
        #expect(decision == true)
        #expect(store.hostTrustRequest == nil)
        transport.onTrust?("fingerprint two") { decision = $0 }
        try await Task.sleep(for: .milliseconds(25))
        store.rejectHost()
        #expect(decision == false)
        #expect(store.state == .failed)
        #expect(store.hostTrustRequest == nil)
    }

    @Test
    func ignoresOutputFromAnOlderConnectionAndClearsDemoData() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        store.connectionInput = "root@node.example"
        store.password = "secret"
        store.connect()
        let oldOutput = transport.onOutput
        store.disconnect()
        oldOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.snapshot == nil)
        #expect(store.state == .disconnected)
        store.loadDemo()
        #expect(store.isDemo)
        #expect(store.snapshot?.hbmPercent != nil)
        #expect(store.history.count == 60)
        store.togglePause()
        #expect(store.isPaused)
        store.disconnect()
        #expect(!store.isDemo)
        #expect(!store.isPaused)
        #expect(store.snapshot == nil)
        #expect(store.lastUpdated == nil)
    }

    @Test
    func restoresOnlyAValidatedAddressAndReleasesItsTimerAndTransport() {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("alice@[2001:db8::1]:2222", forKey: MonitorStore.savedEndpointKey)
        let transport = FakeNPUTransport()
        var store: MonitorStore? = MonitorStore(defaults: defaults, makeTransport: { transport })
        #expect(store?.connectionInput == "alice@[2001:db8::1]:2222")
        #expect(store?.password.isEmpty == true)
        #expect(store?.state == .disconnected)
        store?.password = "secret"
        store?.connect()
        weak var releasedStore: MonitorStore?
        releasedStore = store
        store = nil
        #expect(releasedStore == nil)
        #expect(transport.stopCount == 1)
        defaults.set("ssh host remote-command", forKey: MonitorStore.savedEndpointKey)
        let invalidSaved = MonitorStore(defaults: defaults, startsTimer: false)
        #expect(invalidSaved.connectionInput.isEmpty)
    }

    @Test
    func unexpectedDisconnectReconnectsUsingTheSameCredentialsAndIgnoresOldCallbacks() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FakeNPUTransport(), second = FakeNPUTransport()
        var attempts = 0
        var establishedCount = 0
        var delays: [Int] = []
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            attempts += 1
            return attempts == 1 ? first : second
        }, reconnectDelay: { attempt in delays.append(attempt); return 0.01 })
        store.onConnectionEstablished = { _, credential in
            #expect(credential == "test-password")
            establishedCount += 1
        }
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect()
        first.onOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        try await waitUntil { store.state == .connected }
        let lastSnapshot = store.snapshot
        #expect(establishedCount == 1)

        let oldOutput = first.onOutput
        let oldExit = first.onExit
        first.onExit?(255, "Read from remote host: Connection reset by peer\nclient_loop: send disconnect: Broken pipe")
        try await waitUntil { attempts == 2 }
        #expect(store.state == .connecting)
        #expect(store.isReconnecting)
        #expect(store.snapshot == lastSnapshot)
        #expect(second.endpoint == first.endpoint)
        #expect(second.receivedPassword == "test-password")
        #expect(delays == [1])

        oldOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        oldExit?(255, "old callback")
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.state == .connecting)
        #expect(attempts == 2)
        second.onOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        try await waitUntil { store.state == .connected }
        #expect(!store.isReconnecting)
        #expect(establishedCount == 1)
        store.shutdown()
    }

    @Test
    func manualDisconnectCancelsPendingRetryAndClearsResumeIntent() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        var attempts = 0, userDisconnects = 0, permanentFailures = 0
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            attempts += 1; return transport
        }, reconnectDelay: { _ in 0.4 })
        store.onUserDisconnect = { userDisconnects += 1 }
        store.onPermanentFailure = { permanentFailures += 1 }
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect()
        transport.onOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        try await waitUntil { store.state == .connected }
        transport.onExit?(255, "Broken pipe")
        try await waitUntil { store.isReconnecting }
        store.disconnect()
        try await Task.sleep(for: .milliseconds(550))
        #expect(store.state == .disconnected)
        #expect(!store.isReconnecting)
        #expect(attempts == 1)
        #expect(userDisconnects == 1)
        #expect(permanentFailures == 0)
    }

    @Test
    func authenticationFailureDuringRetryStopsRatherThanReusingPasswordForever() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FakeNPUTransport(), second = FakeNPUTransport()
        var attempts = 0, failures = 0
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            attempts += 1; return attempts == 1 ? first : second
        }, reconnectDelay: { _ in 0.01 })
        store.onPermanentFailure = { failures += 1 }
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect()
        first.onOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        try await waitUntil { store.state == .connected }
        first.onExit?(255, "Connection reset by peer")
        try await waitUntil { attempts == 2 }
        second.onExit?(255, "Permission denied, please try again.")
        try await waitUntil { store.state == .failed }
        try await Task.sleep(for: .milliseconds(80))
        #expect(attempts == 2)
        #expect(!store.isReconnecting)
        #expect(failures == 1)
        #expect(store.errorMessage?.contains("Permission denied") == true)
    }

    @Test
    func previouslyVerifiedSessionCanResumeAfterInitialNetworkFailure() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FakeNPUTransport(), second = FakeNPUTransport()
        var attempts = 0, established = 0, userDisconnects = 0
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            attempts += 1; return attempts == 1 ? first : second
        }, reconnectDelay: { _ in 0.01 })
        store.onConnectionEstablished = { _, _ in established += 1 }
        store.onUserDisconnect = { userDisconnects += 1 }
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect(retryingKnownEndpoint: true)
        #expect(store.isReconnecting)
        first.onExit?(255, "Connection refused")
        try await waitUntil { attempts == 2 }
        second.onOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        try await waitUntil { store.state == .connected }
        #expect(established == 1)
        store.shutdown()
        #expect(userDisconnects == 0)
    }

    @Test
    func unrecognizedFailureAndChangedHostKeyAreNeverRetried() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transports = (0..<4).map { _ in FakeNPUTransport() }
        var attempts = 0, failures = 0
        var scheduledAttempts: [Int] = []
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            defer { attempts += 1 }; return transports[min(attempts, transports.count - 1)]
        }, reconnectDelay: { attempt in scheduledAttempts.append(attempt); return 0.01 })
        store.onPermanentFailure = { failures += 1 }
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect(retryingKnownEndpoint: true)
        transports[0].onExit?(255, "Unrecognized protocol failure")
        try await waitUntil { store.state == .failed }
        #expect(attempts == 1)
        #expect(scheduledAttempts.isEmpty)
        #expect(failures == 1)

        let changedKey = FakeNPUTransport()
        var keyAttempts = 0
        let retry = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            keyAttempts += 1; return changedKey
        }, reconnectDelay: { _ in 0.01 })
        retry.connectionInput = "root@node.example"
        retry.password = "test-password"
        retry.connect(retryingKnownEndpoint: true)
        changedKey.onExit?(255, "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.")
        try await waitUntil { retry.state == .failed }
        #expect(keyAttempts == 1)
    }

    @Test
    func repeatedNetworkErrorsUseBackoffWithoutOverlappingConnections() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transports = (0..<4).map { _ in FakeNPUTransport() }
        var attempts = 0
        var scheduledAttempts: [Int] = []
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            defer { attempts += 1 }; return transports[min(attempts, transports.count - 1)]
        }, reconnectDelay: { attempt in scheduledAttempts.append(attempt); return 0.01 })
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect(retryingKnownEndpoint: true)
        for index in 0..<3 {
            try await waitUntil { attempts > index }
            transports[index].onExit?(255, "Connection reset by peer")
        }
        try await waitUntil { attempts == 4 }
        #expect(scheduledAttempts == [1, 2, 3])
        #expect(transports[0].stopCount == 1)
        #expect(transports[1].stopCount == 1)
        #expect(transports[2].stopCount == 1)
        store.shutdown()
    }

    @Test
    func connectingWriteErrorWaitsForAuthenticationDiagnostic() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        transport.sampleError = MonitorError.transport("Broken pipe")
        var attempts = 0
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            attempts += 1; return transport
        }, reconnectDelay: { _ in 0.01 })
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect(retryingKnownEndpoint: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(attempts == 1)
        #expect(store.state == .connecting)
        transport.onExit?(255, "Permission denied, please try again.")
        try await waitUntil { store.state == .failed }
        #expect(attempts == 1)
        #expect(store.errorMessage?.contains("Permission denied") == true)
    }

    @Test
    func cleanRemoteExitCanReconnectButUnclassifiedErrorCannot() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FakeNPUTransport(), second = FakeNPUTransport()
        var attempts = 0
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            attempts += 1; return attempts == 1 ? first : second
        }, reconnectDelay: { _ in 0.01 })
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect(retryingKnownEndpoint: true)
        first.onExit?(0, "")
        try await waitUntil { attempts == 2 }
        second.onExit?(255, "")
        try await waitUntil { store.state == .failed }
        #expect(attempts == 2)
    }

    @Test
    func rejectingAnUnexpectedHostFingerprintStopsAutomaticReconnect() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        var failures = 0
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport }, reconnectDelay: { _ in 0.01 })
        store.onPermanentFailure = { failures += 1 }
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect(retryingKnownEndpoint: true)
        var decision: Bool?
        transport.onTrust?("unexpected fingerprint") { decision = $0 }
        try await waitUntil { store.hostTrustRequest != nil }
        store.rejectHost()
        #expect(decision == false)
        #expect(store.state == .failed)
        #expect(failures == 1)
        #expect(!store.isReconnecting)
    }

    @Test
    func queuedOldSampleCannotMarkTheNewTransportConnected() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FakeNPUTransport(), second = FakeNPUTransport()
        var attempts = 0
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            attempts += 1; return attempts == 1 ? first : second
        }, reconnectDelay: { _ in 0.01 })
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect(retryingKnownEndpoint: true)
        first.onOutput?(NPUParsingTests.fixture + "\nroot@node:~# ")
        first.onExit?(255, "Connection reset by peer")
        try await waitUntil { attempts == 2 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.state == .connecting)
        #expect(store.snapshot == nil)
        store.shutdown()
    }

    @Test
    func shutdownCancelsRetryWithoutChangingUserResumeIntent() async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        var attempts = 0, userDisconnects = 0, failures = 0
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: {
            attempts += 1; return transport
        }, reconnectDelay: { _ in 0.3 })
        store.onUserDisconnect = { userDisconnects += 1 }
        store.onPermanentFailure = { failures += 1 }
        store.connectionInput = "root@node.example"
        store.password = "test-password"
        store.connect(retryingKnownEndpoint: true)
        transport.onExit?(255, "Connection reset by peer")
        try await waitUntil { transport.stopCount == 1 }
        store.shutdown()
        try await Task.sleep(for: .milliseconds(400))
        #expect(attempts == 1)
        #expect(store.state == .disconnected)
        #expect(userDisconnects == 0)
        #expect(failures == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for monitor state")
    }

    private func testDefaults() -> (UserDefaults, String) {
        let suite = "OpenIsland.NPU.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private final class FakeNPUTransport: NPUTransport {
    var requiresNetworkSection = false
    var onOutput: ((String) -> Void)?
    var onErrorOutput: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    var onTrust: ((String, @escaping (Bool) -> Void) -> Void)?
    var endpoint: SSHEndpoint?
    var receivedPassword: String?
    var sampleRequests = 0
    var stopCount = 0
    var sampleError: (any Error)?

    func start(endpoint: SSHEndpoint, password: String) throws {
        self.endpoint = endpoint
        self.receivedPassword = password
    }

    func requestSample() throws {
        sampleRequests += 1
        if let sampleError { throw sampleError }
    }

    func stop() { stopCount += 1 }
}
