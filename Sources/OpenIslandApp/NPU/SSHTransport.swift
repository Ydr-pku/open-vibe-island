import Foundation
import Darwin

// Ported from apps/npu-monitor. The executable must dispatch
// NPU_MONITOR_ASKPASS_SOCKET to AskPassBroker.runHelper before starting the app.

/// A local-only askpass channel. Secrets travel through a user-only Unix socket,
/// never through command arguments, environment variables, or a temporary file.
final class AskPassBroker: @unchecked Sendable {
    private var listener: Int32 = -1
    private var activeClient: Int32 = -1
    private let queue = DispatchQueue(label: "npu-monitor.askpass")
    private let lock = NSLock()
    private var stopped = false
    let path = "/tmp/npum-\(UUID().uuidString).sock"
    private let promptHandler: (String, @escaping (String?) -> Void) -> Void

    init(promptHandler: @escaping (String, @escaping (String?) -> Void) -> Void) throws {
        self.promptHandler = promptHandler
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw MonitorError.transport("无法创建本地认证通道。") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, S_IRUSR | S_IWUSR) == 0, listen(listener, 4) == 0 else {
            close(listener)
            unlink(path)
            throw MonitorError.transport("无法启动本地认证通道。")
        }
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        while true {
            lock.lock()
            let done = stopped
            let fd = listener
            lock.unlock()
            if done { return }
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            lock.lock()
            if stopped { lock.unlock(); close(client); return }
            activeClient = client
            lock.unlock()
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        // The serving queue owns close(); stop() only shuts down this descriptor.
        // Keeping both transitions under the lock avoids closing a reused fd.
        defer {
            lock.lock()
            activeClient = -1
            close(client)
            lock.unlock()
        }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // Only another process belonging to this login may request a secret.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 32768 {
            let count = read(client, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        lock.lock(); let initiallyCancelled = stopped; lock.unlock()
        guard !initiallyCancelled else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var response: String?
        promptHandler(String(decoding: data, as: UTF8.self)) { answer in
            response = answer
            semaphore.signal()
        }
        // Wake periodically so disconnecting also cancels a pending trust dialog.
        while semaphore.wait(timeout: .now() + 0.2) == .timedOut {
            lock.lock(); let cancelled = stopped; lock.unlock()
            if cancelled { break }
        }
        lock.lock(); let cancelled = stopped; lock.unlock()
        if !cancelled, let response {
            let bytes = Array(response.utf8)
            _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        }
    }

    func stop() {
        lock.lock()
        if !stopped {
            stopped = true
            shutdown(listener, SHUT_RDWR)
            close(listener)
            listener = -1
            // A helper may connect and then never finish its request. Closing
            // the listener alone cannot wake a read on that accepted socket.
            if activeClient >= 0 { shutdown(activeClient, SHUT_RDWR) }
            unlink(path)
        }
        lock.unlock()
    }

    deinit { stop() }

    static func runHelper(socketPath: String, prompt: String) -> Int32 {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { return 1 }
        defer { close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return 1 }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { return 1 }
        let request = Array(prompt.utf8)
        guard request.withUnsafeBytes({ write(client, $0.baseAddress, $0.count) }) == request.count else { return 1 }
        shutdown(client, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 32768 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(contentsOf: buffer.prefix(count))
        }
        guard !response.isEmpty else { return 1 }
        response.append(10)
        FileHandle.standardOutput.write(response)
        return 0
    }
}

/// Owns exactly one local ssh process. The only bytes ever sent as a remote
/// shell command are the literal sampleCommand below.
protocol NPUTransport: AnyObject {
    var requiresNetworkSection: Bool { get }
    var onOutput: ((String) -> Void)? { get set }
    var onErrorOutput: ((String) -> Void)? { get set }
    /// Delivered only after stderr reaches EOF so the exit status and complete
    /// diagnostic are classified together, even if OS callbacks race.
    var onExit: ((Int32, String) -> Void)? { get set }
    var onTrust: ((String, @escaping (Bool) -> Void) -> Void)? { get set }
    func start(endpoint: SSHEndpoint, password: String) throws
    func requestSample() throws
    func stop()
}

extension NPUTransport {
    var requiresNetworkSection: Bool { false }
}

// Lifecycle and handler installation are serialized by MonitorStore's main actor;
// Foundation's I/O callbacks use stateLock for the cancellation/credential state.
final class SSHTransport: NPUTransport, @unchecked Sendable {
    static let sampleCommand = "npu-smi info; printf '\\n__OPEN_ISLAND_NET_DEV_V1__\\n'; cat /proc/net/dev 2>/dev/null | head -c 32769 2>/dev/null || :; printf '\\n__OPEN_ISLAND_NET_ROUTE_V1__\\n'; cat /proc/net/route 2>/dev/null | head -c 32769 2>/dev/null || :; printf '\\n__OPEN_ISLAND_NET_ROUTE6_V1__\\n'; cat /proc/net/ipv6_route 2>/dev/null | head -c 32769 2>/dev/null || :; printf '\\n__OPEN_ISLAND_NET_END_V1__\\n'\n"
    var requiresNetworkSection: Bool { true }
    static func isPasswordPrompt(_ prompt: String) -> Bool {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "password:" || normalized.range(of: "^[^\\r\\n]+'s password:$", options: .regularExpression) != nil
    }
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var broker: AskPassBroker?
    private var stopped = false
    private var secret: String?
    private let stateLock = NSLock()
    var onOutput: ((String) -> Void)?
    var onErrorOutput: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    var onTrust: ((String, @escaping (Bool) -> Void) -> Void)?

    static func knownHostsURL() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenIsland/NPU", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("known_hosts")
    }

    func start(endpoint: SSHEndpoint, password: String) throws {
        try start(endpoint: endpoint, password: password, knownHosts: nil)
    }

    func start(endpoint: SSHEndpoint, password: String, knownHosts: URL?) throws {
        stateLock.lock()
        stopped = false
        secret = password
        stateLock.unlock()
        let hosts = try knownHosts ?? Self.knownHostsURL()
        let broker = try AskPassBroker { [weak self] prompt, respond in
            guard let self else { respond(nil); return }
            self.stateLock.lock()
            let cancelled = self.stopped
            let password = self.secret
            self.stateLock.unlock()
            guard !cancelled else { respond(nil); return }
            let lower = prompt.lowercased()
            if lower.contains("yes/no") || lower.contains("authenticity") {
                if let onTrust = self.onTrust {
                    onTrust(prompt) { respond($0 ? "yes" : "no") }
                } else { respond("no") }
            } else if Self.isPasswordPrompt(prompt) {
                respond(password)
            } else {
                // Never reuse a password as an OTP, PIN, or arbitrary challenge.
                respond(nil)
            }
        }
        self.broker = broker
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let quotedHostsPath = hosts.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%")
        process.arguments = [
            "-F", "/dev/null", "-tt", "-p", String(endpoint.port), "-l", endpoint.user,
            "-o", "StrictHostKeyChecking=ask", "-o", "UserKnownHostsFile=\"\(quotedHostsPath)\"",
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "PermitLocalCommand=no",
            "-o", "ClearAllForwardings=yes", "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR", "--", endpoint.host
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["NPU_MONITOR_ASKPASS_SOCKET"] = broker.path
        environment["DISPLAY"] = "npu-monitor:0"
        environment["TERM"] = "dumb"
        process.environment = environment
        try launch(process, broker: broker)
    }

    /// The same process/pipe lifecycle is used by SSH and the local test
    /// executable. Error output must drain continuously to avoid a full pipe.
    private func launch(_ process: Process, broker: AskPassBroker?) throws {
        let input = Pipe(), output = Pipe(), errors = Pipe()
        self.input = input; self.output = output; self.errors = errors
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let errorDrain = SSHErrorDrain(handle: errors.fileHandleForReading) { [weak self] text in
            self?.onErrorOutput?(text)
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.onOutput?(String(decoding: data, as: UTF8.self)) }
        }
        process.terminationHandler = { [weak self, weak broker, errorDrain] process in
            broker?.stop()
            let code = process.terminationStatus
            errorDrain.afterEOF { [weak self] detail in
                guard let self else { return }
                self.stateLock.lock()
                self.secret = nil
                let notifyExit = !self.stopped
                self.stateLock.unlock()
                if notifyExit { self.onExit?(code, detail) }
            }
        }
        self.process = process
        do {
            try process.run()
            // Parent-side pipe descriptors must not prevent EOF after the
            // child exits. The child already owns its duplicated descriptors.
            try? errors.fileHandleForWriting.close()
            errorDrain.start()
        } catch {
            errorDrain.cancel()
            stop()
            throw error
        }
    }

    #if DEBUG
    /// Runs only local synthetic commands in regression tests; production SSH
    /// continues to use the fixed executable and command above.
    func startLocalTestProcess(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try launch(process, broker: nil)
    }
    #endif

    func requestSample() throws {
        guard let process, process.isRunning, let input else {
            throw MonitorError.transport("SSH 连接已关闭，请重新连接。")
        }
        try input.fileHandleForWriting.write(contentsOf: Data(Self.sampleCommand.utf8))
    }

    func stop() {
        stateLock.lock()
        stopped = true
        secret = nil
        stateLock.unlock()
        broker?.stop()
        broker = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? errors?.fileHandleForReading.close()
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil; output = nil; errors = nil
    }

    deinit { stop() }
}

/// A single reader owns stderr, retaining only a bounded diagnostic tail. The
/// completion group orders process termination after every byte through EOF.
private final class SSHErrorDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let onOutput: (String) -> Void
    private let done = DispatchGroup()
    private let lock = NSLock()
    private var tail = Data()
    private var reachedEOF = false

    init(handle: FileHandle, onOutput: @escaping (String) -> Void) {
        self.handle = handle
        self.onOutput = onOutput
        done.enter()
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { done.leave() }
            do {
                while true {
                    guard let data = try handle.read(upToCount: 4096), !data.isEmpty else {
                        lock.lock(); reachedEOF = true; lock.unlock()
                        break
                    }
                    lock.lock()
                    tail.append(data)
                    if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
                    lock.unlock()
                    onOutput(String(decoding: data, as: UTF8.self))
                }
            } catch {
                // An incomplete diagnostic cannot safely justify another
                // authentication attempt, even if a fragment says network.
            }
        }
    }

    func afterEOF(_ completion: @escaping @Sendable (String) -> Void) {
        done.notify(queue: .global(qos: .utility)) { [self] in
            lock.lock()
            let detail = reachedEOF
                ? String(decoding: tail, as: UTF8.self)
                : "SSH 错误输出读取不完整，已停止自动重连。"
            lock.unlock()
            completion(detail)
        }
    }

    func cancel() {
        try? handle.close()
        // The reader is not started when process.run() fails.
        done.leave()
    }
}
