// 仅监听启动器窗口内事件，不安装全局键盘监视器，不读取其他应用输入。
import AppKit
import SwiftUI
import SunnyDomain

struct LauncherEventBridge: NSViewRepresentable {
    let store: LaunchpadStore

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.store = store
        view.install()
        return view
    }
    func updateNSView(_ nsView: EventView, context: Context) { nsView.store = store }
    static func dismantleNSView(_ nsView: EventView, coordinator: ()) { nsView.uninstall() }

    @MainActor final class EventView: NSView {
        var store: LaunchpadStore?
        private var monitor: Any?
        private var scrollDistance: CGFloat = 0
        private var lastPageTurn = Date.distantPast
        private let pageThreshold: CGFloat = 45
        private let pageCooldown: TimeInterval = 0.4
        private enum Key {
            static let escape: UInt16 = 53
            static let left: UInt16 = 123
            static let right: UInt16 = 124
            static let down: UInt16 = 125
            static let up: UInt16 = 126
            static let enter: UInt16 = 36
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
                return consumed ? nil : event
            }
        }
        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let store, let window, event.window === window, window.isKeyWindow else { return event }
            if event.type == .scrollWheel {
                guard event.momentumPhase.isEmpty, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                if event.phase == .began { scrollDistance = 0 }
                scrollDistance += event.scrollingDeltaX
                if abs(scrollDistance) > pageThreshold && Date().timeIntervalSince(lastPageTurn) > pageCooldown {
                    store.selectPage(store.activePage + (scrollDistance < 0 ? 1 : -1))
                    scrollDistance = 0
                    lastPageTurn = Date()
                }
                return nil
            }
            if event.keyCode == Key.escape { store.escape(); return nil }
            // 输入法候选期间不抢方向键或回车；文件夹名称编辑也使用原生文字行为。
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() || store.folder != nil { return event }
            let command = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case Key.left:
                if command { store.selectPage(store.activePage - 1) } else { store.navigate(-1) }
            case Key.right:
                if command { store.selectPage(store.activePage + 1) } else { store.navigate(1) }
            case Key.down: store.navigate(LaunchpadRules.columns)
            case Key.up: store.navigate(-LaunchpadRules.columns)
            case Key.enter:
                if store.visibleItems.indices.contains(store.selectedIndex) { store.activate(store.visibleItems[store.selectedIndex]) }
            default: return event
            }
            return nil
        }
    }
}
