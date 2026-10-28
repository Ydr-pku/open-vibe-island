import Darwin
import Foundation
import SQLite3

public struct CodexDesktopUsageInterval: Equatable, Codable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var tokens: Int64

    public init(startedAt: Date, endedAt: Date, tokens: Int64) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tokens = tokens
    }
}

public struct CodexDesktopThreadUsage: Equatable, Codable, Sendable {
    public var threadID: String
    public var totalTokens: Int64
    public var updatedAt: Date
    public var startedAt: Date
    public var hostID: String
    public var intervals: [CodexDesktopUsageInterval]?
    public var observedAt: Date?

    public var identityKey: String { "\(hostID)\n\(threadID)" }

    public init(
        threadID: String,
        totalTokens: Int64,
        updatedAt: Date,
        startedAt: Date,
        hostID: String = "local",
        intervals: [CodexDesktopUsageInterval]? = nil,
        observedAt: Date? = nil
    ) {
        self.threadID = threadID
        self.totalTokens = totalTokens
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.hostID = hostID
        self.intervals = intervals
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case threadID, totalTokens, updatedAt, startedAt, hostID, intervals, observedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        threadID = try values.decode(String.self, forKey: .threadID)
        totalTokens = try values.decode(Int64.self, forKey: .totalTokens)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        hostID = try values.decodeIfPresent(String.self, forKey: .hostID) ?? "local"
        intervals = try values.decodeIfPresent([CodexDesktopUsageInterval].self, forKey: .intervals)
        observedAt = try values.decodeIfPresent(Date.self, forKey: .observedAt)
    }
}

/// Retains token totals that only exist in Codex Desktop's in-memory IPC.
///
/// Side tasks do not always produce rollout files. Without this cache, their
/// contribution disappears from local history as soon as Codex Desktop exits
/// and the IPC socket becomes unavailable.
public struct CodexDesktopThreadUsageStore {
    public let fileURL: URL
    private let fileManager: FileManager

    public static var defaultFileURL: URL {
        CodexSessionStore.defaultDirectoryURL
            .appendingPathComponent("codex-desktop-thread-usage.json")
    }

    public init(
        fileURL: URL = Self.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadAndMerge(
        liveUsages: [CodexDesktopThreadUsage],
        now: Date = .now,
        retentionDays: Int = 31
    ) -> [CodexDesktopThreadUsage] {
        let cachedUsages = load()
        let cutoff = now.addingTimeInterval(-Double(max(1, retentionDays)) * 86_400)
        var usagesByThread: [String: CodexDesktopThreadUsage] = [:]
        for usage in cachedUsages where (usage.observedAt ?? usage.updatedAt) >= cutoff
            && (usage.observedAt ?? usage.updatedAt) <= now && usage.updatedAt <= now
            && usage.startedAt <= usage.updatedAt {
            if usage.totalTokens >= (usagesByThread[usage.identityKey]?.totalTokens ?? 0) {
                usagesByThread[usage.identityKey] = usage
            }
        }

        for liveUsage in liveUsages
            where liveUsage.totalTokens > 0
                && (liveUsage.hostID != "local" || liveUsage.updatedAt >= cutoff)
                && liveUsage.updatedAt <= now {
            guard let cachedUsage = usagesByThread[liveUsage.identityKey] else {
                usagesByThread[liveUsage.identityKey] = recordingIntervals(liveUsage, after: nil, now: now)
                continue
            }

            if liveUsage.totalTokens > cachedUsage.totalTokens
                || (liveUsage.hostID != "local" && liveUsage.totalTokens == cachedUsage.totalTokens)
                || (liveUsage.totalTokens == cachedUsage.totalTokens
                    && liveUsage.updatedAt > cachedUsage.updatedAt) {
                usagesByThread[liveUsage.identityKey] = recordingIntervals(liveUsage, after: cachedUsage, now: now)
            }
        }

        let mergedUsages = usagesByThread.values.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.identityKey < $1.identityKey
            }
            return $0.updatedAt < $1.updatedAt
        }
        save(mergedUsages)
        return mergedUsages
    }

    private func recordingIntervals(_ live: CodexDesktopThreadUsage, after cached: CodexDesktopThreadUsage?, now: Date) -> CodexDesktopThreadUsage {
        guard live.hostID != "local" else { return live }
        var result = live
        result.observedAt = now
        var intervals = cached?.intervals ?? cached.map {
            [CodexDesktopUsageInterval(startedAt: $0.startedAt, endedAt: $0.updatedAt, tokens: $0.totalTokens)]
        } ?? []
        let delta = live.totalTokens - (cached?.totalTokens ?? 0)
        if delta > 0 {
            let start = cached.map { $0.observedAt ?? $0.updatedAt } ?? live.startedAt
            let end = cached == nil ? live.updatedAt : now
            let interval = CodexDesktopUsageInterval(startedAt: start, endedAt: end, tokens: delta)
            // Compact frequent samples within a single hour without losing
            // daily/hourly attribution, keeping this cache bounded in practice.
            if let last = intervals.last,
               Calendar.current.isDate(last.startedAt, equalTo: interval.endedAt, toGranularity: .hour),
               last.endedAt <= interval.endedAt {
                intervals[intervals.count - 1].endedAt = interval.endedAt
                intervals[intervals.count - 1].tokens += delta
            } else {
                intervals.append(interval)
            }
        }
        result.intervals = intervals
        return result
    }

    private func load() -> [CodexDesktopThreadUsage] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CodexDesktopThreadUsage].self, from: data)) ?? []
    }

    private func save(_ usages: [CodexDesktopThreadUsage]) {
        let directoryURL = fileURL.deletingLastPathComponent()
        guard (try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )) != nil else {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(usages) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Reads the in-memory token totals owned by Codex Desktop.
///
/// Codex Desktop exposes these totals through its local multi-window IPC
/// router. They include side tasks that are not persisted as rollout JSONL
/// files. The protocol is private and versioned, so failures intentionally
/// degrade to an empty result and leave rollout-based usage untouched.
public enum CodexDesktopIPCUsageLoader {
    public struct Thread: Equatable, Sendable {
        public var id: String
        public var updatedAt: Date
        public var startedAt: Date
        public var hostID: String

        public var identityKey: String { "\(hostID)\n\(id)" }

        public init(id: String, updatedAt: Date, startedAt: Date, hostID: String = "local") {
            self.id = id
            self.updatedAt = updatedAt
            self.startedAt = startedAt
            self.hostID = hostID
        }
    }

    public static var defaultSocketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/ipc/ipc.sock")
    }

    public static func load(
        threads: [Thread],
        socketURL: URL = defaultSocketURL
    ) -> [CodexDesktopThreadUsage] {
        guard !threads.isEmpty,
              let client = try? IPCClient(socketPath: socketURL.path) else {
            return []
        }
        defer { client.close() }

        guard client.initialize() else {
            return []
        }

        return client.tokenTotals(threads: threads)
    }

    static func tokenTotal(from message: [String: Any], threadID: String, hostID: String = "local") -> Int64? {
        guard message["type"] as? String == "broadcast",
              message["method"] as? String == "thread-stream-state-changed",
              let params = message["params"] as? [String: Any],
              params["conversationId"] as? String == threadID,
              (params["hostId"] as? String ?? "local") == hostID,
              let change = params["change"] as? [String: Any],
              change["type"] as? String == "snapshot",
              let state = change["conversationState"] as? [String: Any],
              let usage = state["latestTokenUsageInfo"] as? [String: Any],
              let total = usage["total"] as? [String: Any],
              let number = total["totalTokens"] as? NSNumber else {
            return nil
        }
        let value = number.int64Value
        return value > 0 ? value : nil
    }

    static func threadUsage(from message: [String: Any], thread: Thread) -> CodexDesktopThreadUsage? {
        guard let total = tokenTotal(from: message, threadID: thread.id, hostID: thread.hostID),
              let params = message["params"] as? [String: Any],
              let change = params["change"] as? [String: Any],
              let state = change["conversationState"] as? [String: Any] else { return nil }
        // Desktop's conversation state timestamps are milliseconds, including
        // remote snapshots. Discovery times are only a local fallback.
        func date(_ key: String, fallback: Date) -> Date {
            guard let number = state[key] as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue > 0 else { return fallback }
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        return CodexDesktopThreadUsage(
            threadID: thread.id, totalTokens: total,
            updatedAt: date("updatedAt", fallback: thread.updatedAt),
            startedAt: date("createdAt", fallback: thread.startedAt), hostID: thread.hostID
        )
    }
}

public enum CodexDesktopThreadDiscovery {
    public static var defaultGlobalStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
    }

    /// Reads only thread/project host routing metadata. Remote threads live on
    /// their execution host, so neither local rollout scans nor logs.sqlite can
    /// discover their complete IDs. The desktop owns the remote connection.
    public static func loadRemote(
        globalStateURL: URL = defaultGlobalStateURL,
        limit: Int = 50
    ) -> [CodexDesktopIPCUsageLoader.Thread] {
        guard let data = try? Data(contentsOf: globalStateURL), data.count <= 16 * 1_024 * 1_024,
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var projectHosts: [String: String] = [:]
        for project in state["remote-projects"] as? [[String: Any]] ?? [] {
            if let id = project["id"] as? String, let host = project["hostId"] as? String {
                projectHosts[id] = host
            }
        }
        var hostsByThread: [String: String] = [:]
        for (id, assignment) in state["thread-project-assignments"] as? [String: [String: Any]] ?? [:] {
            if assignment["projectKind"] as? String == "remote",
               let projectID = assignment["projectId"] as? String, let host = projectHosts[projectID] {
                hostsByThread[id] = host
            }
        }
        // Explicit membership routing is newer than legacy project assignment.
        for (id, host) in state["thread-project-membership-host-ids"] as? [String: String] ?? [:] {
            hostsByThread[id] = host
        }
        return hostsByThread.compactMap { id, host in
            let digits = id.replacingOccurrences(of: "-", with: "")
            guard host != "local", !host.isEmpty, host.count <= 2_048,
                  UUID(uuidString: id) != nil, digits.count == 32,
                  digits[digits.index(digits.startIndex, offsetBy: 12)] == "7",
                  let milliseconds = UInt64(digits.prefix(12), radix: 16) else { return nil }
            let startedAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            // Old threads may still be active remotely. Their actual latest
            // update time arrives in the snapshot; UUID age is not an activity
            // filter. Multi-day baseline totals remain explicitly unattributed.
            return CodexDesktopIPCUsageLoader.Thread(
                id: id, updatedAt: startedAt, startedAt: startedAt, hostID: host
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
        .prefix(max(1, limit)).map { $0 }
    }

    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/logs_2.sqlite")
    }

    /// Finds recent local thread IDs without reading prompt or response text.
    ///
    /// Side tasks may not have rollout files, but Codex still tags their local
    /// diagnostic rows with the thread ID. IPC remains authoritative for the
    /// token total; this database is used only to discover candidates.
    public static func load(
        databaseURL: URL = defaultDatabaseURL,
        since: Date,
        limit: Int = 50
    ) -> [CodexDesktopIPCUsageLoader.Thread] {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 60)

        let sql = """
            SELECT thread_id, MIN(ts), MAX(ts)
            FROM logs
            WHERE thread_id IS NOT NULL
            GROUP BY thread_id
            HAVING MIN(ts) >= ?
            ORDER BY MAX(ts) DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970))
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

        var threads: [CodexDesktopIPCUsageLoader.Thread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            guard UUID(uuidString: id) != nil else { continue }
            threads.append(
                CodexDesktopIPCUsageLoader.Thread(
                    id: id,
                    updatedAt: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2))
                    ),
                    startedAt: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))
                    )
                )
            )
        }
        return threads
    }
}

private final class IPCClient {
    private static let maxFrameByteCount = 256 * 1_024 * 1_024
    private let fileDescriptor: Int32
    private var clientID: String?
    private var readDeadline: Date?

    init(socketPath: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.ENOTCONN)
        }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes.map(UInt8.init(bitPattern:)))
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            let error = POSIXErrorCode(rawValue: errno) ?? .ENOTCONN
            Darwin.close(descriptor)
            throw POSIXError(error)
        }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        fileDescriptor = descriptor
    }

    func close() {
        Darwin.close(fileDescriptor)
    }

    func initialize() -> Bool {
        let requestID = UUID().uuidString
        guard send([
            "type": "request",
            "requestId": requestID,
            "version": 0,
            "method": "initialize",
            "params": ["clientType": "open-island-usage"],
        ]) else {
            return false
        }

        let deadline = Date().addingTimeInterval(2)
        readDeadline = deadline
        while Date() < deadline, let message = receive() {
            guard message["type"] as? String == "response",
                  message["requestId"] as? String == requestID else {
                continue
            }
            guard message["resultType"] as? String == "success",
                  let result = message["result"] as? [String: Any],
                  let clientID = result["clientId"] as? String else {
                return false
            }
            self.clientID = clientID
            return true
        }
        return false
    }

    func tokenTotals(threads: [CodexDesktopIPCUsageLoader.Thread]) -> [CodexDesktopThreadUsage] {
        guard let clientID else { return [] }

        let followedThreads = threads.filter { thread in
            send([
                "type": "broadcast",
                "method": "thread-stream-following-changed",
                "sourceClientId": clientID,
                "version": 1,
                "params": [
                    "conversationId": thread.id,
                    "hostId": thread.hostID,
                    "following": true,
                ],
            ])
        }
        defer {
            for thread in followedThreads {
                _ = send([
                    "type": "broadcast",
                    "method": "thread-stream-following-changed",
                    "sourceClientId": clientID,
                    "version": 1,
                    "params": [
                        "conversationId": thread.id,
                        "hostId": thread.hostID,
                        "following": false,
                    ],
                ])
            }
        }

        var usagesByThread: [String: CodexDesktopThreadUsage] = [:]
        var receivedIdentities: Set<String> = []
        let deadline = Date().addingTimeInterval(2)
        readDeadline = deadline
        while Date() < deadline, let message = receive() {
            for thread in followedThreads where !receivedIdentities.contains(thread.identityKey) {
                if let params = message["params"] as? [String: Any],
                   params["conversationId"] as? String == thread.id,
                   (params["hostId"] as? String ?? "local") == thread.hostID,
                   let change = params["change"] as? [String: Any],
                   change["type"] as? String == "snapshot" {
                    receivedIdentities.insert(thread.identityKey)
                }
                if let usage = CodexDesktopIPCUsageLoader.threadUsage(from: message, thread: thread) {
                    usagesByThread[thread.identityKey] = usage
                }
            }
            if receivedIdentities.count == followedThreads.count {
                break
            }
        }
        return Array(usagesByThread.values)
    }

    private func send(_ object: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              let payload = try? JSONSerialization.data(withJSONObject: object),
              payload.count <= Self.maxFrameByteCount else {
            return false
        }

        var byteCount = UInt32(payload.count).littleEndian
        let header = withUnsafeBytes(of: &byteCount) { Data($0) }
        return writeAll(header) && writeAll(payload)
    }

    private func receive() -> [String: Any]? {
        guard let header = readExactly(4) else { return nil }
        let byteCount = header.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        guard byteCount > 0, byteCount <= Self.maxFrameByteCount,
              let payload = readExactly(Int(byteCount)),
              let object = try? JSONSerialization.jsonObject(with: payload)
                as? [String: Any] else {
            return nil
        }
        return object
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        let succeeded = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < count {
                if let readDeadline, Date() >= readDeadline { return false }
                let readCount = Darwin.read(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if readCount < 0 && errno == EINTR { continue }
                guard readCount > 0 else { return false }
                offset += readCount
            }
            return true
        }
        return succeeded ? data : nil
    }
}
