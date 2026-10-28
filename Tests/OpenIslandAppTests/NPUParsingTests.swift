import Foundation
import Testing
@testable import OpenIslandApp

struct NPUParsingTests {
    @Test
    func parsesHardwareAndProcessTablesFromInteractiveOutput() throws {
        let output = "Welcome\r\n\u{1b}[32m" + Self.fixture.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1b}[0m\r\nroot@node:~# "
        let sample = try NPUParser.parse(output, at: Date(timeIntervalSince1970: 123))
        #expect(sample.version == "25.2.1")
        #expect(sample.devices.map(\.npuID) == [3, 5, 6, 7])
        #expect(sample.devices.first?.busID == "0000:82:00.0")
        #expect(sample.hbmUsedMB == 13625)
        #expect(sample.hbmTotalMB == 262144)
        #expect(sample.averageUtilization == 0)
        #expect(sample.processes.isEmpty)
        #expect(sample.timestamp == Date(timeIntervalSince1970: 123))
    }

    @Test
    func preservesProcessIdentityAcrossChipsAndNamesContainingSpaces() throws {
        let busy = Self.fixture.replacingOccurrences(
            of: "| No running processes found in NPU 3                                                            |",
            with: "| 3       0                 | 4321          | python worker            | 4096                    |\n| 3       1                 | 4321          | python worker            | 8192                    |"
        )
        let processes = try NPUParser.parse(busy).processes
        #expect(processes.count == 2)
        #expect(processes.map(\.id) == ["3:0:4321", "3:1:4321"])
        #expect(processes.allSatisfy { $0.name == "python worker" })
        #expect(processes.map(\.memoryMB) == [4096, 8192])
    }

    @Test
    func rejectsTruncatedOrMalformedSamplesInsteadOfShowingPartialData() {
        let invalid = [
            "npu-smi: error while loading shared libraries: libc_sec.so",
            String(Self.fixture.dropLast(10)),
            Self.fixture.components(separatedBy: "| NPU     Chip")[0],
            Self.fixture.replacingOccurrences(of: "0           0    / 0", with: "120         0    / 0"),
            Self.fixture + "\n| npu-smi 25.2.1 Version: 25.2.1 |\n",
            Self.fixture.replacingOccurrences(of: "| No running processes found in NPU 7                                                            |\n", with: "")
        ]
        for output in invalid {
            #expect(throws: (any Error).self) { try NPUParser.parse(output) }
        }
    }

    @Test
    func missingMetricsRemainUnknownIncludingWholeMachineAggregates() throws {
        let unavailable = Self.fixture.replacingOccurrences(of: "93.9        36", with: "N/A         N/A")
            .replacingOccurrences(of: "0           0    / 0          3406 / 65536", with: "N/A         N/A  / N/A        N/A  / N/A  ")
        let sample = try NPUParser.parse(unavailable)
        #expect(sample.devices[0].utilization == nil)
        #expect(sample.hbmPercent == nil)
        #expect(sample.hbmUsedMB == nil)
        #expect(sample.hbmTotalMB == nil)
        #expect(sample.averageUtilization == nil)
    }

    @Test
    func parsesSafeEndpointFormsAndRejectsCommandsAndOptions() throws {
        #expect(try EndpointParser.parse("ssh -p 40009 root@192.0.2.1") == SSHEndpoint(host: "192.0.2.1", port: 40009, user: "root"))
        #expect(try EndpointParser.parse("alice@node.example:2200") == SSHEndpoint(host: "node.example", port: 2200, user: "alice"))
        #expect(try EndpointParser.parse("alice@[2001:db8::1]:2222").host == "2001:db8::1")
        for input in ["", "ssh", "ssh -o ProxyCommand=touch root@host", "ssh -p 0 host", "ssh -p 22 host:23", "ssh root@host npu-smi info", "root@host;touch", "$(touch)", "-oProxyCommand=evil", "root@999.1.1.1", "root@[oops]:22", "a@b@host"] {
            #expect(throws: (any Error).self) { try EndpointParser.parse(input) }
        }
    }

    static let fixture = """
    npu-smi info
    +------------------------------------------------------------------------------------------------+
    | npu-smi 25.2.1                   Version: 25.2.1                                               |
    +---------------------------+---------------+----------------------------------------------------+
    | NPU   Name                | Health        | Power(W)    Temp(C)           Hugepages-Usage(page)|
    | Chip                      | Bus-Id        | AICore(%)   Memory-Usage(MB)  HBM-Usage(MB)        |
    +===========================+===============+====================================================+
    | 3     910B2               | OK            | 93.9        36                0    / 0             |
    | 0                         | 0000:82:00.0  | 0           0    / 0          3406 / 65536         |
    +===========================+===============+====================================================+
    | 5     910B2               | OK            | 105.4       43                0    / 0             |
    | 0                         | 0000:02:00.0  | 0           0    / 0          3406 / 65536         |
    +===========================+===============+====================================================+
    | 6     910B2               | OK            | 95.3        40                0    / 0             |
    | 0                         | 0000:41:00.0  | 0           0    / 0          3407 / 65536         |
    +===========================+===============+====================================================+
    | 7     910B2               | OK            | 90.7        41                0    / 0             |
    | 0                         | 0000:42:00.0  | 0           0    / 0          3406 / 65536         |
    +===========================+===============+====================================================+
    +---------------------------+---------------+----------------------------------------------------+
    | NPU     Chip              | Process id    | Process name             | Process memory(MB)      |
    +===========================+===============+====================================================+
    | No running processes found in NPU 3                                                            |
    +===========================+===============+====================================================+
    | No running processes found in NPU 5                                                            |
    +===========================+===============+====================================================+
    | No running processes found in NPU 6                                                            |
    +===========================+===============+====================================================+
    | No running processes found in NPU 7                                                            |
    +===========================+===============+====================================================+
    """
}

struct NPUAggregationTests {
    @Test
    func hbmUsesCombinedCapacityWhileCoreUsesChipMean() {
        let sample = snapshot([
            device(id: 0, used: 50, total: 100, core: 0),
            device(id: 1, used: 150, total: 300, core: 100)
        ])
        #expect(sample.hbmPercent == 50)
        #expect(sample.averageUtilization == 50)
        let uneven = snapshot([
            device(id: 0, used: 100, total: 100, core: 10),
            device(id: 1, used: 0, total: 300, core: 50)
        ])
        #expect(uneven.hbmPercent == 25)
        #expect(uneven.averageUtilization == 30)
    }

    @Test
    func hbmNeverFallsBackToOrdinaryMemoryOrIgnoresAMissingChip() {
        var noHBM = device(id: 0, used: nil, total: nil, core: 0)
        noHBM.memoryUsedMB = 64
        noHBM.memoryTotalMB = 128
        #expect(noHBM.memoryPercent == 50)
        #expect(noHBM.hbmPercent == nil)
        #expect(snapshot([noHBM]).hbmPercent == nil)
        #expect(snapshot([device(id: 1, used: 50, total: 100, core: 0), noHBM]).hbmPercent == nil)
        #expect(snapshot([]).hbmPercent == nil)
        #expect(snapshot([]).averageUtilization == nil)
    }

    @Test
    func zeroCapacityAndInvalidMemoryAreUnknownButIdleIsZero() {
        for (used, total) in [(0.0, 0.0), (-1, 100), (101, 100), (.nan, 100), (1, .infinity)] {
            #expect(snapshot([device(id: 0, used: used, total: total, core: 0)]).hbmPercent == nil)
        }
        #expect(snapshot([device(id: 0, used: 0, total: 100, core: 0)]).hbmPercent == 0)
    }

    private func device(id: Int, used: Double?, total: Double?, core: Double?) -> NPUDevice {
        NPUDevice(npuID: id, chipID: 0, name: "910B2", health: "OK", busID: "", powerWatts: nil,
                  temperatureC: nil, utilization: core, memoryUsedMB: nil, memoryTotalMB: nil,
                  hbmUsedMB: used, hbmTotalMB: total)
    }

    private func snapshot(_ devices: [NPUDevice]) -> NPUSnapshot {
        NPUSnapshot(timestamp: .now, version: "test", devices: devices, processes: [], rawOutput: "")
    }
}
