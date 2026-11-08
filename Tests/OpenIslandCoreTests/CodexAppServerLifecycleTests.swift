import Foundation
import Testing
@testable import OpenIslandCore

@Suite(.serialized)
struct CodexAppServerLifecycleTests {
    @Test
    func largeRepliesAreDrainedAcrossReadinessCallbacks() async throws {
        let executable = try makeServer(paddingSize: 250_000)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let client = CodexAppServerClient(codexPath: executable.path)
        defer { client.stop() }
        client.requestTimeoutSeconds = 2
        try await client.start()
        let snapshot = try await client.readAccountUsage()
        #expect(snapshot.dailyBuckets.isEmpty)
    }

    @Test
    func repeatedShortConnectionsReleaseTheirPipeDescriptors() async throws {
        let executable = try makeServer()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let before = try descriptorCount()
        for _ in 0..<64 {
            let client = CodexAppServerClient(codexPath: executable.path)
            client.requestTimeoutSeconds = 2
            try await client.start()
            _ = try await client.readAccountUsage()
            client.stop()
            client.stop()
            #expect(!client.isRunning)
        }
        try await Task.sleep(for: .milliseconds(200))
        let after = try descriptorCount()
        #expect(after <= before + 12, "64 account refreshes leaked descriptors: \(before) → \(after)")
    }

    @Test
    func stdoutEOFReleasesAPendingRequestAndClosesBothStreams() async throws {
        let executable = try makeServer(exitOnUsage: true)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let before = try descriptorCount()
        for _ in 0..<8 {
            let client = CodexAppServerClient(codexPath: executable.path)
            client.requestTimeoutSeconds = 2
            defer { client.stop() }
            try await client.start()
            do {
                _ = try await client.readAccountUsage()
                Issue.record("An exited server returned account usage")
            } catch let error as CodexAppServerError {
                switch error {
                case .disconnected, .notConnected: break
                default: Issue.record("EOF did not disconnect promptly: \(error)")
                }
            }
            #expect(!client.isRunning)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try descriptorCount() <= before + 12)
    }

    @Test
    func aFailedLaunchAlsoClosesEveryPipe() async throws {
        let before = try descriptorCount()
        for _ in 0..<16 {
            let client = CodexAppServerClient(codexPath: "/nonexistent/open-island-test-codex")
            do {
                try await client.start()
                Issue.record("A nonexistent executable launched")
            } catch {
                #expect(!client.isRunning)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try descriptorCount() <= before + 4)
    }

    private func descriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").filter { Int($0) != nil }.count
    }

    private func makeServer(exitOnUsage: Bool = false, paddingSize: Int = 0) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("codex.py")
        let script = """
        #!/usr/bin/env python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if request['method'] == 'account/usage/read' and \(exitOnUsage ? "True" : "False"):
                sys.exit(0)
            result = {} if request['method'] == 'initialize' else {'summary': {}, 'dailyUsageBuckets': []}
            if request['method'] != 'initialize':
                result['padding'] = 'x' * \(paddingSize)
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
