// 组装根：只在这里选择基础设施实现，窗口生命周期与用户数据路径集中管理。
import AppKit
import SwiftUI
import SunnyDomain
import SunnyInfrastructure
import SunnyPresentation

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let dataDirectory = JSONWorkspaceRepository.defaultDirectory
    private lazy var store = LaunchpadStore(catalog: MacApplicationCatalog(), repository: JSONWorkspaceRepository(directory: dataDirectory), importer: LegacyLaunchpadImporter(), launcher: MacApplicationLauncher())
    private var launcherWindow: LauncherWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let hotKey = GlobalHotKey()
    private var ready = false
    private var launcherScreenNumber: NSNumber?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        store.dismiss = { [weak self] in self?.hideLauncher() }
        store.openSettings = { [weak self] in self?.showSettings() }
        store.preferencesChanged = { [weak self] preferences in self?.applyPreferences(preferences) }
        hotKey.action = { [weak self] in self?.toggleLauncher() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Sunny Launchpad")
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemLocaleChanged), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        rebuildMenus()
        ready = true
        showLauncher()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ready { showLauncher() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { hotKey.stop() }
    func applicationDidResignActive(_ notification: Notification) { hideLauncher() }

    /// 不创建原生全屏 Space；覆盖鼠标所在显示器，保留普通桌面切换方式。
    @objc private func showLauncher() {
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
        configure(window, on: screen)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { await store.prepare() }
    }

    @objc private func hideLauncher() { launcherWindow?.orderOut(nil) }
    @objc private func toggleLauncher() {
        if launcherWindow?.isVisible == true { hideLauncher() } else { showLauncher() }
    }

    @objc private func showSettings() {
        hideLauncher()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store, dataDirectory: dataDirectory))
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
        let frame = screen.frame
        let visible = screen.visibleFrame.intersection(frame)
        let insets = EdgeInsets(top: max(0, frame.maxY - visible.maxY), leading: max(0, visible.minX - frame.minX), bottom: max(0, visible.minY - frame.minY), trailing: max(0, frame.maxX - visible.maxX))
        let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen).flatMap(NSImage.init(contentsOf:))
        window.contentView = NSHostingView(rootView: LauncherView(store: store, wallpaper: wallpaper, screenInsets: insets))
        window.setFrame(frame, display: true)
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
        rebuildMenus()
    }

    private func rebuildMenus() {
        let menu = NSMenu()
        menu.addItem(item("show", action: #selector(showLauncher)))
        menu.addItem(item("settings", action: #selector(showSettings), key: ","))
        menu.addItem(item("refresh", action: #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(item("quit", action: #selector(quit), key: "q"))
        statusItem?.menu = menu
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
