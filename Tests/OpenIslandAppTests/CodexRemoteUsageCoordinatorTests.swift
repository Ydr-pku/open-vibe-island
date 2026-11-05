import Foundation
import Testing
import OpenIslandCore
@testable import OpenIslandApp

@MainActor
struct CodexRemoteUsageCoordinatorTests {
    private let hostID = "remote-control:test-environment"
    private let threadID = "01a19099-59ed-7a43-b41f-7d5462f1c4eb"

    @Test
    func failedReconnectKeepsRecoveredHistoryAvailable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodexRemoteUsageArchiveStore(fileURL: root.appendingPathComponent("archive.json"))
        let archive = makeArchive(tokens: 100)
        try store.merge(archive)
        let cacheBeforeFailure = try Data(contentsOf: store.fileURL)
        let hooks = makeCoordinator(root: root, store: store, runner: { _, _, _, _, _ in
            throw CodexRemoteUsageSyncError.timedOut
        })
        try hooks.saveCodexRemoteUsageSource(.init(hostID: hostID, sshAlias: "server"))
        try await waitUntil { !hooks.isCodexRemoteUsageSyncing && hooks.codexLocalUsageSnapshot != nil }
        #expect(hooks.codexRemoteUsageError != nil)
        #expect(try Data(contentsOf: store.fileURL) == cacheBeforeFailure)
        #expect(hooks.codexLocalUsageSnapshot?.dailyBuckets.reduce(0) { $0 + $1.tokens } == 100)
    }

    @Test
    func completedBackfillRebuildsAnAlreadyRunningHistoryRefresh() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodexRemoteUsageArchiveStore(fileURL: root.appendingPathComponent("archive.json"))
        let data = try response(makeArchive(tokens: 100))
        let hooks = makeCoordinator(root: root, store: store, runner: { _, _, _, _, _ in data })
        let gate = HistoryGate()
        hooks.codexLocalUsageHistoryProvider = { _, archives in
            await gate.holdFirstCall()
            return CodexLocalUsageLoader.load(fromRootURLs: [], remoteArchives: archives)
        }
        hooks.refreshCodexUsageHistoryState(refreshRemote: false)
        try await waitUntil { await gate.entered }
        try hooks.saveCodexRemoteUsageSource(.init(hostID: hostID, sshAlias: "server"))
        try await waitUntil { !hooks.isCodexRemoteUsageSyncing && !store.load().isEmpty }
        await gate.release()
        try await waitUntil { hooks.codexLocalUsageSnapshot?.dailyBuckets.reduce(0) { $0 + $1.tokens } == 100 }
        #expect(hooks.codexLocalUsageSnapshot?.unattributedRemoteTokens == nil)
        hooks.refreshCodexRemoteUsageHistory()
        try await waitUntil { !hooks.isCodexRemoteUsageSyncing }
        #expect(store.load().first?.threads.first?.records.count == 1)
    }

    @Test
    func replacingSourceWaitsForCancelledSyncAndUsesTheNewProfile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodexRemoteUsageArchiveStore(fileURL: root.appendingPathComponent("archive.json"))
        let first = try response(makeArchive(tokens: 100))
        let second = try response(makeArchive(tokens: 200))
        let probe = SourceProbe(first: first, second: second)
        let hooks = makeCoordinator(root: root, store: store, runner: { _, arguments, _, _, _ in
            await probe.run(arguments)
        })
        try hooks.saveCodexRemoteUsageSource(.init(hostID: hostID, sshAlias: "first"))
        try await waitUntil { await probe.calls == 1 }
        try hooks.saveCodexRemoteUsageSource(.init(hostID: hostID, sshAlias: "second"))
        try await waitUntil { !hooks.isCodexRemoteUsageSyncing && store.load().first?.threads.first?.totalTokens == 200 }
        #expect(await probe.calls == 2)
        #expect(hooks.codexRemoteUsageSources.first?.sshAlias == "second")
        #expect(hooks.codexRemoteUsageError == nil)
    }

    private func makeCoordinator(root: URL, store: CodexRemoteUsageArchiveStore,
                                 runner: @escaping CodexRemoteUsageSync.Runner) -> HookInstallationCoordinator {
        let hooks = HookInstallationCoordinator(
            remoteUsageSync: CodexRemoteUsageSync(runner: runner), remoteUsageArchiveStore: store,
            remoteUsageSourcesURL: root.appendingPathComponent("sources.json")
        )
        hooks.codexLocalUsageHistoryProvider = { _, archives in
            CodexLocalUsageLoader.load(fromRootURLs: [], remoteArchives: archives)
        }
        return hooks
    }

    private func makeArchive(tokens: Int64) -> CodexRemoteUsageArchive {
        .init(hostID: hostID, capturedAt: .now, threads: [
            .init(threadID: threadID, totalTokens: tokens, records: [
                .init(timestamp: .now.addingTimeInterval(-60), totalTokens: tokens, lastTokens: tokens)
            ])
        ])
    }

    private func response(_ archive: CodexRemoteUsageArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(archive)) as? [String: Any])
        object["complete"] = true
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}

private actor HistoryGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func holdFirstCall() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor SourceProbe {
    let first: Data
    let second: Data
    var calls = 0
    init(first: Data, second: Data) { self.first = first; self.second = second }
    func run(_ arguments: [String]) async -> Data {
        calls += 1
        if arguments.contains("first") {
            // Deliberately finish after cancellation to exercise stale-result guards.
            try? await Task.sleep(for: .milliseconds(200))
            return first
        }
        return second
    }
}
