import Foundation
import SQLite3
import Testing
@testable import OpenIslandCore

struct CodexUsageTests {
    @Test
    func codexUsageLoaderParsesLastTokenCountRateLimits() throws {
        let rootURL = temporaryRootURL(named: "codex-usage")
        let rolloutURL = rootURL
            .appendingPathComponent("2026/04/03", isDirectory: true)
            .appendingPathComponent("rollout-latest.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T01:49:35.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "total_tokens": 999_999,
                            ],
                        ],
                        "rate_limits": [
                            "limit_id": "codex",
                            "plan_type": "pro",
                            "primary": [
                                "used_percent": 12.0,
                                "window_minutes": 300,
                                "resets_at": 1_775_158_295,
                            ],
                            "secondary": [
                                "used_percent": 24.0,
                                "window_minutes": 10_080,
                                "resets_at": 1_775_635_184,
                            ],
                        ],
                    ]
                ),
                rolloutLine(
                    timestamp: "2026-04-03T01:50:35.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "total_tokens": 1_234_567,
                            ],
                        ],
                        "rate_limits": [
                            "limit_id": "codex",
                            "plan_type": "pro",
                            "primary": [
                                "used_percent": 13.0,
                                "window_minutes": 300,
                                "resets_at": 1_775_158_295,
                            ],
                            "secondary": [
                                "used_percent": 25.0,
                                "window_minutes": 10_080,
                                "resets_at": 1_775_635_184,
                            ],
                        ],
                    ]
                ),
            ],
            to: rolloutURL
        )
        try setModificationDate(
            Date(timeIntervalSince1970: 2_000),
            for: rolloutURL
        )

        let snapshot = try CodexUsageLoader.load(fromRootURL: rootURL)

        #expect(resolvedPath(snapshot?.sourceFilePath) == rolloutURL.resolvingSymlinksInPath().path)
        #expect(snapshot?.limitID == "codex")
        #expect(snapshot?.planType == "pro")
        #expect(snapshot?.windows.map(\.label) == ["5h", "7d"])
        #expect(snapshot?.windows.map(\.roundedUsedPercentage) == [13, 25])
        #expect(snapshot?.windows.first?.leftPercentage == 87)
        #expect(snapshot?.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_775_158_295))
        #expect(snapshot?.capturedAt == isoDate("2026-04-03T01:50:35.000Z"))
    }

    @Test
    func codexUsageLoaderFallsBackWhenNewestRolloutHasNoRateLimits() throws {
        let rootURL = temporaryRootURL(named: "codex-usage-fallback")
        let oldRolloutURL = rootURL
            .appendingPathComponent("2026/04/02", isDirectory: true)
            .appendingPathComponent("rollout-has-rate-limits.jsonl")
        let newRolloutURL = rootURL
            .appendingPathComponent("2026/04/03", isDirectory: true)
            .appendingPathComponent("rollout-no-rate-limits.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-02T17:54:17.621Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "rate_limits": [
                            "limit_id": "codex",
                            "plan_type": "pro",
                            "primary": [
                                "used_percent": 13.0,
                                "window_minutes": 300,
                                "resets_at": 1_775_158_295,
                            ],
                        ],
                    ]
                ),
            ],
            to: oldRolloutURL
        )
        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T03:00:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "user_message",
                        "message": "Start a fresh session.",
                    ]
                ),
            ],
            to: newRolloutURL
        )

        try setModificationDate(Date(timeIntervalSince1970: 1_000), for: oldRolloutURL)
        try setModificationDate(Date(timeIntervalSince1970: 2_000), for: newRolloutURL)

        let snapshot = try CodexUsageLoader.load(fromRootURL: rootURL)

        #expect(resolvedPath(snapshot?.sourceFilePath) == oldRolloutURL.resolvingSymlinksInPath().path)
        #expect(snapshot?.windows.map(\.label) == ["5h"])
        #expect(snapshot?.windows.first?.roundedUsedPercentage == 13)
    }

    @Test
    func codexUsageLoaderIncludesArchivedSideTasks() throws {
        let rootURL = temporaryRootURL(named: "codex-usage-side-task")
        let sessionsRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        let archivedRootURL = rootURL.appendingPathComponent("archived_sessions", isDirectory: true)
        let activeRolloutURL = sessionsRootURL.appendingPathComponent("rollout-active.jsonl")
        let sideTaskRolloutURL = archivedRootURL.appendingPathComponent("rollout-side-task.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T04:00:00.000Z",
                    type: "event_msg",
                    payload: tokenCountPayload(usedPercentage: 12)
                ),
            ],
            to: activeRolloutURL
        )
        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T05:00:00.000Z",
                    type: "event_msg",
                    payload: tokenCountPayload(usedPercentage: 13)
                ),
            ],
            to: sideTaskRolloutURL
        )

        let snapshot = try CodexUsageLoader.load(
            fromRootURLs: [sessionsRootURL, archivedRootURL]
        )

        #expect(resolvedPath(snapshot?.sourceFilePath) == sideTaskRolloutURL.resolvingSymlinksInPath().path)
        #expect(snapshot?.windows.first?.roundedUsedPercentage == 13)
        #expect(snapshot?.capturedAt == isoDate("2026-04-03T05:00:00.000Z"))
    }

    @Test
    func codexUsageLoaderChoosesLatestEventAcrossConcurrentRollouts() throws {
        let rootURL = temporaryRootURL(named: "codex-usage-concurrent")
        let firstRolloutURL = rootURL.appendingPathComponent("rollout-modified-later.jsonl")
        let secondRolloutURL = rootURL.appendingPathComponent("rollout-event-later.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T04:00:00.000Z",
                    type: "event_msg",
                    payload: tokenCountPayload(usedPercentage: 12)
                ),
            ],
            to: firstRolloutURL
        )
        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T05:00:00.000Z",
                    type: "event_msg",
                    payload: tokenCountPayload(usedPercentage: 13)
                ),
            ],
            to: secondRolloutURL
        )

        try setModificationDate(
            #require(isoDate("2026-04-03T06:00:00.000Z")),
            for: firstRolloutURL
        )
        try setModificationDate(
            #require(isoDate("2026-04-03T05:30:00.000Z")),
            for: secondRolloutURL
        )

        let snapshot = try CodexUsageLoader.load(fromRootURL: rootURL)

        #expect(resolvedPath(snapshot?.sourceFilePath) == secondRolloutURL.resolvingSymlinksInPath().path)
        #expect(snapshot?.windows.first?.roundedUsedPercentage == 13)
        #expect(snapshot?.capturedAt == isoDate("2026-04-03T05:00:00.000Z"))
    }

    @Test
    func codexUsageLoaderFormatsNonStandardWindowLengths() throws {
        let rootURL = temporaryRootURL(named: "codex-usage-labels")
        let rolloutURL = rootURL
            .appendingPathComponent("2026/04/03", isDirectory: true)
            .appendingPathComponent("rollout-custom-window.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T05:30:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "rate_limits": [
                            "primary": [
                                "used_percent": 8.0,
                                "window_minutes": 90,
                                "resets_at": 1_775_200_000,
                            ],
                            "secondary": [
                                "used_percent": 11.0,
                                "window_minutes": 1_500,
                                "resets_at": 1_775_260_000,
                            ],
                        ],
                    ]
                ),
            ],
            to: rolloutURL
        )

        let snapshot = try CodexUsageLoader.load(fromRootURL: rootURL)

        #expect(snapshot?.windows.map(\.label) == ["1h 30m", "1d 1h"])
    }

    @Test
    func localUsageLoaderAggregatesDailyAndCurrentDayHourlyTokens() throws {
        let rootURL = temporaryRootURL(named: "codex-local-history")
        let rolloutURL = rootURL.appendingPathComponent("rollout-history.jsonl")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-07-28T03:15:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": ["last_token_usage": ["total_tokens": 1_200]],
                    ]
                ),
                rolloutLine(
                    timestamp: "2026-07-29T01:10:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": ["last_token_usage": ["total_tokens": 2_000]],
                    ]
                ),
                rolloutLine(
                    timestamp: "2026-07-29T01:45:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": ["last_token_usage": ["total_tokens": 3_000]],
                    ]
                ),
            ],
            to: rolloutURL
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(isoDate("2026-07-29T04:00:00.000Z"))
        try setModificationDate(now, for: rolloutURL)

        let snapshot = CodexLocalUsageLoader.load(
            fromRootURL: rootURL,
            now: now,
            calendar: calendar
        )

        #expect(
            snapshot.dailyBuckets == [
                CodexUsageHistoryBucket(key: "2026-07-28", tokens: 1_200),
                CodexUsageHistoryBucket(key: "2026-07-29", tokens: 5_000),
            ]
        )
        #expect(
            snapshot.hourlyBuckets == [
                CodexUsageHistoryBucket(key: "09", tokens: 5_000),
            ]
        )
    }

    @Test
    func localUsageLoaderIncludesArchivedSideTaskTokens() throws {
        let rootURL = temporaryRootURL(named: "codex-local-side-task")
        let sessionsRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        let archivedRootURL = rootURL.appendingPathComponent("archived_sessions", isDirectory: true)
        let activeRolloutURL = sessionsRootURL.appendingPathComponent("rollout-active.jsonl")
        let sideTaskRolloutURL = archivedRootURL.appendingPathComponent("rollout-side-task.jsonl")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-07-29T01:10:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": ["last_token_usage": ["total_tokens": 2_000]],
                    ]
                ),
            ],
            to: activeRolloutURL
        )
        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-07-29T02:10:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": ["last_token_usage": ["total_tokens": 3_000]],
                    ]
                ),
            ],
            to: sideTaskRolloutURL
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(isoDate("2026-07-29T04:00:00.000Z"))
        try setModificationDate(now, for: activeRolloutURL)
        try setModificationDate(now, for: sideTaskRolloutURL)

        let snapshot = CodexLocalUsageLoader.load(
            fromRootURLs: [sessionsRootURL, archivedRootURL],
            now: now,
            calendar: calendar
        )

        #expect(
            snapshot.dailyBuckets == [
                CodexUsageHistoryBucket(key: "2026-07-29", tokens: 5_000),
            ]
        )
        #expect(
            snapshot.hourlyBuckets == [
                CodexUsageHistoryBucket(key: "09", tokens: 2_000),
                CodexUsageHistoryBucket(key: "10", tokens: 3_000),
            ]
        )
    }

    @Test
    func localUsageLoaderAddsOnlyDesktopTokensMissingFromRollout() throws {
        let rootURL = temporaryRootURL(named: "codex-local-ipc-delta")
        let threadID = "019fb0ab-c4d7-77d0-802d-0bcefdb2d789"
        let rolloutURL = rootURL.appendingPathComponent(
            "rollout-2026-07-30T01-00-00-\(threadID).jsonl"
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-07-30T01:10:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": ["last_token_usage": ["total_tokens": 2_000]],
                    ]
                ),
            ],
            to: rolloutURL
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(isoDate("2026-07-30T04:00:00.000Z"))
        let updatedAt = try #require(isoDate("2026-07-30T02:15:00.000Z"))
        let startedAt = try #require(isoDate("2026-07-30T00:00:00.000Z"))
        try setModificationDate(now, for: rolloutURL)

        let snapshot = CodexLocalUsageLoader.load(
            fromRootURL: rootURL,
            now: now,
            calendar: calendar,
            desktopThreadUsages: [
                CodexDesktopThreadUsage(
                    threadID: threadID,
                    totalTokens: 5_000,
                    updatedAt: updatedAt,
                    startedAt: startedAt
                ),
            ]
        )

        #expect(
            snapshot.dailyBuckets == [
                CodexUsageHistoryBucket(key: "2026-07-30", tokens: 5_000),
            ]
        )
        #expect(
            snapshot.hourlyBuckets == [
                CodexUsageHistoryBucket(key: "09", tokens: 2_000),
                CodexUsageHistoryBucket(key: "10", tokens: 3_000),
            ]
        )
    }

    @Test
    func desktopIPCUsageDecodesSnapshotTokenTotal() throws {
        let threadID = "019fb0ab-c4d7-77d0-802d-0bcefdb2d789"
        let message: [String: Any] = [
            "type": "broadcast",
            "method": "thread-stream-state-changed",
            "params": [
                "conversationId": threadID,
                "change": [
                    "type": "snapshot",
                    "conversationState": [
                        "latestTokenUsageInfo": [
                            "total": ["totalTokens": 17_910_141],
                        ],
                    ],
                ],
            ],
        ]

        #expect(
            CodexDesktopIPCUsageLoader.tokenTotal(from: message, threadID: threadID)
                == 17_910_141
        )
    }

    @Test
    func desktopThreadDiscoveryFindsOnlyThreadsStartedAfterCutoff() throws {
        let rootURL = temporaryRootURL(named: "codex-thread-discovery")
        let databaseURL = rootURL.appendingPathComponent("logs.sqlite")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var database: OpaquePointer?
        try #require(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let oldThread = "019fae43-b69b-7421-9062-c986585f3b02"
        let recentThread = "019fb0ab-c4d7-77d0-802d-0bcefdb2d789"
        let sql = """
            CREATE TABLE logs (thread_id TEXT, ts INTEGER);
            INSERT INTO logs VALUES ('\(oldThread)', 100);
            INSERT INTO logs VALUES ('\(oldThread)', 300);
            INSERT INTO logs VALUES ('\(recentThread)', 250);
            INSERT INTO logs VALUES ('\(recentThread)', 350);
            """
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)

        let threads = CodexDesktopThreadDiscovery.load(
            databaseURL: databaseURL,
            since: Date(timeIntervalSince1970: 200)
        )

        #expect(threads.map(\.id) == [recentThread])
        #expect(threads.first?.startedAt == Date(timeIntervalSince1970: 250))
        #expect(threads.first?.updatedAt == Date(timeIntervalSince1970: 350))
    }
}

private func temporaryRootURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("open-island-\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func writeRollout(_ lines: [String], to url: URL) throws {
    let directoryURL = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
}

private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private func isoDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}

private func resolvedPath(_ value: String?) -> String? {
    guard let value else {
        return nil
    }

    return URL(fileURLWithPath: value).resolvingSymlinksInPath().path
}

private func rolloutLine(
    timestamp: String,
    type: String,
    payload: [String: Any]
) -> String {
    let object: [String: Any] = [
        "timestamp": timestamp,
        "type": type,
        "payload": payload,
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func tokenCountPayload(usedPercentage: Double) -> [String: Any] {
    [
        "type": "token_count",
        "rate_limits": [
            "limit_id": "codex",
            "plan_type": "pro",
            "primary": [
                "used_percent": usedPercentage,
                "window_minutes": 300,
                "resets_at": 1_775_158_295,
            ],
        ],
    ]
}
