import CoreGraphics
import Testing
@testable import OpenIslandApp

struct NPUOpenedHeaderLayoutTests {
    @Test
    func physicalNotchHasEqualSafeLanesForConnectionAndQuota() {
        let notch: CGFloat = 224
        let width = IslandChromeMetrics.minimumNotchedOpenedWidth(notchWidth: notch)
        let visibleLane = (width - notch) / 2 - IslandChromeMetrics.notchHeaderHorizontalPadding
        let laneWidth = IslandChromeMetrics.openedNotchedLaneWidth(leftVisibleWidth: visibleLane, rightVisibleWidth: visibleLane)
        #expect(laneWidth >= IslandChromeMetrics.npuHeaderButtonWidth)
        #expect(laneWidth >= IslandChromeMetrics.minimumOpenedUsageLaneWidth)
    }

    @Test
    func unequalSafeAreasUseTheNarrowerSideToKeepHeadersSymmetric() {
        let width = IslandChromeMetrics.openedNotchedLaneWidth(leftVisibleWidth: 190, rightVisibleWidth: 160)
        #expect(width == 160 - IslandChromeMetrics.notchLaneSafetyInset)
        #expect(width + IslandChromeMetrics.notchLaneSafetyInset <= 190)
    }

    @Test
    func tightHeaderNeverHasNegativeLaneWidth() {
        #expect(IslandChromeMetrics.openedNotchedLaneWidth(leftVisibleWidth: 4, rightVisibleWidth: 100) == 0)
    }
}
