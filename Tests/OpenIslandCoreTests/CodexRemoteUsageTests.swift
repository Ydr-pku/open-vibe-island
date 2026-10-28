import Foundation
import Testing
@testable import OpenIslandCore

struct CodexRemoteUsageTests {
    private let remoteHost = "remote-control:test-host"
    private let threadID = "01a15e64-95c8-71e1-be24-297427a9a825"

    @Test
    func remoteSnapshotRequiresMatchingHostAndUsesActualThreadTimes() {
        let created = date("2026-10-01T08:00:00Z")
        let updated = date("2026-10-02T09:00:00Z")
        let message: [String: Any] = [
            "type": "broadcast", "method": "thread-stream-state-changed",
            "params": ["conversationId": threadID, "hostId": remoteHost,
                       "change": ["type": "snapshot", "conversationState": [
                        "createdAt": created.timeIntervalSince1970 * 1_000,
                        "updatedAt": updated.timeIntervalSince1970 * 1_000,
                        "latestTokenUsageInfo": ["total": ["totalTokens": 42_000]]
                       ]]]
        ]
        let thread = CodexDesktopIPCUsageLoader.Thread(id: threadID, updatedAt: .distantPast, startedAt: .distantPast, hostID: remoteHost)
        let usage = CodexDesktopIPCUsageLoader.threadUsage(from: message, thread: thread)
        #expect(usage?.hostID == remoteHost)
        #expect(usage?.totalTokens == 42_000)
        #expect(usage?.startedAt == created)
        #expect(usage?.updatedAt == updated)
        #expect(CodexDesktopIPCUsageLoader.tokenTotal(from: message, threadID: threadID) == nil)
        #expect(CodexDesktopIPCUsageLoader.tokenTotal(from: message, threadID: threadID, hostID: "other") == nil)
    }

    @Test
    func remoteDiscoveryUsesProjectRoutingAndExplicitMembershipWithoutInventingHosts() throws {
        let file = temporaryURL("remote-state.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let second = "019fb0ab-c4d7-77d0-802d-0bcefdb2d789"
        let state: [String: Any] = [
            "remote-projects": [["id": "p", "hostId": remoteHost]],
            "thread-project-assignments": [threadID: ["projectKind": "remote", "projectId": "p"],
                                            second: ["projectKind": "remote", "projectId": "p"]],
            "thread-project-membership-host-ids": [second: "local", "not-a-thread": remoteHost]
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: file)
        let threads = CodexDesktopThreadDiscovery.loadRemote(globalStateURL: file)
        #expect(threads.map(\.id) == [threadID])
        #expect(threads.first?.hostID == remoteHost)
        #expect(threads.first?.startedAt.timeIntervalSince1970 ?? 0 > 0)
    }

    @Test
    func legacyCacheDecodesAndHostSpecificCountersDoNotOverwriteEachOther() throws {
        let file = temporaryURL("usage.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let legacy = """
        [{"threadID":"\(threadID)","totalTokens":100,"updatedAt":"2026-10-02T09:00:00Z","startedAt":"2026-10-02T08:00:00Z"}]
        """
        try Data(legacy.utf8).write(to: file)
        let now = date("2026-10-02T10:00:00Z")
        let store = CodexDesktopThreadUsageStore(fileURL: file)
        let merged = store.loadAndMerge(liveUsages: [usage(150, start: "2026-10-02T08:00:00Z", end: "2026-10-02T09:00:00Z")], now: now)
        #expect(merged.count == 2)
        #expect(Set(merged.map(\.hostID)) == ["local", remoteHost])
        #expect(merged.first(where: { $0.hostID == "local" })?.totalTokens == 100)
        #expect(store.loadAndMerge(liveUsages: [], now: now) == merged)
    }

    @Test
    func remoteDailyHistoryPersistsAndDoesNotMoveWithTheNextSample() throws {
        let file = temporaryURL("usage.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = CodexDesktopThreadUsageStore(fileURL: file)
        let initial = usage(100_000, start: "2026-10-01T08:00:00Z", end: "2026-10-01T09:00:00Z")
        _ = store.loadAndMerge(liveUsages: [initial], now: date("2026-10-01T09:00:00Z"))
        // A zero-delta sample establishes a fresh lower bound on the next day.
        _ = store.loadAndMerge(liveUsages: [initial], now: date("2026-10-02T09:00:00Z"))
        let higher = usage(100_030, start: "2026-10-01T08:00:00Z", end: "2026-10-01T09:00:00Z")
        _ = store.loadAndMerge(liveUsages: [higher], now: date("2026-10-02T09:05:00Z"))
        let retained = store.loadAndMerge(liveUsages: [higher], now: date("2026-10-03T09:00:00Z"))
        let result = snapshot(retained, now: "2026-10-03T10:00:00Z")
        #expect(result.dailyBuckets == [
            .init(key: "2026-10-01", tokens: 100_000), .init(key: "2026-10-02", tokens: 30)
        ])
        #expect(result.hourlyBuckets.isEmpty)
        #expect(result.unattributedRemoteTokens == nil)
    }

    @Test
    func unknownMultiDayBaselineIsExplicitAndOldThreadsCanAccumulateNewUsage() throws {
        let file = temporaryURL("usage.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = CodexDesktopThreadUsageStore(fileURL: file)
        let initial = usage(90_000, start: "2026-08-01T08:00:00Z", end: "2026-10-02T09:00:00Z")
        _ = store.loadAndMerge(liveUsages: [initial], now: date("2026-10-02T09:00:00Z"))
        let higher = usage(90_050, start: "2026-08-01T08:00:00Z", end: "2026-10-02T09:00:00Z")
        let retained = store.loadAndMerge(liveUsages: [higher], now: date("2026-10-02T09:05:00Z"))
        let result = snapshot(retained, now: "2026-10-02T10:00:00Z")
        #expect(result.dailyBuckets == [.init(key: "2026-10-02", tokens: 50)])
        #expect(result.hourlyBuckets == [.init(key: "09", tokens: 50)])
        #expect(result.unattributedRemoteTokens == 90_000)
    }

    @Test
    func invalidLargerHostCounterCannotHideAValidThreadCounter() {
        let valid = usage(100, start: "2026-10-02T08:00:00Z", end: "2026-10-02T09:00:00Z")
        var future = valid
        future.hostID = "other-host"
        future.totalTokens = 50_000
        future.updatedAt = date("2026-10-03T09:00:00Z")
        var invalidStart = valid
        invalidStart.hostID = "invalid-clock-host"
        invalidStart.totalTokens = 60_000
        invalidStart.startedAt = date("2026-10-03T08:00:00Z")
        let result = snapshot([future, invalidStart, valid], now: "2026-10-02T10:00:00Z")
        #expect(result.dailyBuckets == [.init(key: "2026-10-02", tokens: 100)])
    }

    @Test
    func handoffCopiesAndLocalRolloutAreCountedOnce() throws {
        let root = temporaryURL("rollout-2026-10-02-\(threadID).jsonl")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let event = """
        {"type":"event_msg","timestamp":"2026-10-02T09:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":2000}}}}
        """
        try Data(event.utf8).write(to: root)
        try FileManager.default.setAttributes([.modificationDate: date("2026-10-02T10:00:00Z")], ofItemAtPath: root.path)
        let remote = CodexDesktopThreadUsage(threadID: threadID, totalTokens: 5_000,
            updatedAt: date("2026-10-02T10:00:00Z"), startedAt: date("2026-10-02T08:00:00Z"), hostID: remoteHost,
            intervals: [.init(startedAt: date("2026-10-02T08:00:00Z"), endedAt: date("2026-10-02T09:00:00Z"), tokens: 2_000),
                        .init(startedAt: date("2026-10-02T10:00:00Z"), endedAt: date("2026-10-02T10:05:00Z"), tokens: 3_000)])
        var local = remote
        local.hostID = "local"
        local.intervals = nil
        let result = CodexLocalUsageLoader.load(fromRootURL: root.deletingLastPathComponent(),
            now: date("2026-10-02T11:00:00Z"), calendar: utcCalendar,
            desktopThreadUsages: [local, remote])
        #expect(result.dailyBuckets == [.init(key: "2026-10-02", tokens: 5_000)])
        #expect(result.hourlyBuckets == [.init(key: "09", tokens: 2_000), .init(key: "10", tokens: 3_000)])
    }

    private func usage(_ tokens: Int64, start: String, end: String) -> CodexDesktopThreadUsage {
        .init(threadID: threadID, totalTokens: tokens, updatedAt: date(end), startedAt: date(start), hostID: remoteHost)
    }

    private func snapshot(_ usages: [CodexDesktopThreadUsage], now: String) -> CodexLocalUsageSnapshot {
        CodexLocalUsageLoader.load(fromRootURLs: [], now: date(now), calendar: utcCalendar, desktopThreadUsages: usages)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func temporaryURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-remote-usage-\(UUID())")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
