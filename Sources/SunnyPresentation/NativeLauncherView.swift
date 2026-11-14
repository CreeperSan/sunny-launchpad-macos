// 原生启动器：网格、输入、拖放和模态文件夹均使用 AppKit，动画仅改变合成图层。
import AppKit
import Observation
import QuartzCore
import SunnyDomain

@MainActor public final class NativeLauncherView: NSView, NSTextFieldDelegate {
    /// 搜索条与屏幕安全区域顶部的间距。
    private static let searchTopSpacing: CGFloat = 38
    /// 文件夹标题与面板之间的布局尺寸。
    private static let folderHeaderHeight: CGFloat = 62
    private static let folderTitleFontSize: CGFloat = 28
    /// 文件夹标题只作上下滑动，不跟随文件夹缩略图缩放。
    private static let folderTitleOffset: CGFloat = 16
    /// 缩略图未展示的图标在淡入淡出时保留轻微缩放。
    private static let folderExtraIconScale: CGFloat = 0.8
    /// 文件夹详情玻璃容器的目标圆角。
    private static let folderCornerRadius: CGFloat = 44
    /// 曲线求解精度以及无法读取屏幕刷新率时的兜底帧率。
    private static let timingSearchSteps = 12
    private static let fallbackFrameRate = 60
    /// 手势位置两侧预备的页数。
    private static let pagePreloadRadius = 1
    /// 拖到网格边缘并停留后翻页，避免经过边缘时误触。
    private static let dragPageEdgeWidth: CGFloat = 60
    private static let dragPageDelay: Duration = .milliseconds(650)
    private let store: LaunchpadStore
    private let wallpaper = NativeImageSurface()
    private let tint = NSView()
    private let content = NativeSurface()
    private let searchGlass = NativeSearchGlass()
    private let searchBackground = NativeSearchBackground()
    private let search = NSTextField()
    private let searchIcon = NSImageView()
    private let pages = NativeSurface()
    private let pager = NativePageControl()
    private let loading = NSTextField(labelWithString: "")
    private let folder = NativeSurface()
    private let folderBackground = NSView()
    private let folderGlass = NSGlassEffectView()
    private let folderTitle = NSTextField()
    private let folderPages = NativeSurface()
    private let folderPager = NativePageControl()
    private var pageViews: [Int: NativeSurface] = [:]
    private var folderPageViews: [Int: NativeSurface] = [:]
    private var tiles: [String: NativeTile] = [:]
    private var folderTiles: [String: NativeTile] = [:]
    private var insets: NSEdgeInsets
    private var refreshQueued = false
    private var revision = ""
    private var thumbnails: [String: (AppFolder, NSImage)] = [:]
    private var previousFolderPagePosition = Double.nan
    private var previousPage = Double.nan
    private var previousReveal = Double.nan
    private var previousFolderProgress = Double.nan
    private var previousFolderID: String?
    private var folderSource = CGRect.zero
    private var settleTask: Task<Void, Never>?
    private var pageCleanupTask: Task<Void, Never>?
    private var retainingAnimatedPages = false
    private var dragSource: String?
    private var dragTarget: LayoutItem?
    private var dragGroup = false
    private var lastPreview: String?
    private var previewContext: String?
    private var folderTransitionTask: Task<Void, Never>?
    private var folderPanelTask: Task<Void, Never>?
    private var folderTransitionIcons: [CALayer] = []
    private var folderTransitionHiddenIcons: [CALayer] = []
    private var folderTransitionHiddenLabels: [NSView] = []
    private var dragMonitor: Any?
    private var dragPageTask: Task<Void, Never>?
    private var dragPageDirection = 0
    private var dragTargetPage: Int?
    private let ghost = CALayer()
    private let dragGlass = NSGlassEffectView()
    private var pointerStart = NSPoint.zero
    private var pointerLast = NSPoint.zero
    private var pointerDragging = false
    private var previousBounds = CGRect.zero
    private var renderedError: String?
    private let frameMeter = AnimationFrameMeter()
    private let skeletonGrid = NativeSurface()

    public static func configureIconCache(directory: URL) { AppIconCache.shared.directory = directory }

    public init(store: LaunchpadStore, wallpaper image: NSImage?, screenInsets: NSEdgeInsets) {
        self.store = store
        insets = screenInsets
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        wallpaper.image = image
        wallpaper.layer?.contentsGravity = .resize
        addSubview(wallpaper)
        tint.wantsLayer = true
        addSubview(tint)
        addSubview(content)
        // 玻璃仅用于控件表面，避免对整个 4K 背景持续采样。
        content.addSubview(searchBackground)
        searchGlass.style = .clear
        searchGlass.cornerRadius = 22
        content.addSubview(searchGlass)
        content.addSubview(searchIcon)
        content.addSubview(search)
        content.addSubview(pages)
        content.addSubview(pager)
        content.addSubview(loading)
        pages.addSubview(skeletonGrid)
        pages.layer?.masksToBounds = true
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        search.isBordered = false
        search.drawsBackground = false
        search.font = .systemFont(ofSize: 15)
        search.textColor = .white
        search.cell?.usesSingleLineMode = true
        search.cell?.isScrollable = true
        search.cell?.wraps = false
        searchGlass.focusSearch = { [weak self] in
            guard let self, self.store.folderID == nil else { return }
            self.window?.makeFirstResponder(self.search)
        }
        searchBackground.focusSearch = { [weak self] in
            guard let self, self.store.folderID == nil else { return }
            self.window?.makeFirstResponder(self.search)
        }
        search.isEditable = true
        search.isSelectable = true
        search.maximumNumberOfLines = 1
        search.delegate = self
        // 搜索内容变化不触发启动，只有明确回车或点击图标才会启动。
        search.target = nil
        search.action = nil
        loading.alignment = .center
        loading.textColor = .white
        folder.consumeBackgroundEvents = true
        folderPages.consumeBackgroundEvents = true
        folder.wantsLayer = true
        folder.layer?.cornerRadius = Self.folderCornerRadius
        // 收起时玻璃需要移动到详情面板之外的原始图标位置。
        folder.layer?.masksToBounds = false
        folderBackground.wantsLayer = true
        folderBackground.layer?.cornerRadius = Self.folderCornerRadius
        folder.addSubview(folderBackground)
        folderGlass.cornerRadius = Self.folderCornerRadius
        folderGlass.style = .clear
        folder.addSubview(folderGlass)
        // 分别裁剪玻璃和不透明背景，使两种外观使用相同的圆角过渡。
        folderGlass.layer?.masksToBounds = true
        folderBackground.layer?.masksToBounds = true
        folder.isHidden = true
        addSubview(folder)
        dragGlass.style = .clear
        dragGlass.isHidden = true
        addSubview(dragGlass)
        folderTitle.isBordered = false
        folderTitle.focusRingType = .none
        folderTitle.drawsBackground = false
        folderTitle.alignment = .center
        folderTitle.font = .systemFont(ofSize: Self.folderTitleFontSize, weight: .medium)
        folderTitle.textColor = .white
        folderTitle.delegate = self
        folderTitle.target = self
        folderTitle.action = #selector(renameFolder)
        folder.addSubview(folderTitle)
        folder.addSubview(folderPages)
        folder.addSubview(folderPager)
        folderPages.layer?.masksToBounds = true
        pager.select = { [weak store] in store?.selectPage($0) }
        folderPager.select = { [weak store] in store?.selectPage($0) }
        ghost.opacity = 0
        ghost.zPosition = 100
        layer?.addSublayer(ghost)
        NotificationCenter.default.addObserver(self, selector: #selector(iconsLoaded(_:)), name: AppIconCache.didLoad, object: nil)
        observe()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, dragSource != nil { cancelTileDrag() }
        window?.makeFirstResponder(search)
        frameMeter.attach(to: self)
        render()
    }

    /// Observation 只合并业务状态更新；CA 动画的中间帧不经过此方法。
    private func observe() {
        withObservationTracking {
            _ = store.state; _ = store.layoutRevision; _ = store.query; _ = store.pagePosition
            _ = store.selectedIndex; _ = store.keyboardSelection; _ = store.organizing
            _ = store.folderID; _ = store.folderProgress; _ = store.revealProgress
            _ = store.busy; _ = store.groupingReady; _ = store.groupingTarget
            _ = store.presentationID; _ = store.errorMessage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                self.queueRender()
            }
        }
    }
    @objc private func iconsLoaded(_ notification: Notification) {
        let paths = notification.userInfo?["paths"] as? Set<String> ?? []
        // 图片准备就绪只替换对应 image，不重建网格、不改变 frame、不重新注册可访问性。
        for tile in Array(tiles.values) + Array(folderTiles.values) {
            guard let item = tile.item else { continue }
            switch item {
            case .app(let id):
                if let app = store.app(id), let path = app.path, paths.contains(path) { tile.revealIcon(AppIconCache.shared.image(for: app), animated: true) }
            case .folder(let folder):
                if folder.appIDs.contains(where: { store.app($0)?.path.map { paths.contains($0) } == true }) {
                    thumbnails.removeValue(forKey: folder.id)
                    tile.revealIcon(folderThumbnail(folder), animated: true)
                }
            }
        }
    }

    private func queueRender() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.render()
        }
    }

    public override func layout() {
        super.layout()
        guard previousBounds != bounds else { return }
        previousBounds = bounds
        wallpaper.frame = bounds.insetBy(dx: -64, dy: -64)
        tint.frame = bounds
        content.frame = bounds
        let area = bounds.insetBy(dx: 0, dy: 0)
        searchGlass.frame = NSRect(x: area.midX - 166, y: insets.top + Self.searchTopSpacing, width: 332, height: 44)
        searchBackground.frame = searchGlass.frame
        searchIcon.frame = NSRect(x: searchGlass.frame.minX + 14, y: searchGlass.frame.midY - 8, width: 16, height: 16)
        search.frame = NSRect(x: searchGlass.frame.minX + 39, y: searchGlass.frame.midY - 11, width: searchGlass.frame.width - 54, height: 22)
        pages.frame = NSRect(x: 0, y: insets.top + 85, width: bounds.width, height: max(100, bounds.height - insets.top - insets.bottom - 190))
        pager.frame = NSRect(x: bounds.midX - 90, y: bounds.height - insets.bottom - 88, width: 180, height: 44)
        loading.frame = NSRect(x: bounds.midX - 250, y: bounds.midY - 20, width: 500, height: 40)
        revision = ""
        previousPage = .nan
        render()
    }

    private func render() {
        guard bounds.width > 0 else { return }
        let preferences = store.preferences
        let config = preferences.interaction
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rgb = UInt32(config.dimColorHex, radix: 16) ?? 0
        tint.layer?.backgroundColor = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: config.dimOpacity).cgColor
        let glass = preferences.style == .liquidGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        searchGlass.isHidden = !glass
        searchBackground.isHidden = glass
        searchBackground.layer?.backgroundColor = NSColor(white: 0.15, alpha: dark ? 0.75 : 0.55).cgColor
        search.focusRingType = glass ? .none : .default
        folderGlass.isHidden = !glass
        folderBackground.isHidden = glass
        folderBackground.layer?.backgroundColor = NSColor(white: dark ? 0.16 : 0.88, alpha: 0.94).cgColor
        folder.layer?.backgroundColor = NSColor.clear.cgColor
        if search.placeholderString != store.text("search"), let cell = search.cell as? NSTextFieldCell {
            cell.placeholderAttributedString = NSAttributedString(string: store.text("search"), attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.7)])
        }
        if search.stringValue != store.query { search.stringValue = store.query }
        loading.stringValue = store.state.catalog.isEmpty ? store.text(store.catalogLoading ? "loading" : "empty") : ""
        let modal = store.folderID != nil
        search.isEnabled = !modal
        pager.isHidden = modal
        let signature = "\(store.pageIndex)|\(store.folderPage)|\(store.layoutRevision)|\(store.query)|\(config)|\(store.keyboardSelection)|\(store.selectedIndex)|\(store.groupingTarget ?? "")|\(store.groupingReady)"
        let changed = revision != signature
        revision = signature
        let oldPosition = modal ? previousFolderPagePosition : previousPage
        if !store.pageDragging && oldPosition.isFinite && oldPosition != store.pagePosition && store.motion != nil && config.pageAnimation != .none {
            // 连续翻页期间保留正在运动的页面，动画结束后再回收。
            retainingAnimatedPages = true
            pageCleanupTask?.cancel()
            pageCleanupTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(config.pageDuration))
                guard !Task.isCancelled, let self else { return }
                self.retainingAnimatedPages = false
                self.queueRender()
            }
        }
        let metrics = LauncherMetrics(availableSize: NSSize(width: bounds.width, height: pages.bounds.height + LauncherMetrics.verticalChrome), configuration: config)
        let rootPages = store.isSearching ? LayoutEditor.chunks(store.searchResults.map { LayoutItem.app($0.id) }, size: config.capacity) : store.displayedLayout.pages.map(\.items)
        updateSkeleton(metrics: metrics)
        updatePages(rootPages.isEmpty ? [[]] : rootPages, surfaces: &pageViews, tileMap: &tiles, container: pages, metrics: metrics, columns: config.columns, rows: config.rows, rebuild: changed, inFolder: false)
        // 过渡层独占展开中的文件夹，避免主页面的缩略图和玻璃容器同时露出。
        for (id, tile) in tiles { tile.isHidden = store.folderID.map { id == "folder:\($0)" } ?? false }
        if !modal {
            pager.count = store.pageCount; pager.active = store.activePage; pager.style = config.pagerStyle
            pager.needsDisplay = true
            if changed || previousPage != store.pagePosition {
                transformPages(pageViews, position: store.pagePosition, container: pages, animated: !store.pageDragging && previousPage.isFinite && previousPage != store.pagePosition)
            }
            previousPage = store.pagePosition
        } else if previousFolderID != store.folderID {
            // 打开文件夹时先固定主页面，避免尚未结束的翻页在关闭时再次播放。
            transformPages(pageViews, position: store.rootPagePosition, container: pages, animated: false)
            previousPage = store.rootPagePosition
        }
        updateFolder(changed: changed)
        if previousReveal != store.revealProgress {
            let progress = store.revealProgress
            let duration = previousReveal.isFinite ? transitionDuration : 0
            let scale = config.windowAnimation == .classic ? 1 + (1 - progress) * 0.14 : 1
            var transform = LayerAnimation.centeredScale(x: scale, y: scale, size: content.bounds.size)
            if config.windowAnimation == .rise { transform = CATransform3DTranslate(transform, 0, (1 - progress) * 60, 0) }
            let entering = previousReveal == 0 && progress == 1
            if let layer = content.layer {
                // 入场起点以已配置的模型图层为准：窗口刚显示时 presentation 可能仍是旧的恒等变换。
                let start = entering ? NSValue(caTransform3D: layer.transform) : nil
                LayerAnimation.apply(layer, key: "transform", value: NSValue(caTransform3D: transform), duration: duration, screen: window?.screen, startValue: start)
            }
            // 整个启动器淡出，包括壁纸和正在打开的文件夹；窗口在动画完成前保持原层级。
            // 起始帧保持透明，避免布局完成后先出现静止画面，再开始动画。
            if let layer { LayerAnimation.apply(layer, key: "opacity", value: Float(progress), duration: duration, screen: window?.screen, startValue: entering ? Float(0) : nil) }
            frameMeter.sample(for: duration)
            previousReveal = progress
        }
        if let error = store.errorMessage, error != renderedError, let window, window.isVisible {
            renderedError = error
            let alert = NSAlert(); alert.messageText = store.text("error"); alert.informativeText = error
            alert.beginSheetModal(for: window) { [weak store] _ in Task { @MainActor in store?.errorMessage = nil } }
        }
    }

    private var transitionDuration: Double {
        store.motion == nil || store.preferences.interaction.windowAnimation == .none ? 0 : store.preferences.interaction.windowDuration
    }

    private func updatePages(_ data: [[LayoutItem]], surfaces: inout [Int: NativeSurface], tileMap: inout [String: NativeTile], container: NSView, metrics: LauncherMetrics, columns: Int, rows: Int, rebuild: Bool, inFolder: Bool, iconSizeOverride: CGFloat? = nil) {
        let active = inFolder ? store.folderPage : store.pageIndex
        guard !data.isEmpty else { return }
        // 跟随浮点位置预加载，快速跨页时不受尚未更新的 activePage 限制。
        let position = inFolder ? store.folderPagePosition : store.rootPagePosition
        let first = max(0, min(data.count - 1, Int(floor(position)) - Self.pagePreloadRadius))
        let last = max(first, min(data.count - 1, Int(ceil(position)) + Self.pagePreloadRadius))
        var retained = Set(first...last)
        if retainingAnimatedPages {
            retained.formUnion(surfaces.keys.filter { $0 < data.count })
            let previous = inFolder ? previousFolderPagePosition : previousPage
            if previous.isFinite && !store.pageDragging && (inFolder || store.folderID == nil) {
                // 点击分页器跨多页时，动画途经的页面也必须存在。
                let start = max(0, min(data.count - 1, Int(floor(min(previous, position)))))
                let end = max(start, min(data.count - 1, Int(ceil(max(previous, position)))))
                retained.formUnion(start...end)
            }
        }
        guard rebuild || Set(surfaces.keys) != retained else { return }
        let wantedIDs = Set(retained.flatMap { data[$0].map(\.id) })
        for id in Array(tileMap.keys) where !wantedIDs.contains(id) { tileMap.removeValue(forKey: id)?.removeFromSuperview() }
        for index in Array(surfaces.keys) where !retained.contains(index) { surfaces.removeValue(forKey: index)?.removeFromSuperview() }
        for pageIndex in retained {
            let surface: NativeSurface
            if let existing = surfaces[pageIndex] {
                surface = existing
                if !rebuild { continue }
            }
            else {
                surface = NativeSurface()
                // 新页面从上一帧的正确位置进入，快速连翻时不会从中央闪现。
                let previous = inFolder ? previousFolderPagePosition : previousPage
                let initial = previous.isFinite ? previous : position
                surface.frame = NSRect(x: (Double(pageIndex) - initial) * container.bounds.width, y: 0, width: container.bounds.width, height: container.bounds.height)
                surfaces[pageIndex] = surface; container.addSubview(surface)
            }
            if surface.frame.size != container.bounds.size { surface.setFrameSize(container.bounds.size) }
            let width = max(1, (container.bounds.width - metrics.horizontalPadding * 2) / CGFloat(columns))
            let height = container.bounds.height / CGFloat(rows)
            for (index, item) in data[pageIndex].enumerated() {
                let tile: NativeTile
                if let existing = tileMap[item.id] { tile = existing }
                else { tile = NativeTile(); tileMap[item.id] = tile }
                let oldFrame = tile.frame
                let animate = tile.superview === surface && oldFrame != .zero && store.dragPreviewActive
                if tile.superview !== surface { tile.removeFromSuperview(); surface.addSubview(tile) }
                tile.item = item
                tile.owner = self
                let title: String
                let image: NSImage
                switch item {
                case .app(let id):
                    let app = store.app(id)
                    title = (app?.name ?? id) + (app?.isAvailable == false ? " · \(store.text("missing"))" : "")
                    image = AppIconCache.shared.image(for: app)
                case .folder(let folder):
                    title = folder.name
                    image = folderThumbnail(folder)
                }
                // 文件夹优先沿用主页面图标尺寸，同时受当前单元格限制，避免小屏重叠。
                let iconSize = min(iconSizeOverride ?? metrics.iconSize, height - 32, width - 16)
                tile.configure(title: title, image: image, iconSize: iconSize, selected: pageIndex == active && store.keyboardSelection && store.selectedIndex == index, grouping: store.groupingTarget == item.id && store.groupingReady, loading: { if case .app(let id) = item { !AppIconCache.shared.isReady(store.app(id)) } else { false } }(), folderStyle: { if case .folder = item { store.preferences.style == .liquidGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency } else { nil } }())
                let target = NSRect(x: metrics.horizontalPadding + CGFloat(index % columns) * width, y: CGFloat(index / columns) * height, width: width, height: height)
                let from = tile.layer?.presentation()?.position ?? tile.layer?.position
                tile.frame = target
                if animate, let layer = tile.layer, let from {
                    let animation = CABasicAnimation(keyPath: "position"); animation.fromValue = NSValue(point: from); animation.toValue = NSValue(point: layer.position); animation.duration = LayerAnimation.reorderDuration; animation.timingFunction = LayerAnimation.timing
                    requestRefreshRate(animation)
                    layer.add(animation, forKey: "position")
                }
                tile.alphaValue = dragSource == item.id ? 0.18 : 1
            }
        }
    }

    /// 首次列表未到达时显示静态骨架，不用持续 shimmer 消耗高刷新率资源。
    private func updateSkeleton(metrics: LauncherMetrics) {
        skeletonGrid.isHidden = !store.catalogLoading || !store.state.catalog.isEmpty
        guard !skeletonGrid.isHidden else { return }
        skeletonGrid.frame = pages.bounds
        let columns = store.preferences.interaction.columns
        let rows = store.preferences.interaction.rows
        let count = min(columns * rows, 35)
        if skeletonGrid.layer?.sublayers?.count != count {
            skeletonGrid.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            for _ in 0..<count { let tile = CALayer(); tile.cornerRadius = 18; skeletonGrid.layer?.addSublayer(tile) }
        }
        let width = (pages.bounds.width - metrics.horizontalPadding * 2) / CGFloat(columns)
        let height = pages.bounds.height / CGFloat(rows)
        for (index, layer) in (skeletonGrid.layer?.sublayers ?? []).enumerated() {
            layer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.20).cgColor
            layer.frame = CGRect(x: metrics.horizontalPadding + (CGFloat(index % columns) + 0.5) * width - metrics.iconSize / 2, y: CGFloat(index / columns) * height + 8, width: metrics.iconSize, height: metrics.iconSize)
        }
    }

    private func folderThumbnail(_ folder: AppFolder) -> NSImage {
        if let cached = thumbnails[folder.id], cached.0 == folder { return cached.1 }
        let image = NSImage(size: NSSize(width: 96, height: 96))
        image.lockFocus()
        for (index, id) in folder.appIDs.prefix(9).enumerated() {
            AppIconCache.shared.image(for: store.app(id)).draw(in: NSRect(x: 10 + (index % 3) * 27, y: 65 - (index / 3) * 27, width: 23, height: 23))
        }
        image.unlockFocus()
        thumbnails[folder.id] = (folder, image)
        return image
    }

    /// 缩略图与详情共用同一组几何位置，避免过渡时图标跳动。
    private func thumbnailRect(_ index: Int, in frame: CGRect) -> CGRect {
        let scale = frame.width / 96
        return CGRect(x: frame.minX + CGFloat(10 + index % 3 * 27) * scale, y: frame.minY + CGFloat(8 + index / 3 * 27) * scale, width: 23 * scale, height: 23 * scale)
    }

    /// 同步更新原生玻璃的尺寸和圆角，避免直接修改视图托管图层导致坐标错位。
    private func setFolderPanel(frame: CGRect, cornerRadius: CGFloat) {
        folderGlass.frame = frame
        folderGlass.cornerRadius = cornerRadius
        folderBackground.frame = frame
        folderBackground.layer?.cornerRadius = cornerRadius
    }

    /// 根据屏幕刷新率插值原生视图；反向时从当前帧继续，不跳回动画起点。
    private func animateFolderPanel(from start: CGRect, radius startRadius: CGFloat, to end: CGRect, radius endRadius: CGFloat, duration: Double) {
        folderPanelTask?.cancel(); folderPanelTask = nil
        setFolderPanel(frame: start, cornerRadius: startRadius)
        guard duration > 0 else { setFolderPanel(frame: end, cornerRadius: endRadius); return }
        let startTime = CACurrentMediaTime()
        let interval = 1.0 / Double(max(window?.screen?.maximumFramesPerSecond ?? Self.fallbackFrameRate, 1))
        folderPanelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = min((CACurrentMediaTime() - startTime) / duration, 1)
                // 与其他过渡使用相同的贝塞尔缓动，先根据横坐标求曲线参数。
                var lower = 0.0, upper = 1.0
                for _ in 0..<Self.timingSearchSteps {
                    let t = (lower + upper) / 2
                    let x = 3 * (1 - t) * (1 - t) * t * LayerAnimation.timingX1 + 3 * (1 - t) * t * t * LayerAnimation.timingX2 + t * t * t
                    if x < elapsed { lower = t } else { upper = t }
                }
                let t = (lower + upper) / 2
                let progress = CGFloat(3 * (1 - t) * (1 - t) * t * LayerAnimation.timingY1 + 3 * (1 - t) * t * t * LayerAnimation.timingY2 + t * t * t)
                func interpolate(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
                let frame = CGRect(x: interpolate(start.minX, end.minX), y: interpolate(start.minY, end.minY), width: interpolate(start.width, end.width), height: interpolate(start.height, end.height))
                self.setFolderPanel(frame: frame, cornerRadius: interpolate(startRadius, endRadius))
                if elapsed >= 1 {
                    self.setFolderPanel(frame: end, cornerRadius: endRadius)
                    self.folderPanelTask = nil
                    return
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// 过渡期间由独立文字图层接管真实标签，避免两份文字重叠。
    private func animateFolderText(_ text: String, from source: CGRect, sourceFont: CGFloat, to destination: CGRect, destinationFont: CGFloat, opening: Bool, fade: Bool, duration: Double) {
        guard let layer, !source.isEmpty, !destination.isEmpty else { return }
        let proxy = CATextLayer()
        proxy.string = text
        proxy.font = NSFont.systemFont(ofSize: destinationFont, weight: .medium)
        proxy.fontSize = opening ? destinationFont : sourceFont
        proxy.foregroundColor = NSColor.white.cgColor
        proxy.alignmentMode = .center
        proxy.truncationMode = .end
        proxy.isWrapped = true
        proxy.contentsScale = window?.backingScaleFactor ?? 2
        proxy.zPosition = 91
        let start = opening ? source : destination
        let end = opening ? destination : source
        proxy.frame = end
        layer.addSublayer(proxy)
        folderTransitionIcons.append(proxy)
        LayerAnimation.apply(proxy, key: "position", value: NSValue(point: CGPoint(x: end.midX, y: end.midY)), duration: duration, screen: window?.screen, startValue: NSValue(point: CGPoint(x: start.midX, y: start.midY)))
        LayerAnimation.apply(proxy, key: "bounds", value: NSValue(rect: CGRect(origin: .zero, size: end.size)), duration: duration, screen: window?.screen, startValue: NSValue(rect: CGRect(origin: .zero, size: start.size)))
        LayerAnimation.apply(proxy, key: "fontSize", value: opening ? destinationFont : sourceFont, duration: duration, screen: window?.screen, startValue: opening ? sourceFont : destinationFont)
        if fade { LayerAnimation.apply(proxy, key: "opacity", value: Float(opening ? 1 : 0), duration: duration, screen: window?.screen, startValue: Float(opening ? 0 : 1)) }
    }

    /// 使用独立图层承接前九个图标及名称。
    private func animateFolderTransition(_ data: AppFolder, opening: Bool, duration: Double) {
        folderTransitionTask?.cancel()
        folderTransitionIcons.forEach { $0.removeFromSuperlayer() }
        folderTransitionHiddenIcons.forEach { $0.opacity = 1 }
        folderTransitionHiddenLabels.forEach { $0.isHidden = false }
        folderTransitionIcons.removeAll(); folderTransitionHiddenIcons.removeAll(); folderTransitionHiddenLabels.removeAll()
        guard duration > 0, let layer else { return }
        folder.layoutSubtreeIfNeeded()
        let ids = store.folderPage == 0 ? Array(data.appIDs.prefix(9)) : []
        for (index, id) in ids.enumerated() {
            guard let tile = folderTiles["app:\(id)"], tile.superview === folderPageViews[0] else { continue }
            tile.layoutSubtreeIfNeeded()
            let destination = tile.icon.convert(tile.icon.bounds, to: self)
            let source = thumbnailRect(index, in: folderSource)
            guard !destination.isEmpty, let iconLayer = tile.icon.layer else { continue }
            let proxy = CALayer()
            proxy.contents = AppIconCache.shared.image(for: store.app(id)).cgImage(forProposedRect: nil, context: nil, hints: nil)
            proxy.contentsGravity = .resizeAspect
            proxy.zPosition = 90
            proxy.frame = opening ? destination : source
            layer.addSublayer(proxy)
            iconLayer.opacity = 0
            folderTransitionIcons.append(proxy); folderTransitionHiddenIcons.append(iconLayer)
            let start = opening ? source : destination
            let end = opening ? destination : source
            LayerAnimation.apply(proxy, key: "position", value: NSValue(point: CGPoint(x: end.midX, y: end.midY)), duration: duration, screen: window?.screen, startValue: NSValue(point: CGPoint(x: start.midX, y: start.midY)))
            LayerAnimation.apply(proxy, key: "bounds", value: NSValue(rect: CGRect(origin: .zero, size: end.size)), duration: duration, screen: window?.screen, startValue: NSValue(rect: CGRect(origin: .zero, size: start.size)))
            let labelFrame = tile.label.convert(tile.label.bounds, to: self)
            let scale = source.width / max(destination.width, 1)
            let labelSource = CGRect(x: source.midX - labelFrame.width * scale / 2, y: source.maxY, width: labelFrame.width * scale, height: labelFrame.height * scale)
            let fontSize = tile.label.font?.pointSize ?? NSFont.systemFontSize
            animateFolderText(tile.label.stringValue, from: labelSource, sourceFont: fontSize * scale, to: labelFrame, destinationFont: fontSize, opening: opening, fade: true, duration: duration)
            tile.label.isHidden = true
            folderTransitionHiddenLabels.append(tile.label)
        }
        // 没有缩略图对应位置的图标单独淡入淡出并缩放，避免突然出现。
        let visibleIDs = data.pages.indices.contains(store.folderPage) ? data.pages[store.folderPage] : []
        let fadingIDs = store.folderPage == 0 ? visibleIDs.dropFirst(9) : visibleIDs.dropFirst(0)
        for id in fadingIDs {
            guard let tile = folderTiles["app:\(id)"], tile.superview === folderPageViews[store.folderPage], let iconLayer = tile.icon.layer else { continue }
            tile.layoutSubtreeIfNeeded()
            let iconFrame = tile.icon.convert(tile.icon.bounds, to: self)
            let proxy = CALayer()
            proxy.contents = AppIconCache.shared.image(for: store.app(id)).cgImage(forProposedRect: nil, context: nil, hints: nil)
            proxy.contentsGravity = .resizeAspect; proxy.frame = iconFrame; proxy.zPosition = 90
            layer.addSublayer(proxy)
            folderTransitionIcons.append(proxy)
            iconLayer.opacity = 0; folderTransitionHiddenIcons.append(iconLayer)
            LayerAnimation.apply(proxy, key: "opacity", value: Float(opening ? 1 : 0), duration: duration, screen: window?.screen, startValue: Float(opening ? 0 : 1))
            let fullBounds = CGRect(origin: .zero, size: iconFrame.size)
            let smallBounds = CGRect(origin: .zero, size: CGSize(width: iconFrame.width * Self.folderExtraIconScale, height: iconFrame.height * Self.folderExtraIconScale))
            LayerAnimation.apply(proxy, key: "bounds", value: NSValue(rect: opening ? fullBounds : smallBounds), duration: duration, screen: window?.screen, startValue: NSValue(rect: opening ? smallBounds : fullBounds))
            let labelFrame = tile.label.convert(tile.label.bounds, to: self)
            let fontSize = tile.label.font?.pointSize ?? NSFont.systemFontSize
            animateFolderText(tile.label.stringValue, from: labelFrame, sourceFont: fontSize, to: labelFrame, destinationFont: fontSize, opening: opening, fade: true, duration: duration)
            tile.label.isHidden = true; folderTransitionHiddenLabels.append(tile.label)
        }
        folderTransitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.folderTransitionIcons.forEach { $0.removeFromSuperlayer() }
            self.folderTransitionHiddenIcons.forEach { $0.opacity = 1 }
            self.folderTransitionHiddenLabels.forEach { $0.isHidden = false }
            self.folderTransitionIcons.removeAll(); self.folderTransitionHiddenIcons.removeAll(); self.folderTransitionHiddenLabels.removeAll()
        }
    }

    private func transformPages(_ surfaces: [Int: NativeSurface], position: Double, container: NSView, animated: Bool) {
        let config = store.preferences.interaction
        let duration = animated && store.motion != nil && config.pageAnimation != .none ? config.pageDuration : 0
        for (index, view) in surfaces {
            guard let layer = view.layer else { continue }
            let distance = Double(index) - position
            let magnitude = min(abs(distance), 1)
            // 同步更新 NSView 的实际位置，确保绘制与鼠标命中使用同一坐标。
            let oldPosition = layer.presentation()?.position ?? layer.position
            view.setFrameOrigin(NSPoint(x: distance * container.bounds.width, y: 0))
            if duration > 0 {
                let animation = CABasicAnimation(keyPath: "position")
                animation.fromValue = NSValue(point: oldPosition)
                animation.toValue = NSValue(point: layer.position)
                animation.duration = duration
                animation.timingFunction = LayerAnimation.timing
                requestRefreshRate(animation)
                layer.add(animation, forKey: "pagePosition")
            } else { layer.removeAnimation(forKey: "pagePosition") }
            var transform = CATransform3DIdentity
            // 淡入淡出叠放画面，但视图命中位置仍保持在各自的页面坐标。
            if config.pageAnimation == .fade { transform = CATransform3DTranslate(transform, -distance * container.bounds.width, 0, 0) }
            if config.pageAnimation == .depth { let scale = 1 - magnitude * 0.22; transform = CATransform3DScale(transform, scale, scale, 1) }
            if config.pageAnimation == .cube { transform.m34 = -1 / max(container.bounds.width, 1); transform = CATransform3DRotate(transform, -distance * .pi / 3, 0, 1, 0) }
            let opacity = config.pageAnimation == .none ? (magnitude < 0.5 ? 1.0 : 0) : config.pageAnimation == .fade || config.pageAnimation == .depth ? 1 - magnitude : 1
            LayerAnimation.apply(layer, key: "transform", value: NSValue(caTransform3D: transform), duration: duration, screen: window?.screen)
            LayerAnimation.apply(layer, key: "opacity", value: Float(opacity), duration: duration, screen: window?.screen)
        }
        frameMeter.sample(for: duration)
    }
    private func requestRefreshRate(_ animation: CAAnimation) {
        let rate = Float(max(window?.screen?.maximumFramesPerSecond ?? 60, 1))
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
    }

    private func updateFolder(changed: Bool) {
        guard let data = store.folder else {
            folderPanelTask?.cancel(); folderPanelTask = nil
            folder.isHidden = true
            if previousFolderID != nil {
                content.layer?.opacity = Float(store.revealProgress)
                previousFolderID = nil
                previousFolderProgress = .nan
                window?.makeFirstResponder(search)
            }
            return
        }
        let opening = previousFolderID != data.id
        if opening {
            settleTask?.cancel(); settleTask = nil
            previousFolderPagePosition = .nan
            if let tile = tiles["folder:\(data.id)"] { folderSource = tile.icon.convert(tile.icon.bounds, to: self).intersection(bounds) }
            if folderSource.isEmpty { folderSource = NSRect(x: bounds.midX - 40, y: bounds.midY - 40, width: 80, height: 80) }
            previousFolderID = data.id
            previousFolderProgress = .nan
            window?.makeFirstResponder(self)
        }
        let rows = min(LaunchpadRules.folderRows, max(1, Int(ceil(Double(data.pages.map(\.count).max() ?? 1) / Double(LaunchpadRules.columns)))))
        let width = min(bounds.width * 0.84, bounds.width - 80)
        let rootRowHeight = pages.bounds.height / CGFloat(store.preferences.interaction.rows)
        let headerExtra = Self.folderHeaderHeight - 50
        let height = min(bounds.height - insets.top - insets.bottom - 120, CGFloat(rows) * rootRowHeight + 115 + headerExtra)
        let target = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        folder.frame = target
        // 标题置于半透明面板上方，布局参照 LaunchOS 的文件夹展开样式。
        let panel = NSRect(x: 0, y: Self.folderHeaderHeight, width: width, height: height - Self.folderHeaderHeight)
        folderTitle.frame = NSRect(x: 30, y: 4, width: width - 60, height: 42)
        if opening { folderTitle.stringValue = data.name }
        folderPages.frame = NSRect(x: 12, y: 65 + headerExtra, width: width - 24, height: height - 115 - headerExtra)
        folderPager.frame = NSRect(x: width / 2 - 140, y: height - 47, width: 280, height: 40)
        folderPager.count = data.pages.count; folderPager.active = store.folderPage; folderPager.style = store.preferences.interaction.pagerStyle; folderPager.needsDisplay = true
        var config = store.preferences.interaction; config.columns = LaunchpadRules.columns; config.rows = rows
        let metrics = LauncherMetrics(availableSize: NSSize(width: width, height: folderPages.bounds.height + LauncherMetrics.verticalChrome), configuration: config)
        let rootMetrics = LauncherMetrics(availableSize: NSSize(width: bounds.width, height: pages.bounds.height + LauncherMetrics.verticalChrome), configuration: store.preferences.interaction)
        let rootIconSize = min(rootMetrics.iconSize, rootRowHeight - 32)
        updatePages(data.pages.map { $0.map(LayoutItem.app) }, surfaces: &folderPageViews, tileMap: &folderTiles, container: folderPages, metrics: metrics, columns: LaunchpadRules.columns, rows: rows, rebuild: changed || opening, inFolder: true, iconSizeOverride: rootIconSize)
        if previousFolderPagePosition != store.pagePosition || changed || opening {
            transformPages(folderPageViews, position: store.pagePosition, container: folderPages, animated: !store.pageDragging && previousFolderPagePosition.isFinite && previousFolderPagePosition != store.pagePosition)
            previousFolderPagePosition = store.pagePosition
        }
        folder.isHidden = false
        if previousFolderProgress != store.folderProgress || opening {
            let progress = store.folderProgress
            let source = convert(folderSource, to: folder)
            let duration = opening && progress == 0 ? 0 : store.folderAnimationDuration
            let sourceRadius = min(source.width, source.height) * NativeTile.folderCornerRadiusRatio
            let start = opening ? source : folderGlass.frame
            let startRadius = opening ? sourceRadius : folderGlass.cornerRadius
            animateFolderPanel(from: start, radius: startRadius, to: progress == 0 ? source : panel, radius: progress == 0 ? sourceRadius : Self.folderCornerRadius, duration: duration)
            for layer in [folderTitle.layer, folderPages.layer, folderPager.layer].compactMap({ $0 }) {
                LayerAnimation.apply(layer, key: "opacity", value: Float(progress), duration: duration, screen: window?.screen, startValue: opening && progress == 1 ? Float(0) : nil)
            }
            if let layer = folderTitle.layer {
                let offset = CATransform3DMakeTranslation(0, Self.folderTitleOffset, 0)
                LayerAnimation.apply(layer, key: "transform", value: NSValue(caTransform3D: progress == 0 ? offset : CATransform3DIdentity), duration: duration, screen: window?.screen, startValue: opening && progress == 1 ? NSValue(caTransform3D: offset) : nil)
            }
            if duration > 0 { animateFolderTransition(data, opening: progress == 1, duration: duration) }
            if let layer = content.layer { LayerAnimation.apply(layer, key: "opacity", value: Float((1 - progress) * store.revealProgress), duration: duration, screen: window?.screen, startValue: opening && progress == 1 ? Float(store.revealProgress) : nil) }
            previousFolderProgress = progress
            frameMeter.sample(for: duration)
        } else if folderPanelTask == nil && store.folderProgress == 1 {
            setFolderPanel(frame: panel, cornerRadius: Self.folderCornerRadius)
        }
    }

    /// 开发诊断模式使用独立数据：只切换页面与文件夹，不启动应用、不修改布局。
    public func runPerformanceCheck() async {
        await store.prepare()
        for _ in 0..<100 where store.catalogLoading { try? await Task.sleep(for: .milliseconds(20)) }
        guard !store.catalogLoading else { print("Catalog still loading; skipping animation measurement."); return }
        print("Native AppKit performance check: screen=\(window?.screen?.frame ?? .zero) maximumHz=\(window?.screen?.maximumFramesPerSecond ?? 0)")
        for index in 0..<8 {
            store.selectPage(index % 2)
            try? await Task.sleep(for: .milliseconds(600))
        }
        store.selectPage(0)
        try? await Task.sleep(for: .milliseconds(500))
        if let first = store.state.layout.folders.first {
            store.activate(.folder(first))
            try? await Task.sleep(for: .milliseconds(650))
            store.closeFolder()
            try? await Task.sleep(for: .milliseconds(650))
        }
        for progress in [0.0, 1.0, 0.0, 1.0] {
            store.revealProgress = progress
            try? await Task.sleep(for: .milliseconds(500))
        }
        print("Native AppKit performance check completed. Display-link cadence is not GPU presentation FPS.")
    }

    /// 文件夹存在（包括回缩过程）时，根视图只路由到面板或自己，背景永远不参与命中。
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if store.folderID != nil {
            // AppKit 的 hitTest 接收父视图坐标，不能提前转换成文件夹自身坐标。
            if folder.frame.contains(local), store.folderProgress == 1 { return folder.hitTest(local) ?? folder }
            return self
        }
        return super.hitTest(point)
    }
    public override func mouseDown(with event: NSEvent) { pointerStart = convert(event.locationInWindow, from: nil); pointerLast = pointerStart; pointerDragging = false }
    public override func mouseDragged(with event: NSEvent) {
        guard store.folderID == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointerDragging = true
        store.pageWidth = Double(max(pages.bounds.width, 1))
        store.dragPage(delta: Double(point.x - pointerLast.x) * pagingSign); pointerLast = point
    }
    public override func mouseUp(with event: NSEvent) {
        if store.folderID != nil { store.closeFolder(); return }
        if pointerDragging { store.finishPageDrag() } else { store.dismiss() }
    }
    private var pagingSign: Double { store.preferences.interaction.reversePaging ? -1 : 1 }
    public func setWallpaper(_ image: NSImage) { wallpaper.image = image }

    /// 完成布局并设置入场起点，随后在同一轮事件中启动动画。
    public func prepareReveal() {
        layoutSubtreeIfNeeded()
        previousReveal = .nan
        render()
    }

    /// 窗口显示后立即提交终点，不依赖异步 Observation 更新是否合并。
    public func performReveal() { render() }

    public override func scrollWheel(with event: NSEvent) {
        if dragSource != nil {
            dragTarget = nil; dragGroup = false; lastPreview = nil
            store.hoverGroup(nil)
            dragPageTask?.cancel(); dragPageTask = nil; dragPageDirection = 0
        }
        store.pageWidth = Double(max((store.folderID == nil ? pages : folderPages).bounds.width, 1))
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            if delta != 0 { store.selectPage(store.activePage + (delta < 0 ? 1 : -1) * (store.preferences.interaction.reversePaging ? -1 : 1)) }
            return
        }
        if event.phase == .began {
            settleTask?.cancel()
            let surfaces = store.folderID == nil ? pageViews : folderPageViews
            // 接续尚未结束的动画，从屏幕上实际显示的位置开始跟手。
            if let (index, view) = surfaces.first(where: { $0.value.layer?.animation(forKey: "pagePosition") != nil }),
               let position = view.layer?.presentation()?.position.x {
                store.pagePosition = Double(index) - (Double(position) / store.pageWidth - 0.5)
            } else { store.resetPagePosition() }
        }
        // NSEvent delta 表达内容位移；内容向左移动时，页位置应增大。
        if event.momentumPhase.isEmpty { store.dragPage(delta: -Double(delta) * pagingSign) }
        settleTask?.cancel()
        if event.phase.contains(.cancelled) { store.finishPageDrag(cancelled: true) }
        else if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) { store.finishPageDrag() }
        else {
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.store.finishPageDrag()
            }
        }
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if dragSource != nil { cancelTileDrag() } else { store.escape() }
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," { store.openSettings(); return }
        switch event.keyCode {
        case 123: event.modifierFlags.contains(.command) ? store.selectPage(store.activePage - 1) : store.navigate(-1)
        case 124: event.modifierFlags.contains(.command) ? store.selectPage(store.activePage + 1) : store.navigate(1)
        case 125: store.navigate(store.folderID == nil ? store.preferences.interaction.columns : LaunchpadRules.columns)
        case 126: store.navigate(-(store.folderID == nil ? store.preferences.interaction.columns : LaunchpadRules.columns))
        case 36: launchSelection()
        default: super.keyDown(with: event)
        }
    }
    public func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === folderTitle { renameFolder(); return }
        guard notification.object as? NSTextField === search else { return }
        store.query = search.stringValue; store.pageIndex = 0; store.selectedIndex = 0; store.resetPagePosition()
    }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search else { return false }
        if textView.hasMarkedText() { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { launchSelection(); return true }
        if commandSelector == #selector(NSResponder.moveToBeginningOfLine(_:)) { store.selectPage(store.activePage - 1); return true }
        if commandSelector == #selector(NSResponder.moveToEndOfLine(_:)) { store.selectPage(store.activePage + 1); return true }
        if commandSelector == #selector(NSResponder.moveLeft(_:)) { store.navigate(-1); return true }
        if commandSelector == #selector(NSResponder.moveRight(_:)) { store.navigate(1); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { store.navigate(store.preferences.interaction.columns); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { store.navigate(-store.preferences.interaction.columns); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { store.escape(); return true }
        return false
    }
    @objc private func launchSelection() { if store.visibleItems.indices.contains(store.selectedIndex) { activate(store.visibleItems[store.selectedIndex]) } }
    @objc private func renameFolder() { if let id = store.folderID { store.renameFolder(id, name: folderTitle.stringValue) } }
    func activate(_ item: LayoutItem) {
        guard store.folderID == nil || store.visibleItems.contains(where: { $0.id == item.id }) else { return }
        if case .folder = item, let tile = tiles[item.id] { folderSource = tile.icon.convert(tile.icon.bounds, to: self) }
        store.activate(item)
    }

    func contextMenu(for item: LayoutItem) -> NSMenu {
        let menu = NSMenu()
        if case .app(let id) = item, store.app(id)?.path != nil {
            let reveal = NSMenuItem(title: store.text("reveal"), action: #selector(revealFromMenu(_:)), keyEquivalent: "")
            reveal.target = self; reveal.representedObject = id; menu.addItem(reveal)
        }
        for page in 0...store.state.layout.pages.count {
            let title = page == store.state.layout.pages.count ? store.text("newPage") : "\(store.text("movePage")) \(page + 1)"
            let move = NSMenuItem(title: title, action: #selector(moveFromMenu(_:)), keyEquivalent: "")
            move.target = self; move.tag = page; move.representedObject = item; move.isEnabled = store.canEdit && !store.isSearching
            menu.addItem(move)
        }
        return menu
    }
    @objc private func revealFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let path = store.app(id)?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    @objc private func moveFromMenu(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? LayoutItem { store.move(item, to: sender.tag) }
    }

    func beginTileDrag(_ tile: NativeTile, event: NSEvent) {
        guard store.canEdit, !store.isSearching, let item = tile.item else { return }
        dragSource = item.id
        dragTargetPage = store.activePage
        store.beginDrag(item.id)
        // 翻页时源视图可能被回收；由窗口级监听器继续接收拖动和松手。
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, self.dragSource != nil else { return event }
            if event.type == .leftMouseDragged { self.moveTileDrag(event) }
            else { self.endTileDrag(event) }
            return nil
        }
        ghost.contents = tile.icon.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        ghost.bounds = tile.icon.bounds
        let folderDrag: Bool = if case .folder = item { true } else { false }
        let glassDrag = folderDrag && store.preferences.style == .liquidGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        dragGlass.cornerRadius = ghost.bounds.width * 0.23
        dragGlass.isHidden = !glassDrag
        ghost.cornerRadius = folderDrag ? ghost.bounds.width * 0.23 : 0
        ghost.backgroundColor = folderDrag && !glassDrag ? NSColor(white: 0.7, alpha: 0.32).cgColor : NSColor.clear.cgColor
        ghost.opacity = 0.9
        tile.alphaValue = 0.18
        moveTileDrag(event)
    }
    func moveTileDrag(_ event: NSEvent) {
        guard let source = dragSource else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateDragPageEdge(point)
        if dragTargetPage != store.activePage {
            dragTargetPage = store.activePage; dragTarget = nil; dragGroup = false; lastPreview = nil
            store.hoverGroup(nil)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); ghost.position = point; CATransaction.commit()
        if !dragGlass.isHidden { dragGlass.frame = NSRect(x: point.x - ghost.bounds.width / 2, y: point.y - ghost.bounds.height / 2, width: ghost.bounds.width, height: ghost.bounds.height) }
        let map = store.folderID == nil ? tiles : folderTiles
        let activeSurface = store.folderID == nil ? pageViews[store.activePage] : folderPageViews[store.activePage]
        guard let target = map.values.first(where: { tile in
            guard tile.item?.id != source, tile.superview === activeSurface else { return false }
            return tile.convert(tile.bounds, to: self).contains(point)
        }), let item = target.item else { store.hoverGroup(nil); dragTarget = nil; dragGroup = false; return }
        let local = target.convert(point, from: self)
        let center = target.icon.frame.insetBy(dx: target.icon.frame.width * 0.18, dy: target.icon.frame.height * 0.18).contains(local)
        let isFolder: Bool = if case .folder = item { true } else { false }
        dragGroup = store.folderID == nil && source.hasPrefix("app:") && center
        if dragGroup {
            store.hoverGroup(item.id)
            if isFolder { store.groupingReady = true }
            dragTarget = item
        } else {
            store.hoverGroup(nil)
            let items = store.visibleItems
            let index = items.firstIndex { $0.id == item.id } ?? 0
            let following = items.dropFirst(index + 1).first { $0.id != source }
            let before = local.x > target.bounds.midX ? following : item
            dragTarget = before
            let key = before?.id ?? "end"
            if key != lastPreview {
                lastPreview = key; store.previewMove(before: before)
                previewContext = "\(store.folderID ?? "root")|\(store.activePage)"
            }
        }
    }
    func endTileDrag(_ event: NSEvent) {
        guard dragSource != nil else { return }
        // 触控板仍在翻页时松手，先吸附到目标页再计算落点。
        settleTask?.cancel()
        if store.pageDragging { store.finishPageDrag() }
        if dragTargetPage != store.activePage { dragTarget = nil; dragGroup = false }
        if store.folderID != nil, !folder.frame.contains(convert(event.locationInWindow, from: nil)) { store.drop(onto: nil, page: store.pageIndex) }
        else {
            if dragTarget == nil && previewContext != "\(store.folderID ?? "root")|\(store.activePage)" { store.previewMove(before: nil) }
            store.drop(onto: dragTarget, group: dragGroup && store.groupingReady)
        }
        clearTileDrag()
        queueRender()
    }
    private func cancelTileDrag() {
        store.cancelDrag(); clearTileDrag(); queueRender()
    }

    /// 翻页后清除旧页面的悬停目标，允许继续拖向下一页。
    private func updateDragPageEdge(_ point: NSPoint) {
        let container = store.folderID == nil ? pages : folderPages
        let frame = container.convert(container.bounds, to: self)
        let direction = frame.contains(point) && point.x < frame.minX + Self.dragPageEdgeWidth ? -1 : frame.contains(point) && point.x > frame.maxX - Self.dragPageEdgeWidth ? 1 : 0
        guard direction != dragPageDirection else { return }
        dragPageTask?.cancel(); dragPageDirection = direction
        guard direction != 0 else { return }
        dragPageTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dragPageDelay)
            guard !Task.isCancelled, let self, self.dragSource != nil else { return }
            self.store.selectPage(self.store.activePage + direction)
            self.dragTarget = nil; self.dragGroup = false; self.lastPreview = nil
            self.dragTargetPage = self.store.activePage
            self.store.hoverGroup(nil)
            self.dragPageDirection = 0
            self.updateDragPageEdge(point)
        }
    }

    private func clearTileDrag() {
        dragPageTask?.cancel(); dragPageTask = nil; dragPageDirection = 0
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor); self.dragMonitor = nil }
        dragSource = nil; dragTarget = nil; dragTargetPage = nil; dragGroup = false; lastPreview = nil; previewContext = nil
        ghost.opacity = 0; dragGlass.isHidden = true
    }
}

