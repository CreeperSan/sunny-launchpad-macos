// 仅在动画期间采样所在显示器的回调节奏；不把回调 FPS 冒充实际 GPU 呈现 FPS。
import AppKit
import QuartzCore
import OSLog

@MainActor final class AnimationFrameMeter: NSObject {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var deadline = 0.0
    private var previous = 0.0
    private var samples: [Double] = []
    private let logger = Logger(subsystem: "com.creepersan.SunnyLaunchpad", category: "FrameTiming")

    func attach(to view: NSView) { self.view = view }
    func sample(for duration: Double) {
        guard duration > 0, let view, view.window != nil else { return }
        deadline = CACurrentMediaTime() + duration + 0.08
        guard link == nil else { return }
        samples.removeAll(keepingCapacity: true)
        previous = 0
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(max(view.window?.screen?.maximumFramesPerSecond ?? 60, 1))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ sender: CADisplayLink) {
        if previous > 0 { samples.append(sender.timestamp - previous) }
        previous = sender.timestamp
        guard CACurrentMediaTime() >= deadline || view?.window?.isVisible != true else { return }
        sender.invalidate()
        link = nil
        if !samples.isEmpty {
            let ordered = samples.sorted()
            let mean = samples.reduce(0, +) / Double(samples.count)
            let percentile = ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))] * 1000
            print("DisplayLink cadence Hz=\(1 / max(mean, 0.0001)) p95IntervalMs=\(percentile) screenMaxHz=\(view?.window?.screen?.maximumFramesPerSecond ?? 0)")
            logger.info("Display-link cadence: \(1 / max(mean, 0.0001), privacy: .public) Hz, p95 interval: \(percentile, privacy: .public) ms. This is not GPU presentation FPS.")
        }
    }
    func stop() { link?.invalidate(); link = nil }
}
