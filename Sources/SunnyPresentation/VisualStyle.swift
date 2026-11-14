// 图标后台解析为有限尺寸 CGImage，主线程只接收结果；避免翻页首次加载阻塞合成提交。
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import SunnyDomain

@MainActor final class AppIconCache {
    static let shared = AppIconCache()
    static let didLoad = Notification.Name("SunnyLaunchpadIconDidLoad")
    private let cache = NSCache<NSString, NSImage>()
    private let loader = NativeIconLoader()
    var directory: URL?
    private var pending = Set<String>()
    private var readyPaths = Set<String>()
    private var notificationTask: Task<Void, Never>?
    private let placeholder = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    private let notificationDelay: Duration = .milliseconds(24)

    private init() { cache.countLimit = 256; cache.totalCostLimit = 64 * 1024 * 1024 }

    func isReady(_ app: ApplicationRecord?) -> Bool {
        guard let app, app.isAvailable, let path = app.path else { return true }
        return cache.object(forKey: path as NSString) != nil
    }

    func image(for app: ApplicationRecord?) -> NSImage {
        guard let app, app.isAvailable, let path = app.path else { return placeholder }
        if let image = cache.object(forKey: path as NSString) { return image }
        guard pending.insert(path).inserted else { return placeholder }
        Task {
            let result = await loader.load(path, directory: directory)
            if let result {
                cache.setObject(NSImage(cgImage: result, size: NSSize(width: 128, height: 128)), forKey: path as NSString, cost: result.bytesPerRow * result.height)
            } else { cache.setObject(placeholder, forKey: path as NSString) }
            pending.remove(path)
            readyPaths.insert(path)
            // 固定小批次提交，持续到达的图标不会不断推迟已有结果的显示。
            guard notificationTask == nil else { return }
            notificationTask = Task {
                try? await Task.sleep(for: notificationDelay)
                let paths = readyPaths
                readyPaths.removeAll(keepingCapacity: true)
                notificationTask = nil
                NotificationCenter.default.post(name: Self.didLoad, object: nil, userInfo: ["paths": paths])
            }
        }
        return placeholder
    }
}

/// 读取与解码只发生在工作 actor；NSImage 不跨隔离边界传递。
private actor NativeIconLoader {
    private let pixels = 256
    private let diskEntryLimit = 512
    func load(_ path: String, directory: URL?) -> CGImage? {
        let modified = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(path)|\(modified)|\(pixels)".utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = directory?.appendingPathComponent(digest + ".png")
        if let destination, let source = CGImageSourceCreateWithURL(destination as CFURL, nil), let cached = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        var proposed = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let result = context.makeImage() else { return nil }
        if let destination, let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
            if let writer = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(writer, result, nil)
                if CGImageDestinationFinalize(writer) { try? FileManager.default.moveItem(at: temporary, to: destination) }
                try? FileManager.default.removeItem(at: temporary)
            }
            // 磁盘缓存有界，旧图标可按需重建。
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > diskEntryLimit {
                let sorted = files.sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
                for file in sorted.prefix(files.count - diskEntryLimit) { try? FileManager.default.removeItem(at: file) }
            }
        }
        return result
    }
}
