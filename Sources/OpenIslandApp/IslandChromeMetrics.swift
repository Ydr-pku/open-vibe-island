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

/// The labels and shared width budget for the expanded monitor capsules.
struct OpenedMonitorSummary {
    static let fontSize: CGFloat = 10
    static let horizontalPadding: CGFloat = 8
    static let chipSpacing: CGFloat = 6
    let cpuUsage: [Double?]
    let npuUsage: (hbm: Double?, aic: Double?)?

    var cpuText: String? {
        guard !cpuUsage.isEmpty else { return nil }
        return "CPU " + cpuUsage.map(NPUIslandPresentation.percentage).joined(separator: "/")
    }

    var npuText: String? {
        guard let npuUsage else { return nil }
        return "NPU HBM\(NPUIslandPresentation.percentage(npuUsage.hbm)) AIC\(NPUIslandPresentation.percentage(npuUsage.aic))"
    }

    static func requiredWidth(cpuHostCount: Int, showsNPU: Bool) -> CGFloat {
        // Reserve the width of 100% on each active monitor so sampling doesn't
        // move the window as the number of digits changes.
        let summary = Self(cpuUsage: Array(repeating: 100, count: cpuHostCount), npuUsage: showsNPU ? (100, 100) : nil)
        let labels = [summary.cpuText, summary.npuText].compactMap { $0 }
        guard !labels.isEmpty else { return IslandChromeMetrics.openedHeaderControlsWidth }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let chips = labels.reduce(CGFloat(0)) { total, label in
            let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
            return total + max(IslandChromeMetrics.openedHeaderControlsWidth, ceil(textWidth) + 2 * horizontalPadding + 2)
        }
        return chips + (labels.count > 1 ? chipSpacing : 0)
    }
}
