import Foundation
import Testing
@testable import OpenIslandApp

@MainActor
struct NPUIslandPresentationTests {
    @Test
    func oldOrPausedSamplesAreNeverPresentedAsLive() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(NPUIslandPresentation.isFresh(state: .connected, isPaused: false, lastUpdated: now.addingTimeInterval(-2), refreshInterval: 2, at: now))
        #expect(!NPUIslandPresentation.isFresh(state: .connected, isPaused: false, lastUpdated: now.addingTimeInterval(-11), refreshInterval: 2, at: now))
        #expect(!NPUIslandPresentation.isFresh(state: .connected, isPaused: true, lastUpdated: now, refreshInterval: 2, at: now))
        #expect(!NPUIslandPresentation.isFresh(state: .failed, isPaused: false, lastUpdated: now, refreshInterval: 2, at: now))
        #expect(!NPUIslandPresentation.isFresh(state: .disconnected, isPaused: false, lastUpdated: now, refreshInterval: 2, at: now))
        #expect(!NPUIslandPresentation.isFresh(state: .connected, isPaused: false, lastUpdated: nil, refreshInterval: 2, at: now))
        #expect(NPUIslandPresentation.isFresh(state: .connected, isPaused: false, lastUpdated: now.addingTimeInterval(-15), refreshInterval: 10, at: now))
    }

    @Test
    func missingMetricAndIdleMetricHaveDifferentLabels() {
        #expect(NPUIslandPresentation.percentage(nil) == "—%")
        #expect(NPUIslandPresentation.percentage(0) == "0%")
        #expect(NPUIslandPresentation.percentage(99.8) == "100%")
        #expect(NPUIslandPresentation.coreLabel(0) == "AIC0%")
        #expect(NPUIslandPresentation.coreLabel(nil) == "AIC—%")
    }

    @Test
    func utilizationBarsClampAndKeepUnknownDistinctFromZero() {
        #expect(NPUIslandPresentation.utilizationFraction(nil) == nil)
        #expect(NPUIslandPresentation.utilizationFraction(.nan) == nil)
        #expect(NPUIslandPresentation.utilizationFraction(-1) == 0)
        #expect(NPUIslandPresentation.utilizationFraction(0) == 0)
        #expect(NPUIslandPresentation.utilizationFraction(50) == 0.5)
        #expect(NPUIslandPresentation.utilizationFraction(100) == 1)
        #expect(NPUIslandPresentation.utilizationFraction(110) == 1)
    }

    @Test
    func connectedPanelReservesSpaceForUtilizationBars() {
        let monitor = MonitorStore(startsTimer: false)
        #expect(NPUIslandPresentation.contentHeight(for: monitor) == 84)
        monitor.loadDemo()
        let rows = min(NPUIslandPresentation.visibleRows, monitor.snapshot?.processes.count ?? 0)
        #expect(NPUIslandPresentation.contentHeight(for: monitor) == 68 + 106 + 8 + 24 * CGFloat(max(1, rows)))
        #expect(NPUIslandPresentation.utilizationSectionHeight(deviceCount: 0) == 40)
        #expect(NPUIslandPresentation.utilizationSectionHeight(deviceCount: 1) == 40)
        #expect(NPUIslandPresentation.utilizationSectionHeight(deviceCount: 4) == 106)
        #expect(NPUIslandPresentation.utilizationSectionHeight(deviceCount: 8) == 106)
    }

    @Test
    func deviceRowsUseStableNPUAndChipNumbers() {
        let sample = MonitorStore.demoSnapshot(at: .now)
        var first = sample.devices[0]
        var second = sample.devices[1]
        var third = sample.devices[2]
        first.npuID = 5; first.chipID = 0; first.utilization = 80
        second.npuID = 3; second.chipID = 1; second.utilization = nil
        third.npuID = 3; third.chipID = 0; third.utilization = 0
        let devices = NPUIslandPresentation.sortedDevices([first, second, third])
        #expect(devices.map(\.id) == ["3:0", "3:1", "5:0"])
        #expect(devices.map(\.utilization) == [0, nil, 80])
        #expect(devices.map(\.hbmPercent) == [third.hbmPercent, second.hbmPercent, first.hbmPercent])
    }

    @Test
    func expandedControlsRemainOutsideThePhysicalNotch() {
        let width = IslandChromeMetrics.minimumNotchedOpenedWidth(notchWidth: 224)
        let visibleLane = (width - 224) / 2 - IslandChromeMetrics.notchHeaderHorizontalPadding
        #expect(visibleLane >= IslandChromeMetrics.openedHeaderControlsWidth + IslandChromeMetrics.notchLaneSafetyInset)
    }

    @Test
    func externalDisplayReservesSpaceEvenWithAnEmptyRightLane() {
        let width = V6ClosedPill.contentWidth(layout: .external, height: 24, physicalNotchWidth: 0,
                                              label: nil, rightSlot: nil)
        #expect(width >= 24 + NPUIslandPresentation.compactWidth(state: .disconnected) + 6)
    }

    @Test
    func bothClosedLanesRemainOutsideThePhysicalNotch() {
        let right: IslandRightSlotContent = .usage(quotaRemainingPercentage: 100, resetTimeRemainingPercentage: 100)
        let leftWidth = NPUIslandPresentation.compactWidth(state: .connected, hbm: 100, core: 100)
        let width = V6ClosedPill.contentWidth(layout: .macbook, height: 32, physicalNotchWidth: 224,
                                              label: nil, rightSlot: right, leftWidth: leftWidth)
        let laneWidth = (width - 224) / 2 - 16
        #expect(laneWidth >= leftWidth)
        #expect(laneWidth >= V6RightSlotView.intrinsicWidth(of: right))
        let hitArea = OverlayPanelController.closedSurfaceRect(notchRect: .init(x: 200, y: 0, width: 224, height: 32), closedWidth: width)
        #expect(hitArea.width == width)
        #expect(hitArea.midX == 312)
    }

    @Test
    func idleAndSmallValuesUseNarrowerLanesWithoutClipping() {
        let disconnected = NPUIslandPresentation.compactWidth(state: .disconnected)
        let small = NPUIslandPresentation.compactWidth(state: .connected, hbm: 5, core: 0)
        let maximum = NPUIslandPresentation.compactWidth(state: .connected, hbm: 100, core: 100)
        let demo = NPUIslandPresentation.compactWidth(state: .connected, isDemo: true, hbm: 100, core: 100)
        #expect(disconnected < small)
        #expect(small < maximum)
        #expect(demo > maximum)
        #expect(maximum < 112)
        #expect(NPUIslandPresentation.compactWidth(state: .connecting) > disconnected)
        #expect(NPUIslandPresentation.compactWidth(state: .failed) > disconnected)

        let right: IslandRightSlotContent = .usage(quotaRemainingPercentage: 95, resetTimeRemainingPercentage: 99)
        let idleIsland = V6ClosedPill.contentWidth(layout: .macbook, height: 32, physicalNotchWidth: 224,
                                                   label: nil, rightSlot: right, leftWidth: disconnected)
        let connectedIsland = V6ClosedPill.contentWidth(layout: .macbook, height: 32, physicalNotchWidth: 224,
                                                        label: nil, rightSlot: right, leftWidth: small)
        #expect(idleIsland < 224 + 2 * (112 + 16))
        #expect(connectedIsland < 224 + 2 * (112 + 16))
    }
}
