import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct CodexDesktopPresenceTests {
    @Test
    func recentPresenceSurvivesTransientMiss() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(ProcessMonitoringCoordinator.debouncedCodexAppRunningState(
            observedRunning: false,
            lastSeenAt: now.addingTimeInterval(-10),
            now: now
        ))
        #expect(!ProcessMonitoringCoordinator.debouncedCodexAppRunningState(
            observedRunning: false,
            lastSeenAt: now.addingTimeInterval(-16),
            now: now
        ))
        #expect(ProcessMonitoringCoordinator.debouncedCodexAppRunningState(
            observedRunning: true,
            lastSeenAt: nil,
            now: now
        ))
    }

    @Test
    func rediscoveryDoesNotResurrectOldCompletedThread() {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldCompleted = record(
            phase: .completed,
            updatedAt: now.addingTimeInterval(-601)
        )
        let recentCompleted = record(
            phase: .completed,
            updatedAt: now.addingTimeInterval(-599)
        )
        let active = record(
            phase: .running,
            updatedAt: now.addingTimeInterval(-3_600)
        )

        #expect(!SessionDiscoveryCoordinator.shouldSurfaceCodexRecord(oldCompleted, now: now))
        #expect(SessionDiscoveryCoordinator.shouldSurfaceCodexRecord(recentCompleted, now: now))
        #expect(SessionDiscoveryCoordinator.shouldSurfaceCodexRecord(active, now: now))
    }

    @Test
    func runningCodexDesktopGetsFallbackWhenNoThreadIsAttributable() {
        let coordinator = ProcessMonitoringCoordinator()
        let sessions = coordinator.mergedWithSyntheticCodexDesktopSession(
            existingSessions: [],
            isCodexAppRunning: true,
            now: Date(timeIntervalSince1970: 10_000)
        )

        #expect(sessions.count == 1)
        #expect(sessions[0].title == "Codex Desktop")
        #expect(sessions[0].phase == .completed)
        #expect(sessions[0].summary.contains("No attributable task details"))
        #expect(sessions[0].isVisibleInIsland)
        #expect(coordinator.isSyntheticCodexDesktopSession(sessions[0]))

        let nextTick = coordinator.mergedWithSyntheticCodexDesktopSession(
            existingSessions: sessions,
            isCodexAppRunning: true,
            now: Date(timeIntervalSince1970: 20_000)
        )
        #expect(nextTick == sessions)

        var legacyRunningFallback = sessions[0]
        legacyRunningFallback.phase = .running
        legacyRunningFallback.summary = "Codex Desktop is active."
        let normalized = coordinator.mergedWithSyntheticCodexDesktopSession(
            existingSessions: [legacyRunningFallback],
            isCodexAppRunning: true
        )
        #expect(normalized[0].phase == .completed)
        #expect(normalized[0].summary.contains("No attributable task details"))
    }

    @Test
    func attributableCodexThreadReplacesDesktopFallback() {
        let coordinator = ProcessMonitoringCoordinator()
        let fallback = coordinator.mergedWithSyntheticCodexDesktopSession(
            existingSessions: [],
            isCodexAppRunning: true
        )
        var real = AgentSession(
            id: "real-codex-thread",
            title: "Real thread",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Working",
            updatedAt: .now
        )
        real.isCodexAppSession = true
        real.isProcessAlive = true

        let sessions = coordinator.mergedWithSyntheticCodexDesktopSession(
            existingSessions: fallback + [real],
            isCodexAppRunning: true
        )

        #expect(sessions.map(\.id) == ["real-codex-thread"])
    }

    @Test
    func desktopFallbackIsRemovedWhenCodexQuits() {
        let coordinator = ProcessMonitoringCoordinator()
        let fallback = coordinator.mergedWithSyntheticCodexDesktopSession(
            existingSessions: [],
            isCodexAppRunning: true
        )

        let sessions = coordinator.mergedWithSyntheticCodexDesktopSession(
            existingSessions: fallback,
            isCodexAppRunning: false
        )

        #expect(sessions.isEmpty)
    }

    private func record(
        phase: SessionPhase,
        updatedAt: Date
    ) -> CodexTrackedSessionRecord {
        CodexTrackedSessionRecord(
            sessionID: UUID().uuidString,
            title: "Codex",
            origin: .live,
            summary: "Test",
            phase: phase,
            updatedAt: updatedAt
        )
    }
}
