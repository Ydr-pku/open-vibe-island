import CoreGraphics
import Testing
@testable import OpenIslandApp

struct NPUOpenedHeaderLayoutTests {
    @Test
    func monitorSummaryShowsCPUAndNPUAtTheSameTime() {
        let both = OpenedMonitorSummary(cpuUsage: [36, nil], npuUsage: (51, 72))
        #expect(both.cpuText == "CPU 36%/—%")
        #expect(both.npuText == "NPU HBM51% AIC72%")
        #expect(OpenedMonitorSummary(cpuUsage: [0], npuUsage: nil).cpuText == "CPU 0%")
        #expect(OpenedMonitorSummary(cpuUsage: [0], npuUsage: nil).npuText == nil)
        #expect(OpenedMonitorSummary(cpuUsage: [], npuUsage: (nil, nil)).npuText == "NPU HBM—% AIC—%")
        #expect(OpenedMonitorSummary(cpuUsage: [], npuUsage: nil).cpuText == nil)
    }

    @Test
    func bothMonitorTypesFitTheExpandedNotchLanes() {
        let controlsWidth = OpenedMonitorSummary.requiredWidth(cpuHostCount: CPUCollector.aliases.count, showsNPU: true)
        let cpuWidth = OpenedMonitorSummary.requiredWidth(cpuHostCount: CPUCollector.aliases.count, showsNPU: false)
        let npuWidth = OpenedMonitorSummary.requiredWidth(cpuHostCount: 0, showsNPU: true)
        #expect(controlsWidth == cpuWidth + OpenedMonitorSummary.chipSpacing + npuWidth)
        let notch: CGFloat = 224
        let width = IslandChromeMetrics.minimumNotchedOpenedWidth(notchWidth: notch, monitorHeaderWidth: controlsWidth)
        let visibleLane = (width - notch) / 2 - IslandChromeMetrics.notchHeaderHorizontalPadding
        let lane = IslandChromeMetrics.openedNotchedLaneWidth(leftVisibleWidth: visibleLane, rightVisibleWidth: visibleLane)
        #expect(lane >= controlsWidth)
        #expect(lane >= IslandChromeMetrics.minimumOpenedUsageLaneWidth)
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
