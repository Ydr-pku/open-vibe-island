import Darwin
import Foundation
import OpenIslandCore

struct CodexRemoteUsageSource: Codable, Equatable, Sendable {
    var hostID: String
    var sshAlias: String
    var codexHome: String?

    init(hostID: String, sshAlias: String, codexHome: String? = nil) {
        self.hostID = hostID
        self.sshAlias = sshAlias
        self.codexHome = codexHome
    }

    func validate() throws {
        guard hostID.hasPrefix("remote-control:"), hostID.count <= 2_048,
              !hostID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !sshAlias.isEmpty, sshAlias.count <= 255,
              sshAlias.first?.isLetter == true || sshAlias.first?.isNumber == true,
              sshAlias.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
              }),
              codexHome.map({ $0.count <= 4_096 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true else {
            throw CodexRemoteUsageSyncError.invalidSource
        }
    }
}

enum CodexRemoteUsageSyncError: Error, LocalizedError, Sendable {
    case invalidSource
    case missingExporter
    case invalidResponse
    case timedOut
    case outputTooLarge
    case cancelled
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .invalidSource: "Invalid remote usage source. Configure a Codex host ID and an SSH alias."
        case .missingExporter: "The remote token exporter is missing from this application."
        case .invalidResponse: "The remote token export was incomplete or belonged to another host."
        case .timedOut: "Remote token export timed out. The previous history is retained."
        case .outputTooLarge: "Remote token export exceeded the size limit. The previous history is retained."
        case .cancelled: "Remote token export was cancelled."
        case .commandFailed(let status, let detail): "Remote token export failed (\(status)). \(detail)"
        }
    }
}

/// Uses the user's existing SSH configuration. It neither stores credentials
/// nor associates the independent NPU monitor endpoint with a Codex host.
actor CodexRemoteUsageSync {
    typealias Runner = @Sendable (URL, [String], Data, TimeInterval, Int) async throws -> Data

    nonisolated static var defaultSourcesFileURL: URL {
        CodexSessionStore.defaultDirectoryURL.appendingPathComponent("codex-remote-usage-sources.json")
    }

    nonisolated static var defaultExporterURL: URL? {
        Bundle.module.url(forResource: "codex-remote-usage-export", withExtension: "py")
    }

    private let sourcesFileURL: URL
    private let exporterURL: URL?
    private let runner: Runner
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private var syncing = false
    private(set) var lastErrors: [String] = []

    init(
        sourcesFileURL: URL = defaultSourcesFileURL,
        exporterURL: URL? = defaultExporterURL,
        timeout: TimeInterval = 90,
        maximumOutputBytes: Int = 32 * 1_024 * 1_024,
        runner: @escaping Runner = { executable, arguments, input, timeout, limit in
            try await RemoteUsageCommand.run(executable: executable, arguments: arguments, input: input, timeout: timeout, maximumOutputBytes: limit)
        }
    ) {
        self.sourcesFileURL = sourcesFileURL
        self.exporterURL = exporterURL
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.runner = runner
    }

    nonisolated static func loadSources(from fileURL: URL = defaultSourcesFileURL) throws -> [CodexRemoteUsageSource] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let sources = try JSONDecoder().decode([CodexRemoteUsageSource].self, from: Data(contentsOf: fileURL))
        try validate(sources)
        return sources
    }

    nonisolated static func saveSources(_ sources: [CodexRemoteUsageSource], to fileURL: URL = defaultSourcesFileURL) throws {
        try validate(sources)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sources).write(to: fileURL, options: .atomic)
    }

    private nonisolated static func validate(_ sources: [CodexRemoteUsageSource]) throws {
        guard Set(sources.map(\.hostID)).count == sources.count else { throw CodexRemoteUsageSyncError.invalidSource }
        for source in sources { try source.validate() }
    }

    func sync() async -> [CodexRemoteUsageArchive] {
        do {
            let sources = try Self.loadSources(from: sourcesFileURL)
            return await sync(sources: sources)
        }
        catch { lastErrors = [error.localizedDescription]; return [] }
    }

    func sync(sources: [CodexRemoteUsageSource]) async -> [CodexRemoteUsageArchive] {
        guard !syncing else { return [] }
        syncing = true
        defer { syncing = false }
        lastErrors = []
        do { try Self.validate(sources) }
        catch { lastErrors = [error.localizedDescription]; return [] }
        guard !sources.isEmpty else { return [] }
        guard let exporterURL, let input = try? Data(contentsOf: exporterURL) else {
            lastErrors = [CodexRemoteUsageSyncError.missingExporter.localizedDescription]
            return []
        }
        var archives: [CodexRemoteUsageArchive] = []
        for source in sources {
            guard !Task.isCancelled else { break }
            do {
                let output = try await runner(
                    URL(fileURLWithPath: "/usr/bin/ssh"), Self.arguments(for: source), input,
                    timeout, maximumOutputBytes
                )
                archives.append(try Self.decodeArchive(output, source: source))
            } catch {
                lastErrors.append("\(source.sshAlias): \(error.localizedDescription)")
            }
        }
        return archives
    }

    nonisolated static func arguments(for source: CodexRemoteUsageSource) -> [String] {
        var command = "python3 - --host-id \(shellQuote(source.hostID))"
        if let home = source.codexHome, !home.isEmpty { command += " --codex-home \(shellQuote(home))" }
        return ["-T", "-C", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes",
                "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "--", source.sshAlias, command]
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func decodeArchive(_ data: Data, source: CodexRemoteUsageSource) throws -> CodexRemoteUsageArchive {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["complete"] as? Bool == true,
              value["version"] as? Int == 1,
              value["hostID"] as? String == source.hostID else { throw CodexRemoteUsageSyncError.invalidResponse }
        if let environmentID = value["remoteEnvironmentID"] as? String,
           source.hostID != "remote-control:" + environmentID { throw CodexRemoteUsageSyncError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(CodexRemoteUsageArchive.self, from: data)
    }
}

/// Pipe readers drain concurrently, retaining a bounded stdout and diagnostic
/// tail. Timeout/cancellation terminates SSH, including while a pipe is blocked.
final class RemoteUsageCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var failure: CodexRemoteUsageSyncError?
    private var output = Data()
    private var diagnostic = Data()

    static func run(executable: URL, arguments: [String], input: Data, timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        let command = RemoteUsageCommand()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try command.execute(executable: executable, arguments: arguments, input: input, timeout: timeout, maximumOutputBytes: maximumOutputBytes)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { command.stop(.cancelled) }
    }

    private func execute(executable: URL, arguments: [String], input: Data, timeout: TimeInterval, maximumOutputBytes: Int) throws -> Data {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        lock.lock()
        guard failure == nil else { lock.unlock(); throw CodexRemoteUsageSyncError.cancelled }
        self.process = process
        // Serialize process launch with cancellation so a cancelled request
        // cannot start an orphan subprocess after stop() has returned.
        do { try process.run() } catch { self.process = nil; lock.unlock(); throw error }
        lock.unlock()
        let timer = DispatchWorkItem { [weak self] in self?.stop(.timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, timeout), execute: timer)
        defer { timer.cancel() }
        let readers = DispatchGroup()
        for (handle, isOutput) in [(stdout.fileHandleForReading, true), (stderr.fileHandleForReading, false)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { try? handle.close(); readers.leave() }
                let descriptor = handle.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    stop(.commandFailed(-1, "Cannot read remote token export."))
                    return
                }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    // A descendant can inherit the pipe after SSH exits. A
                    // blocking FileHandle.read would then ignore our deadline.
                    lock.lock()
                    let stopped = failure != nil
                    lock.unlock()
                    if stopped { break }
                    var status = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                    let ready = poll(&status, 1, 100)
                    if ready == 0 { continue }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        stop(.commandFailed(-1, "Cannot read remote token export."))
                        break
                    }
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        stop(.commandFailed(-1, "Cannot read remote token export."))
                        break
                    }
                    let chunk = Data(buffer.prefix(count))
                    lock.lock()
                    if isOutput {
                        if output.count <= maximumOutputBytes - chunk.count { output.append(chunk) }
                        else { lock.unlock(); stop(.outputTooLarge); continue }
                    } else {
                        diagnostic.append(chunk)
                        if diagnostic.count > 8_192 { diagnostic.removeFirst(diagnostic.count - 8_192) }
                    }
                    lock.unlock()
                }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        readers.wait()
        lock.lock()
        self.process = nil
        let failure = self.failure, output = self.output, diagnostic = self.diagnostic
        lock.unlock()
        if let failure { throw failure }
        guard process.terminationStatus == 0 else {
            throw CodexRemoteUsageSyncError.commandFailed(process.terminationStatus, String(decoding: diagnostic, as: UTF8.self))
        }
        return output
    }

    private func stop(_ failure: CodexRemoteUsageSyncError) {
        lock.lock()
        if self.failure == nil { self.failure = failure }
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
