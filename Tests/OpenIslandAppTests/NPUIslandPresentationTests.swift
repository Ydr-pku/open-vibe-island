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
    }

    @Test
    func expandedControlsRemainOutsideThePhysicalNotch() {
        let width = IslandChromeMetrics.minimumNotchedOpenedWidth(notchWidth: 224)
        let visibleLane = (width - 224) / 2 - IslandChromeMetrics.notchHeaderHorizontalPadding
        #expect(visibleLane >= IslandChromeMetrics.openedHeaderControlsWidth + IslandChromeMetrics.notchLaneSafetyInset)
    }

    @Test
    func bothClosedLanesRemainOutsideThePhysicalNotch() {
        let right: IslandRightSlotContent = .usage(quotaRemainingPercentage: 100, resetTimeRemainingPercentage: 100)
        let width = V6ClosedPill.contentWidth(layout: .macbook, height: 32, physicalNotchWidth: 224, label: nil, rightSlot: right)
        let laneWidth = (width - 224) / 2 - 16
        #expect(laneWidth >= NPUIslandPresentation.compactWidth)
        #expect(laneWidth >= V6RightSlotView.intrinsicWidth(of: right))
        let hitArea = OverlayPanelController.closedSurfaceRect(notchRect: .init(x: 200, y: 0, width: 224, height: 32), closedWidth: width)
        #expect(hitArea.width == width)
        #expect(hitArea.midX == 312)
    }
}
