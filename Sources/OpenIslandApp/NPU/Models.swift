import Foundation

// Ported from the workspace's apps/npu-monitor (NPU Observatory). The sampling
// model stays independent of its dashboard; island HBM totals never use Memory.
struct NPUDevice: Identifiable, Equatable, Sendable {
    var npuID: Int
    var chipID: Int
    var name: String
    var health: String
    var busID: String
    var powerWatts: Double?
    var temperatureC: Double?
    var utilization: Double?
    var memoryUsedMB: Double?
    var memoryTotalMB: Double?
    var hbmUsedMB: Double?
    var hbmTotalMB: Double?
    var id: String { "\(npuID):\(chipID)" }
    var displayMemoryUsedMB: Double? {
        if (hbmTotalMB ?? 0) > 0 { return hbmUsedMB }
        return (memoryTotalMB ?? 0) > 0 ? memoryUsedMB : nil
    }
    var displayMemoryTotalMB: Double? {
        if (hbmTotalMB ?? 0) > 0 { return hbmTotalMB }
        return (memoryTotalMB ?? 0) > 0 ? memoryTotalMB : nil
    }
    var memoryPercent: Double? {
        guard let used = displayMemoryUsedMB, let total = displayMemoryTotalMB, total > 0 else { return nil }
        return used / total * 100
    }
    var hbmPercent: Double? {
        guard let used = hbmUsedMB, let total = hbmTotalMB,
              used.isFinite, total.isFinite, used >= 0, total > 0, used <= total else { return nil }
        return used / total * 100
    }
    var isHealthy: Bool { ["OK", "NORMAL"].contains(health.uppercased()) }
}

struct NPUProcess: Identifiable, Equatable, Sendable {
    var npuID: Int
    var chipID: Int
    var pid: Int
    var name: String
    var memoryMB: Double?
    var id: String { "\(npuID):\(chipID):\(pid)" }
}

struct NPUSnapshot: Identifiable, Equatable, Sendable {
    var timestamp: Date
    var version: String
    var devices: [NPUDevice]
    var processes: [NPUProcess]
    var rawOutput: String
    var id: Date { timestamp }
    var averageUtilization: Double? { average(devices.map(\.utilization)) }
    var averageTemperature: Double? { average(devices.map(\.temperatureC)) }
    var totalPower: Double? { total(devices.map(\.powerWatts)) }
    var memoryUsedMB: Double? { total(devices.map(\.displayMemoryUsedMB)) }
    var memoryTotalMB: Double? { total(devices.map(\.displayMemoryTotalMB)) }
    var hbmUsedMB: Double? { total(devices.map(\.hbmUsedMB)) }
    var hbmTotalMB: Double? { total(devices.map(\.hbmTotalMB)) }
    /// Capacity-weighted HBM occupation across every chip, with no Memory fallback.
    var hbmPercent: Double? {
        guard !devices.isEmpty, devices.allSatisfy({ $0.hbmPercent != nil }),
              let used = hbmUsedMB, let capacity = hbmTotalMB, capacity > 0 else { return nil }
        return used / capacity * 100
    }
    private func average(_ values: [Double?]) -> Double? {
        guard let sum = total(values) else { return nil }
        return sum / Double(values.count)
    }
    private func total(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        let sum = values.compactMap { $0 }.reduce(0, +)
        return sum.isFinite ? sum : nil
    }
}

struct SSHEndpoint: Equatable, Sendable {
    let host: String
    let port: Int
    let user: String
    var displayName: String { "\(user)@\(host):\(port)" }
}

enum MonitorError: LocalizedError {
    case invalidEndpoint(String)
    case invalidOutput(String)
    case transport(String)
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let message), .invalidOutput(let message), .transport(let message): return message
        }
    }
}

struct HostTrustRequest: Identifiable, Sendable {
    let id = UUID()
    let prompt: String
}
