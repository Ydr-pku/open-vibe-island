import Darwin
import Foundation
import SQLite3

public struct CodexDesktopThreadUsage: Equatable, Sendable {
    public var threadID: String
    public var totalTokens: Int64
    public var updatedAt: Date
    public var startedAt: Date

    public init(
        threadID: String,
        totalTokens: Int64,
        updatedAt: Date,
        startedAt: Date
    ) {
        self.threadID = threadID
        self.totalTokens = totalTokens
        self.updatedAt = updatedAt
        self.startedAt = startedAt
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

        public init(id: String, updatedAt: Date, startedAt: Date) {
            self.id = id
            self.updatedAt = updatedAt
            self.startedAt = startedAt
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

        return threads.compactMap { thread in
            guard let totalTokens = client.totalTokens(threadID: thread.id),
                  totalTokens > 0 else {
                return nil
            }
            return CodexDesktopThreadUsage(
                threadID: thread.id,
                totalTokens: totalTokens,
                updatedAt: thread.updatedAt,
                startedAt: thread.startedAt
            )
        }
    }

    static func tokenTotal(from message: [String: Any], threadID: String) -> Int64? {
        guard message["type"] as? String == "broadcast",
              message["method"] as? String == "thread-stream-state-changed",
              let params = message["params"] as? [String: Any],
              params["conversationId"] as? String == threadID,
              let change = params["change"] as? [String: Any],
              change["type"] as? String == "snapshot",
              let state = change["conversationState"] as? [String: Any],
              let usage = state["latestTokenUsageInfo"] as? [String: Any],
              let total = usage["total"] as? [String: Any],
              let number = total["totalTokens"] as? NSNumber else {
            return nil
        }
        return number.int64Value
    }
}

public enum CodexDesktopThreadDiscovery {
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

    init(socketPath: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.ENOTCONN)
        }

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

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
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

        while let message = receive() {
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

    func totalTokens(threadID: String) -> Int64? {
        guard let clientID else { return nil }

        let followingParams: [String: Any] = [
            "conversationId": threadID,
            "hostId": "local",
            "following": true,
        ]
        guard send([
            "type": "broadcast",
            "method": "thread-stream-following-changed",
            "sourceClientId": clientID,
            "version": 1,
            "params": followingParams,
        ]) else {
            return nil
        }
        defer {
            _ = send([
                "type": "broadcast",
                "method": "thread-stream-following-changed",
                "sourceClientId": clientID,
                "version": 1,
                "params": [
                    "conversationId": threadID,
                    "hostId": "local",
                    "following": false,
                ],
            ])
        }

        let requestID = UUID().uuidString
        guard send([
            "type": "request",
            "requestId": requestID,
            "sourceClientId": clientID,
            "version": 1,
            "method": "thread-follower-load-complete-history",
            "params": ["conversationId": threadID],
            "timeoutMs": 30_000,
        ]) else {
            return nil
        }

        var tokenTotal: Int64?
        var requestSucceeded = false
        while let message = receive() {
            if tokenTotal == nil {
                tokenTotal = CodexDesktopIPCUsageLoader.tokenTotal(
                    from: message,
                    threadID: threadID
                )
            }
            if message["type"] as? String == "response",
               message["requestId"] as? String == requestID {
                requestSucceeded = message["resultType"] as? String == "success"
                break
            }
        }
        return requestSucceeded ? tokenTotal : nil
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
                let readCount = Darwin.read(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                guard readCount > 0 else { return false }
                offset += readCount
            }
            return true
        }
        return succeeded ? data : nil
    }
}
