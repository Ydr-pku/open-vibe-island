import CoreGraphics

enum IslandChromeMetrics {
    static let headerControlButtonSize: CGFloat = 22
    static let headerControlSpacing: CGFloat = 8
    // Fits NPU, both 100% metrics, the demo marker, and capsule padding.
    static let npuHeaderButtonWidth: CGFloat = 166
    static let openedHeaderChipHeight: CGFloat = 22
    static let notchHeaderHorizontalPadding: CGFloat = 46
    static let notchLaneSafetyInset: CGFloat = 12
    // Reserve space for the full compact Codex quota/reset chip, including
    // 100% values and its capsule padding, on either side of the notch.
    static let minimumOpenedUsageLaneWidth: CGFloat = 146
    static var openedHeaderControlsWidth: CGFloat {
        npuHeaderButtonWidth
    }
    static func minimumNotchedOpenedWidth(notchWidth: CGFloat) -> CGFloat {
        notchWidth + 2 * (notchHeaderHorizontalPadding
            + max(openedHeaderControlsWidth, minimumOpenedUsageLaneWidth) + notchLaneSafetyInset)
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
