// 回归连续页位置与松手／取消吸附，避免退化成阈值直接换页。
import Foundation
import AppKit
import Testing
import SunnyDomain
@testable import SunnyPresentation

@MainActor struct PageGestureTests {
    @Test func searchOnlyLaunchesAfterExplicitReturn() async {
        let fixture = GestureFixture()
        let spy = GestureLauncherSpy()
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: spy)
        await store.prepare()
        let view = NativeLauncherView(store: store, wallpaper: nil, screenInsets: NSEdgeInsets())
        func searchField(in parent: NSView) -> NSTextField? {
            if let field = parent as? NSTextField { return field }
            return parent.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        guard let field = searchField(in: view) else { Issue.record("搜索框未创建"); return }
        #expect(field.action == nil)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor()?.isEditable == true)
        #expect(field.cell?.usesSingleLineMode == true)
        field.stringValue = "App 0"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(store.searchResults.count == 1)
        for _ in 0..<10 { await Task.yield() }
        #expect(spy.launched.isEmpty)
        #expect(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        for _ in 0..<20 { await Task.yield() }
        #expect(spy.launched == ["0"])
    }

    @Test func searchGlassConsumesClicksAndRequestsFocus() {
        let glass = NativeSearchGlass(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        var focusCount = 0
        glass.focusSearch = { focusCount += 1 }
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { Issue.record("无法创建鼠标事件"); return }
        glass.mouseDown(with: down)
        glass.mouseUp(with: up)
        #expect(focusCount == 1)
    }
    @Test func tileHitTestingUsesSuperviewCoordinates() {
        let parent = NativeSurface(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let tile = NativeTile(frame: NSRect(x: 120, y: 80, width: 100, height: 100))
        parent.addSubview(tile)
        tile.configure(title: "App", image: NSImage(), iconSize: 50, selected: false, grouping: false, loading: false)
        tile.layout()
        #expect(tile.hitTest(NSPoint(x: 150, y: 110)) === tile)
        #expect(tile.hitTest(NSPoint(x: 20, y: 20)) == nil)
        #expect(tile.hitTest(NSPoint(x: 122, y: 82)) == nil)
    }

    @Test func folderTileUsesGlassOnlyForGlassStyle() {
        let tile = NativeTile(frame: NSRect(x: 0, y: 0, width: 150, height: 150))
        tile.configure(title: "Folder", image: NSImage(), iconSize: 80, selected: false, grouping: false, loading: false, folderStyle: true)
        tile.layout()
        guard let glass = tile.subviews.first(where: { $0 is NSGlassEffectView }) else { Issue.record("文件夹图标缺少玻璃视图"); return }
        #expect(!glass.isHidden)
        #expect(glass.frame == tile.icon.frame)
        tile.configure(title: "Folder", image: NSImage(), iconSize: 80, selected: false, grouping: false, loading: false, folderStyle: false)
        #expect(glass.isHidden)
    }

    @Test func folderIconsMatchRootOnLargeDisplay() async {
        let folder = AppFolder(id: "tools", name: "Tools", pages: [["0", "1"]])
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.folder(folder), .app("2")])]), catalog: (0...2).map { ApplicationRecord(id: "\($0)", name: "App \($0)") })
        seed.catalogUpdatedAt = Date()
        let fixture = GestureFixture(seed: seed)
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2560, height: 1440), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NativeLauncherView(store: store, wallpaper: nil, screenInsets: NSEdgeInsets())
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        store.activate(.folder(folder))
        for _ in 0..<30 { await Task.yield() }
        view.layoutSubtreeIfNeeded()
        func tiles(in parent: NSView) -> [NativeTile] {
            (parent as? NativeTile).map { [$0] } ?? parent.subviews.flatMap { tiles(in: $0) }
        }
        let all = tiles(in: view)
        guard let root = all.first(where: { $0.item?.id == "app:2" }), let child = all.first(where: { $0.item?.id == "app:0" }) else { Issue.record("没有创建外层或文件夹图标"); return }
        #expect(abs(root.icon.frame.width - child.icon.frame.width) < 0.01)
    }

    @Test func folderTransitionAnimatesThumbnailIconsIndependently() async {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let folder = AppFolder(id: "tools", name: "Tools", pages: [["0", "1", "2"]])
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.folder(folder)])]), catalog: (0...2).map { ApplicationRecord(id: "\($0)", name: "App \($0)") })
        seed.catalogUpdatedAt = Date()
        let fixture = GestureFixture(seed: seed)
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NativeLauncherView(store: store, wallpaper: nil, screenInsets: NSEdgeInsets())
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        func tiles(in parent: NSView) -> [NativeTile] { (parent as? NativeTile).map { [$0] } ?? parent.subviews.flatMap { tiles(in: $0) } }
        guard let source = tiles(in: view).first(where: { $0.item?.id == "folder:tools" }) else { Issue.record("没有创建文件夹图标"); return }
        store.activate(.folder(folder))
        for _ in 0..<40 { await Task.yield() }
        #expect(source.isHidden)
        let icons = (view.layer?.sublayers ?? []).filter { $0.zPosition == 90 }
        #expect(icons.count == 3)
        let expandedPositions = icons.map(\.position)
        store.closeFolder()
        for _ in 0..<40 { await Task.yield() }
        let closing = (view.layer?.sublayers ?? []).filter { $0.zPosition == 90 }
        #expect(closing.count == 3)
        #expect(closing.map(\.position) != expandedPositions)
        #expect(source.isHidden)
    }

    @Test func folderSourceRestoresAfterClosing() async {
        let folder = AppFolder(id: "tools", name: "Tools", pages: [["0", "1"]])
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.folder(folder)])]), catalog: (0...1).map { ApplicationRecord(id: "\($0)", name: "App \($0)") })
        seed.catalogUpdatedAt = Date()
        seed.preferences.reduceMotion = true
        let fixture = GestureFixture(seed: seed)
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NativeLauncherView(store: store, wallpaper: nil, screenInsets: NSEdgeInsets())
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        func tiles(in parent: NSView) -> [NativeTile] { (parent as? NativeTile).map { [$0] } ?? parent.subviews.flatMap { tiles(in: $0) } }
        guard let source = tiles(in: view).first(where: { $0.item?.id == "folder:tools" }) else { Issue.record("没有创建文件夹图标"); return }
        store.activate(.folder(folder))
        for _ in 0..<40 { await Task.yield() }
        #expect(source.isHidden)
        store.closeFolder()
        for _ in 0..<40 { await Task.yield() }
        #expect(!source.isHidden)
    }

    @Test func folderGlassReachesCenteredFrameWithRoundedCorners() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let folder = AppFolder(id: "tools", name: "Tools", pages: [["0", "1"]])
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.folder(folder)])]), catalog: (0...1).map { ApplicationRecord(id: "\($0)", name: "App \($0)") })
        seed.catalogUpdatedAt = Date()
        let fixture = GestureFixture(seed: seed)
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NativeLauncherView(store: store, wallpaper: nil, screenInsets: NSEdgeInsets())
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        store.activate(.folder(folder))
        for _ in 0..<40 { await Task.yield() }
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        let title = try #require(descendants(view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Tools" && $0.isEditable })
        let parent = try #require(title.superview)
        let glass = try #require(parent.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        try await Task.sleep(for: .milliseconds(100))
        #expect(glass.cornerRadius > 0 && glass.cornerRadius <= 44)
        try await Task.sleep(for: .milliseconds(350))
        #expect(abs(glass.frame.minX) < 0.01)
        #expect(abs(glass.frame.width - parent.bounds.width) < 0.01)
        #expect(abs(glass.cornerRadius - 44) < 0.01)
        let rect = glass.convert(glass.bounds, to: view)
        #expect(abs(rect.midX - view.bounds.midX) < 0.01)
    }

    @Test func openFolderRoutesHitsToItsContents() async {
        let folder = AppFolder(id: "tools", name: "Tools", pages: [["0", "1"]])
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.folder(folder), .app("2")])]), catalog: (0...2).map { ApplicationRecord(id: "\($0)", name: "App \($0)") })
        seed.catalogUpdatedAt = Date()
        seed.preferences.reduceMotion = true
        let fixture = GestureFixture(seed: seed)
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let parent = NSView(frame: window.contentView!.bounds)
        window.contentView = parent
        let view = NativeLauncherView(store: store, wallpaper: nil, screenInsets: NSEdgeInsets())
        view.frame = NSRect(x: 40, y: 30, width: 1000, height: 700)
        parent.addSubview(view)
        view.layoutSubtreeIfNeeded()
        store.activate(.folder(folder))
        for _ in 0..<30 { await Task.yield() }
        view.layoutSubtreeIfNeeded()
        func descendants(of parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants(of: $0) } }
        let all = descendants(of: view)
        guard let child = all.compactMap({ $0 as? NativeTile }).first(where: { $0.item?.id == "app:0" }),
              let title = all.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "Tools" && $0.isEditable }) else { Issue.record("没有创建文件夹内容或标题"); return }
        let iconPoint = child.icon.convert(NSPoint(x: child.icon.bounds.midX, y: child.icon.bounds.midY), to: parent)
        let titlePoint = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: parent)
        #expect(view.hitTest(iconPoint) === child)
        #expect(view.hitTest(titlePoint) === title)
        #expect(view.hitTest(view.convert(NSPoint(x: 5, y: 5), to: parent)) === view)
    }
    @Test func dragIsContinuousAndCancellationRestoresPage() async {
        let fixture = GestureFixture()
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        store.pageWidth = 1000
        store.dragPage(delta: -100)
        #expect(abs(store.pagePosition - 0.1) < 0.001)
        #expect(store.activePage == 0)
        store.dragPage(delta: -150)
        #expect(abs(store.pagePosition - 0.25) < 0.001)
        store.finishPageDrag()
        #expect(store.activePage == 1)
        #expect(store.pagePosition == 1)
        store.dragPage(delta: 250)
        store.finishPageDrag(cancelled: true)
        #expect(store.activePage == 1)
        #expect(store.pagePosition == 1)
    }

    @Test func longDragLoadsAndSettlesOnTheReachedPage() async {
        let pages = (0..<6).map { LayoutPage(items: [.app("\($0)")]) }
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: pages), catalog: (0..<6).map { ApplicationRecord(id: "\($0)", name: "App \($0)") })
        seed.catalogUpdatedAt = Date()
        let fixture = GestureFixture(seed: seed)
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        let view = NativeLauncherView(store: store, wallpaper: nil, screenInsets: NSEdgeInsets())
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        view.layoutSubtreeIfNeeded()
        store.pageWidth = 1000
        store.dragPage(delta: -3200)
        for _ in 0..<30 { await Task.yield() }
        func tiles(in parent: NSView) -> [NativeTile] {
            (parent as? NativeTile).map { [$0] } ?? parent.subviews.flatMap { tiles(in: $0) }
        }
        #expect(tiles(in: view).contains { $0.item?.id == "app:3" })
        #expect(tiles(in: view).contains { $0.item?.id == "app:4" })
        store.finishPageDrag()
        #expect(store.activePage == 3)
        #expect(store.pagePosition == 3)
    }
    @Test func liveReorderIsTransientAndCancelsWithoutDataLoss() async {
        let fixture = GestureFixture()
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        let original = store.state.layout
        store.beginDrag("app:0")
        store.previewMove(before: .app("3"))
        #expect(store.displayedLayout != original)
        #expect(store.state.layout == original)
        #expect(Set(store.displayedLayout.appIDs) == Set(original.appIDs))
        store.cancelDrag()
        #expect(store.displayedLayout == original)
    }

    @Test func dropCommitsThePreviewedOrder() async {
        let fixture = GestureFixture()
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        store.beginDrag("app:0")
        store.previewMove(before: .app("3"))
        let preview = store.displayedLayout
        store.drop(onto: nil)
        for _ in 0..<100 where store.dragPreviewActive { await Task.yield() }
        #expect(store.state.layout == preview)
    }

    @Test func crossPageDropCommitsPreviewInRootAndFolder() async {
        let folderApps = (0..<LaunchpadRules.folderCapacity + 2).map { "f\($0)" }
        let folder = AppFolder(id: "tools", name: "Tools", pages: LayoutEditor.chunks(folderApps, size: LaunchpadRules.folderCapacity))
        let pages = [LayoutPage(items: [.app("a"), .folder(folder)]), LayoutPage(items: [.app("b")])]
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: pages), catalog: (["a", "b"] + folderApps).map { ApplicationRecord(id: $0, name: $0) })
        seed.catalogUpdatedAt = Date()
        seed.preferences.reduceMotion = true
        let fixture = GestureFixture(seed: seed)
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        store.beginDrag("app:a")
        store.selectPage(1)
        store.previewMove(before: .app("b"))
        store.drop(onto: .app("b"))
        for _ in 0..<100 where store.dragPreviewActive { await Task.yield() }
        #expect(store.state.layout.pages[1].items == [.app("a"), .app("b")])
        store.selectPage(0)
        store.activate(.folder(folder))
        for _ in 0..<20 { await Task.yield() }
        store.beginDrag("app:\(folderApps[0])")
        store.selectPage(1)
        store.previewMove(before: .app(folderApps.last!))
        let expected = store.displayedLayout
        store.drop(onto: .app(folderApps.last!))
        for _ in 0..<100 where store.dragPreviewActive { await Task.yield() }
        #expect(store.state.layout == expected)
    }

    @Test func droppingOutsideTilesKeepsLastReorderPreview() async {
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.app("a"), .app("b"), .app("c")])]), catalog: ["a", "b", "c"].map { ApplicationRecord(id: $0, name: $0) })
        seed.catalogUpdatedAt = Date()
        let fixture = GestureFixture(seed: seed)
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NativeLauncherView(store: store, wallpaper: nil, screenInsets: NSEdgeInsets())
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        func tiles(in parent: NSView) -> [NativeTile] { (parent as? NativeTile).map { [$0] } ?? parent.subviews.flatMap { tiles(in: $0) } }
        guard let source = tiles(in: view).first(where: { $0.item?.id == "app:a" }),
              let target = tiles(in: view).first(where: { $0.item?.id == "app:c" }) else { Issue.record("没有创建拖动图标"); return }
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let targetPoint = target.convert(NSPoint(x: target.bounds.minX + 2, y: target.bounds.midY), to: view)
        view.beginTileDrag(source, event: event(.leftMouseDragged, at: targetPoint))
        let preview = store.displayedLayout
        #expect(preview.pages[0].items == [.app("b"), .app("a"), .app("c")])
        let blank = NSPoint(x: view.bounds.midX, y: 5)
        view.moveTileDrag(event(.leftMouseDragged, at: blank))
        view.endTileDrag(event(.leftMouseUp, at: blank))
        for _ in 0..<100 where store.dragPreviewActive { await Task.yield() }
        #expect(store.state.layout == preview)
    }

    @Test func folderBlocksBackgroundActivationAndRestoresPage() async {
        let folder = AppFolder(id: "tools", name: "Tools", pages: [["0", "1"]])
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.folder(folder), .app("10")])]), catalog: [ApplicationRecord(id: "0", name: "A"), ApplicationRecord(id: "1", name: "B"), ApplicationRecord(id: "10", name: "Outside")])
        seed.preferences.reduceMotion = true
        let fixture = GestureFixture(seed: seed)
        let spy = GestureLauncherSpy()
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: spy)
        await store.prepare()
        store.activate(.folder(folder))
        for _ in 0..<10 { await Task.yield() }
        store.activate(.app("10"))
        for _ in 0..<10 { await Task.yield() }
        #expect(spy.launched.isEmpty)
        store.activate(.app("0"))
        for _ in 0..<10 { await Task.yield() }
        #expect(spy.launched == ["0"])
        store.closeFolder()
        for _ in 0..<10 { await Task.yield() }
        #expect(store.folderID == nil)
        #expect(store.pagePosition == Double(store.pageIndex))
    }

    @Test func scaleKeepsGeometricCenterFixed() {
        let size = CGSize(width: 2560, height: 1440)
        let transform = LayerAnimation.centeredScale(x: 1.14, y: 1.14, size: size)
        #expect(abs(size.width / 2 * transform.m11 + transform.m41 - size.width / 2) < 0.001)
        #expect(abs(size.height / 2 * transform.m22 + transform.m42 - size.height / 2) < 0.001)
    }

    @Test func classicRevealAnimatesFromConfiguredZoom() async {
        let fixture = GestureFixture()
        let store = LaunchpadStore(catalog: fixture, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = NativeLauncherView(store: store, wallpaper: nil, screenInsets: NSEdgeInsets())
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        store.revealProgress = 0
        view.prepareReveal()
        store.revealProgress = 1
        view.performReveal()
        guard let content = view.subviews.compactMap({ $0 as? NativeSurface }).first,
              let animation = content.layer?.animation(forKey: "transform") as? CABasicAnimation,
              let from = animation.fromValue as? NSValue,
              let to = animation.toValue as? NSValue else { Issue.record("经典入场缺少缩放动画"); return }
        #expect(abs(from.caTransform3DValue.m11 - 1.14) < 0.001)
        #expect(abs(to.caTransform3DValue.m11 - 1) < 0.001)
        #expect(abs(animation.duration - store.preferences.interaction.windowDuration) < 0.001)
        store.revealProgress = 0
        view.performReveal()
        #expect(view.layer?.opacity == 0)
        #expect((view.layer?.animation(forKey: "opacity") as? CABasicAnimation)?.duration == store.preferences.interaction.windowDuration)
    }

    @Test func recentCacheSkipsScanUntilInvalidated() async {
        var seed = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.app("cached")])]), catalog: [ApplicationRecord(id: "cached", name: "Cached")])
        seed.catalogUpdatedAt = Date()
        let fixture = GestureFixture(seed: seed)
        let scanner = CatalogScanSpy()
        let store = LaunchpadStore(catalog: scanner, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        #expect(await scanner.calls == 0)
        #expect(store.state.catalog.first?.id == "cached")
        store.markCatalogDirty()
        await store.prepare()
        #expect(await scanner.calls == 1)
        #expect(store.state.catalogUpdatedAt != nil)
    }

    @Test func cacheOlderThanOneHourRefreshesOnShow() async {
        var seed = WorkspaceState(catalog: [ApplicationRecord(id: "cached", name: "Cached")])
        seed.catalogUpdatedAt = Date(timeIntervalSinceNow: -3601)
        let fixture = GestureFixture(seed: seed)
        let scanner = CatalogScanSpy()
        let store = LaunchpadStore(catalog: scanner, repository: fixture, importer: fixture, launcher: fixture)
        await store.prepare()
        #expect(await scanner.calls == 1)
    }

    @Test func firstScanKeepsSkeletonUntilCatalogArrives() async {
        let fixture = GestureFixture()
        let scanner = SuspendedCatalog()
        let store = LaunchpadStore(catalog: scanner, repository: fixture, importer: fixture, launcher: fixture)
        let preparation = Task { await store.prepare() }
        await scanner.waitUntilStarted()
        #expect(store.catalogLoading)
        #expect(store.state.catalog.isEmpty)
        await scanner.finish()
        await preparation.value
        #expect(!store.catalogLoading)
        #expect(store.state.catalog.first?.name == "Loaded name")
    }

    @Test func silentRefreshKeepsCachedCatalogInteractive() async {
        let seed = WorkspaceState(catalog: [ApplicationRecord(id: "cached", name: "Cached name")])
        let fixture = GestureFixture(seed: seed)
        let scanner = SuspendedCatalog()
        let store = LaunchpadStore(catalog: scanner, repository: fixture, importer: fixture, launcher: fixture)
        let preparation = Task { await store.prepare() }
        await scanner.waitUntilStarted()
        #expect(!store.catalogLoading)
        #expect(store.canEdit)
        #expect(store.state.catalog.first?.name == "Cached name")
        await scanner.finish()
        await preparation.value
        #expect(store.state.catalog.contains { $0.name == "Loaded name" })
    }

}

/// 值类型服务替身，不访问用户磁盘或窗口。
private struct GestureFixture: ApplicationCatalog, WorkspaceRepository, LegacyLayoutImporting, ApplicationLaunching {
    func scan() async throws -> [ApplicationRecord] { (0..<50).map { ApplicationRecord(id: "\($0)", name: "App \($0)") } }
    var seed: WorkspaceState? = nil
    func load() async throws -> WorkspaceState? { seed }
    func save(_ state: WorkspaceState) async throws {}
    func exportState(to url: URL) async throws {}
    func readBackup(from url: URL) async throws -> WorkspaceState { WorkspaceState() }
    func discover() async -> [URL] { [] }
    func preview(from url: URL, catalog: [ApplicationRecord]) async throws -> ImportPreview { throw SunnyError.emptyImport }
    func launch(_ app: ApplicationRecord) async throws {}
}

@MainActor private final class GestureLauncherSpy: ApplicationLaunching {
    var launched: [String] = []
    func launch(_ app: ApplicationRecord) async throws { launched.append(app.id) }
}

private actor CatalogScanSpy: ApplicationCatalog {
    private(set) var calls = 0
    func scan() async throws -> [ApplicationRecord] { calls += 1; return [ApplicationRecord(id: "cached", name: "Cached")] }
}

/// 精确挂起扫描，不依赖磁盘速度或固定 sleep 验证首屏与静默刷新状态。
private actor SuspendedCatalog: ApplicationCatalog {
    private var result: CheckedContinuation<[ApplicationRecord], Never>?
    private var started: CheckedContinuation<Void, Never>?
    func scan() async throws -> [ApplicationRecord] {
        await withCheckedContinuation { continuation in
            result = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        result?.resume(returning: [ApplicationRecord(id: "loaded", name: "Loaded name")])
        result = nil
    }
}
