import Foundation
import Testing
@testable import OpenIslandCore

struct CodexRemoteUsageArchiveTests {
    private let id = "01a15e64-95c8-71e1-be24-297427a9a825"
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-10-03T12:00:00Z") }
    private func record(_ total: Int64, _ last: Int64?, _ time: String) -> CodexRemoteUsageRecord {
        .init(timestamp: date(time), totalTokens: total, lastTokens: last)
    }
    private func archive(_ records: [CodexRemoteUsageRecord]) -> CodexRemoteUsageArchive {
        .init(hostID: "remote-control:test", capturedAt: now,
              threads: [.init(threadID: id, totalTokens: records.map(\.totalTokens).max() ?? 0, records: records)])
    }
    private func snapshot(_ archives: [CodexRemoteUsageArchive], ipc: [CodexDesktopThreadUsage] = [],
                          roots: [URL] = []) -> CodexLocalUsageSnapshot {
        CodexLocalUsageLoader.load(fromRootURLs: roots, now: now, calendar: calendar,
                                   desktopThreadUsages: ipc, remoteArchives: archives)
    }

    @Test func offlineCrossDayHistoryReplacesUnknownIPCBaseline() {
        let source = archive([record(100, 100, "2026-10-01T09:00:00Z"),
                              record(300, 200, "2026-10-03T10:00:00Z")])
        let ipc = CodexDesktopThreadUsage(threadID: id, totalTokens: 300,
            updatedAt: date("2026-10-03T10:00:00Z"), startedAt: date("2026-10-01T08:00:00Z"),
            hostID: source.hostID)
        let result = snapshot([source], ipc: [ipc])
        #expect(result.dailyBuckets == [.init(key: "2026-10-01", tokens: 100), .init(key: "2026-10-03", tokens: 200)])
        #expect(result.hourlyBuckets == [.init(key: "10", tokens: 200)])
        #expect(result.unattributedRemoteTokens == nil)
    }

    @Test func repeatedCountersAndRepeatedArchivesCountOnce() {
        let source = archive([record(100, 100, "2026-10-01T09:00:00Z"),
                              record(100, 100, "2026-10-01T10:00:00Z"),
                              record(120, 20, "2026-10-03T10:00:00Z")])
        let result = snapshot([source, source])
        #expect(result.dailyBuckets == [.init(key: "2026-10-01", tokens: 100), .init(key: "2026-10-03", tokens: 20)])
    }

    @Test func newerIPCTailSurvivesBackfill() {
        let source = archive([record(100, 100, "2026-10-01T09:00:00Z")])
        let ipc = CodexDesktopThreadUsage(threadID: id, totalTokens: 150,
            updatedAt: date("2026-10-03T11:05:00Z"), startedAt: date("2026-10-01T08:00:00Z"),
            hostID: source.hostID, intervals: [
                .init(startedAt: date("2026-10-01T08:00:00Z"), endedAt: date("2026-10-03T10:00:00Z"), tokens: 100),
                .init(startedAt: date("2026-10-03T11:00:00Z"), endedAt: date("2026-10-03T11:05:00Z"), tokens: 50)])
        let result = snapshot([source], ipc: [ipc])
        #expect(result.dailyBuckets == [.init(key: "2026-10-01", tokens: 100), .init(key: "2026-10-03", tokens: 50)])
        #expect(result.hourlyBuckets == [.init(key: "11", tokens: 50)])
        #expect(result.unattributedRemoteTokens == nil)
    }

    @Test func incompleteFirstCounterRetainsUnknownPrefixAndMissingEventGap() {
        let source = archive([record(100, 20, "2026-10-01T09:00:00Z"),
                              record(150, 10, "2026-10-03T10:00:00Z")])
        let result = snapshot([source])
        #expect(result.dailyBuckets == [.init(key: "2026-10-01", tokens: 20), .init(key: "2026-10-03", tokens: 10)])
        #expect(result.unattributedRemoteTokens == 120)
    }

    @Test func oldExactCounterPrefixDoesNotReappearAsUnknownInCurrentWindow() {
        let source = archive([record(100, 100, "2026-08-01T09:00:00Z"),
                              record(150, 50, "2026-10-03T10:00:00Z")])
        let ipc = CodexDesktopThreadUsage(threadID: id, totalTokens: 150,
            updatedAt: date("2026-10-03T10:00:00Z"), startedAt: date("2026-08-01T08:00:00Z"), hostID: source.hostID)
        let result = snapshot([source], ipc: [ipc])
        #expect(result.dailyBuckets == [.init(key: "2026-10-03", tokens: 50)])
        #expect(result.unattributedRemoteTokens == nil)
    }

    @Test func oldObservedCounterPrefixStaysOutsideWindowAfterNewActivity() {
        let ipc = CodexDesktopThreadUsage(threadID: id, totalTokens: 150,
            updatedAt: date("2026-10-03T11:05:00Z"), startedAt: date("2026-08-01T08:00:00Z"),
            hostID: "remote-control:test", intervals: [
                .init(startedAt: date("2026-08-01T08:00:00Z"), endedAt: date("2026-08-01T09:00:00Z"), tokens: 100),
                .init(startedAt: date("2026-10-03T11:00:00Z"), endedAt: date("2026-10-03T11:05:00Z"), tokens: 50)])
        let result = snapshot([], ipc: [ipc])
        #expect(result.dailyBuckets == [.init(key: "2026-10-03", tokens: 50)])
        #expect(result.unattributedRemoteTokens == nil)
    }

    @Test func localCopiesAndIPCDoNotDuplicateRemoteCounterRanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = """
        {"type":"event_msg","timestamp":"2026-10-03T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100},"last_token_usage":{"total_tokens":100}}}}
        """
        for prefix in ["active", "archived"] {
            let file = root.appendingPathComponent("rollout-\(prefix)-\(id).jsonl")
            try Data((json + "\n" + json).utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }
        let source = archive([record(100, 100, "2026-10-03T10:00:00Z")])
        let ipc = CodexDesktopThreadUsage(threadID: id, totalTokens: 100,
            updatedAt: date("2026-10-03T10:00:00Z"), startedAt: date("2026-10-03T09:00:00Z"), hostID: source.hostID)
        let result = snapshot([source], ipc: [ipc], roots: [root])
        #expect(result.dailyBuckets == [.init(key: "2026-10-03", tokens: 100)])
        #expect(result.hourlyBuckets == [.init(key: "10", tokens: 100)])
        #expect(result.unattributedRemoteTokens == nil)
    }

    @Test func cacheMergeIsIdempotentAndInvalidImportKeepsPreviousData() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("usage.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = CodexRemoteUsageArchiveStore(fileURL: file)
        let source = archive([record(100, 100, "2026-10-03T10:00:00Z")])
        try store.merge(source, now: now)
        try store.merge(source, now: now)
        #expect(store.load(now: now) == [source])
        let empty = CodexRemoteUsageArchive(hostID: source.hostID, capturedAt: now, threads: [])
        try store.merge(empty, now: now)
        #expect(store.load(now: now) == [source])
        var invalid = source
        invalid.threads[0].totalTokens = 200
        #expect(throws: CodexRemoteUsageArchiveError.invalidArchive) { try store.merge(invalid, now: now) }
        #expect(store.load(now: now) == [source])
        invalid = archive([record(100, 100, "2026-10-03T10:00:00Z"), record(90, 10, "2026-10-03T11:00:00Z")])
        #expect(throws: CodexRemoteUsageArchiveError.invalidArchive) { try invalid.validate(now: now) }
    }

    @Test func numericEpochWireSupportsFractionalSecondsAndRejectsTruncation() throws {
        let raw = """
        {"version":1,"hostID":"remote:test","capturedAt":1791028800.5,"threads":[{"threadID":"\(id)","totalTokens":100,"records":[{"timestamp":1791021600.25,"totalTokens":100,"lastTokens":100}]}]}
        """
        let decoded = try CodexRemoteUsageArchiveStore.decode(Data(raw.utf8), now: now)
        #expect(decoded.threads[0].records[0].timestamp.timeIntervalSince1970 == 1791021600.25)
        #expect(throws: (any Error).self) {
            try CodexRemoteUsageArchiveStore.decode(Data(raw.dropLast().utf8), now: now)
        }
    }

    @Test func rediscoveredEarlierCheckpointReplacesLaterDuplicateObservation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("usage.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = CodexRemoteUsageArchiveStore(fileURL: file)
        try store.merge(archive([record(100, 100, "2026-10-03T11:00:00Z")]), now: now)
        let recovered = archive([record(100, 100, "2026-10-01T09:00:00Z"),
                                 record(150, 50, "2026-10-02T10:00:00Z")])
        try store.merge(recovered, now: now)
        try store.merge(recovered, now: now)
        let retained = store.load(now: now)
        #expect(retained == [recovered])
        #expect(snapshot(retained).dailyBuckets == [
            .init(key: "2026-10-01", tokens: 100), .init(key: "2026-10-02", tokens: 50)])
    }
}
