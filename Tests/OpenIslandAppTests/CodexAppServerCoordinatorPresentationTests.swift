import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct CodexAppServerCoordinatorPresentationTests {
    @Test
    func rootWorkingDirectoryUsesCodexFallback() {
        #expect(CodexAppServerCoordinator.displayWorkspaceName(for: "/") == "Codex")
        #expect(CodexAppServerCoordinator.displayWorkspaceName(for: "") == "Codex")
    }

    @Test
    func projectWorkingDirectoryUsesLastPathComponent() {
        #expect(
            CodexAppServerCoordinator.displayWorkspaceName(
                for: "/Users/example/Projects/open-vibe-island"
            ) == "open-vibe-island"
        )
    }

    @Test
    func injectedContextBlocksAreRemovedFromPreview() {
        let preview = """
        <recommended_plugins>
        GitHub and Slack
        </recommended_plugins>
        <environment_context>
          <cwd>/</cwd>
        </environment_context>
        首先没有触发的灵动岛，现在左边有个图标。
        """

        #expect(
            CodexSessionPresentationSanitizer.prompt(preview)
                == "首先没有触发的灵动岛，现在左边有个图标。"
        )
    }

    @Test
    func multilineUserPreviewCollapsesWhitespace() {
        let preview = """
        帮我检查灵动岛，
        然后修复标题。
        """

        #expect(
            CodexSessionPresentationSanitizer.prompt(preview)
                == "帮我检查灵动岛， 然后修复标题。"
        )
    }

    @Test
    func metadataOnlyOrTruncatedMetadataPreviewIsHidden() {
        #expect(
            CodexSessionPresentationSanitizer.prompt(
                "<recommended_plugins>GitHub</recommended_plugins>"
            ) == nil
        )
        #expect(
            CodexSessionPresentationSanitizer.prompt(
                "<recommended_plugins>GitHub"
            ) == nil
        )
    }

    @Test
    func cachedCodexSessionHeadlineAlsoUsesSanitizedPrompt() {
        let session = AgentSession(
            id: "cached-codex",
            title: "Codex",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Working",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Codex.app",
                workspaceName: "/",
                paneTitle: "Codex",
                workingDirectory: "/"
            ),
            codexMetadata: CodexSessionMetadata(
                initialUserPrompt: """
                <recommended_plugins>
                GitHub
                </recommended_plugins>
                帮我修复会话标题。
                """
            )
        )

        #expect(session.spotlightHeadlineText == "Codex · 帮我修复会话标题。")
    }
}
