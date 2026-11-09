import AppKit

enum IslandChromeMetrics {
    static let headerControlButtonSize: CGFloat = 22
    static let headerControlSpacing: CGFloat = 8
    static let npuHeaderButtonWidth: CGFloat = 40
    static let notchHeaderHorizontalPadding: CGFloat = 46
    static let notchLaneSafetyInset: CGFloat = 12
    // Reserve space for the full compact Codex quota/reset chip, including
    // 100% values and its capsule padding, on either side of the notch.
    static let minimumOpenedUsageLaneWidth: CGFloat = 146
    static var openedHeaderControlsWidth: CGFloat {
        npuHeaderButtonWidth
    }
    static func minimumNotchedOpenedWidth(
        notchWidth: CGFloat,
        monitorHeaderWidth: CGFloat = openedHeaderControlsWidth
    ) -> CGFloat {
        notchWidth + 2 * (notchHeaderHorizontalPadding
            + max(monitorHeaderWidth, minimumOpenedUsageLaneWidth) + notchLaneSafetyInset)
    }
    static func openedNotchedLaneWidth(leftVisibleWidth: CGFloat, rightVisibleWidth: CGFloat) -> CGFloat {
        max(0, min(leftVisibleWidth, rightVisibleWidth) - notchLaneSafetyInset)
    }
    static let openedShadowHorizontalInset: CGFloat = 18
    static let openedShadowBottomInset: CGFloat = 22
    static let closedShadowHorizontalInset: CGFloat = 12
    static let closedShadowBottomInset: CGFloat = 14
    static let closedHoverScale: CGFloat = 1.028
}

/// A one-line summary for the SSH button above the expanded monitor panels.
struct OpenedMonitorSummary {
    static let fontSize: CGFloat = 10
    static let horizontalPadding: CGFloat = 8
    let cpuUsage: [Double?]
    let npuUsage: (hbm: Double?, aic: Double?)?

    var isEmpty: Bool { cpuUsage.isEmpty && npuUsage == nil }

    var text: String {
        var groups: [String] = []
        if !cpuUsage.isEmpty {
            groups.append("CPU " + cpuUsage.map(NPUIslandPresentation.percentage).joined(separator: "/"))
        }
        if let npuUsage {
            groups.append("NPU HBM\(NPUIslandPresentation.percentage(npuUsage.hbm)) AIC\(NPUIslandPresentation.percentage(npuUsage.aic))")
        }
        return groups.isEmpty ? "SSH" : groups.joined(separator: " · ")
    }

    static func requiredWidth(cpuHostCount: Int, showsNPU: Bool) -> CGFloat {
        // Reserve the width of 100% on each active monitor so sampling doesn't
        // move the window as the number of digits changes.
        let summary = Self(cpuUsage: Array(repeating: 100, count: cpuHostCount), npuUsage: showsNPU ? (100, 100) : nil)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let textWidth = (summary.text as NSString).size(withAttributes: [.font: font]).width
        return max(IslandChromeMetrics.openedHeaderControlsWidth, ceil(textWidth) + 2 * horizontalPadding + 2)
    }
}
