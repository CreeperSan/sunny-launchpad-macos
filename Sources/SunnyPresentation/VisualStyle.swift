// 两套材质共享内容结构；遵从系统减少透明度，主题仅影响视觉不改变数据。
import AppKit
import SwiftUI
import SunnyDomain

public extension Theme {
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .dark: .dark; case .light: .light }
    }
}

struct PanelSurface: ViewModifier {
    let style: InterfaceStyle
    var radius: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
        } else if style == .liquidGlass {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.16), lineWidth: 1))
        }
    }
}

/// 读取系统壁纸而非截屏，不要求屏幕录制权限；动态壁纸不可读时显示渐变。
struct WallpaperView: View {
    var wallpaper: NSImage?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: scheme == .dark ? [Color(red: 0.10, green: 0.15, blue: 0.24), Color(red: 0.19, green: 0.25, blue: 0.34)] : [Color(red: 0.68, green: 0.80, blue: 0.87), Color(red: 0.90, green: 0.82, blue: 0.74)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let wallpaper, !reduceTransparency {
                    Image(nsImage: wallpaper).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).blur(radius: 24)
                }
                (scheme == .dark ? Color.black : Color.white).opacity(scheme == .dark ? 0.34 : 0.30)
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .ignoresSafeArea()
    }
}

/// 图标缓存仅保留本机 NSImage；应用是否可用变化时使用不同缓存键。
@MainActor final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for app: ApplicationRecord?) -> NSImage {
        guard let app, app.isAvailable, let path = app.path else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        if let image = cache.object(forKey: path as NSString) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
