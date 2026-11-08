import Foundation
import Testing
@testable import OpenIslandApp

struct FanSampleTests {
    @Test
    func macMaximumProducesPerFanPercentageAndColor() throws {
        let sample = try FanSnapshot.decode(Data(#"{"fans":[{"id":"0","name":"Fan1","rpm":3168,"maximumRPM":6336},{"id":"1","name":"Fan2","rpm":0,"maximumRPM":6864}]}"#.utf8))
        #expect(sample.fans[0].percentage == 50)
        #expect(sample.fans[0].speedBand == 1)
        #expect(sample.fans[1].percentage == 0)
        #expect(sample.fans[1].speedBand == 0)
    }

    @Test
    func windowsScaleAndUnavailableStateDoNotBecomeFalseZeroOrMaximum() throws {
        let csv = """
        Node,BaseUnits,CurrentReading,CurrentState,DeviceID,MaxReadable,Name,RateUnits,SensorType,UnitModifier
        HOST,19,15600,OK,56.0.32,306000,"Fan1, system board",0,5,-1
        HOST,19,0,N/A,57.0.32,306000,Fan2,0,5,-1
        """.replacingOccurrences(of: "\n", with: "\r\r\n")
        for encoding: String.Encoding in [.utf8, .utf16LittleEndian] {
            let sample = try FanSnapshot.decodeWindows(#require(csv.data(using: encoding)))
            #expect(sample.fans[0].rpm == 1560)
            #expect(sample.fans[0].name == "Fan1, system board")
            #expect(sample.fans[0].maximumRPM == nil)
            #expect(sample.fans[0].percentage == nil)
            #expect(sample.fans[0].speedBand == 0)
            #expect(sample.fans[1].rpm == nil)
            #expect(sample.fans[1].speedBand == nil)
        }
    }

    @Test(arguments: [
        "HOST,19,15600,OK,1,Fan1,0,5,-99",
        "HOST,19,15600,OK,1,Fan1,4,5,-1",
        "HOST,65,15600,OK,1,Fan1,0,5,-1",
        "HOST,19,,OK,1,Fan1,0,5,-1",
        "HOST,19,-1,OK,1,Fan1,0,5,0",
        "HOST,19,inf,OK,1,Fan1,0,5,-1"
    ])
    func invalidWindowsUnitsAndValuesAreRejected(_ row: String) {
        let header = "Node,BaseUnits,CurrentReading,CurrentState,DeviceID,Name,RateUnits,SensorType,UnitModifier\n"
        #expect(throws: (any Error).self) { try FanSnapshot.decodeWindows(Data((header + row).utf8)) }
    }

    @Test(arguments: [
        #"{"fans":[{"id":"0","name":"Fan1","rpm":-1}]}"#,
        #"{"fans":[{"id":"0","name":"Fan1","rpm":2000,"maximumRPM":0}]}"#,
        #"{"fans":[{"id":"0","name":"Fan1","rpm":2000},{"id":"0","name":"Fan2","rpm":3000}]}"#
    ])
    func malformedMacReadingsAreRejected(_ json: String) {
        #expect(throws: (any Error).self) { try FanSnapshot.decode(Data(json.utf8)) }
    }

    @Test
    func fanFreshnessIsIndependentOfCpuFailureButRejectsFailedAndExpiredFanReads() {
        let now = Date()
        var host = CPUHostState(id: "macserver", state: .failed, fansUpdated: now)
        #expect(host.fansAreFresh(at: now))
        #expect(!host.fansAreFresh(at: now.addingTimeInterval(21)))
        host.fanError = "sensor timeout"
        #expect(!host.fansAreFresh(at: now))
        host.fanError = nil
        host.state = .disconnected
        #expect(!host.fansAreFresh(at: now))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_FAN_SSH"] == "1"))
    func configuredHostsReturnRealHostFanReadings() async throws {
        let mac = try await FanCollector.sample(alias: "macserver")
        #expect(mac.fans.count == 2)
        #expect(mac.fans.allSatisfy { $0.rpm != nil && $0.maximumRPM != nil && $0.percentage != nil })
        let dell = try await FanCollector.sample(alias: "winserver2055")
        #expect(dell.fans.first(where: { $0.id == "56.0.32" })?.rpm != nil)
        #expect(dell.fans.allSatisfy { $0.maximumRPM == nil })
        #expect(!FanCollector.supports("winserver"))
    }
}

@MainActor
struct FanMonitorStoreTests {
    @Test
    func blockedFanReadDoesNotBlockCpuAndOldReadCannotOverwriteReconnect() async throws {
        let gate = FanSampleGate()
        let monitor = CPUMonitorStore(sampler: { alias in
            CPUSnapshot(hostname: alias, platform: "macOS", totalUsage: 1,
                        cores: [CPUCore(id: 0, usage: 1)], cpuModel: nil, scope: "host")
        }, fanSampler: { _ in await gate.sample() })
        defer { monitor.shutdown() }
        monitor.connect("macserver")
        try await waitUntil {
            let count = await gate.count
            return monitor.selectedHost?.state == .connected && count == 1
        }
        #expect(monitor.selectedHost?.fanSnapshot == nil)
        monitor.disconnect("macserver")
        monitor.connect("macserver")
        try await waitUntil { await gate.count == 2 }
        await gate.release(0, rpm: 1000)
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.selectedHost?.fanSnapshot == nil)
        await gate.release(1, rpm: 2000)
        try await waitUntil { monitor.selectedHost?.fanSnapshot?.fans.first?.rpm == 2000 }
        #expect(monitor.selectedHost?.fansUpdated != nil)
        monitor.disconnect("macserver")
        #expect(monitor.hosts[0].fanSnapshot == nil)
        #expect(monitor.hosts[0].fansUpdated == nil)
    }

    @Test
    func fanFailureDoesNotFailCpuConnection() async throws {
        let monitor = CPUMonitorStore(sampler: { alias in
            CPUSnapshot(hostname: alias, platform: "WSL", totalUsage: 2,
                        cores: [CPUCore(id: 0, usage: 2)], cpuModel: nil, scope: "WSL")
        }, fanSampler: { _ in throw FanCollectionError.invalidSample })
        defer { monitor.shutdown() }
        monitor.connect("winserver2055")
        try await waitUntil { monitor.selectedHost?.state == .connected && monitor.selectedHost?.fanError != nil }
        #expect(monitor.selectedHost?.errorMessage == nil)
        #expect(monitor.selectedHost?.snapshot?.totalUsage == 2)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Fan monitor did not reach the expected state within 2 seconds")
    }
}

private actor FanSampleGate {
    private var requests: [CheckedContinuation<FanSnapshot, Never>] = []
    var count: Int { requests.count }
    func sample() async -> FanSnapshot {
        await withCheckedContinuation { requests.append($0) }
    }
    func release(_ index: Int, rpm: Double) {
        requests[index].resume(returning: FanSnapshot(fans: [FanReading(id: "0", name: "Fan1", rpm: rpm, maximumRPM: 6000)]))
    }
}
