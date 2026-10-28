import Foundation
import Combine

enum ConnectionState: Equatable, Sendable {
    case disconnected, connecting, connected, failed
}

@MainActor
final class MonitorStore: ObservableObject {
    static let savedEndpointKey = "npuMonitor.connectionInput"
    @Published var connectionInput = ""
    @Published var password = ""
    @Published var refreshInterval = 2.0
    @Published var snapshot: NPUSnapshot?
    @Published var history: [NPUSnapshot] = []
    @Published var state: ConnectionState = .disconnected
    @Published private(set) var isReconnecting = false
    @Published var isPaused = false
    @Published var isDemo = false
    @Published var errorMessage: String?
    @Published var hostTrustRequest: HostTrustRequest?
    @Published var lastUpdated: Date?
    @Published private(set) var endpointLabel = "尚未连接"
    /// Called after the first complete sample of a user-initiated session.
    /// The owner can persist credentials securely only after successful login.
    var onConnectionEstablished: ((SSHEndpoint, String) -> Void)?
    var onUserDisconnect: (() -> Void)?
    var onPermanentFailure: (() -> Void)?
    private var transport: (any NPUTransport)?
    private let makeTransport: () -> any NPUTransport
    private let reconnectDelay: (Int) -> TimeInterval
    private let defaults: UserDefaults
    private var timer: Timer?
    private var settle: DispatchWorkItem?
    private var sampleStarted: Date?
    private var nextSample = Date.distantPast
    private var buffer = ""
    private var stderrBuffer = ""
    private var generation = UUID()
    private var trustReply: ((Bool) -> Void)?
    private var activeEndpoint: SSHEndpoint?
    private var activeCredential: String?
    private var mayReconnect = false
    private var notifiedEstablished = false
    private var reconnectTask: Task<Void, Never>?
    private var retryCount = 0
    private var unknownFailureCount = 0
    private var timeoutFailureCount = 0

    // Ported from apps/npu-monitor. Ownership belongs to the application, so
    // collapsing or closing the island's presentation never stops sampling.
    init(defaults: UserDefaults = .standard, startsTimer: Bool = true,
         makeTransport: @escaping () -> any NPUTransport = { SSHTransport() },
         reconnectDelay: @escaping (Int) -> TimeInterval = { attempt in
             min(30, pow(2, Double(min(max(attempt - 1, 0), 5))))
         }) {
        self.defaults = defaults
        self.makeTransport = makeTransport
        self.reconnectDelay = reconnectDelay
        if let saved = defaults.string(forKey: Self.savedEndpointKey),
           (try? EndpointParser.parse(saved)) != nil {
            connectionInput = saved
        }
        if startsTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    isolated deinit {
        reconnectTask?.cancel()
        timer?.invalidate()
        settle?.cancel()
        trustReply?(false)
        transport?.stop()
    }

    func connect(retryingKnownEndpoint: Bool = false) {
        let endpoint: SSHEndpoint
        do {
            endpoint = try EndpointParser.parse(connectionInput)
            guard !password.isEmpty else { throw MonitorError.invalidEndpoint("请输入 SSH 密码。") }
        } catch { errorMessage = error.localizedDescription; return }
        let credential = password
        // Persist only an address accepted by EndpointParser, never credentials.
        defaults.set(connectionInput.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.savedEndpointKey)
        stopConnection()
        password = ""
        snapshot = nil; history = []; lastUpdated = nil
        endpointLabel = endpoint.displayName
        errorMessage = nil
        isDemo = false
        isPaused = false
        activeEndpoint = endpoint
        activeCredential = credential
        mayReconnect = retryingKnownEndpoint
        notifiedEstablished = false
        retryCount = 0
        unknownFailureCount = 0
        timeoutFailureCount = 0
        startTransport(isRetry: retryingKnownEndpoint)
    }

    private func startTransport(isRetry: Bool) {
        guard let endpoint = activeEndpoint, let credential = activeCredential else { return }
        state = .connecting
        isReconnecting = isRetry
        sampleStarted = nil
        buffer = ""; stderrBuffer = ""
        let token = generation
        let transport = makeTransport()
        self.transport = transport
        transport.onOutput = { [weak self] text in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.receive(text)
            }
        }
        transport.onErrorOutput = { [weak self] text in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.stderrBuffer = String((self.stderrBuffer + text).suffix(8192))
            }
        }
        transport.onExit = { [weak self] code in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                // stderr and termination callbacks may arrive in either order.
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard self.generation == token else { return }
                let detail = self.stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail.isEmpty ? "SSH 连接已关闭（状态 \(code)），请重新连接。" : detail
                self.handleFailure(message, disposition: Self.sshFailureDisposition(detail))
            }
        }
        transport.onTrust = { [weak self] prompt, reply in
            Task { @MainActor in
                guard let self, self.generation == token else { reply(false); return }
                self.trustReply = reply
                self.hostTrustRequest = HostTrustRequest(prompt: prompt)
            }
        }
        do {
            try transport.start(endpoint: endpoint, password: credential)
        } catch {
            // Local process start or setup errors cannot be repaired by retries.
            handleFailure(error.localizedDescription, disposition: .permanent)
            return
        }
        do { try requestSample() }
        catch { handleFailure(error.localizedDescription, disposition: Self.sshFailureDisposition(error.localizedDescription)) }
    }

    func disconnect() {
        stopConnection()
        onUserDisconnect?()
    }

    /// Application shutdown releases secrets and child processes without
    /// changing the user's choice to resume monitoring on the next launch.
    func shutdown() {
        stopConnection()
    }

    private func stopConnection() {
        let wasDemo = isDemo
        stopTransport()
        activeEndpoint = nil; activeCredential = nil
        mayReconnect = false; notifiedEstablished = false
        retryCount = 0; unknownFailureCount = 0; timeoutFailureCount = 0
        isDemo = false; isPaused = false; isReconnecting = false
        state = .disconnected
        password = ""
        errorMessage = nil
        if wasDemo {
            snapshot = nil; history = []; lastUpdated = nil
            endpointLabel = "尚未连接"
        }
    }

    /// Invalidate callbacks from the old process before closing it. This is
    /// also used while waiting for a retry, retaining only the active secret.
    private func stopTransport() {
        generation = UUID()
        reconnectTask?.cancel(); reconnectTask = nil
        trustReply?(false); trustReply = nil; hostTrustRequest = nil
        settle?.cancel(); settle = nil
        transport?.stop(); transport = nil
        sampleStarted = nil
    }

    func approveHost() {
        trustReply?(true); trustReply = nil; hostTrustRequest = nil
        // Human time spent checking the fingerprint is not a sampling timeout.
        sampleStarted = Date()
    }

    func rejectHost() {
        trustReply?(false); trustReply = nil; hostTrustRequest = nil
        failPermanently("已取消连接：未信任此主机的 SSH 指纹。")
    }

    func togglePause() {
        guard state == .connected else { return }
        isPaused.toggle()
        if !isPaused { nextSample = Date() }
    }

    func refreshNow() {
        guard state == .connected, sampleStarted == nil else { return }
        if isDemo { appendDemo(); return }
        do { try requestSample() }
        catch { handleFailure(error.localizedDescription, disposition: Self.sshFailureDisposition(error.localizedDescription)) }
    }

    private func requestSample() throws {
        buffer = ""
        sampleStarted = Date()
        try transport?.requestSample()
    }

    private func receive(_ text: String) {
        guard sampleStarted != nil else { return }
        buffer += text
        if buffer.utf8.count > 1_048_576 { failPermanently("采集输出超过 1 MB，已停止连接。请检查主机登录输出。"); return }
        settle?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.finishSample()
            }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func finishSample() {
        guard sampleStarted != nil else { return }
        // Wait for the interactive shell prompt before accepting a table. A
        // packet boundary in the middle of a table must never become a sample.
        let plain = buffer.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let hasPrompt = plain.range(of: "[#$%>]\\s*$", options: .regularExpression) != nil
        guard hasPrompt else { return }
        do {
            let sample = try NPUParser.parse(buffer)
            snapshot = sample
            lastUpdated = sample.timestamp
            history.append(sample)
            if history.count > 300 { history.removeFirst(history.count - 300) }
            state = .connected
            isReconnecting = false
            mayReconnect = true
            retryCount = 0; unknownFailureCount = 0; timeoutFailureCount = 0
            errorMessage = nil
            sampleStarted = nil
            nextSample = Date().addingTimeInterval(refreshInterval)
            if !notifiedEstablished, let endpoint = activeEndpoint, let credential = activeCredential {
                notifiedEstablished = true
                onConnectionEstablished?(endpoint, credential)
            }
        } catch {
            // A login banner can end with a prompt just before our queued first
            // command is echoed. Only fail once the command itself is present.
            if plain.contains("npu-smi info") { failPermanently(error.localizedDescription) }
        }
    }

    private func tick() {
        guard state == .connected || state == .connecting else { return }
        if isDemo {
            if !isPaused && Date() >= nextSample { appendDemo() }
            return
        }
        if let sampleStarted {
            if hostTrustRequest == nil && Date().timeIntervalSince(sampleStarted) > 35 {
                handleFailure("35 秒内未收到完整的 npu-smi info 输出。请检查网络、驱动环境及登录 shell；当前支持以 #、$、%、> 结尾的提示符。", disposition: .timeout)
            }
        } else if state == .connected && !isPaused && Date() >= nextSample {
            do { try requestSample() }
            catch { handleFailure(error.localizedDescription, disposition: Self.sshFailureDisposition(error.localizedDescription)) }
        }
    }

    private enum FailureDisposition {
        case transient, timeout, unknown, permanent
    }

    /// Unknown SSH failures have their own small retry budget, so an
    /// unrecognized authentication error cannot cause unlimited logins.
    private static func sshFailureDisposition(_ detail: String) -> FailureDisposition {
        let message = detail.lowercased()
        let terminal = ["permission denied", "authentication failed", "authentication failure",
                        "host key verification failed", "remote host identification has changed",
                        "host key has changed", "no supported authentication", "too many authentication failures",
                        "key exchange failed", "offending ", "password expired"]
        if terminal.contains(where: message.contains) { return .permanent }
        let transient = ["connection reset", "broken pipe", "connection closed", "connection refused",
                         "connection timed out", "operation timed out", "timed out", "connection aborted",
                         "connection lost", "network is unreachable", "network is down", "no route to host",
                         "could not resolve hostname", "temporary failure in name resolution", "host is down",
                         "connection to", "client_loop: send disconnect", "ssh 连接已关闭"]
        return transient.contains(where: message.contains) ? .transient : .unknown
    }

    private func handleFailure(_ message: String, disposition: FailureDisposition) {
        guard mayReconnect, activeEndpoint != nil, activeCredential != nil else {
            failPermanently(message)
            return
        }
        switch disposition {
        case .permanent:
            failPermanently(message); return
        case .unknown:
            unknownFailureCount += 1
            if unknownFailureCount > 3 { failPermanently(message); return }
        case .timeout:
            timeoutFailureCount += 1
            if timeoutFailureCount > 5 { failPermanently(message); return }
        case .transient:
            break
        }

        stopTransport()
        retryCount += 1
        state = .connecting
        isReconnecting = true
        errorMessage = message
        let token = generation
        let delay = max(0, reconnectDelay(retryCount))
        reconnectTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == token, self.isReconnecting else { return }
            self.reconnectTask = nil
            self.startTransport(isRetry: true)
        }
    }

    private func failPermanently(_ message: String) {
        stopConnection()
        state = .failed
        errorMessage = message
        onPermanentFailure?()
    }

    func loadDemo() {
        disconnect()
        isDemo = true
        state = .connected
        endpointLabel = "DEMO · 本地模拟数据"
        history = []
        let now = Date()
        for index in 0..<60 { history.append(Self.demoSnapshot(at: now.addingTimeInterval(Double(index - 59) * 2))) }
        snapshot = history.last
        lastUpdated = snapshot?.timestamp
        nextSample = now.addingTimeInterval(refreshInterval)
    }

    private func appendDemo() {
        let sample = Self.demoSnapshot(at: Date())
        snapshot = sample; lastUpdated = sample.timestamp
        history.append(sample)
        if history.count > 300 { history.removeFirst(history.count - 300) }
        nextSample = Date().addingTimeInterval(refreshInterval)
    }

    static func demoSnapshot(at date: Date) -> NPUSnapshot {
        let t = date.timeIntervalSince1970
        let devices = [0, 1, 2, 3].map { index -> NPUDevice in
            let load = max(0, min(100, 62 + 23 * sin(t / 17 + Double(index)) + 9 * cos(t / 7)))
            return NPUDevice(npuID: index, chipID: 0, name: "910B2", health: "OK", busID: "0000:0\(index + 1):00.0",
                             powerWatts: 100 + load * 1.8, temperatureC: 38 + load * 0.28,
                             utilization: load, memoryUsedMB: 0, memoryTotalMB: 0,
                             hbmUsedMB: 32000 + Double(index) * 2500 + 2000 * sin(t / 30), hbmTotalMB: 65536)
        }
        return NPUSnapshot(timestamp: date, version: "25.2.1 · DEMO", devices: devices,
                           processes: devices.map { NPUProcess(npuID: $0.npuID, chipID: 0, pid: 8000 + $0.npuID, name: "python (示例)", memoryMB: $0.hbmUsedMB) },
                           rawOutput: "示例模式：这些数据在本地生成，未连接远程主机。\n请选择连接并输入 SSH 地址与密码以采集真实数据。")
    }
}
