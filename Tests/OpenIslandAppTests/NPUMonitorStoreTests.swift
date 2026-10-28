import Foundation
import Testing
@testable import OpenIslandApp

@MainActor
struct NPUMonitorStoreTests {
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
    func connectionFailureStopsTransportAndCanBeRetried() {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeNPUTransport()
        transport.sampleError = MonitorError.transport("local test failure")
        let store = MonitorStore(defaults: defaults, startsTimer: false, makeTransport: { transport })
        store.connectionInput = "alice@node.example"
        store.password = "secret"
        store.connect()
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

    private func testDefaults() -> (UserDefaults, String) {
        let suite = "OpenIsland.NPU.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private final class FakeNPUTransport: NPUTransport {
    var onOutput: ((String) -> Void)?
    var onErrorOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onTrust: ((String, @escaping (Bool) -> Void) -> Void)?
    var endpoint: SSHEndpoint?
    var sampleRequests = 0
    var stopCount = 0
    var sampleError: (any Error)?

    func start(endpoint: SSHEndpoint, password: String) throws {
        self.endpoint = endpoint
    }

    func requestSample() throws {
        sampleRequests += 1
        if let sampleError { throw sampleError }
    }

    func stop() { stopCount += 1 }
}
