import Foundation

public struct CodexUsageWindow: Equatable, Codable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var usedPercentage: Double
    public var leftPercentage: Double
    public var windowMinutes: Int
    public var resetsAt: Date?

    public init(
        key: String,
        label: String,
        usedPercentage: Double,
        leftPercentage: Double,
        windowMinutes: Int,
        resetsAt: Date?
    ) {
        self.key = key
        self.label = label
        self.usedPercentage = usedPercentage
        self.leftPercentage = leftPercentage
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var id: String {
        key
    }

    public var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

public struct CodexUsageSnapshot: Equatable, Codable, Sendable {
    public var sourceFilePath: String
    public var capturedAt: Date?
    public var planType: String?
    public var limitID: String?
    public var windows: [CodexUsageWindow]

    public init(
        sourceFilePath: String,
        capturedAt: Date?,
        planType: String? = nil,
        limitID: String? = nil,
        windows: [CodexUsageWindow]
    ) {
        self.sourceFilePath = sourceFilePath
        self.capturedAt = capturedAt
        self.planType = planType
        self.limitID = limitID
        self.windows = windows
    }

    public var isEmpty: Bool {
        windows.isEmpty
    }
}

public struct CodexUsageHistoryBucket: Equatable, Codable, Sendable, Identifiable {
    public var key: String
    public var tokens: Int64

    public init(key: String, tokens: Int64) {
        self.key = key
        self.tokens = tokens
    }

    public var id: String { key }
}

public struct CodexAccountUsageSummary: Equatable, Codable, Sendable {
    public var lifetimeTokens: Int64?
    public var peakDailyTokens: Int64?
    public var longestRunningTurnSeconds: Int?
    public var currentStreakDays: Int?
    public var longestStreakDays: Int?

    public init(
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        longestRunningTurnSeconds: Int?,
        currentStreakDays: Int?,
        longestStreakDays: Int?
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSeconds = longestRunningTurnSeconds
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }
}

public struct CodexAccountUsageSnapshot: Equatable, Codable, Sendable {
    public var summary: CodexAccountUsageSummary
    public var dailyBuckets: [CodexUsageHistoryBucket]
    public var capturedAt: Date

    public init(
        summary: CodexAccountUsageSummary,
        dailyBuckets: [CodexUsageHistoryBucket],
        capturedAt: Date
    ) {
        self.summary = summary
        self.dailyBuckets = dailyBuckets
        self.capturedAt = capturedAt
    }
}

public struct CodexLocalUsageSnapshot: Equatable, Codable, Sendable {
    public var dailyBuckets: [CodexUsageHistoryBucket]
    public var hourlyBuckets: [CodexUsageHistoryBucket]
    public var capturedAt: Date
    /// Remote cumulative history whose generation day cannot be recovered.
    /// Excluded from daily/hourly charts rather than assigned to the last day.
    public var unattributedRemoteTokens: Int64?
    /// Today's remote usage known by day but not by individual hour.
    public var unattributedRemoteHourlyTokens: Int64?

    public init(
        dailyBuckets: [CodexUsageHistoryBucket],
        hourlyBuckets: [CodexUsageHistoryBucket],
        capturedAt: Date,
        unattributedRemoteTokens: Int64? = nil,
        unattributedRemoteHourlyTokens: Int64? = nil
    ) {
        self.dailyBuckets = dailyBuckets
        self.hourlyBuckets = hourlyBuckets
        self.capturedAt = capturedAt
        self.unattributedRemoteTokens = unattributedRemoteTokens
        self.unattributedRemoteHourlyTokens = unattributedRemoteHourlyTokens
    }
}

public enum CodexUsageLoader {
    public static let defaultRootURL = CodexRolloutDiscovery.defaultRootURL
    /// Codex moves archived threads and side conversations out of `sessions/`,
    /// but their token-count events still carry the account-wide rate limits.
    public static let defaultArchivedRootURL = CodexArchivedSessionIndex.defaultDirectoryURL
    public static let defaultRootURLs = [defaultRootURL, defaultArchivedRootURL]

    private struct Candidate: Sendable {
        var fileURL: URL
        var modifiedAt: Date
    }

    public static func load(
        fileManager: FileManager = .default
    ) throws -> CodexUsageSnapshot? {
        try load(fromRootURLs: defaultRootURLs, fileManager: fileManager)
    }

    public static func load(
        fromRootURL rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> CodexUsageSnapshot? {
        try load(fromRootURLs: [rootURL], fileManager: fileManager)
    }

    public static func load(
        fromRootURLs rootURLs: [URL],
        fileManager: FileManager = .default
    ) throws -> CodexUsageSnapshot? {
        var candidates: [Candidate] = []

        for rootURL in rootURLs {
            guard fileManager.fileExists(atPath: rootURL.path),
                  let enumerator = fileManager.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            appendCandidates(from: enumerator, to: &candidates)
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.fileURL.path.localizedStandardCompare(rhs.fileURL.path) == .orderedDescending
            }

            return lhs.modifiedAt > rhs.modifiedAt
        }

        var latestSnapshot: CodexUsageSnapshot?
        for candidate in sortedCandidates {
            // A file cannot contain an event newer than its own modification
            // date. Once candidates are older than the best event found, the
            // remaining rollout files cannot improve the result.
            if let capturedAt = latestSnapshot?.capturedAt,
               candidate.modifiedAt < capturedAt {
                break
            }

            guard let snapshot = loadLatestSnapshot(
                from: candidate.fileURL,
                modifiedAt: candidate.modifiedAt
            ) else {
                continue
            }

            if latestSnapshot == nil
                || (snapshot.capturedAt ?? candidate.modifiedAt)
                    > (latestSnapshot?.capturedAt ?? .distantPast) {
                latestSnapshot = snapshot
            }
        }

        return latestSnapshot
    }

    private static func appendCandidates(
        from enumerator: FileManager.DirectoryEnumerator,
        to candidates: inout [Candidate]
    ) {
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl",
                  let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  resourceValues.isRegularFile == true else {
                continue
            }

            candidates.append(
                Candidate(
                    fileURL: fileURL,
                    modifiedAt: resourceValues.contentModificationDate ?? .distantPast
                )
            )
        }
    }

    private static func loadLatestSnapshot(from fileURL: URL, modifiedAt: Date) -> CodexUsageSnapshot? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        var latestSnapshot: CodexUsageSnapshot?
        contents.enumerateLines { line, _ in
            guard let snapshot = snapshot(
                from: line,
                filePath: fileURL.path,
                fallbackTimestamp: modifiedAt
            ) else {
                return
            }

            latestSnapshot = snapshot
        }

        return latestSnapshot
    }

    private static func snapshot(
        from line: String,
        filePath: String,
        fallbackTimestamp: Date
    ) -> CodexUsageSnapshot? {
        guard let object = jsonObject(for: line),
              object["type"] as? String == "event_msg" else {
            return nil
        }

        let payload = object["payload"] as? [String: Any] ?? [:]
        guard payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any] else {
            return nil
        }

        let windows = ["primary", "secondary"].compactMap { key in
            usageWindow(for: key, in: rateLimits)
        }
        guard !windows.isEmpty else {
            return nil
        }

        return CodexUsageSnapshot(
            sourceFilePath: filePath,
            capturedAt: timestamp(from: object["timestamp"]) ?? fallbackTimestamp,
            planType: string(from: rateLimits["plan_type"]),
            limitID: string(from: rateLimits["limit_id"]),
            windows: windows
        )
    }

    private static func usageWindow(for key: String, in rateLimits: [String: Any]) -> CodexUsageWindow? {
        guard let payload = rateLimits[key] as? [String: Any],
              let usedPercentage = number(from: payload["used_percent"]),
              let windowMinutes = integer(from: payload["window_minutes"]) else {
            return nil
        }

        return CodexUsageWindow(
            key: key,
            label: windowLabel(forMinutes: windowMinutes),
            usedPercentage: usedPercentage,
            leftPercentage: max(0, 100 - usedPercentage),
            windowMinutes: windowMinutes,
            resetsAt: date(from: payload["resets_at"])
        )
    }

    static func windowLabel(forMinutes minutes: Int) -> String {
        let days = minutes / 1_440
        let remainingMinutesAfterDays = minutes % 1_440
        let hours = remainingMinutesAfterDays / 60
        let remainingMinutes = remainingMinutesAfterDays % 60

        if days > 0, hours == 0, remainingMinutes == 0 {
            return "\(days)d"
        }

        if days > 0, hours > 0 {
            return "\(days)d \(hours)h"
        }

        if hours > 0, remainingMinutes == 0 {
            return "\(hours)h"
        }

        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }

        return "\(minutes)m"
    }

    private static func jsonObject(for line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        return dictionary
    }

    private static func timestamp(from value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string)
        default:
            nil
        }
    }

    private static func integer(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            guard let seconds = Double(string) else {
                return nil
            }

            return Date(timeIntervalSince1970: seconds)
        default:
            return nil
        }
    }

    private static func string(from value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

public enum CodexLocalUsageLoader {
    private static let streamingChunkSize = 256 * 1_024
    public static let defaultRootURLs = CodexUsageLoader.defaultRootURLs

    private struct ExactUsage {
        var range: CodexUsageTokenRange
        var timestamp: Date
        var priority: Int
    }

    public static func load(
        now: Date = .now,
        calendar: Calendar = .current,
        fileManager: FileManager = .default,
        desktopThreadUsages: [CodexDesktopThreadUsage] = [],
        remoteArchives: [CodexRemoteUsageArchive] = []
    ) -> CodexLocalUsageSnapshot {
        load(fromRootURLs: defaultRootURLs, now: now, calendar: calendar, fileManager: fileManager,
             desktopThreadUsages: desktopThreadUsages, remoteArchives: remoteArchives)
    }

    public static func load(
        fromRootURL rootURL: URL,
        now: Date = .now,
        calendar: Calendar = .current,
        fileManager: FileManager = .default,
        desktopThreadUsages: [CodexDesktopThreadUsage] = [],
        remoteArchives: [CodexRemoteUsageArchive] = []
    ) -> CodexLocalUsageSnapshot {
        load(fromRootURLs: [rootURL], now: now, calendar: calendar, fileManager: fileManager,
             desktopThreadUsages: desktopThreadUsages, remoteArchives: remoteArchives)
    }

    public static func load(
        fromRootURLs rootURLs: [URL],
        now: Date = .now,
        calendar: Calendar = .current,
        fileManager: FileManager = .default,
        desktopThreadUsages: [CodexDesktopThreadUsage] = [],
        remoteArchives: [CodexRemoteUsageArchive] = []
    ) -> CodexLocalUsageSnapshot {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let candidateCutoff = firstDay.addingTimeInterval(-86_400)
        var daily: [String: Int64] = [:]
        var hourly: [String: Int64] = [:]
        var exactByThread: [String: [ExactUsage]] = [:]
        var remoteTotals: [String: Int64] = [:]
        var unattributedRemoteTokens: Int64 = 0
        var unattributedRemoteHourlyTokens: Int64 = 0

        // Keep the cumulative coordinates even for old records. Subtracting only
        // the displayed 30-day sum from a lifetime IPC counter creates duplicates.
        for archive in remoteArchives.sorted(by: { $0.capturedAt > $1.capturedAt }) {
            guard (try? archive.validate(now: now)) != nil else { continue }
            for thread in archive.threads {
                let id = thread.threadID.lowercased()
                let records = thread.records.sorted(by: CodexRemoteUsageArchive.recordOrder)
                exactByThread[id, default: []] += exactRecords(records, priority: 0, now: now)
                if records.last.map({ $0.timestamp >= firstDay && $0.timestamp <= now }) == true {
                    remoteTotals[id] = max(remoteTotals[id, default: 0], thread.totalTokens)
                }
            }
        }

        for rootURL in rootURLs {
            guard let enumerator = fileManager.enumerator(
                at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.hasPrefix("rollout-"), fileURL.pathExtension == "jsonl",
                      let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      (values.contentModificationDate ?? .distantPast) >= candidateCutoff else { continue }
                let rollout = localRecords(fileURL: fileURL)
                let id = rollout.threadID ?? threadID(from: fileURL) ?? fileURL.standardizedFileURL.path
                exactByThread[id, default: []] += exactRecords(rollout.records, priority: 1, now: now)
            }
        }

        // A handoff can expose the same logical thread through several hosts.
        var desktopByThread: [String: CodexDesktopThreadUsage] = [:]
        for usage in desktopThreadUsages {
            let activityDate = usage.observedAt ?? usage.updatedAt
            guard usage.totalTokens > 0, activityDate >= firstDay, activityDate <= now,
                  usage.updatedAt <= now, usage.startedAt <= usage.updatedAt,
                  usage.hostID != "local" || usage.startedAt >= firstDay else { continue }
            let id = usage.threadID.lowercased()
            let old = desktopByThread[id]
            if old == nil || usage.totalTokens > old!.totalTokens
                || (usage.totalTokens == old!.totalTokens && usage.intervals != nil && old!.intervals == nil)
                || (usage.totalTokens == old!.totalTokens && (usage.intervals != nil) == (old!.intervals != nil)
                    && usage.updatedAt > old!.updatedAt) {
                desktopByThread[id] = usage
            }
        }

        for id in Set(exactByThread.keys).union(desktopByThread.keys).union(remoteTotals.keys) {
            var covered = CodexUsageTokenCoverage()
            let exact = (exactByThread[id] ?? []).sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                if $0.range.lower != $1.range.lower { return $0.range.lower < $1.range.lower }
                return $0.timestamp < $1.timestamp
            }
            for entry in exact {
                let tokens = covered.uncovered(entry.range).reduce(Int64(0)) { $0 + $1.count }
                covered.insert(entry.range)
                guard tokens > 0, entry.timestamp >= firstDay else { continue }
                add(tokens, at: entry.timestamp, today: today, calendar: calendar, daily: &daily, hourly: &hourly)
            }

            if let usage = desktopByThread[id] {
                let intervals = usage.hostID == "local" ? [CodexDesktopUsageInterval(
                    startedAt: usage.startedAt, endedAt: usage.updatedAt, tokens: usage.totalTokens
                )] : (usage.intervals ?? [CodexDesktopUsageInterval(
                    startedAt: usage.startedAt, endedAt: usage.updatedAt, tokens: usage.totalTokens
                )])
                var cursor: Int64 = 0
                for interval in intervals.sorted(by: { $0.endedAt < $1.endedAt }) {
                    let count = min(max(0, interval.tokens), usage.totalTokens - cursor)
                    let range = CodexUsageTokenRange(lower: cursor, upper: cursor + count)
                    cursor += count
                    let tokens = covered.uncovered(range).reduce(Int64(0)) { $0 + $1.count }
                    guard tokens > 0, interval.endedAt <= now else { continue }
                    covered.insert(range)
                    // A retained counter can include known usage before this
                    // chart window. It is covered, even though it is not drawn.
                    guard interval.endedAt >= firstDay else { continue }
                    if usage.hostID == "local" || (interval.startedAt <= interval.endedAt
                        && calendar.isDate(interval.startedAt, inSameDayAs: interval.endedAt)) {
                        daily[dayKey(for: interval.endedAt, calendar: calendar), default: 0] += tokens
                        if interval.endedAt >= today {
                            if usage.hostID == "local" || calendar.isDate(interval.startedAt, equalTo: interval.endedAt, toGranularity: .hour) {
                                let hour = calendar.component(.hour, from: interval.endedAt)
                                hourly[String(format: "%02d", hour), default: 0] += tokens
                            } else { unattributedRemoteHourlyTokens += tokens }
                        }
                    } else { unattributedRemoteTokens += tokens }
                }
                if usage.hostID != "local" {
                    remoteTotals[id] = max(remoteTotals[id, default: 0], usage.totalTokens)
                }
            }
            // Missing first records remain explicit unknowns, including when a
            // host's archive is available before Desktop has loaded that thread.
            if let total = remoteTotals[id] {
                unattributedRemoteTokens += covered.uncovered(.init(lower: 0, upper: total))
                    .reduce(Int64(0)) { $0 + $1.count }
            }
        }

        return CodexLocalUsageSnapshot(
            dailyBuckets: daily.map { .init(key: $0.key, tokens: $0.value) }.sorted { $0.key < $1.key },
            hourlyBuckets: hourly.map { .init(key: $0.key, tokens: $0.value) }.sorted { $0.key < $1.key },
            capturedAt: now,
            unattributedRemoteTokens: unattributedRemoteTokens > 0 ? unattributedRemoteTokens : nil,
            unattributedRemoteHourlyTokens: unattributedRemoteHourlyTokens > 0 ? unattributedRemoteHourlyTokens : nil
        )
    }

    private static func exactRecords(_ records: [CodexRemoteUsageRecord], priority: Int, now: Date) -> [ExactUsage] {
        var previous: Int64?
        var result: [ExactUsage] = []
        for record in records {
            guard record.timestamp <= now, record.totalTokens >= (previous ?? 0) else { continue }
            let old = previous
            previous = record.totalTokens
            guard old != record.totalTokens else { continue }
            let lower: Int64
            if let last = record.lastTokens, last >= 0, last <= record.totalTokens {
                // A missing prefix or skipped event has no recoverable timestamp.
                lower = max(old ?? 0, record.totalTokens - last)
            } else if let old {
                lower = old
            } else { continue }
            let range = CodexUsageTokenRange(lower: lower, upper: record.totalTokens)
            if range.count > 0 { result.append(.init(range: range, timestamp: record.timestamp, priority: priority)) }
        }
        return result
    }

    private static func localRecords(fileURL: URL) -> (threadID: String?, records: [CodexRemoteUsageRecord]) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return (nil, []) }
        defer { try? handle.close() }
        var canonicalThreadID: String?
        var records: [CodexRemoteUsageRecord] = []
        var counter: Int64 = 0
        func append(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { return }
            if object["type"] as? String == "session_meta" {
                if canonicalThreadID == nil, let id = payload["id"] as? String, UUID(uuidString: id) != nil {
                    canonicalThreadID = id.lowercased()
                }
                return
            }
            guard object["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let text = object["timestamp"] as? String, let timestamp = isoDate(text) else { return }
            let last = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber
            let cumulative = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber
            let total: Int64
            if let cumulative { total = cumulative.int64Value }
            else if let last, last.int64Value > 0, last.int64Value <= Int64.max - counter {
                total = counter + last.int64Value
            } else { return }
            guard total >= counter, total >= 0 else { return }
            counter = total
            records.append(.init(timestamp: timestamp, totalTokens: total, lastTokens: last?.int64Value))
        }
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: streamingChunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            for line in extractCompleteLines(from: &buffer) { append(line) }
        }
        if !buffer.isEmpty { append(String(decoding: buffer, as: UTF8.self)) }
        return (canonicalThreadID, records)
    }

    private static func add(_ tokens: Int64, at timestamp: Date, today: Date, calendar: Calendar,
                            daily: inout [String: Int64], hourly: inout [String: Int64]) {
        daily[dayKey(for: timestamp, calendar: calendar), default: 0] += tokens
        if timestamp >= today {
            hourly[String(format: "%02d", calendar.component(.hour, from: timestamp)), default: 0] += tokens
        }
    }

    private static func extractCompleteLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[..<index]
            buffer.removeSubrange(...index)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func threadID(from fileURL: URL) -> String? {
        let basename = fileURL.deletingPathExtension().lastPathComponent
        // Split copies may append another UUID; the first one identifies the
        // logical thread when the authoritative session_meta header is absent.
        guard let range = basename.range(
            of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            options: .regularExpression
        ) else { return nil }
        let candidate = String(basename[range])
        return UUID(uuidString: candidate) == nil ? nil : candidate.lowercased()
    }
}
