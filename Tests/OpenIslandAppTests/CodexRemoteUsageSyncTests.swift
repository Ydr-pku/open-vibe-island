import Foundation
import Testing
@testable import OpenIslandApp

struct CodexRemoteUsageSyncTests {
    private let hostID = "remote-control:test-environment"

    @Test
    func exporterKeepsOnlyUsageAndDeduplicatesArchivesAndRepeatedSnapshots() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = "01a19099-59ed-7a43-b41f-7d5462f1c4eb"
        let sessions = root.appendingPathComponent("sessions")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let contents = """
        {"type":"response_item","payload":{"body":"private prompt must stay remote"}}
        {"type":"event_msg","timestamp":"2026-11-01T23:59:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100},"last_token_usage":{"total_tokens":100}}}}
        {"type":"event_msg","timestamp":"2026-11-02T00:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100},"last_token_usage":{"total_tokens":100}}}}
        {"type":"event_msg","timestamp":"2026-11-02T00:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":140},"last_token_usage":{"total_tokens":40}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":null}}
        """ + "\n"
        for directory in [sessions, archived] {
            try Data(contents.utf8).write(to: directory.appendingPathComponent("rollout-\(threadID).jsonl"))
        }
        let output = try await runExporter(root: root)
        let raw = String(decoding: output, as: UTF8.self)
        #expect(!raw.contains("private prompt"))
        #expect(!raw.contains("response_item"))
        let value = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(value["complete"] as? Bool == true)
        #expect(value["duplicateCheckpoints"] as? Int == 4)
        let threads = try #require(value["threads"] as? [[String: Any]])
        #expect(threads.count == 1)
        #expect(threads[0]["threadID"] as? String == threadID)
        #expect(threads[0]["totalTokens"] as? Int == 140)
        let records = try #require(threads[0]["records"] as? [[String: Any]])
        #expect(records.count == 2)
        #expect(records[0]["timestamp"] as? Double == ISO8601DateFormatter().date(from: "2026-11-01T23:59:00Z")?.timeIntervalSince1970)
    }

    @Test
    func sessionMetadataOwnsRenamedAndSplitLogIdentity() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = "01a17795-9d40-74f3-8444-fe00bf19bcc3"
        let child = "01a17bf8-95c8-71e1-be24-297427a99ed4"
        let prefix = """
        {"type":"session_meta","payload":{"id":"\(original)"}}
        {"type":"event_msg","timestamp":"2026-11-01T23:59:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100},"last_token_usage":{"total_tokens":100}}}}
        """ + "\n"
        let suffix = """
        {"type":"session_meta","payload":{"id":"\(original)"}}
        {"type":"event_msg","timestamp":"2026-11-02T00:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":140},"last_token_usage":{"total_tokens":40}}}}
        """ + "\n"
        try Data(prefix.utf8).write(to: directory.appendingPathComponent("rollout-\(original).jsonl"))
        try Data(suffix.utf8).write(to: directory.appendingPathComponent("rollout-\(original)_\(child).jsonl"))
        let value = try #require(JSONSerialization.jsonObject(with: try await runExporter(root: root)) as? [String: Any])
        let threads = try #require(value["threads"] as? [[String: Any]])
        #expect(threads.count == 1)
        #expect(threads[0]["threadID"] as? String == original)
        #expect(threads[0]["totalTokens"] as? Int == 140)
        #expect((threads[0]["records"] as? [[String: Any]])?.count == 2)
    }

    @Test
    func inheritedParentMetadataDoesNotMergeIndependentForkCounters() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = "01a15ec8-95c8-71e1-be24-297427a9a825"
        let children = ["01a15ecb-95c8-71e1-be24-297427a9a825", "01a15ecc-95c8-71e1-be24-297427a9a825"]
        for (index, child) in children.enumerated() {
            let total = 40_000 + index
            let contents = """
            {"type":"session_meta","payload":{"id":"\(child)"}}
            {"type":"response_item","payload":{"body":"inherited context"}}
            {"type":"session_meta","payload":{"id":"\(parent)"}}
            {"type":"event_msg","timestamp":"2026-11-02T00:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(total)},"last_token_usage":{"total_tokens":\(total)}}}}
            """ + "\n"
            try Data(contents.utf8).write(to: directory.appendingPathComponent("rollout-\(child).jsonl"))
        }
        let value = try #require(JSONSerialization.jsonObject(with: try await runExporter(root: root)) as? [String: Any])
        let threads = try #require(value["threads"] as? [[String: Any]])
        #expect(threads.count == 2)
        #expect(Set(threads.compactMap { $0["threadID"] as? String }) == Set(children))
        #expect(threads.compactMap { $0["totalTokens"] as? Int }.reduce(0, +) == 80_001)
        #expect(!threads.contains { $0["threadID"] as? String == parent })
    }

    @Test
    func conflictingCopiesRetainAnUnknownCumulativeAnchorWithoutBlockingOtherThreads() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ambiguous = "01a0b72e-1b65-79b2-9e60-442f3e33316f"
        let stable = "01a17795-9d40-74f3-8444-fe00bf19bcc3"
        for (index, values) in [(ambiguous, 1_961_143, "2026-11-01T23:59:00Z"),
                                (ambiguous, 136_770, "2026-11-02T00:02:00Z"),
                                (stable, 50, "2026-11-02T00:03:00Z")].enumerated() {
            let contents = """
            {"type":"session_meta","payload":{"id":"\(values.0)"}}
            {"type":"event_msg","timestamp":"\(values.2)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(values.1)},"last_token_usage":{"total_tokens":\(values.1)}}}}
            """ + "\n"
            try Data(contents.utf8).write(to: directory.appendingPathComponent("rollout-\(index)-\(values.0).jsonl"))
        }
        let value = try #require(JSONSerialization.jsonObject(with: try await runExporter(root: root)) as? [String: Any])
        #expect(value["complete"] as? Bool == true)
        #expect(value["ambiguousThreads"] as? Int == 1)
        #expect((value["warnings"] as? [String])?.count == 1)
        let threads = try #require(value["threads"] as? [[String: Any]])
        #expect(threads.count == 2)
        let thread = try #require(threads.first { $0["threadID"] as? String == ambiguous })
        let records = try #require(thread["records"] as? [[String: Any]])
        #expect(thread["totalTokens"] as? Int == 1_961_143)
        #expect(records.count == 1)
        #expect(records[0]["lastTokens"] as? Int == 0)
        #expect(records[0]["timestamp"] as? Double == ISO8601DateFormatter().date(from: "2026-11-02T00:02:00Z")?.timeIntervalSince1970)
        let other = try #require(threads.first { $0["threadID"] as? String == stable })
        #expect(other["totalTokens"] as? Int == 50)
    }

    @Test(.enabled(if: zstdToolURL != nil))
    func compressedOriginalAndSplitLogMergeWithoutLosingHistoricalTimestamps() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let original = "01a17795-9d40-74f3-8444-fe00bf19bcc3"
        let child = "01a17bf8-95c8-71e1-be24-297427a99ed4"
        let prefix = """
        {"type":"session_meta","payload":{"id":"\(original)"}}
        {"type":"response_item","payload":{"body":"compressed private prompt"}}
        {"type":"event_msg","timestamp":"2026-11-01T23:59:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100},"last_token_usage":{"total_tokens":100}}}}
        """ + "\n"
        let suffix = """
        {"type":"session_meta","payload":{"id":"\(original)"}}
        {"type":"event_msg","timestamp":"2026-11-02T00:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":140},"last_token_usage":{"total_tokens":40}}}}
        """ + "\n"
        let compressed = try await RemoteUsageCommand.run(executable: try #require(Self.zstdToolURL), arguments: ["-q", "-c"], input: Data(prefix.utf8), timeout: 10, maximumOutputBytes: 1_048_576)
        try compressed.write(to: directory.appendingPathComponent("rollout-\(original).jsonl.zst"))
        try Data(prefix.utf8).write(to: archived.appendingPathComponent("rollout-\(original).jsonl"))
        try Data(suffix.utf8).write(to: directory.appendingPathComponent("rollout-\(original)_\(child).jsonl"))
        let output = try await runExporter(root: root)
        #expect(!String(decoding: output, as: UTF8.self).contains("compressed private prompt"))
        let value = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let threads = try #require(value["threads"] as? [[String: Any]])
        #expect(threads.count == 1)
        #expect(threads[0]["threadID"] as? String == original)
        #expect(threads[0]["totalTokens"] as? Int == 140)
        let records = try #require(threads[0]["records"] as? [[String: Any]])
        #expect(records.count == 2)
        #expect(records[0]["timestamp"] as? Double == ISO8601DateFormatter().date(from: "2026-11-01T23:59:00Z")?.timeIntervalSince1970)
        #expect(value["inspectedFiles"] as? Int == 3)
    }

    @Test
    func corruptCompressedLogCannotReplaceRetainedHistory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a zstd frame".utf8).write(to: directory.appendingPathComponent("rollout-01a17795-9d40-74f3-8444-fe00bf19bcc3.jsonl.zst"))
        do { _ = try await runExporter(root: root); Issue.record("Corrupt compressed log was accepted") }
        catch { #expect(error is CodexRemoteUsageSyncError) }
    }

    @Test
    func exporterRetainsInitialGapAndIgnoresOnlyAnUnfinishedFinalAppend() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = """
        {"type":"event_msg","timestamp":"2026-11-02T00:02:00.123Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1000},"last_token_usage":{"total_tokens":40}}}}
        """ + "\n{\"type\":\"event_msg\",\"payload\":"
        try Data(contents.utf8).write(to: directory.appendingPathComponent("rollout-01a19099-59ed-7a43-b41f-7d5462f1c4eb.jsonl"))
        let value = try #require(JSONSerialization.jsonObject(with: try await runExporter(root: root)) as? [String: Any])
        let threads = try #require(value["threads"] as? [[String: Any]])
        let records = try #require(threads[0]["records"] as? [[String: Any]])
        #expect(records[0]["totalTokens"] as? Int == 1000)
        #expect(records[0]["lastTokens"] as? Int == 40)
    }

    @Test
    func captureTimeIncludesEventsWrittenDuringTheScan() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = """
        {"type":"event_msg","timestamp":"2026-11-02T00:00:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":40},"last_token_usage":{"total_tokens":40}}}}
        """ + "\n"
        try Data(contents.utf8).write(to: directory.appendingPathComponent("rollout-01a19099-59ed-7a43-b41f-7d5462f1c4eb.jsonl"))
        let script = try #require(CodexRemoteUsageSync.defaultExporterURL)
        let program = """
        import json, runpy, sys
        from pathlib import Path
        from unittest.mock import patch
        module = runpy.run_path(sys.argv[1])
        with patch('time.time', side_effect=[1793577600.0, 1793577602.0]):
            archive = module['export_archive'](Path(sys.argv[2]), 'remote-control:test-environment')
        print(json.dumps(archive))
        """
        let output = try await RemoteUsageCommand.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", program, script.path, root.path], input: Data(), timeout: 10, maximumOutputBytes: 1_048_576)
        let value = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let capturedAt = try #require(value["capturedAt"] as? Double)
        let threads = try #require(value["threads"] as? [[String: Any]])
        let records = try #require(threads[0]["records"] as? [[String: Any]])
        let timestamp = try #require(records[0]["timestamp"] as? Double)
        #expect(timestamp <= capturedAt)
        #expect(capturedAt == 1793577602.0)
    }

    @Test
    func exporterRejectsCorruptCompletedLinesAndWrongRemoteHost() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid sensitive log body\n".utf8).write(to: directory.appendingPathComponent("rollout-01a19099-59ed-7a43-b41f-7d5462f1c4eb.jsonl"))
        do { _ = try await runExporter(root: root); Issue.record("Invalid complete line was accepted") }
        catch { #expect(!error.localizedDescription.contains("sensitive")) }
        try Data("{\"electron-local-remote-control-environment-id\":\"another-machine\"}".utf8)
            .write(to: root.appendingPathComponent(".codex-global-state.json"))
        do { _ = try await runExporter(root: root); Issue.record("Wrong SSH host was accepted") }
        catch { #expect(error is CodexRemoteUsageSyncError) }
    }

    @Test
    func validatesSourceAndQuotesRemoteHomeWithoutShellExpansion() throws {
        for alias in ["-oProxyCommand=bad", "host;echo bad", "$(bad)", "user@host", ""] {
            #expect(throws: CodexRemoteUsageSyncError.self) {
                try CodexRemoteUsageSource(hostID: hostID, sshAlias: alias).validate()
            }
        }
        let source = CodexRemoteUsageSource(hostID: hostID, sshAlias: "macserver", codexHome: "/home/user/it's $(literal)")
        try source.validate()
        let command = try #require(CodexRemoteUsageSync.arguments(for: source).last)
        #expect(command.contains("'/home/user/it'\\''s $(literal)'"))
        #expect(CodexRemoteUsageSync.arguments(for: source).contains("StrictHostKeyChecking=yes"))
        #expect(CodexRemoteUsageSync.arguments(for: source).contains("BatchMode=yes"))
        #expect(CodexRemoteUsageSync.arguments(for: source).contains("-C"))
    }

    @Test
    func failedAndTruncatedResponsesProduceNoReplacementArchive() async throws {
        let source = CodexRemoteUsageSource(hostID: hostID, sshAlias: "macserver")
        let sync = CodexRemoteUsageSync(runner: { _, _, _, _, _ in
            Data("{\"version\":1,\"complete\":true,\"hostID\":\"remote-control:test-environment\",\"threads\":[".utf8)
        })
        #expect(await sync.sync(sources: [source]).isEmpty)
        #expect(await sync.lastErrors.count == 1)
    }

    @Test
    func acceptsOnlyACompleteResponseFromTheConfiguredHost() async throws {
        let source = CodexRemoteUsageSource(hostID: hostID, sshAlias: "macserver")
        let now = Date.now.timeIntervalSince1970
        let valid = Data("{\"version\":1,\"complete\":true,\"hostID\":\"\(hostID)\",\"remoteEnvironmentID\":\"test-environment\",\"capturedAt\":\(now),\"threads\":[]}".utf8)
        let sync = CodexRemoteUsageSync(runner: { _, _, _, _, _ in valid })
        #expect(await sync.sync(sources: [source]).count == 1)
        #expect(await sync.lastErrors.isEmpty)
        let wrongHost = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"test-environment\"", with: "\"wrong-machine\"").utf8)
        #expect(throws: CodexRemoteUsageSyncError.self) {
            _ = try CodexRemoteUsageSync.decodeArchive(wrongHost, source: source)
        }
        let partial = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"complete\":true", with: "\"complete\":false").utf8)
        #expect(throws: CodexRemoteUsageSyncError.self) {
            _ = try CodexRemoteUsageSync.decodeArchive(partial, source: source)
        }
    }

    @Test
    func runnerTerminatesTimedOutAndOversizedCommands() async throws {
        do {
            _ = try await RemoteUsageCommand.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; time.sleep(10)"], input: Data(), timeout: 0.05, maximumOutputBytes: 1024)
            Issue.record("Timeout did not terminate the command")
        } catch let error as CodexRemoteUsageSyncError {
            if case .timedOut = error {} else { Issue.record("Unexpected timeout error: \(error)") }
        }
        do {
            _ = try await RemoteUsageCommand.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys; sys.stdout.write('x' * 1000000)"], input: Data(), timeout: 5, maximumOutputBytes: 1024)
            Issue.record("Oversized output was accepted")
        } catch let error as CodexRemoteUsageSyncError {
            if case .outputTooLarge = error {} else { Issue.record("Unexpected size error: \(error)") }
        }
    }

    @Test
    func cancellingASyncTerminatesItsCommand() async throws {
        let task = Task {
            try await RemoteUsageCommand.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; time.sleep(10)"], input: Data(), timeout: 20, maximumOutputBytes: 1024)
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled command returned normally") }
        catch let error as CodexRemoteUsageSyncError {
            if case .cancelled = error {} else { Issue.record("Unexpected cancellation error: \(error)") }
        }
    }

    @Test
    func timeoutRemainsBoundedWhenAnExitedProcessLeavesAPipeInItsChild() async throws {
        let started = ContinuousClock.now
        let program = "import subprocess, sys; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(2)'])"
        do {
            _ = try await RemoteUsageCommand.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", program], input: Data(), timeout: 0.1, maximumOutputBytes: 1024)
            Issue.record("A descendant's inherited pipe bypassed the deadline")
        } catch let error as CodexRemoteUsageSyncError {
            if case .timedOut = error {} else { Issue.record("Unexpected inherited-pipe error: \(error)") }
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-usage-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static var zstdToolURL: URL? {
        let entries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        let candidates = entries.map { URL(fileURLWithPath: String($0)).appendingPathComponent("zstd") }
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("miniconda3/bin/zstd")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func runExporter(root: URL) async throws -> Data {
        let script = try #require(CodexRemoteUsageSync.defaultExporterURL)
        return try await RemoteUsageCommand.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path, "--host-id", hostID, "--codex-home", root.path],
            input: Data(), timeout: 10, maximumOutputBytes: 1_048_576
        )
    }
}
