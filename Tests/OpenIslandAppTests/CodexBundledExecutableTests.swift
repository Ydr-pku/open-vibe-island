import Foundation
import Testing
@testable import OpenIslandApp

@MainActor
struct CodexBundledExecutableTests {
    @Test(arguments: [
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex-cli/bin/codex",
        "Contents/Resources/codex",
    ])
    func resolvesExecutableInsideRenamedOrLegacyBundle(relativePath: String) {
        let bundle = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let executable = bundle.appendingPathComponent(relativePath)

        #expect(CodexAppServerCoordinator.bundledCodexExecutable(
            in: bundle,
            isExecutable: { $0 == executable.path }
        ) == executable)
    }

    @Test
    func prefersSignedCLIWhenLegacyExecutableAlsoExists() {
        let bundle = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        #expect(CodexAppServerCoordinator.bundledCodexExecutable(
            in: bundle,
            isExecutable: { _ in true }
        ) == bundle.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        ))
    }

    @Test
    func unavailableBundleDoesNotAttemptToLaunchAnExecutable() {
        #expect(CodexAppServerCoordinator.bundledCodexExecutable(
            in: URL(fileURLWithPath: "/Applications/Missing.app"),
            isExecutable: { _ in false }
        ) == nil)
    }
}
