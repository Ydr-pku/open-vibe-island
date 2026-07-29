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
