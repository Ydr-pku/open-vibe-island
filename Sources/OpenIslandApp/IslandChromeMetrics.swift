import CoreGraphics

enum IslandChromeMetrics {
    static let headerControlButtonSize: CGFloat = 22
    static let headerControlSpacing: CGFloat = 8
    static let npuHeaderButtonWidth: CGFloat = 40
    static let notchHeaderHorizontalPadding: CGFloat = 46
    static let notchLaneSafetyInset: CGFloat = 12
    static var openedHeaderControlsWidth: CGFloat {
        headerControlButtonSize * 3 + npuHeaderButtonWidth + headerControlSpacing * 3
    }
    static func minimumNotchedOpenedWidth(notchWidth: CGFloat) -> CGFloat {
        notchWidth + 2 * (notchHeaderHorizontalPadding + openedHeaderControlsWidth + notchLaneSafetyInset)
    }
    static let openedShadowHorizontalInset: CGFloat = 18
    static let openedShadowBottomInset: CGFloat = 22
    static let closedShadowHorizontalInset: CGFloat = 12
    static let closedShadowBottomInset: CGFloat = 14
    static let closedHoverScale: CGFloat = 1.028
}
