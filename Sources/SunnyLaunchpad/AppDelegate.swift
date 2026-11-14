// 组装根：只在这里选择基础设施实现，窗口生命周期与用户数据路径集中管理。
import AppKit
import QuartzCore
import SunnyDomain
import SunnyInfrastructure
import SunnyPresentation

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let dataDirectory = JSONWorkspaceRepository.defaultDirectory
    private lazy var store = LaunchpadStore(catalog: MacApplicationCatalog(), repository: JSONWorkspaceRepository(directory: dataDirectory), importer: LegacyLaunchpadImporter(), launcher: MacApplicationLauncher())
    private var launcherWindow: LauncherWindow?
    private var launcherView: NativeLauncherView?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let hotKey = GlobalHotKey()
    private let directoryWatcher = ApplicationDirectoryWatcher()
    private var ready = false
    private var closing = false
    /// 每次反向显隐递增，过期动画完成回调不得隐藏新打开的窗口。
    private var transitionGeneration = 0
    private var appliedInteraction: InteractionPreferences?
    private let systemMenuBarAnimator = SystemMenuBarAnimator()
    /// 覆盖菜单栏所需的最低常规层级；避免使用屏保层级压住辅助窗口。
    private let systemBarCoverLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    private let wallpaperRenderer = WallpaperRenderer()
    private var wallpaperTask: Task<Void, Never>?
    private var launcherScreenNumber: NSNumber?
    private var configurationKey = ""
    private var wallpaperCache: [String: NSImage] = [:]
    private var preparationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NativeLauncherView.configureIconCache(directory: dataDirectory.appendingPathComponent("IconCache", isDirectory: true))
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) { NSApp.applicationIconImage = image }
        store.dismiss = { [weak self] in self?.hideLauncher() }
        store.launchFailed = { [weak self] in self?.showLauncher() }
        store.openSettings = { [weak self] in self?.showSettings() }
        store.preferencesChanged = { [weak self] preferences in self?.applyPreferences(preferences) }
        hotKey.action = { [weak self] in self?.toggleLauncher() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Sunny Launchpad")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemLocaleChanged), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        rebuildMenus()
        // 先读取自有布局和偏好再准备首帧，避免入场中途切换覆盖范围。
        Task {
            await store.loadCachedState()
            ready = true
            store.markCatalogDirty()
            showLauncher()
        }
        Task { [self] in
            await Task.yield()
            directoryWatcher.onChange = { [weak self] in
                guard let self else { return }
                self.store.markCatalogDirty()
                if self.launcherWindow?.isVisible == true { Task { await self.store.refresh() } }
            }
            directoryWatcher.start()
        }
        if CommandLine.arguments.contains("--performance-check") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let native = launcherWindow?.contentView as? NativeLauncherView { await native.runPerformanceCheck() }
                if CommandLine.arguments.contains("--quit-after-performance-check") { NSApp.terminate(nil) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ready { showLauncher() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { hotKey.stop(); directoryWatcher.stop(); systemMenuBarAnimator.restore() }
    func applicationDidResignActive(_ notification: Notification) { hideLauncher(); systemMenuBarAnimator.restore() }
    func applicationDidBecomeActive(_ notification: Notification) { updateSystemMenuBar(duration: windowMotion ?? 0) }

    /// 不创建原生全屏 Space；覆盖鼠标所在显示器，保留普通桌面切换方式。
    @objc private func showLauncher() {
        if launcherWindow?.isVisible == true && !closing { launcherWindow?.makeKeyAndOrderFront(nil); return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let window: LauncherWindow
        if let existing = launcherWindow { window = existing }
        else {
            window = LauncherWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            launcherWindow = window
        }
        let reversing = closing
        closing = false
        transitionGeneration += 1
        window.animationBehavior = .none
        if !reversing {
            store.resetPresentation()
            store.revealProgress = 0
        }
        // 保留已有内容；窗口隐藏时先完成布局和图层初态，再一次性显示及提交入场。
        configure(window, on: screen)
        if !reversing { launcherView?.prepareReveal() }
        applyWindowLevel()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateSystemMenuBar(duration: windowMotion ?? 0)
        store.revealProgress = 1
        launcherView?.performReveal(continuing: reversing)
        preparationTask?.cancel()
        preparationTask = Task { await store.prepare(resetPresentation: false) }
    }

    private var windowMotion: Double? {
        store.preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || store.preferences.interaction.windowAnimation == .none ? nil : store.preferences.interaction.windowDuration
    }

    /// 整个窗口淡出直接露出系统栏，不再等待动画后切换 Dock 隐藏状态。
    @objc private func hideLauncher() {
        guard !closing, let window = launcherWindow, window.isVisible else { return }
        closing = true
        transitionGeneration += 1
        let generation = transitionGeneration
        store.cancelDrag()
        let duration = windowMotion ?? 0
        updateSystemMenuBar(duration: duration)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.closing, self.transitionGeneration == generation else { return }
                self.launcherWindow?.orderOut(nil)
                self.systemMenuBarAnimator.restore()
                self.closing = false
            }
        }
        store.revealProgress = 0
        launcherView?.performReveal()
        CATransaction.commit()
    }

    /// 覆盖范围由窗口矩形控制，不触发系统 Dock 自身的显隐。
    private func applyWindowLevel() {
        let interaction = store.preferences.interaction
        launcherWindow?.level = interaction.coverMenuBar || interaction.coverDock ? systemBarCoverLevel : .normal
    }

    /// 私有能力只增强菜单栏透明度；关闭实验选项时完全使用普通窗口覆盖。
    private func updateSystemMenuBar(duration: Double) {
        let interaction = store.preferences.interaction
        guard interaction.useSystemAnimation, interaction.coverMenuBar, NSApp.isActive,
              let window = launcherWindow, window.isVisible, let view = launcherView else {
            systemMenuBarAnimator.restore()
            return
        }
        systemMenuBarAnimator.animate(hidden: !closing, duration: duration, view: view)
    }

    @objc private func toggleLauncher() {
        if closing || launcherWindow?.isVisible != true { showLauncher() } else { hideLauncher() }
    }

    @objc private func showSettings() {
        hideLauncher()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 820, height: 620)
            window.contentView = NativeSettingsView(store: store, dataDirectory: dataDirectory)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = "Sunny Launchpad · \(store.text("settings"))"
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func refresh() { Task { await store.refresh() } }
    @objc private func quit() { NSApp.terminate(nil) }

    /// 分辨率、缩放比例、Dock 和屏幕连接变化时重新计算，优先留在原显示器。
    @objc private func screenParametersChanged() {
        guard let window = launcherWindow, window.isVisible else { return }
        let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == launcherScreenNumber } ?? NSScreen.main
        if let screen { configure(window, on: screen) }
    }

    @objc private func systemLocaleChanged() {
        if store.preferences.language == .system { applyPreferences(store.preferences); store.presentationID = UUID() }
    }

    private func configure(_ window: NSWindow, on screen: NSScreen) {
        launcherScreenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let interaction = store.preferences.interaction
        let layout = LauncherWindowLayout(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top, coverMenuBar: interaction.coverMenuBar, coverDock: interaction.coverDock)
        let frame = layout.frame
        let insets = layout.contentInsets
        window.setFrame(frame, display: false)
        let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let blur = store.preferences.interaction.backgroundBlur
        let wallpaperKey = "\(wallpaperURL?.path ?? "")|\(blur)"
        let key = "\(screen.deviceDescription)-\(frame)-\(insets)-\(wallpaperKey)"
        if configurationKey == key, let launcherView {
            if window.contentView !== launcherView { window.contentView = launcherView }
            return
        }
        configurationKey = key
        // 首屏只使用已经解码的缓存；大壁纸的读取、解码和模糊都不阻塞窗口出现。
        let native = NativeLauncherView(store: store, wallpaper: wallpaperCache[wallpaperKey], screenInsets: insets, wallpaperFrame: layout.wallpaperFrame)
        launcherView = native
        window.contentView = native
        wallpaperTask?.cancel()
        if let wallpaperURL {
            wallpaperTask = Task { [weak native] in
                let image = await wallpaperRenderer.render(url: wallpaperURL, radius: blur)
                guard !Task.isCancelled, let image else { return }
                let wallpaper = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                if wallpaperCache.count >= 3 { wallpaperCache.removeAll(keepingCapacity: true) }
                wallpaperCache[wallpaperKey] = wallpaper
                native?.setWallpaper(wallpaper)
            }
        }
    }

    private func applyPreferences(_ preferences: Preferences) {
        let appearance: NSAppearance? = switch preferences.theme {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
        NSApp.appearance = appearance
        let status = hotKey.setEnabled(preferences.hotKeyEnabled)
        store.hotkeyError = status == noErr ? nil : "\(store.text("hotkeyError")) (\(status))"
        settingsWindow?.title = "Sunny Launchpad · \(store.text("settings"))"
        if appliedInteraction != preferences.interaction {
            appliedInteraction = preferences.interaction
            applyWindowLevel()
            screenParametersChanged()
            updateSystemMenuBar(duration: windowMotion ?? 0)
        }
        rebuildMenus()
    }

    private var statusMenu: NSMenu?

    /// 左键显示启动器，右键在菜单栏图标处展示操作菜单。
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            if statusMenu == nil { rebuildMenus() }
            statusMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else { showLauncher() }
    }

    private func rebuildMenus() {
        let menu = NSMenu()
        menu.addItem(item("show", action: #selector(showLauncher)))
        menu.addItem(item("settings", action: #selector(showSettings), key: ","))
        menu.addItem(item("refresh", action: #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(item("quit", action: #selector(quit), key: "q"))
        statusMenu = menu
        let mainMenu = NSMenu()
        let root = NSMenuItem()
        root.title = "Sunny Launchpad"
        root.submenu = menu.copy() as? NSMenu
        mainMenu.addItem(root)
        // 标准编辑菜单使搜索框和名称编辑支持复制、粘贴、撤销。
        let edit = NSMenuItem()
        edit.title = store.text("edit")
        let editMenu = NSMenu()
        for (title, selector, key) in [("undo", Selector(("undo:")), "z"), ("cut", #selector(NSText.cut(_:)), "x"), ("copy", #selector(NSText.copy(_:)), "c"), ("paste", #selector(NSText.paste(_:)), "v"), ("selectAll", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: store.text(title), action: selector, keyEquivalent: key)
        }
        edit.submenu = editMenu
        mainMenu.addItem(edit)
        NSApp.mainMenu = mainMenu
    }

    private func item(_ key: String, action: Selector, key equivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: store.text(key), action: action, keyEquivalent: equivalent)
        item.target = self
        return item
    }
}

/// 无边框窗口仍需成为 key window，才能接收搜索与输入法事件。
private final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
