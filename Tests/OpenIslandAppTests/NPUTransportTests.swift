import Darwin
import Foundation
import Testing
@testable import OpenIslandApp

struct NPUTransportTests {
    @Test
    func authenticatesOverUserOnlyLocalSocketAndRemovesItOnStop() throws {
        let secret = "local-test-only-\(UUID().uuidString)"
        let broker = try AskPassBroker { prompt, reply in
            reply(prompt == "Password:" ? secret : nil)
        }
        defer { broker.stop() }
        var metadata = stat()
        #expect(lstat(broker.path, &metadata) == 0)
        #expect(metadata.st_mode & 0o777 == 0o600)
        let client = try connectClient(broker.path)
        defer { close(client) }
        try sendPrompt("Password:", to: client)
        #expect(try readResponse(client) == secret)
        broker.stop()
        #expect(!FileManager.default.fileExists(atPath: broker.path))
    }

    @Test
    func aMissingAnswerEmitsNoSecret() throws {
        let broker = try AskPassBroker { _, reply in reply(nil) }
        defer { broker.stop() }
        let client = try connectClient(broker.path)
        defer { close(client) }
        try sendPrompt("Password:", to: client)
        #expect(try readResponse(client).isEmpty)
    }

    @Test
    func stoppingClosesAnIncompleteRequestWithoutResponding() throws {
        let broker = try AskPassBroker { _, reply in reply("must-not-be-sent") }
        defer { broker.stop() }
        let client = try connectClient(broker.path)
        defer { close(client) }
        let bytes = Array("Password:".utf8)
        #expect(bytes.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) } == bytes.count)
        // Keep the write half open: the broker must cancel a blocked request read.
        usleep(50_000)
        broker.stop()
        #expect(try readResponse(client).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: broker.path))
    }

    @Test
    func stoppingCancelsAHostTrustPromptAwaitingUserInput() throws {
        let requested = DispatchSemaphore(value: 0)
        let broker = try AskPassBroker { _, _ in requested.signal() }
        defer { broker.stop() }
        let client = try connectClient(broker.path)
        defer { close(client) }
        try sendPrompt("Host authenticity yes/no?", to: client)
        #expect(requested.wait(timeout: .now() + 2) == .success)
        broker.stop()
        #expect(try readResponse(client).isEmpty)
    }

    @Test
    func passwordIsNeverReusedForMFAOrPasswordChangePrompts() {
        #expect(SSHTransport.isPasswordPrompt("Password: "))
        #expect(SSHTransport.isPasswordPrompt("root@192.0.2.1's password: "))
        for prompt in ["New password:", "Current password:", "Retype new password:", "Verification code:", "Password expired. Please change password:", "Password:\nVerification code:"] {
            #expect(!SSHTransport.isPasswordPrompt(prompt))
        }
        #expect(SSHTransport.sampleCommand == "npu-smi info\n")
    }

    #if DEBUG
    @Test
    func sshExitWaitsForDelayedStderrAndIncludesAuthenticationFailure() throws {
        let transport = SSHTransport()
        defer { transport.stop() }
        let stderrStarted = DispatchSemaphore(value: 0)
        let releaseStderr = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        let result = ExitResult()
        transport.onErrorOutput = { _ in
            stderrStarted.signal()
            _ = releaseStderr.wait(timeout: .now() + 3)
        }
        transport.onExit = { code, stderr in
            result.set(code: code, stderr: stderr)
            exited.signal()
        }
        try transport.startLocalTestProcess(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                            arguments: ["-c", "printf 'Permission denied (password).\\n' >&2; exit 255"])
        #expect(stderrStarted.wait(timeout: .now() + 3) == .success)
        // The child can already be dead, but auth diagnostics are not yet
        // delivered. Exit must wait for the stderr reader to finish.
        #expect(exited.wait(timeout: .now() + 0.3) == .timedOut)
        releaseStderr.signal()
        #expect(exited.wait(timeout: .now() + 3) == .success)
        #expect(result.code == 255)
        #expect(result.stderr.contains("Permission denied"))
    }

    @Test
    func largeStderrIsDrainedContinuouslyAndRetainsItsFinalDiagnostic() throws {
        let transport = SSHTransport()
        defer { transport.stop() }
        let exited = DispatchSemaphore(value: 0)
        let result = ExitResult()
        transport.onExit = { code, stderr in result.set(code: code, stderr: stderr); exited.signal() }
        let script = "i=0; while [ $i -lt 3000 ]; do printf 'diagnostic padding output\\n' >&2; i=$((i+1)); done; printf 'Host key verification failed.\\n' >&2; exit 255"
        try transport.startLocalTestProcess(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        #expect(exited.wait(timeout: .now() + 5) == .success)
        #expect(result.code == 255)
        #expect(result.stderr.contains("Host key verification failed"))
        #expect(result.stderr.utf8.count <= 8192)
    }

    @Test
    func stopDoesNotWaitForAStillRunningProcessOrEmitExit() throws {
        let transport = SSHTransport()
        let exited = DispatchSemaphore(value: 0)
        transport.onExit = { _, _ in exited.signal() }
        try transport.startLocalTestProcess(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 2"])
        let start = Date()
        transport.stop()
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(exited.wait(timeout: .now() + 0.2) == .timedOut)
    }
    #endif

    private func connectClient(_ path: String) throws -> Int32 {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw MonitorError.transport("local test socket() failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(client); throw MonitorError.transport("local test connect() failed") }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return client
    }

    private func sendPrompt(_ prompt: String, to client: Int32) throws {
        let bytes = Array(prompt.utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(client, $0.baseAddress, $0.count) }) == bytes.count else {
            throw MonitorError.transport("local test request write failed")
        }
        shutdown(client, SHUT_WR)
    }

    private func readResponse(_ client: Int32) throws -> String {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw MonitorError.transport("local test response timed out") }
            if count == 0 { return String(decoding: result, as: UTF8.self) }
            result.append(contentsOf: bytes.prefix(count))
        }
    }
}

private final class ExitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCode: Int32 = 0
    private var storedStderr = ""
    func set(code: Int32, stderr: String) { lock.lock(); storedCode = code; storedStderr = stderr; lock.unlock() }
    var code: Int32 { lock.lock(); defer { lock.unlock() }; return storedCode }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return storedStderr }
}
