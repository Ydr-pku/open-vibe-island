import Foundation
import Testing
@testable import OpenIslandApp

struct UsagePercentageTests {
    @Test
    func remainingQuotaInvertsAndClampsUsedPercentage() {
        #expect(UsagePercentage.remainingQuota(usedPercentage: 42.4) == 58)
        #expect(UsagePercentage.remainingQuota(usedPercentage: -5) == 100)
        #expect(UsagePercentage.remainingQuota(usedPercentage: 120) == 0)
    }

    @Test
    func resetTimeRemainingUsesFullWindowAsDenominator() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(
            UsagePercentage.resetTimeRemaining(
                resetsAt: now.addingTimeInterval(2.5 * 60 * 60),
                windowMinutes: 5 * 60,
                now: now
            ) == 50
        )
        #expect(
            UsagePercentage.resetTimeRemaining(
                resetsAt: now.addingTimeInterval(8 * 60 * 60),
                windowMinutes: 5 * 60,
                now: now
            ) == 100
        )
        #expect(
            UsagePercentage.resetTimeRemaining(
                resetsAt: now.addingTimeInterval(-60),
                windowMinutes: 5 * 60,
                now: now
            ) == 0
        )
    }

    @Test
    func resetTimeRemainingIsUnavailableWithoutRequiredData() {
        #expect(UsagePercentage.resetTimeRemaining(resetsAt: nil, windowMinutes: 300) == nil)
        #expect(
            UsagePercentage.resetTimeRemaining(
                resetsAt: Date(timeIntervalSince1970: 10_000),
                windowMinutes: 0
            ) == nil
        )
    }
}
