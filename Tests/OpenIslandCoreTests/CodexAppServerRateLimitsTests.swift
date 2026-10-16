import Foundation
import Testing
@testable import OpenIslandCore

struct CodexAppServerRateLimitsTests {
    @Test(arguments: [
        "null",
        "{}",
        "{\"lifetimeTokens\":null,\"peakDailyTokens\":null,\"longestRunningTurnSec\":null,\"currentStreakDays\":null,\"longestStreakDays\":null}",
    ])
    func unavailableSummaryMetricsDoNotDiscardDailyUsage(summaryJSON: String) throws {
        let data = Data("""
            {"summary": \(summaryJSON),
             "dailyUsageBuckets": [{"startDate":"2026-10-15","tokens":192276509}]}
            """.utf8)

        let snapshot = try CodexAppServerClient.decodeAccountUsageSnapshot(
            from: data, capturedAt: .now
        )

        #expect(snapshot.dailyBuckets == [
            CodexUsageHistoryBucket(key: "2026-10-15", tokens: 192_276_509),
        ])
        #expect(snapshot.summary.lifetimeTokens == nil)
        #expect(snapshot.summary.peakDailyTokens == nil)
        #expect(snapshot.summary.longestRunningTurnSeconds == nil)
        #expect(snapshot.summary.currentStreakDays == nil)
        #expect(snapshot.summary.longestStreakDays == nil)
    }

    @Test(arguments: [
        "{}",
        "{\"summary\":null,\"dailyUsageBuckets\":null}",
        "{\"summary\":{\"lifetimeTokens\":0},\"dailyUsageBuckets\":[]}",
    ])
    func unavailableDailyBucketsRemainEmpty(response: String) throws {
        let snapshot = try CodexAppServerClient.decodeAccountUsageSnapshot(
            from: Data(response.utf8), capturedAt: .now
        )
        #expect(snapshot.dailyBuckets.isEmpty)
    }

    @Test
    func decodesLiveAccountRateLimitsIntoUsageSnapshot() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 2,
                  "windowDurationMins": 10080,
                  "resetsAt": 1785903223
                },
                "secondary": null,
                "planType": "prolite"
              },
              "rateLimitsByLimitId": {},
              "rateLimitResetCredits": {
                "availableCount": 0,
                "credits": []
              }
            }
            """.utf8
        )
        let capturedAt = Date(timeIntervalSince1970: 10_000)

        let decoded = try CodexAppServerClient.decodeRateLimitsSnapshot(
            from: data,
            capturedAt: capturedAt
        )
        let snapshot = try #require(decoded)

        #expect(snapshot.sourceFilePath == CodexAppServerClient.rateLimitsSourceIdentifier)
        #expect(snapshot.capturedAt == capturedAt)
        #expect(snapshot.limitID == "codex")
        #expect(snapshot.planType == "prolite")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].label == "7d")
        #expect(snapshot.windows[0].usedPercentage == 2)
        #expect(snapshot.windows[0].leftPercentage == 98)
        #expect(snapshot.windows[0].windowMinutes == 10_080)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_785_903_223))
    }

    @Test
    func fallsBackToNamedCodexLimitWhenTopLevelLimitIsAbsent() throws {
        let data = Data(
            """
            {
              "rateLimits": null,
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "primary": {
                    "usedPercent": 27,
                    "windowDurationMins": 300,
                    "resetsAt": null
                  },
                  "secondary": null,
                  "planType": "plus"
                }
              }
            }
            """.utf8
        )

        let decoded = try CodexAppServerClient.decodeRateLimitsSnapshot(
            from: data,
            capturedAt: .now
        )
        let snapshot = try #require(decoded)

        #expect(snapshot.windows[0].label == "5h")
        #expect(snapshot.windows[0].usedPercentage == 27)
    }

    @Test
    func decodesOfficialDailyAccountUsage() throws {
        let data = Data(
            """
            {
              "summary": {
                "lifetimeTokens": 1279847322,
                "peakDailyTokens": 184708462,
                "longestRunningTurnSec": 26287,
                "currentStreakDays": 16,
                "longestStreakDays": 16
              },
              "dailyUsageBuckets": [
                {"startDate": "2026-07-27", "tokens": 80558027},
                {"startDate": "2026-07-28", "tokens": 184708462}
              ]
            }
            """.utf8
        )
        let capturedAt = Date(timeIntervalSince1970: 10_000)

        let snapshot = try CodexAppServerClient.decodeAccountUsageSnapshot(
            from: data,
            capturedAt: capturedAt
        )

        #expect(snapshot.capturedAt == capturedAt)
        #expect(snapshot.summary.lifetimeTokens == 1_279_847_322)
        #expect(snapshot.summary.currentStreakDays == 16)
        #expect(
            snapshot.dailyBuckets == [
                CodexUsageHistoryBucket(key: "2026-07-27", tokens: 80_558_027),
                CodexUsageHistoryBucket(key: "2026-07-28", tokens: 184_708_462),
            ]
        )
    }
}
