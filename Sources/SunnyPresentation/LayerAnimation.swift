// 稳定的 AppKit 承载视图：动画只更新合成图层，避免逐帧重建 SwiftUI 网格。
import AppKit
import QuartzCore

@MainActor enum LayerAnimation {
    // 以下为 Sunny 的调校值，非 Apple 未公开的“原生常量”。
    static let folderDuration = 0.30
    static let reorderDuration = 0.20
    static let folderHoverDelay: Duration = .milliseconds(450)
    /// 文件夹视图逐帧插值与图层动画共用同一条缓动曲线。
    static let timingX1 = 0.22
    static let timingY1 = 0.72
    static let timingX2 = 0.20
    static let timingY2 = 1.0
    static let timing = CAMediaTimingFunction(controlPoints: Float(timingX1), Float(timingY1), Float(timingX2), Float(timingY2))

    /// AppKit backing layer 的锚点在原点，显式补偿平移使几何中心固定。
    static func centeredScale(x: CGFloat, y: CGFloat, size: CGSize) -> CATransform3D {
        var transform = CATransform3DMakeScale(x, y, 1)
        transform.m41 = size.width * (1 - x) / 2
        transform.m42 = size.height * (1 - y) / 2
        return transform
    }

    static func apply(_ layer: CALayer, key: String, value: Any, duration: Double, screen: NSScreen?, startValue: Any? = nil) {
        let from = startValue ?? layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        layer.removeAnimation(forKey: key)
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        let rate = Float(max(screen?.maximumFramesPerSecond ?? 60, 1))
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        layer.add(animation, forKey: key)
    }
}

