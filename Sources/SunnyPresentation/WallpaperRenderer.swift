// 后台预渲染模糊壁纸，clamp 后裁剪避免暗边；动画只合成缓存结果。
import AppKit
import CoreImage

public actor WallpaperRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cache: [String: CGImage] = [:]
    public init() {}

    public func render(url: URL, radius: Double) -> CGImage? {
        let key = "\(url.path)|\(radius)"
        if let cached = cache[key] { return cached }
        guard let source = CIImage(contentsOf: url), source.extent.width > 0 else { return nil }
        let maximumWidth = radius == 0 ? 4096.0 : 1600.0
        let scale = min(1, maximumWidth / source.extent.width)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = radius == 0 ? scaled : scaled.clampedToExtent().applyingGaussianBlur(sigma: radius * scale).cropped(to: scaled.extent)
        guard let image = context.createCGImage(blurred, from: scaled.extent) else { return nil }
        // 控制缓存上限，避免反复拖动设置滑块累积大图。
        if cache.count >= 3 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }
}
