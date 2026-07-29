import Foundation

enum UsagePercentage {
    static func remainingQuota(usedPercentage: Double) -> Int {
        Int(clamp(100 - usedPercentage).rounded())
    }

    static func resetTimeRemaining(
        resetsAt: Date?,
        windowMinutes: Int,
        now: Date = .now
    ) -> Int? {
        guard let resetsAt, windowMinutes > 0 else {
            return nil
        }

        let fullWindow = TimeInterval(windowMinutes * 60)
        let percentage = resetsAt.timeIntervalSince(now) / fullWindow * 100
        return Int(clamp(percentage).rounded())
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
