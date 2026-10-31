import Foundation
import Testing
@testable import OpenIslandApp

struct NetworkTrafficTests {
    static func section(rx: UInt64 = 1000, tx: UInt64 = 2000) -> String {
        """

        __OPEN_ISLAND_NET_DEV_V1__
        Inter-| Receive | Transmit
         eth0: \(rx) 0 0 0 0 0 0 0 \(tx) 0 0 0 0 0 0 0
         docker0: 999 0 0 0 0 0 0 0 999 0 0 0 0 0 0 0
             lo: 999 0 0 0 0 0 0 0 999 0 0 0 0 0 0 0 0
        __OPEN_ISLAND_NET_ROUTE_V1__
        Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT
        eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0
        docker0 000011AC 00000000 0001 0 0 0 0000FFFF 0 0 0
        __OPEN_ISLAND_NET_ROUTE6_V1__
        00000000000000000000000000000000 00 00000000000000000000000000000000 00 00000000000000000000000000000000 00000000 00000000 00000000 00200200 lo
        __OPEN_ISLAND_NET_END_V1__
        """
    }

    @Test
    func parsesOnlyDefaultRouteInterfacesAndIgnoresEchoAndVirtualBridges() throws {
        let echo = "root@host:~# printf '__OPEN_ISLAND_NET_END_V1__'\r\n"
        let sample = try #require(NetworkTrafficParser.parse(echo + Self.section().replacingOccurrences(of: "\n", with: "\r\n") + "\nroot@host:~# "))
        #expect(sample == [NetworkInterfaceCounters(name: "eth0", received: 1000, transmitted: 2000)])
        #expect(!NetworkTrafficParser.hasCompleteSection(echo))
        #expect(NetworkTrafficParser.hasCompleteSection(echo + Self.section()))
        #expect(NetworkTrafficParser.parse(echo + Self.section().replacingOccurrences(of: NetworkTrafficParser.endMarker, with: "")) == nil)
    }

    @Test
    func supportsIPv6AndDoesNotGuessWhenDefaultRouteIsAbsent() throws {
        let ipv6 = "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000000 00000000 00000003 eth0"
        let noIPv4 = Self.section().replacingOccurrences(of: "eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0", with: "")
        #expect(NetworkTrafficParser.parse(noIPv4) == nil)
        let dual = noIPv4.replacingOccurrences(of: NetworkTrafficParser.endMarker, with: ipv6 + "\n" + NetworkTrafficParser.endMarker)
        #expect(try #require(NetworkTrafficParser.parse(dual)).map(\.name) == ["eth0"])
    }

    @Test
    func truncatedNetworkSectionIsUnavailableInsteadOfPartiallyReported() {
        let huge = Self.section().replacingOccurrences(of: NetworkTrafficParser.routeMarker,
            with: String(repeating: " ", count: 32_769) + "\n" + NetworkTrafficParser.routeMarker)
        #expect(NetworkTrafficParser.parse(huge) == nil)
    }

    @Test
    func optionalNetworkReadsFinishUnderStrictShellSettings() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -e; set -o pipefail; npu-smi() { :; }; " + SSHTransport.sampleCommand]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(NetworkTrafficParser.hasCompleteSection(String(decoding: data, as: UTF8.self)))
    }

    @Test
    func multipleDefaultInterfacesAreReportedSeparately() throws {
        let output = Self.section()
            .replacingOccurrences(of: "__OPEN_ISLAND_NET_ROUTE_V1__", with: "wlan0: 10 0 0 0 0 0 0 0 20 0 0 0 0 0 0 0\n__OPEN_ISLAND_NET_ROUTE_V1__")
            .replacingOccurrences(of: "__OPEN_ISLAND_NET_ROUTE6_V1__", with: "wlan0 00000000 0100000A 0003 0 0 100 00000000 0 0 0\n__OPEN_ISLAND_NET_ROUTE6_V1__")
        #expect(try #require(NetworkTrafficParser.parse(output)).map(\.name) == ["eth0", "wlan0"])
    }

    @Test
    func derivesRatesOnlyFromCompatibleMonotonicCounters() {
        func counter(_ name: String, _ rx: UInt64, _ tx: UInt64) -> NetworkInterfaceCounters {
            NetworkInterfaceCounters(name: name, received: rx, transmitted: tx)
        }
        var tracker = NetworkTrafficTracker()
        #expect(tracker.update([counter("eth0", 100, 200)], at: 10)[0].receivedPerSecond == nil)
        let next = tracker.update([counter("eth0", 500, 300)], at: 12)[0]
        #expect(next.receivedPerSecond == 200)
        #expect(next.transmittedPerSecond == 50)
        #expect(tracker.update([counter("eth0", 500, 300)], at: 14)[0].receivedPerSecond == 0)
        #expect(tracker.update([counter("eth0", 1, 2)], at: 16)[0].receivedPerSecond == nil)
        #expect(tracker.update([counter("eth1", 3, 4)], at: 18)[0].receivedPerSecond == nil)
        #expect(tracker.update(nil, at: 20).isEmpty)
        #expect(tracker.update([counter("eth1", 4, 5)], at: 22)[0].receivedPerSecond == nil)
        tracker.reset()
        #expect(tracker.update([counter("eth1", 5, 6)], at: 24)[0].receivedPerSecond == nil)
    }
}
