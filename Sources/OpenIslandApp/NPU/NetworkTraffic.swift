import Foundation

struct NetworkInterfaceCounters: Equatable {
    let name: String
    let received: UInt64
    let transmitted: UInt64
}

struct NetworkInterfaceRate: Identifiable, Equatable {
    let name: String
    let receivedPerSecond: Double?
    let transmittedPerSecond: Double?
    var id: String { name }
}

/// Linux default-route interfaces are reported separately, never summed with
/// their underlying devices or container bridges.
enum NetworkTrafficParser {
    static let devMarker = "__OPEN_ISLAND_NET_DEV_V1__"
    static let routeMarker = "__OPEN_ISLAND_NET_ROUTE_V1__"
    static let route6Marker = "__OPEN_ISLAND_NET_ROUTE6_V1__"
    static let endMarker = "__OPEN_ISLAND_NET_END_V1__"

    static func hasCompleteSection(_ output: String) -> Bool {
        cleanLines(output).contains { $0.trimmingCharacters(in: .whitespaces) == endMarker }
    }

    static func parse(_ output: String) -> [NetworkInterfaceCounters]? {
        let lines = cleanLines(output)
        guard let start = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == devMarker }),
              let route = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == routeMarker }),
              let route6 = lines[(route + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == route6Marker }),
              let end = lines[(route6 + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker }) else { return nil }
        // The remote command caps each file at 32 KiB plus one sentinel byte.
        // Reject truncated data rather than silently missing an interface.
        for section in [lines[(start + 1)..<route], lines[(route + 1)..<route6], lines[(route6 + 1)..<end]] {
            guard section.joined(separator: "\n").utf8.count <= 32_768 else { return nil }
        }

        var interfaces = Set<String>()
        for line in lines[(route + 1)..<route6] {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 8, fields[1] == "00000000", fields[7] == "00000000",
                  let flags = UInt64(fields[3], radix: 16), flags & 1 != 0, flags & 0x200 == 0 else { continue }
            interfaces.insert(String(fields[0]))
        }
        for line in lines[(route6 + 1)..<end] {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 10, fields[0] == String(repeating: "0", count: 32), fields[1] == "00",
                  let flags = UInt64(fields[8], radix: 16), flags & 1 != 0, flags & 0x200 == 0 else { continue }
            interfaces.insert(String(fields[9]))
        }
        interfaces.remove("lo")
        guard !interfaces.isEmpty else { return nil }
        var counters: [String: NetworkInterfaceCounters] = [:]
        for line in lines[(start + 1)..<route] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard interfaces.contains(name) else { continue }
            let fields = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace)
            guard fields.count >= 16, let received = UInt64(fields[0]), let transmitted = UInt64(fields[8]),
                  counters[name] == nil else { return nil }
            counters[name] = NetworkInterfaceCounters(name: name, received: received, transmitted: transmitted)
        }
        guard counters.count == interfaces.count else { return nil }
        return counters.values.sorted { $0.name < $1.name }
    }

    private static func cleanLines(_ output: String) -> [String] {
        output.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
    }
}

struct NetworkTrafficTracker {
    private var previous: [String: NetworkInterfaceCounters] = [:]
    private var previousTime: TimeInterval?

    mutating func reset() {
        previous = [:]
        previousTime = nil
    }

    mutating func update(_ counters: [NetworkInterfaceCounters]?, at time: TimeInterval) -> [NetworkInterfaceRate] {
        guard let counters, !counters.isEmpty, time.isFinite else { reset(); return [] }
        let interval = previousTime.map { time - $0 }
        let rates = counters.map { current in
            guard let old = previous[current.name], let interval, interval > 0,
                  current.received >= old.received, current.transmitted >= old.transmitted else {
                return NetworkInterfaceRate(name: current.name, receivedPerSecond: nil, transmittedPerSecond: nil)
            }
            return NetworkInterfaceRate(name: current.name,
                                        receivedPerSecond: Double(current.received - old.received) / interval,
                                        transmittedPerSecond: Double(current.transmitted - old.transmitted) / interval)
        }
        previous = Dictionary(uniqueKeysWithValues: counters.map { ($0.name, $0) })
        previousTime = time
        return rates
    }
}
