// 覆盖组合与壁纸坐标回归：关闭某一系统栏覆盖时，不得连带改变另一项。
import AppKit
import Testing
@testable import SunnyPresentation

struct LauncherWindowLayoutTests {
    private let screen = NSRect(x: 100, y: -200, width: 1600, height: 1000)

    @Test func bottomDockAndMenuBarCoverIndependently() {
        let visible = NSRect(x: 100, y: -130, width: 1600, height: 900)
        for menuBar in [false, true] {
            for dock in [false, true] {
                let layout = LauncherWindowLayout(screenFrame: screen, visibleFrame: visible, safeAreaTop: 0, coverMenuBar: menuBar, coverDock: dock)
                #expect(layout.frame.maxY == (menuBar ? screen.maxY : visible.maxY))
                #expect(layout.frame.minY == (dock ? screen.minY : visible.minY))
                #expect(layout.frame.width == screen.width)
                #expect(layout.wallpaperFrame.size == screen.size)
                #expect(layout.wallpaperFrame.minY == (menuBar ? 0 : -30))
            }
        }
    }

    @Test func sideDockAndNotchRemainOutsideInteractiveContent() {
        for leftDock in [false, true] {
            let visible = NSRect(x: leftDock ? 170 : 100, y: -200, width: 1530, height: 970)
            let layout = LauncherWindowLayout(screenFrame: screen, visibleFrame: visible, safeAreaTop: 32, coverMenuBar: true, coverDock: false)
            #expect(layout.frame.minX == visible.minX)
            #expect(layout.frame.maxX == visible.maxX)
            #expect(layout.frame.maxY == screen.maxY)
            #expect(layout.contentInsets.top == 32)
            #expect(layout.wallpaperFrame.minX == (leftDock ? -70 : 0))
            let uncoveredMenu = LauncherWindowLayout(screenFrame: screen, visibleFrame: visible, safeAreaTop: 32, coverMenuBar: false, coverDock: true)
            #expect(uncoveredMenu.frame.width == screen.width)
            #expect(uncoveredMenu.contentInsets.top == 2)
        }
    }
}
