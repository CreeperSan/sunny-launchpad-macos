// 按可用屏幕计算图标与中心间距；百分比微调受单元格边界约束，避免重叠。
import Foundation
import SunnyDomain

public struct LauncherMetrics: Equatable, Sendable {
    public let cellHeight: CGFloat
    public let iconSize: CGFloat
    public let horizontalPadding: CGFloat
    public let tileWidth: CGFloat
    public static let verticalChrome: CGFloat = 190
    public static let columnSpacing: CGFloat = 10

    public init(availableSize: CGSize, configuration: InteractionPreferences = InteractionPreferences()) {
        let usableWidth = max(200, availableSize.width - 40)
        // 100% 使用屏幕宽度的 88%；增加间距时最多扩展到安全边缘。
        let gridWidth = min(usableWidth, availableSize.width * 0.88 * configuration.spacingScale)
        horizontalPadding = max(20, (availableSize.width - gridWidth) / 2)
        tileWidth = (gridWidth - CGFloat(configuration.columns - 1) * Self.columnSpacing) / CGFloat(configuration.columns)
        let availableHeight = max(180, availableSize.height - Self.verticalChrome)
        let baseHeight = availableHeight / CGFloat(configuration.rows)
        cellHeight = max(min(32, baseHeight), baseHeight * min(1, configuration.spacingScale))
        let displayScale = min(availableSize.width / 1512, availableSize.height / 850)
        let desired = 80 * displayScale * configuration.iconScale
        iconSize = max(8, min(desired, cellHeight - (cellHeight < 70 ? 26 : 43), tileWidth - 16))
    }
}
