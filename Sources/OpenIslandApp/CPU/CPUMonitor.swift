import Combine
import Foundation

struct CPUCore: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let usage: Double
}

struct CPUSnapshot: Decodable, Equatable, Sendable {
    let hostname: String
    let platform: String
    let totalUsage: Double
    var cores: [CPUCore]
    let cpuModel: String?
    let scope: String?

    static func decode(_ data: Data) throws -> Self {
        var sample = try JSONDecoder().decode(Self.self, from: data)
        guard !sample.hostname.isEmpty, !sample.platform.isEmpty,
              sample.totalUsage.isFinite, (0...100).contains(sample.totalUsage),
              !sample.cores.isEmpty, sample.cores.count <= 4_096,
              Set(sample.cores.map(\.id)).count == sample.cores.count,
              sample.cores.allSatisfy({ $0.id >= 0 && $0.usage.isFinite && (0...100).contains($0.usage) }) else {
            throw CPUCollectionError.invalidSample
        }
        sample.cores.sort { $0.id < $1.id }
        return sample
    }
}

enum CPUCollectionError: LocalizedError {
    case invalidSample, missingCollector
    case connection(String)

    var errorDescription: String? {
        let lang = LanguageManager.shared
        switch self {
        case .invalidSample: return lang.t("cpu.error.sample")
        case .missingCollector: return lang.t("cpu.error.collector")
        case .connection(let detail): return detail
        }
    }
}

enum CPUCollector {
    static let aliases = ["macserver", "winserver", "winserver2055"]

    static func arguments(for alias: String, command: String = "python3 -") -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no",
         "-o", "KbdInteractiveAuthentication=no", "-o", "ConnectTimeout=8",
         "-o", "ConnectionAttempts=1", "-o", "StrictHostKeyChecking=yes",
         "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
         "--", alias, command]
    }

    static func sample(alias: String) async throws -> CPUSnapshot {
        guard aliases.contains(alias) else { throw CPUCollectionError.invalidSample }
        guard let script = Bundle.appResources.url(forResource: "cpu-sample", withExtension: "py") else {
            throw CPUCollectionError.missingCollector
        }
        do {
            let data = try await RemoteUsageCommand.run(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments(for: alias),
                input: Data(contentsOf: script), timeout: 20, maximumOutputBytes: 512 * 1_024
            )
            return try CPUSnapshot.decode(data)
        } catch let error as CodexRemoteUsageSyncError {
            switch error {
            case .cancelled: throw CancellationError()
            case .timedOut: throw CPUCollectionError.connection(LanguageManager.shared.t("cpu.error.timeout"))
            case .commandFailed(_, let detail):
                throw CPUCollectionError.connection(detail.trimmingCharacters(in: .whitespacesAndNewlines))
            default: throw CPUCollectionError.invalidSample
            }
        }
    }
}

struct CPUHostState: Identifiable, Sendable {
    let id: String
    var state: ConnectionState = .disconnected
    var snapshot: CPUSnapshot?
    var lastUpdated: Date?
    var errorMessage: String?
    var history: [Double] = []
    var isRetrying = false
    var fanSnapshot: FanSnapshot?
    var fansUpdated: Date?
    var fanError: String?

    func fansAreFresh(at date: Date) -> Bool {
        guard state != .disconnected, fanError == nil, let fansUpdated else { return false }
        return date.timeIntervalSince(fansUpdated) <= 20
    }

    func isFresh(at date: Date, interval: Double) -> Bool {
        guard state == .connected, let lastUpdated else { return false }
        return date.timeIntervalSince(lastUpdated) <= max(10, interval * 3 + 2)
    }
}

/// Each selected server owns an independent polling task. Closing the
/// selection window leaves all selected servers sampling on the island.
@MainActor
final class CPUMonitorStore: ObservableObject {
    typealias Sampler = @Sendable (String) async throws -> CPUSnapshot
    typealias FanSampler = @Sendable (String) async throws -> FanSnapshot
    static let savedAliasesKey = "cpuMonitor.enabledAliases"
    static let savedIntervalKey = "cpuMonitor.refreshInterval"
    static let supportedIntervals: [Double] = [1, 2, 3, 5, 10]
    @Published private(set) var hosts = CPUCollector.aliases.map { CPUHostState(id: $0) }
    @Published private(set) var selectedID: String?
    @Published var refreshInterval: Double = 2 {
        didSet {
            if Self.supportedIntervals.contains(refreshInterval) {
                defaults?.set(refreshInterval, forKey: Self.savedIntervalKey)
            }
        }
    }

    private let sampler: Sampler
    private let fanSampler: FanSampler?
    private let defaults: UserDefaults?
    private var enabledAliases: Set<String>
    private var tasks: [String: Task<Void, Never>] = [:]
    private var fanTasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]

    init(defaults: UserDefaults? = nil,
         sampler: @escaping Sampler = { try await CPUCollector.sample(alias: $0) },
         fanSampler: FanSampler? = nil) {
        self.defaults = defaults
        self.sampler = sampler
        self.fanSampler = fanSampler
        enabledAliases = Set(defaults?.stringArray(forKey: Self.savedAliasesKey) ?? [])
            .intersection(CPUCollector.aliases)
        if let interval = defaults?.double(forKey: Self.savedIntervalKey),
           Self.supportedIntervals.contains(interval) {
            refreshInterval = interval
        }
    }

    var selectedHost: CPUHostState? { hosts.first { $0.id == selectedID } }
    var monitoredHosts: [CPUHostState] { hosts.filter { $0.state != .disconnected } }

    /// Called for normal app startup, never by previews or the UI harness.
    func resumeSavedConnections() {
        for alias in CPUCollector.aliases where enabledAliases.contains(alias) {
            connect(alias)
        }
    }

    func toggle(_ alias: String) {
        if hosts.first(where: { $0.id == alias })?.state == .disconnected {
            connect(alias)
        } else {
            disconnect(alias)
        }
    }

    func connect(_ alias: String) {
        guard let index = hosts.firstIndex(where: { $0.id == alias }) else { return }
        enabledAliases.insert(alias)
        saveSelection()
        selectedID = alias
        guard tasks[alias] == nil else { return }
        hosts[index].state = .connecting
        hosts[index].errorMessage = nil
        hosts[index].isRetrying = false
        let generation = UUID()
        generations[alias] = generation
        startFans(alias, index: index, generation: generation)
        let sampler = sampler
        tasks[alias] = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let started = Date()
                do {
                    let snapshot = try await sampler(alias)
                    guard !Task.isCancelled, let self, self.generations[alias] == generation else { return }
                    self.hosts[index].snapshot = snapshot
                    self.hosts[index].lastUpdated = Date()
                    self.hosts[index].state = .connected
                    self.hosts[index].errorMessage = nil
                    self.hosts[index].isRetrying = false
                    self.hosts[index].history.append(snapshot.totalUsage)
                    if self.hosts[index].history.count > 60 { self.hosts[index].history.removeFirst() }
                    failures = 0
                } catch {
                    guard !Task.isCancelled, let self, self.generations[alias] == generation else { return }
                    let message = error.localizedDescription
                    let lower = message.lowercased()
                    let terminal = ["permission denied", "host key verification failed", "identification has changed",
                                    "authentication failed", "too many authentication failures", "not found", "no such file"]
                    let retry = error is CPUCollectionError && {
                        if case CPUCollectionError.connection = error { return true }
                        return false
                    }() && !terminal.contains(where: lower.contains)
                    self.hosts[index].state = .failed
                    self.hosts[index].errorMessage = message
                    self.hosts[index].isRetrying = retry
                    if !retry { self.tasks[alias] = nil; return }
                    failures += 1
                }
                guard let self else { return }
                let delay = failures == 0
                    ? max(0.2, self.refreshInterval - Date().timeIntervalSince(started))
                    : min(30, Double(1 << min(failures, 5)))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    func disconnect(_ alias: String) {
        enabledAliases.remove(alias)
        saveSelection()
        stopConnection(alias)
    }

    // Fan sensor access can be slower or unavailable while WSL is healthy.
    // Keep its SSH deadline, retry loop and freshness independent of CPU data.
    private func startFans(_ alias: String, index: Int, generation: UUID) {
        fanTasks.removeValue(forKey: alias)?.cancel()
        guard let fanSampler, FanCollector.supports(alias) else { return }
        fanTasks[alias] = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let started = Date()
                do {
                    let sample = try await fanSampler(alias)
                    guard !Task.isCancelled, let self, self.generations[alias] == generation else { return }
                    self.hosts[index].fanSnapshot = sample
                    self.hosts[index].fansUpdated = Date()
                    self.hosts[index].fanError = nil
                    failures = 0
                } catch {
                    guard !Task.isCancelled, let self, self.generations[alias] == generation else { return }
                    self.hosts[index].fanError = error.localizedDescription
                    failures += 1
                }
                let delay = failures == 0 ? max(0.2, 5 - Date().timeIntervalSince(started))
                    : min(60, Double(5 * (1 << min(failures, 4))))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private func saveSelection() {
        defaults?.set(CPUCollector.aliases.filter { enabledAliases.contains($0) }, forKey: Self.savedAliasesKey)
    }

    private func stopConnection(_ alias: String) {
        generations[alias] = nil
        tasks.removeValue(forKey: alias)?.cancel()
        fanTasks.removeValue(forKey: alias)?.cancel()
        if let index = hosts.firstIndex(where: { $0.id == alias }) {
            hosts[index].state = .disconnected
            hosts[index].errorMessage = nil
            hosts[index].isRetrying = false
            hosts[index].fanSnapshot = nil
            hosts[index].fansUpdated = nil
            hosts[index].fanError = nil
        }
        if selectedID == alias {
            selectedID = hosts.first { $0.state != .disconnected }?.id
        }
    }

    func shutdown() {
        // Quitting stops processes without changing which servers the user
        // wants to monitor on the next launch.
        for alias in CPUCollector.aliases { stopConnection(alias) }
    }
}

enum CPUGridLayout {
    static let columns = 8
    static let tileHeight: CGFloat = 26
    static let gap: CGFloat = 4
    static let maximumVisibleRows = 7

    static func rows(for count: Int) -> Int { (max(0, count) + columns - 1) / columns }
    static func gridHeight(for count: Int) -> CGFloat {
        let rows = min(maximumVisibleRows, rows(for: count))
        return CGFloat(rows) * tileHeight + CGFloat(max(0, rows - 1)) * gap
    }

    @MainActor
    static func panelHeight(for host: CPUHostState) -> CGFloat {
        guard let sample = host.snapshot else { return 76 }
        return 54 + gridHeight(for: sample.cores.count)
    }

    @MainActor
    static func panelHeight(for monitor: CPUMonitorStore) -> CGFloat {
        let hosts = monitor.monitoredHosts
        return hosts.reduce(0) { $0 + panelHeight(for: $1) } + CGFloat(max(0, hosts.count - 1)) * 8
    }

}
