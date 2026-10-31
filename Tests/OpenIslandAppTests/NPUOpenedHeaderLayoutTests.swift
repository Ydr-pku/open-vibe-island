import AppKit
import Testing
@testable import OpenIslandApp

struct NPUOpenedHeaderLayoutTests {
    @Test
    func widestNPUCapsuleFitsInTheReservedLane() {
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let metricFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
        func width(_ text: String, font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let title = width("NPU", font: titleFont)
        let demo = width("D", font: metricFont)
        let hbm = width("HBM100%", font: metricFont)
        let core = width(NPUIslandPresentation.coreLabel(100), font: metricFont)
        let capsuleWidth = title + demo + hbm + core + 3 * 5 + 2 * 8
        #expect(capsuleWidth <= IslandChromeMetrics.openedHeaderControlsWidth)
    }

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
