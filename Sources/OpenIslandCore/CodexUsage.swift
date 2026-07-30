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
    public var lifetimeTokens: Int64
    public var peakDailyTokens: Int64
    public var longestRunningTurnSeconds: Int
    public var currentStreakDays: Int
    public var longestStreakDays: Int

    public init(
        lifetimeTokens: Int64,
        peakDailyTokens: Int64,
        longestRunningTurnSeconds: Int,
        currentStreakDays: Int,
        longestStreakDays: Int
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

    public init(
        dailyBuckets: [CodexUsageHistoryBucket],
        hourlyBuckets: [CodexUsageHistoryBucket],
        capturedAt: Date
    ) {
        self.dailyBuckets = dailyBuckets
        self.hourlyBuckets = hourlyBuckets
        self.capturedAt = capturedAt
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

    public static func load(
        fromRootURL rootURL: URL = CodexRolloutDiscovery.defaultRootURL,
        now: Date = .now,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) -> CodexLocalUsageSnapshot {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let candidateCutoff = firstDay.addingTimeInterval(-86_400)
        var daily: [String: Int64] = [:]
        var hourly: [String: Int64] = [:]

        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return CodexLocalUsageSnapshot(
                dailyBuckets: [],
                hourlyBuckets: [],
                capturedAt: now
            )
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl",
                  let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= candidateCutoff else {
                continue
            }

            accumulate(
                fileURL: fileURL,
                firstDay: firstDay,
                today: today,
                now: now,
                calendar: calendar,
                daily: &daily,
                hourly: &hourly
            )
        }

        return CodexLocalUsageSnapshot(
            dailyBuckets: daily
                .map { CodexUsageHistoryBucket(key: $0.key, tokens: $0.value) }
                .sorted { $0.key < $1.key },
            hourlyBuckets: hourly
                .map { CodexUsageHistoryBucket(key: $0.key, tokens: $0.value) }
                .sorted { $0.key < $1.key },
            capturedAt: now
        )
    }

    private static func accumulate(
        fileURL: URL,
        firstDay: Date,
        today: Date,
        now: Date,
        calendar: Calendar,
        daily: inout [String: Int64],
        hourly: inout [String: Int64]
    ) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return
        }
        defer { try? handle.close() }

        var buffer = Data()
        while let chunk = try? handle.read(upToCount: streamingChunkSize),
              !chunk.isEmpty {
            buffer.append(chunk)
            for line in extractCompleteLines(from: &buffer) {
                accumulate(
                    line: line,
                    firstDay: firstDay,
                    today: today,
                    now: now,
                    calendar: calendar,
                    daily: &daily,
                    hourly: &hourly
                )
            }
        }
        if !buffer.isEmpty {
            accumulate(
                line: String(decoding: buffer, as: UTF8.self),
                firstDay: firstDay,
                today: today,
                now: now,
                calendar: calendar,
                daily: &daily,
                hourly: &hourly
            )
        }
    }

    private static func accumulate(
        line: String,
        firstDay: Date,
        today: Date,
        now: Date,
        calendar: Calendar,
        daily: inout [String: Int64],
        hourly: inout [String: Int64]
    ) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let lastUsage = info["last_token_usage"] as? [String: Any],
              let tokenNumber = lastUsage["total_tokens"] as? NSNumber,
              tokenNumber.int64Value > 0,
              let timestampText = object["timestamp"] as? String,
              let timestamp = isoDate(timestampText),
              timestamp >= firstDay,
              timestamp <= now else {
            return
        }

        let dayKey = dayKey(for: timestamp, calendar: calendar)
        daily[dayKey, default: 0] += tokenNumber.int64Value

        if timestamp >= today {
            let hour = calendar.component(.hour, from: timestamp)
            let hourKey = String(format: "%02d", hour)
            hourly[hourKey, default: 0] += tokenNumber.int64Value
        }
    }

    private static func extractCompleteLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            if !lineData.isEmpty {
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
        }
        return lines
    }

    private static func isoDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
