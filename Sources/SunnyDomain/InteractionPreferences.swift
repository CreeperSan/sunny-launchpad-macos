// 交互配置独立建模；新增字段通过默认值兼容已有用户数据。
import Foundation

public enum PageAnimation: String, Codable, CaseIterable, Sendable { case slide, depth, cube, fade, none }
public enum WindowAnimation: String, Codable, CaseIterable, Sendable { case classic, fade, rise, none }
public enum PagerStyle: String, Codable, CaseIterable, Sendable { case dots, capsules, numbers }

public struct InteractionPreferences: Codable, Equatable, Sendable {
    /// 兼容旧配置时沿用原先的文件夹动画时长。
    public static let defaultFolderDuration = 0.3
    public static let animationDurationRange = 0.0...1.5
    public var columns = LaunchpadRules.columns
    public var rows = LaunchpadRules.rows
    public var iconScale = 1.0
    public var spacingScale = 1.0
    public var pageAnimation: PageAnimation = .slide
    public var pageDuration = 0.3
    public var folderDuration = Self.defaultFolderDuration
    public var windowAnimation: WindowAnimation = .classic
    public var windowDuration = 0.25
    public var pagerStyle: PagerStyle = .dots
    /// 菜单栏和 Dock 独立覆盖；实验性系统动画能力必须由用户手动开启。
    public var coverMenuBar = true
    public var coverDock = true
    public var useSystemAnimation = false
    public var reversePaging = false
    public var backgroundBlur = 18.0
    /// 背景遮罩使用 sRGB 十六进制颜色和独立透明度，旧配置按默认值迁移。
    public var dimColorHex = "000000"
    public var dimOpacity = 0.22
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case columns, rows, iconScale, spacingScale, pageAnimation, pageDuration, folderDuration, windowAnimation, windowDuration, pagerStyle, coverMenuBar, coverDock, useSystemAnimation, reversePaging, backgroundBlur, dimColorHex, dimOpacity
    }
    /// 缺省字段使用当前默认值；覆盖选项只读取各自的新配置键。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        columns = try values.decodeIfPresent(Int.self, forKey: .columns) ?? LaunchpadRules.columns
        rows = try values.decodeIfPresent(Int.self, forKey: .rows) ?? LaunchpadRules.rows
        iconScale = try values.decodeIfPresent(Double.self, forKey: .iconScale) ?? 1
        spacingScale = try values.decodeIfPresent(Double.self, forKey: .spacingScale) ?? 1
        pageAnimation = try values.decodeIfPresent(PageAnimation.self, forKey: .pageAnimation) ?? .slide
        pageDuration = try values.decodeIfPresent(Double.self, forKey: .pageDuration) ?? 0.3
        folderDuration = try values.decodeIfPresent(Double.self, forKey: .folderDuration) ?? Self.defaultFolderDuration
        windowAnimation = try values.decodeIfPresent(WindowAnimation.self, forKey: .windowAnimation) ?? .classic
        windowDuration = try values.decodeIfPresent(Double.self, forKey: .windowDuration) ?? 0.25
        pagerStyle = try values.decodeIfPresent(PagerStyle.self, forKey: .pagerStyle) ?? .dots
        coverMenuBar = try values.decodeIfPresent(Bool.self, forKey: .coverMenuBar) ?? true
        coverDock = try values.decodeIfPresent(Bool.self, forKey: .coverDock) ?? true
        useSystemAnimation = try values.decodeIfPresent(Bool.self, forKey: .useSystemAnimation) ?? false
        reversePaging = try values.decodeIfPresent(Bool.self, forKey: .reversePaging) ?? false
        backgroundBlur = try values.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 18
        dimColorHex = try values.decodeIfPresent(String.self, forKey: .dimColorHex) ?? "000000"
        dimOpacity = try values.decodeIfPresent(Double.self, forKey: .dimOpacity) ?? 0.22
    }
    public var capacity: Int { columns * rows }
    public var isValid: Bool {
        (4...12).contains(columns) && (3...8).contains(rows) && (0.5...1.5).contains(iconScale) && (0.5...1.5).contains(spacingScale) && Self.animationDurationRange.contains(pageDuration) && Self.animationDurationRange.contains(folderDuration) && Self.animationDurationRange.contains(windowDuration) && (0...60).contains(backgroundBlur) && (0...1).contains(dimOpacity) && dimColorHex.count == 6 && dimColorHex.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
