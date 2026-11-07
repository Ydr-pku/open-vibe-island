import Foundation
import Testing
@testable import OpenIslandApp

struct CPUSampleTests {
    @Test
    func idleIsValidAndLogicalCoresAreSorted() throws {
        let sample = try CPUSnapshot.decode(Data(#"{"hostname":"wsl","platform":"WSL","totalUsage":0,"cores":[{"id":1,"usage":0},{"id":0,"usage":0}]}"#.utf8))
        #expect(sample.totalUsage == 0)
        #expect(sample.cores.map(\.id) == [0, 1])
    }

    @Test(arguments: [
        #"{"hostname":"host","platform":"WSL","totalUsage":0,"cores":[]}"#,
        #"{"hostname":"host","platform":"WSL","totalUsage":0,"cores":[{"id":0,"usage":null}]}"#,
        #"{"hostname":"host","platform":"WSL","totalUsage":0,"cores":[{"id":0,"usage":1},{"id":0,"usage":2}]}"#,
        #"{"hostname":"host","platform":"WSL","totalUsage":101,"cores":[{"id":0,"usage":1}]}"#,
        #"{"hostname":"host","platform":"WSL","totalUsage":1,"cores":[{"id":0,"usage":-1}]}"#
    ])
    func malformedSamplesAreNeverShownAsIdle(_ json: String) {
        #expect(throws: (any Error).self) { try CPUSnapshot.decode(Data(json.utf8)) }
    }

    @Test
    func gridHasSevenRowsForThe56CoreServer() {
        #expect(CPUGridLayout.rows(for: 8) == 1)
        #expect(CPUGridLayout.rows(for: 9) == 2)
        #expect(CPUGridLayout.rows(for: 56) == 7)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_CPU_SSH"] == "1"))
    func configuredServersReturnRealSamples() async throws {
        try await withThrowingTaskGroup(of: (String, CPUSnapshot).self) { group in
            for alias in CPUCollector.aliases {
                group.addTask { (alias, try await CPUCollector.sample(alias: alias)) }
            }
            var count = 0
            for try await (alias, sample) in group {
                #expect(sample.cores.count == (alias == "winserver2055" ? 56 : 8))
                #expect(sample.platform == (alias == "macserver" ? "macOS" : "WSL"))
                count += 1
            }
            #expect(count == 3)
        }
    }
}

@MainActor
struct CPUMonitorStoreTests {
    @Test
    func relaunchRestoresSelectionAndIntervalWhileDeselectStaysOff() async throws {
        let suite = "CPUMonitorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sampler: CPUMonitorStore.Sampler = { alias in
            CPUSnapshot(hostname: alias, platform: "WSL", totalUsage: 1,
                        cores: [CPUCore(id: 0, usage: 1)], cpuModel: nil, scope: "WSL")
        }
        let first = CPUMonitorStore(defaults: defaults, sampler: sampler)
        first.connect("winserver")
        first.connect("winserver2055")
        first.refreshInterval = 5
        first.shutdown()
        #expect(defaults.stringArray(forKey: CPUMonitorStore.savedAliasesKey) == ["winserver", "winserver2055"])

        let second = CPUMonitorStore(defaults: defaults, sampler: sampler)
        #expect(second.monitoredHosts.isEmpty)
        #expect(second.refreshInterval == 5)
        second.resumeSavedConnections()
        try await waitUntil { second.monitoredHosts.filter { $0.state == .connected }.count == 2 }
        second.disconnect("winserver")
        second.shutdown()

        let third = CPUMonitorStore(defaults: defaults, sampler: sampler)
        defer { third.shutdown() }
        third.resumeSavedConnections()
        try await waitUntil { third.monitoredHosts.first?.state == .connected }
        #expect(third.monitoredHosts.map(\.id) == ["winserver2055"])
    }

    @Test
    func invalidSavedAliasesAreIgnoredAndRepeatedResumeDoesNotDuplicateTasks() async throws {
        let suite = "CPUMonitorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["winserver2055", "winserver2055", "unknown", "-oProxyCommand=invalid"],
                     forKey: CPUMonitorStore.savedAliasesKey)
        defaults.set(-1, forKey: CPUMonitorStore.savedIntervalKey)
        let gate = CPUSampleGate()
        let monitor = CPUMonitorStore(defaults: defaults) { _ in await gate.sample() }
        defer { monitor.shutdown() }
        #expect(monitor.refreshInterval == 2)
        monitor.resumeSavedConnections()
        monitor.resumeSavedConnections()
        try await waitUntil { await gate.count == 1 }
        #expect(monitor.monitoredHosts.map(\.id) == ["winserver2055"])
        await gate.release(0, usage: 1)
        try await waitUntil { monitor.selectedHost?.state == .connected }
        #expect(await gate.count == 1)
    }

    @Test
    func buttonsSelectMultipleServersAndToggleIndependently() async throws {
        let monitor = CPUMonitorStore { alias in
            let count = alias == "winserver2055" ? 56 : 8
            return CPUSnapshot(hostname: alias, platform: "WSL", totalUsage: 1,
                               cores: (0..<count).map { CPUCore(id: $0, usage: 1) },
                               cpuModel: nil, scope: "WSL")
        }
        monitor.refreshInterval = 10
        defer { monitor.shutdown() }
        for alias in CPUCollector.aliases { monitor.toggle(alias) }
        try await waitUntil { monitor.monitoredHosts.filter { $0.state == .connected }.count == 3 }
        #expect(monitor.monitoredHosts.map(\.id) == CPUCollector.aliases)
        #expect(CPUGridLayout.panelHeight(for: monitor) == 436)
        monitor.toggle("winserver")
        #expect(monitor.monitoredHosts.map(\.id) == ["macserver", "winserver2055"])
        #expect(CPUGridLayout.panelHeight(for: monitor) == 348)
    }

    @Test
    func lateSampleCannotOverwriteAReconnectedHost() async throws {
        let gate = CPUSampleGate()
        let monitor = CPUMonitorStore { _ in await gate.sample() }
        monitor.refreshInterval = 10
        defer { monitor.shutdown() }

        monitor.connect("macserver")
        try await waitUntil { await gate.count == 1 }
        monitor.disconnect("macserver")
        monitor.connect("macserver")
        try await waitUntil { await gate.count == 2 }
        await gate.release(1, usage: 80)
        try await waitUntil { monitor.selectedHost?.state == .connected }
        await gate.release(0, usage: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.selectedHost?.snapshot?.totalUsage == 80)
        #expect(monitor.selectedHost?.history == [80])
    }

    @Test
    func switchingHostsKeepsOtherConnectionsAndDisconnectRestoresSelection() async throws {
        let monitor = CPUMonitorStore { alias in
            CPUSnapshot(hostname: alias, platform: "WSL", totalUsage: 0,
                        cores: [CPUCore(id: 0, usage: 0)], cpuModel: nil, scope: "WSL")
        }
        monitor.refreshInterval = 10
        defer { monitor.shutdown() }
        monitor.connect("macserver")
        monitor.connect("winserver2055")
        try await waitUntil { monitor.hosts.filter { $0.state == .connected }.count == 2 }
        #expect(monitor.selectedID == "winserver2055")
        monitor.disconnect("winserver2055")
        #expect(monitor.selectedID == "macserver")
        monitor.disconnect("macserver")
        #expect(monitor.selectedHost == nil)
    }

    @Test
    func staleAndDisconnectedSamplesNeverAppearLive() {
        let now = Date()
        var host = CPUHostState(id: "macserver", state: .connected, lastUpdated: now)
        #expect(host.isFresh(at: now, interval: 2))
        #expect(!host.isFresh(at: now.addingTimeInterval(11), interval: 2))
        host.state = .failed
        #expect(!host.isFresh(at: now, interval: 2))
        host.state = .disconnected
        #expect(!host.isFresh(at: now, interval: 2))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("CPU monitor did not reach the expected state within 2 seconds")
    }
}

private actor CPUSampleGate {
    private var requests: [CheckedContinuation<CPUSnapshot, Never>] = []
    var count: Int { requests.count }

    func sample() async -> CPUSnapshot {
        await withCheckedContinuation { requests.append($0) }
    }

    func release(_ index: Int, usage: Double) {
        requests[index].resume(returning: CPUSnapshot(
            hostname: "mac", platform: "macOS", totalUsage: usage,
            cores: [CPUCore(id: 0, usage: usage)], cpuModel: nil, scope: "host"
        ))
    }
}
