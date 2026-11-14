// 实验性菜单栏动画：仅在用户开启后动态解析私有符号，不修改 Dock 或系统偏好。
import AppKit
import Darwin
import OSLog
import QuartzCore

@MainActor public final class SystemMenuBarAnimator: NSObject {
    /// ABI 与 LaunchOS 的 arm64 调用及 yabai 的 SkyLight 声明交叉核对。
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetMenuBarAlpha = @convention(c) (Int32, Double, Double, Float) -> Int32
    private static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let visibleAlpha: Float = 1
    private static let hiddenAlpha: Float = 0
    private static let fallbackRefreshRate = 60
    private let logger = Logger(subsystem: "com.creepersan.SunnyLaunchpad", category: "SystemMenuBarAnimation")
    private var framework: UnsafeMutableRawPointer?
    private var connection: Int32 = 0
    private var setMenuBarAlpha: SetMenuBarAlpha?
    private var attemptedLoading = false
    private var failed = false
    private var ownsAlpha = false
    private var link: CADisplayLink?
    private var currentAlpha = visibleAlpha
    private var startAlpha = visibleAlpha
    private var targetAlpha = visibleAlpha
    private var startTime = 0.0
    private var duration = 0.0

    public override init() { super.init() }

    /// 仅由显式开启实验选项的调用路径使用；反向过渡从上次实际提交值继续。
    public func animate(hidden: Bool, duration: Double, view: NSView) {
        guard loadFunctions(), !failed else { return }
        stop()
        startAlpha = currentAlpha
        targetAlpha = hidden ? Self.hiddenAlpha : Self.visibleAlpha
        self.duration = duration
        guard duration > 0, startAlpha != targetAlpha else { apply(targetAlpha); return }
        startTime = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(max(view.window?.screen?.maximumFramesPerSecond ?? Self.fallbackRefreshRate, 1))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(Float(Self.fallbackRefreshRate), rate), maximum: rate, preferred: rate)
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    /// 关停选项、失去焦点或退出时立即恢复；从未启用时不会加载或调用任何私有符号。
    public func restore() {
        stop()
        guard ownsAlpha, let setMenuBarAlpha else { return }
        let result = setMenuBarAlpha(connection, 0, 1, Self.visibleAlpha)
        if result == 0 { currentAlpha = Self.visibleAlpha; ownsAlpha = false }
        else { logger.error("恢复菜单栏透明度失败：\(result, privacy: .public)") }
    }

    /// 不强链接私有框架；缺少符号时回退到普通窗口覆盖。
    private func loadFunctions() -> Bool {
        if attemptedLoading { return setMenuBarAlpha != nil }
        attemptedLoading = true
        guard let framework = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            logger.notice("系统菜单栏动画不可用，使用普通窗口动画。")
            return false
        }
        guard let main = dlsym(framework, "CGSMainConnectionID"), let alpha = dlsym(framework, "CGSSetMenuBarInsetAndAlpha") else {
            dlclose(framework)
            logger.notice("系统菜单栏动画符号缺失，使用普通窗口动画。")
            return false
        }
        // 保留框架句柄直至进程退出，确保函数指针在动画和恢复期间始终有效。
        self.framework = framework
        connection = unsafeBitCast(main, to: MainConnection.self)()
        setMenuBarAlpha = unsafeBitCast(alpha, to: SetMenuBarAlpha.self)
        return true
    }

    /// 与 LaunchOS 相同，按实际经过时间线性插值菜单栏透明度，不假定固定帧率。
    @objc private func tick(_ sender: CADisplayLink) {
        let progress = min(max((CACurrentMediaTime() - startTime) / duration, 0), 1)
        apply(startAlpha + (targetAlpha - startAlpha) * Float(progress))
        if progress >= 1 { stop() }
    }

    private func apply(_ alpha: Float) {
        guard let setMenuBarAlpha else { return }
        let result = setMenuBarAlpha(connection, 0, 1, alpha)
        guard result == 0 else {
            failed = true
            logger.error("系统菜单栏动画失败：\(result, privacy: .public)，恢复并回退到普通窗口动画。")
            restore()
            return
        }
        currentAlpha = alpha
        ownsAlpha = alpha != Self.visibleAlpha
    }

    private func stop() { link?.invalidate(); link = nil }
}
