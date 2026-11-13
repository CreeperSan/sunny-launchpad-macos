// 按逻辑点计算网格，跨屏只改变尺寸，不改变分页或应用顺序。
import Foundation
import SunnyDomain

public struct LauncherMetrics: Equatable, Sendable {
    public let cellHeight: CGFloat
    public let iconSize: CGFloat
    public let horizontalPadding: CGFloat
    public let tileWidth: CGFloat
    public static let verticalChrome: CGFloat = 190
    public static let columnSpacing: CGFloat = 10
    private static let maximumCellHeight: CGFloat = 148
    private static let maximumIconSize: CGFloat = 88
    private static let labelAndInsets: CGFloat = 43
    private static let maximumGridWidth: CGFloat = 1240

    public init(availableSize: CGSize) {
        horizontalPadding = max(20, availableSize.width * 0.06)
        let gridWidth = min(Self.maximumGridWidth, availableSize.width - horizontalPadding * 2)
        tileWidth = (gridWidth - CGFloat(LaunchpadRules.columns - 1) * Self.columnSpacing) / CGFloat(LaunchpadRules.columns)
        cellHeight = max(48, min(Self.maximumCellHeight, (availableSize.height - Self.verticalChrome) / CGFloat(LaunchpadRules.rows)))
        iconSize = max(12, min(Self.maximumIconSize, cellHeight - Self.labelAndInsets, tileWidth - 16))
    }
}
