// 原生图标、图层容器与分页器；与启动器窗口布局和业务状态分别维护。
import AppKit
import QuartzCore
import SunnyDomain

/// 搜索栏玻璃边缘也接收点击，避免事件冒泡到启动器背景导致关闭。
@MainActor final class NativeSearchGlass: NSGlassEffectView {
    var focusSearch: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { focusSearch() }
    override func mouseUp(with event: NSEvent) {}
}

/// 经典和减少透明度模式下的搜索框底板，同样拦截空白处点击。
@MainActor final class NativeSearchBackground: NSView {
    var focusSearch: () -> Void = {}
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.cornerRadius = 22 }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { focusSearch() }
    override func mouseUp(with event: NSEvent) {}
}

/// 已解码图片直接作为图层内容，避免 NSImageView 在提交时反复走绘制与缩放路径。
@MainActor final class NativeImageSurface: NSView {
    var image: NSImage? { didSet { if oldValue !== image { needsDisplay = true } } }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() {
        layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// 可命中的原生图层容器；空白事件沿 responder 链交给根视图处理。
@MainActor final class NativeSurface: NSView {
    var consumeBackgroundEvents = false
    override func mouseDown(with event: NSEvent) { if !consumeBackgroundEvents { super.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) { if !consumeBackgroundEvents { super.mouseUp(with: event) } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
}

/// 独立图标视图保持稳定身份，实时重排只改变 frame，不销毁重建。
@MainActor final class NativeTile: NSView {
    /// 文件夹缩略图玻璃容器的圆角比例，与展开动画起点保持一致。
    static let folderCornerRadiusRatio: CGFloat = 0.23
    var item: LayoutItem?
    weak var owner: NativeLauncherView?
    let icon = NativeImageSurface()
    private let folderGlass = NSGlassEffectView()
    private let skeleton = CALayer()
    /// 拖放与文件夹过渡共用图标名称的实际布局和文字。
    let label = NSTextField(labelWithString: "")
    private var down = NSPoint.zero
    private var dragging = false
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        skeleton.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.22).cgColor
        skeleton.cornerRadius = 18
        skeleton.opacity = 0
        icon.layer?.addSublayer(skeleton)
        folderGlass.style = .clear
        folderGlass.cornerRadius = 24
        folderGlass.isHidden = true
        addSubview(folderGlass); addSubview(icon); addSubview(label)
        label.alignment = .center; label.maximumNumberOfLines = 2; label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .white
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let iconHit = icon.frame.insetBy(dx: -8, dy: -8)
        let labelHit = label.frame.intersection(NSRect(x: iconHit.minX, y: label.frame.minY, width: iconHit.width, height: label.frame.height))
        return !isHidden && (iconHit.contains(local) || labelHit.contains(local)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func configure(title: String, image: NSImage, iconSize: CGFloat, selected: Bool, grouping: Bool, loading: Bool, folderStyle: Bool? = nil) {
        folderGlass.isHidden = folderStyle != true
        icon.layer?.backgroundColor = folderStyle == false ? NSColor(white: 0.7, alpha: 0.32).cgColor : NSColor.clear.cgColor
        icon.layer?.cornerRadius = 18
        if label.stringValue != title { label.stringValue = title; setAccessibilityLabel(title) }
        if loading { icon.image = nil; skeleton.opacity = 1 }
        else if icon.image !== image { revealIcon(image, animated: skeleton.opacity > 0) }
        let size = NSSize(width: max(16, iconSize), height: max(16, iconSize))
        folderGlass.cornerRadius = size.width * Self.folderCornerRadiusRatio
        icon.layer?.cornerRadius = size.width * Self.folderCornerRadiusRatio
        if icon.frame.size != size { icon.setFrameSize(size); needsLayout = true }
        layer?.cornerRadius = 20
        layer?.borderWidth = selected || grouping ? 2 : 0
        layer?.borderColor = (grouping ? NSColor.controlAccentColor : NSColor.labelColor).cgColor
        if label.frame == .zero { needsLayout = true }
    }
    func revealIcon(_ image: NSImage, animated: Bool) {
        icon.image = image
        LayerAnimation.apply(skeleton, key: "opacity", value: Float(0), duration: animated ? 0.16 : 0, screen: window?.screen)
    }

    override func layout() {
        super.layout()
        skeleton.frame = icon.bounds
        icon.setFrameOrigin(NSPoint(x: bounds.midX - icon.frame.width / 2, y: max(0, (bounds.height - icon.frame.height - 30) / 2)))
        folderGlass.frame = icon.frame
        label.frame = NSRect(x: 2, y: icon.frame.maxY + 5, width: bounds.width - 4, height: 30)
    }
    override func mouseDown(with event: NSEvent) { down = event.locationInWindow; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        if !dragging, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) > 5 { dragging = true; owner?.beginTileDrag(self, event: event) }
        if dragging { owner?.moveTileDrag(event) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { owner?.endTileDrag(event) }
        else if let item { owner?.activate(item) }
        dragging = false
    }
    override func menu(for event: NSEvent) -> NSMenu? { item.flatMap { owner?.contextMenu(for: $0) } }
    override func accessibilityPerformPress() -> Bool { if let item { owner?.activate(item); return true }; return false }
}

/// 分页器整块命中，平均分配区域，空白也不穿透到桌面关闭操作。
@MainActor final class NativePageControl: NSView {
    var count = 1
    var active = 0
    var style: PagerStyle = .dots
    var select: (Int) -> Void = { _ in }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let cell = bounds.width / CGFloat(max(count, 1))
        for index in 0..<count {
            let center = CGFloat(index) * cell + cell / 2
            NSColor.white.withAlphaComponent(index == active ? 1 : 0.35).setFill()
            if style == .numbers {
                let title = "\(index + 1)"
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white]
                let size = (title as NSString).size(withAttributes: attributes)
                (title as NSString).draw(at: NSPoint(x: center - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            } else {
                let width: CGFloat = style == .capsules && index == active ? 22 : 8
                NSBezierPath(roundedRect: NSRect(x: center - width / 2, y: bounds.midY - 4, width: width, height: 8), xRadius: 4, yRadius: 4).fill()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let slot = Int(point.x / max(bounds.width / CGFloat(max(count, 1)), 1))
        select(min(max(slot, 0), max(count - 1, 0)))
    }
}
