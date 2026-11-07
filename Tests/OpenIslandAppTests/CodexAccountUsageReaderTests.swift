import Foundation
import Testing
@testable import OpenIslandApp

@MainActor
struct CodexAccountUsageReaderTests {
    @Test(arguments: [false, true])
    func standaloneReaderDoesNotConnectDesktopAndAlwaysStops(failRequest: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex.py")
        let script = """
        #!/usr/bin/env python3
        import json, pathlib, signal, sys
        log = pathlib.Path(__file__).with_suffix('.log')
        stopped = pathlib.Path(__file__).with_suffix('.stopped')
        def stop(*args):
            stopped.write_text('stopped')
            sys.exit(0)
        signal.signal(signal.SIGTERM, stop)
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get('method')
            with log.open('a') as output:
                output.write(method + '\\n')
            response = {'id': request['id']}
            if method == 'initialize':
                response['result'] = {}
            elif method == 'account/usage/read' and \(failRequest ? "True" : "False"):
                response['error'] = {'code': -1, 'message': 'account usage unavailable'}
            elif method == 'account/usage/read':
                response['result'] = {'summary': {}, 'dailyUsageBuckets': [{'startDate': '2026-11-07', 'tokens': 123}]}
            else:
                response['error'] = {'code': -32601, 'message': 'unexpected method'}
            print(json.dumps(response), flush=True)
        stop()
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let coordinator = CodexAppServerCoordinator(resolveExecutable: { executable })
        var desktopCallbacks = 0
        coordinator.onConnected = { desktopCallbacks += 1 }
        coordinator.onEvent = { _ in desktopCallbacks += 1 }

        do {
            let snapshot = try await coordinator.readAccountUsageSnapshot()
            #expect(!failRequest)
            #expect(snapshot.dailyBuckets.count == 1)
            #expect(snapshot.dailyBuckets.first?.tokens == 123)
        } catch {
            #expect(failRequest)
            #expect(error.localizedDescription.contains("account usage unavailable"))
        }
        #expect(!coordinator.isConnected)
        #expect(desktopCallbacks == 0)
        let requests = try String(contentsOf: root.appendingPathComponent("codex.log"), encoding: .utf8)
        #expect(requests.split(separator: "\n").map(String.init) == ["initialize", "account/usage/read"])
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("codex.stopped").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("codex.stopped").path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_ACCOUNT_USAGE"] == "1"))
    func installedCLIReadsAccountHistoryWithoutConnectingDesktop() async throws {
        let coordinator = CodexAppServerCoordinator()
        let snapshot = try await coordinator.readAccountUsageSnapshot()
        #expect(!snapshot.dailyBuckets.isEmpty)
        #expect(snapshot.dailyBuckets.allSatisfy { $0.key.count == 10 && $0.tokens >= 0 })
        #expect(!coordinator.isConnected)
    }
}
