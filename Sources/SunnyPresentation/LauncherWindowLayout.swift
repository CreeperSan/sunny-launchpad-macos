// 窗口覆盖范围独立于系统 presentationOptions，不触发 Dock 自身的显隐动画。
import AppKit

public struct LauncherWindowLayout {
    public let frame: NSRect
    public let contentInsets: NSEdgeInsets
    public let wallpaperFrame: NSRect

    /// 未覆盖的系统栏留在窗口之外；壁纸仍以整块屏幕定位，避免裁剪后被拉伸。
    public init(screenFrame: NSRect, visibleFrame: NSRect, safeAreaTop: CGFloat, coverMenuBar: Bool, coverDock: Bool) {
        let visible = visibleFrame.intersection(screenFrame)
        let left = coverDock ? screenFrame.minX : visible.minX
        let right = coverDock ? screenFrame.maxX : visible.maxX
        let bottom = coverDock ? screenFrame.minY : visible.minY
        let top = coverMenuBar ? screenFrame.maxY : visible.maxY
        frame = NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
        contentInsets = NSEdgeInsets(top: max(0, safeAreaTop - (screenFrame.maxY - top)), left: 0, bottom: 0, right: 0)
        // 启动器使用翻转坐标：顶部裁剪量对应壁纸的负 y 偏移。
        wallpaperFrame = NSRect(x: screenFrame.minX - left, y: top - screenFrame.maxY, width: screenFrame.width, height: screenFrame.height)
    }
}
