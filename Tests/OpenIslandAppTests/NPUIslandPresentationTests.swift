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
        #expect(NPUIslandPresentation.percentage(.nan) == "—%")
    }

    @Test
    func expandedControlsRemainOutsideThePhysicalNotch() {
        let width = IslandChromeMetrics.minimumNotchedOpenedWidth(notchWidth: 224)
        let visibleLane = (width - 224) / 2 - IslandChromeMetrics.notchHeaderHorizontalPadding
        #expect(visibleLane >= IslandChromeMetrics.openedHeaderControlsWidth + IslandChromeMetrics.notchLaneSafetyInset)
    }

    @Test
    func closedMonitorLabelFollowsActiveMonitorsIncludingRetry() {
        let active = CPUHostState(id: "macserver", state: .connected)
        let stopped = CPUHostState(id: "macserver", state: .failed)
        let retrying = CPUHostState(id: "macserver", state: .failed, isRetrying: true)

        #expect(ClosedMonitorLabel.text(cpuHosts: [stopped], npuState: .disconnected) == nil)
        #expect(ClosedMonitorLabel.text(cpuHosts: [active], npuState: .disconnected) == "CPU")
        #expect(ClosedMonitorLabel.text(cpuHosts: [], npuState: .connected) == "NPU")
        #expect(ClosedMonitorLabel.text(cpuHosts: [retrying], npuState: .connecting) == "CPU · NPU")
    }

    @Test
    func combinedMonitorLabelFitsBothClosedLayouts() {
        let right: IslandRightSlotContent = .usage(quotaRemainingPercentage: 100, resetTimeRemainingPercentage: 100)
        let label = ClosedMonitorLabel.text(cpuHosts: [CPUHostState(id: "macserver", state: .connected)], npuState: .connected)
        let leftWidth = ClosedMonitorLabel.width(for: label)
        let rightWidth = V6RightSlotView.intrinsicWidth(of: right)
        let width = V6ClosedPill.contentWidth(layout: .macbook, height: 32, physicalNotchWidth: 224,
                                              label: nil, rightSlot: right, monitorLabel: label)
        let laneWidth = (width - 224) / 2 - 16
        #expect(laneWidth >= leftWidth)
        #expect(laneWidth + 0.01 >= rightWidth)
        let hitArea = OverlayPanelController.closedSurfaceRect(notchRect: .init(x: 200, y: 0, width: 224, height: 32), closedWidth: width)
        #expect(hitArea.width == width)
        #expect(hitArea.midX == 312)

        let externalWidth = V6ClosedPill.contentWidth(layout: .external, height: 24, physicalNotchWidth: 0,
                                                      label: nil, rightSlot: right, monitorLabel: label)
        #expect(externalWidth + 0.01 >= 24 + leftWidth + 6 + rightWidth)
    }

    @Test
    func expandedPanelReservesChipRowsEvenWithoutProcesses() {
        let monitor = MonitorStore(startsTimer: false)
        var snapshot = MonitorStore.demoSnapshot(at: Date())
        snapshot.processes = []
        monitor.state = .connected
        monitor.snapshot = snapshot

        let withoutProcesses = NPUIslandPresentation.contentHeight(for: monitor)
        snapshot.devices = []
        monitor.snapshot = snapshot
        let withoutDevices = NPUIslandPresentation.contentHeight(for: monitor)
        #expect(withoutProcesses - withoutDevices == 98)

        snapshot.devices = MonitorStore.demoSnapshot(at: Date()).devices
        snapshot.devices += snapshot.devices.map { device in
            var extra = device
            extra.npuID += 100
            return extra
        }
        monitor.snapshot = snapshot
        #expect(NPUIslandPresentation.contentHeight(for: monitor) == withoutProcesses)
    }
}
