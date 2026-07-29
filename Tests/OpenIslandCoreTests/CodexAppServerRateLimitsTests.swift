import Foundation
import Testing
@testable import OpenIslandCore

struct CodexAppServerRateLimitsTests {
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
}
