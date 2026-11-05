import Foundation

/// A usage-only export. Dates on the wire are seconds since the Unix epoch.
public struct CodexRemoteUsageArchive: Codable, Equatable, Sendable {
    public var version: Int
    public var hostID: String
    public var capturedAt: Date
    public var threads: [CodexRemoteUsageThread]

    public init(version: Int = 1, hostID: String, capturedAt: Date, threads: [CodexRemoteUsageThread]) {
        self.version = version
        self.hostID = hostID
        self.capturedAt = capturedAt
        self.threads = threads
    }

    public func validate(now: Date = .now) throws {
        guard version == 1, !hostID.isEmpty, hostID != "local", hostID.count <= 512,
              !hostID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              capturedAt.timeIntervalSince1970.isFinite, capturedAt <= now.addingTimeInterval(300),
              threads.count <= 100_000 else { throw CodexRemoteUsageArchiveError.invalidArchive }
        var ids = Set<String>()
        for thread in threads {
            guard UUID(uuidString: thread.threadID) != nil, ids.insert(thread.threadID.lowercased()).inserted,
                  thread.totalTokens >= 0, thread.records.count <= 1_000_000 else {
                throw CodexRemoteUsageArchiveError.invalidArchive
            }
            var previous: Int64 = 0
            for record in thread.records.sorted(by: Self.recordOrder) {
                guard record.timestamp.timeIntervalSince1970.isFinite,
                      record.timestamp <= capturedAt, record.totalTokens >= previous,
                      record.totalTokens <= thread.totalTokens,
                      record.lastTokens.map({ $0 >= 0 && $0 <= record.totalTokens }) ?? true else {
                    throw CodexRemoteUsageArchiveError.invalidArchive
                }
                previous = record.totalTokens
            }
            guard previous == thread.totalTokens else { throw CodexRemoteUsageArchiveError.invalidArchive }
        }
    }

    static func recordOrder(_ lhs: CodexRemoteUsageRecord, _ rhs: CodexRemoteUsageRecord) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.totalTokens < rhs.totalTokens
    }
}

public struct CodexRemoteUsageThread: Codable, Equatable, Sendable {
    public var threadID: String
    public var totalTokens: Int64
    public var records: [CodexRemoteUsageRecord]

    public init(threadID: String, totalTokens: Int64, records: [CodexRemoteUsageRecord]) {
        self.threadID = threadID.lowercased()
        self.totalTokens = totalTokens
        self.records = records
    }
}

public struct CodexRemoteUsageRecord: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var totalTokens: Int64
    public var lastTokens: Int64?

    public init(timestamp: Date, totalTokens: Int64, lastTokens: Int64? = nil) {
        self.timestamp = timestamp
        self.totalTokens = totalTokens
        self.lastTokens = lastTokens
    }
}

public enum CodexRemoteUsageArchiveError: Error, Equatable {
    case invalidArchive
    case archiveTooLarge
}

/// Keeps the last successful export while the remote host is unavailable.
public struct CodexRemoteUsageArchiveStore: Sendable {
    public let fileURL: URL
    private static let maximumBytes = 64 * 1_024 * 1_024

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("open-island/codex-remote-usage-archives.json")
    }

    public init(fileURL: URL = Self.defaultFileURL) { self.fileURL = fileURL }

    public static func decode(_ data: Data, now: Date = .now) throws -> CodexRemoteUsageArchive {
        guard data.count <= maximumBytes else { throw CodexRemoteUsageArchiveError.archiveTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let archive = try decoder.decode(CodexRemoteUsageArchive.self, from: data)
        try archive.validate(now: now)
        return archive
    }

    public func load(now: Date = .now) -> [CodexRemoteUsageArchive] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= Self.maximumBytes,
              let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let archives = try? decoder.decode([CodexRemoteUsageArchive].self, from: data) else { return [] }
        return archives.filter { (try? $0.validate(now: now)) != nil }
    }

    @discardableResult
    public func merge(_ archive: CodexRemoteUsageArchive, now: Date = .now) throws -> [CodexRemoteUsageArchive] {
        try archive.validate(now: now)
        var archives = load(now: now)
        if let index = archives.firstIndex(where: { $0.hostID == archive.hostID }) {
            let existing = archives[index]
            guard archive.capturedAt >= existing.capturedAt else { return archives }
            var threads = Dictionary(uniqueKeysWithValues: existing.threads.map { ($0.threadID.lowercased(), $0) })
            for incoming in archive.threads {
                let id = incoming.threadID.lowercased()
                if let old = threads[id] {
                    // A stale or truncated remote file must not erase retained history.
                    guard incoming.totalTokens >= old.totalTokens else { continue }
                    // A moved archive can reveal the original event earlier
                    // than a previously retained observation of that counter.
                    // Keep one checkpoint per counter, so a later duplicate
                    // cannot appear after a newer, higher counter.
                    var checkpoints: [Int64: CodexRemoteUsageRecord] = [:]
                    for record in old.records + incoming.records {
                        guard let previous = checkpoints[record.totalTokens] else {
                            checkpoints[record.totalTokens] = record
                            continue
                        }
                        if record.timestamp < previous.timestamp {
                            checkpoints[record.totalTokens] = record
                        } else if record.timestamp == previous.timestamp {
                            var checkpoint = previous
                            // Conflicting per-event details must not invent a
                            // larger known range. Prefer the smaller known tail.
                            checkpoint.lastTokens = [previous.lastTokens, record.lastTokens].compactMap { $0 }.min()
                            checkpoints[record.totalTokens] = checkpoint
                        }
                    }
                    let records = checkpoints.values.sorted(by: CodexRemoteUsageArchive.recordOrder)
                    threads[id] = CodexRemoteUsageThread(threadID: id, totalTokens: incoming.totalTokens, records: records)
                } else {
                    threads[id] = incoming
                }
            }
            let merged = CodexRemoteUsageArchive(hostID: archive.hostID, capturedAt: archive.capturedAt,
                                                threads: threads.values.sorted { $0.threadID < $1.threadID })
            try merged.validate(now: now)
            archives[index] = merged
        } else {
            archives.append(archive)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(archives.sorted { $0.hostID < $1.hostID })
        guard data.count <= Self.maximumBytes else { throw CodexRemoteUsageArchiveError.archiveTooLarge }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return archives
    }
}

struct CodexUsageTokenRange {
    var lower: Int64
    var upper: Int64
    var count: Int64 { max(0, upper - lower) }
}

/// Counter ranges identify the same generated tokens across archive copies and IPC.
struct CodexUsageTokenCoverage {
    private var ranges: [CodexUsageTokenRange] = []

    func uncovered(_ range: CodexUsageTokenRange) -> [CodexUsageTokenRange] {
        guard range.count > 0 else { return [] }
        var lower = range.lower
        var result: [CodexUsageTokenRange] = []
        for covered in ranges where covered.upper > lower && covered.lower < range.upper {
            if covered.lower > lower { result.append(.init(lower: lower, upper: min(covered.lower, range.upper))) }
            lower = max(lower, covered.upper)
            if lower >= range.upper { break }
        }
        if lower < range.upper { result.append(.init(lower: lower, upper: range.upper)) }
        return result
    }

    mutating func insert(_ range: CodexUsageTokenRange) {
        guard range.count > 0 else { return }
        var result: [CodexUsageTokenRange] = []
        for item in (ranges + [range]).sorted(by: { $0.lower < $1.lower }) {
            if let last = result.last, item.lower <= last.upper {
                result[result.count - 1].upper = max(last.upper, item.upper)
            } else { result.append(item) }
        }
        ranges = result
    }
}
