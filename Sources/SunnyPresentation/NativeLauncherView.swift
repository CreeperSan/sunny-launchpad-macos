// 原生启动器：网格、输入、拖放和模态文件夹均使用 AppKit，动画仅改变合成图层。
import AppKit
import Observation
import QuartzCore
import SunnyDomain

@MainActor public final class NativeLauncherView: NSView, NSTextFieldDelegate {
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
    private let settings = NSButton()
    private let organize = NSButton()
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
    private var dragSource: String?
    private var dragTarget: LayoutItem?
    private var dragGroup = false
    private var lastPreview: String?
    private let ghost = CALayer()
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
        searchGlass.style = .regular
        searchGlass.cornerRadius = 22
        content.addSubview(searchGlass)
        content.addSubview(searchIcon)
        content.addSubview(search)
        content.addSubview(pages)
        content.addSubview(pager)
        content.addSubview(settings)
        content.addSubview(organize)
        content.addSubview(loading)
        pages.addSubview(skeletonGrid)
        pages.layer?.masksToBounds = true
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        search.isBordered = false
        search.drawsBackground = false
        search.font = .systemFont(ofSize: 15)
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
        settings.target = self
        settings.action = #selector(openSettings)
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.isBordered = false
        organize.target = self
        organize.action = #selector(toggleOrganizing)
        organize.isBordered = false
        loading.alignment = .center
        folder.consumeBackgroundEvents = true
        folderPages.consumeBackgroundEvents = true
        folder.wantsLayer = true
        folder.layer?.cornerRadius = 30
        folder.layer?.masksToBounds = true
        folderBackground.wantsLayer = true
        folderBackground.layer?.cornerRadius = 30
        folder.addSubview(folderBackground)
        folderGlass.cornerRadius = 30
        folderGlass.style = .regular
        folder.addSubview(folderGlass)
        folder.isHidden = true
        addSubview(folder)
        folderTitle.isBordered = false
        folderTitle.drawsBackground = false
        folderTitle.alignment = .center
        folderTitle.font = .systemFont(ofSize: 23, weight: .medium)
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
        searchGlass.frame = NSRect(x: area.midX - 166, y: insets.top + 13, width: 332, height: 44)
        searchBackground.frame = searchGlass.frame
        searchIcon.frame = NSRect(x: searchGlass.frame.minX + 14, y: searchGlass.frame.midY - 8, width: 16, height: 16)
        search.frame = NSRect(x: searchGlass.frame.minX + 39, y: searchGlass.frame.midY - 11, width: searchGlass.frame.width - 54, height: 22)
        pages.frame = NSRect(x: 0, y: insets.top + 85, width: bounds.width, height: max(100, bounds.height - insets.top - insets.bottom - 190))
        pager.frame = NSRect(x: bounds.midX - 90, y: bounds.height - insets.bottom - 88, width: 180, height: 44)
        settings.frame = NSRect(x: bounds.width - 80, y: bounds.height - insets.bottom - 40, width: 44, height: 32)
        organize.frame = NSRect(x: bounds.width - 230, y: settings.frame.minY, width: 140, height: 32)
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
        searchBackground.layer?.backgroundColor = NSColor(white: dark ? 0.2 : 0.95, alpha: 0.88).cgColor
        search.focusRingType = glass ? .none : .default
        folderGlass.isHidden = !glass
        folderBackground.isHidden = glass
        folderBackground.layer?.backgroundColor = NSColor(white: dark ? 0.16 : 0.88, alpha: 0.94).cgColor
        folder.layer?.backgroundColor = NSColor.clear.cgColor
        search.placeholderString = store.text("search")
        if search.stringValue != store.query { search.stringValue = store.query }
        settings.toolTip = store.text("settings")
        organize.title = store.text(store.organizing ? "done" : "organize")
        loading.stringValue = store.state.catalog.isEmpty ? store.text(store.catalogLoading ? "loading" : "empty") : ""
        let modal = store.folderID != nil
        search.isEnabled = !modal
        organize.isEnabled = !modal && store.canEdit
        settings.isEnabled = !modal
        pager.isHidden = modal
        let signature = "\(store.pageIndex)|\(store.folderPage)|\(store.layoutRevision)|\(store.query)|\(config)|\(store.keyboardSelection)|\(store.selectedIndex)|\(store.groupingTarget ?? "")|\(store.groupingReady)"
        let changed = revision != signature
        revision = signature
        let metrics = LauncherMetrics(availableSize: NSSize(width: bounds.width, height: pages.bounds.height + LauncherMetrics.verticalChrome), configuration: config)
        let rootPages = store.isSearching ? LayoutEditor.chunks(store.searchResults.map { LayoutItem.app($0.id) }, size: config.capacity) : store.displayedLayout.pages.map(\.items)
        updateSkeleton(metrics: metrics)
        updatePages(rootPages.isEmpty ? [[]] : rootPages, surfaces: &pageViews, tileMap: &tiles, container: pages, metrics: metrics, columns: config.columns, rows: config.rows, rebuild: changed, inFolder: false)
        if !modal {
            pager.count = store.pageCount; pager.active = store.activePage; pager.style = config.pagerStyle
            pager.needsDisplay = true
            if changed || previousPage != store.pagePosition {
                transformPages(pageViews, position: store.pagePosition, container: pages, animated: !store.pageDragging && previousPage.isFinite && previousPage != store.pagePosition)
            }
        }
        previousPage = store.pagePosition
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
            // 经典缩放在起始帧保留可见内容，避免透明度动画掩盖缩放；淡入样式仍从全透明开始。
            let initialOpacity = config.windowAnimation == .classic ? 0.65 : 0.0
            let opacity = progress == 0 && previousReveal.isFinite ? 0 : initialOpacity + (1 - initialOpacity) * progress
            if let layer { LayerAnimation.apply(layer, key: "opacity", value: Float(opacity), duration: duration, screen: window?.screen, startValue: entering ? Float(initialOpacity) : nil) }
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

    private func updatePages(_ data: [[LayoutItem]], surfaces: inout [Int: NativeSurface], tileMap: inout [String: NativeTile], container: NSView, metrics: LauncherMetrics, columns: Int, rows: Int, rebuild: Bool, inFolder: Bool) {
        // 数据变化才整理图标视图；跟手阶段仅改变父图层的 transform。
        guard rebuild || surfaces.isEmpty else { return }
        let active = inFolder ? store.folderPage : store.pageIndex
        let retained = Set(max(0, active - 1)...min(max(0, data.count - 1), active + 1))
        let wantedIDs = Set(retained.flatMap { data[$0].map(\.id) })
        for id in Array(tileMap.keys) where !wantedIDs.contains(id) { tileMap.removeValue(forKey: id)?.removeFromSuperview() }
        for index in Array(surfaces.keys) where !retained.contains(index) { surfaces.removeValue(forKey: index)?.removeFromSuperview() }
        for pageIndex in retained {
            let surface: NativeSurface
            if let existing = surfaces[pageIndex] { surface = existing }
            else {
                surface = NativeSurface()
                // 新页面从上一帧的正确位置进入，快速连翻时不会从中央闪现。
                let previous = inFolder ? previousFolderPagePosition : previousPage
                let initial = previous.isFinite ? previous : store.pagePosition
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
                tile.configure(title: title, image: image, iconSize: min(metrics.iconSize, height - 32), selected: pageIndex == active && store.keyboardSelection && store.selectedIndex == index, grouping: store.groupingTarget == item.id && store.groupingReady, loading: { if case .app(let id) = item { !AppIconCache.shared.isReady(store.app(id)) } else { false } }(), folderStyle: { if case .folder = item { store.preferences.style == .liquidGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency } else { nil } }())
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
            if let tile = tiles["folder:\(data.id)"] { folderSource = tile.icon.convert(tile.icon.bounds, to: self).intersection(bounds) }
            if folderSource.isEmpty { folderSource = NSRect(x: bounds.midX - 40, y: bounds.midY - 40, width: 80, height: 80) }
            previousFolderID = data.id
            previousFolderProgress = .nan
            window?.makeFirstResponder(self)
        }
        let rows = min(LaunchpadRules.folderRows, max(1, Int(ceil(Double(data.pages.map(\.count).max() ?? 1) / Double(LaunchpadRules.columns)))))
        let width = min(bounds.width * 0.84, bounds.width - 80)
        let height = min(bounds.height - insets.top - insets.bottom - 120, CGFloat(rows) * min(160, pages.bounds.height / CGFloat(store.preferences.interaction.rows)) + 115)
        let target = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        folder.frame = target
        // 标题置于半透明面板上方，布局参照 LaunchOS 的文件夹展开样式。
        folderGlass.frame = NSRect(x: 0, y: 50, width: width, height: height - 50)
        folderBackground.frame = folderGlass.frame
        folderGlass.layer?.borderWidth = 1
        folderGlass.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        folderTitle.frame = NSRect(x: 30, y: 4, width: width - 60, height: 36)
        if opening { folderTitle.stringValue = data.name }
        folderPages.frame = NSRect(x: 12, y: 65, width: width - 24, height: height - 115)
        folderPager.frame = NSRect(x: width / 2 - 140, y: height - 47, width: 280, height: 40)
        folderPager.count = data.pages.count; folderPager.active = store.folderPage; folderPager.style = store.preferences.interaction.pagerStyle; folderPager.needsDisplay = true
        var config = store.preferences.interaction; config.columns = LaunchpadRules.columns; config.rows = rows
        let metrics = LauncherMetrics(availableSize: NSSize(width: width, height: folderPages.bounds.height + LauncherMetrics.verticalChrome), configuration: config)
        updatePages(data.pages.map { $0.map(LayoutItem.app) }, surfaces: &folderPageViews, tileMap: &folderTiles, container: folderPages, metrics: metrics, columns: LaunchpadRules.columns, rows: rows, rebuild: changed || opening, inFolder: true)
        if previousFolderPagePosition != store.pagePosition || changed || opening {
            transformPages(folderPageViews, position: store.pagePosition, container: folderPages, animated: !store.pageDragging && previousFolderPagePosition.isFinite && previousFolderPagePosition != store.pagePosition)
            previousFolderPagePosition = store.pagePosition
        }
        folder.isHidden = false
        if previousFolderProgress != store.folderProgress || opening {
            let progress = store.folderProgress
            let scaleX = max(0.05, folderSource.width / target.width)
            let scaleY = max(0.05, folderSource.height / target.height)
            var from = CATransform3DMakeScale(scaleX, scaleY, 1)
            from.m41 = folderSource.minX - target.minX
            from.m42 = folderSource.minY - target.minY
            let duration = store.motion == nil || opening ? 0 : LayerAnimation.folderDuration
            if let layer = folder.layer {
                LayerAnimation.apply(layer, key: "transform", value: NSValue(caTransform3D: progress == 0 ? from : CATransform3DIdentity), duration: duration, screen: window?.screen)
                LayerAnimation.apply(layer, key: "opacity", value: Float(progress), duration: duration, screen: window?.screen)
            }
            if let layer = content.layer { LayerAnimation.apply(layer, key: "opacity", value: Float((1 - progress) * store.revealProgress), duration: duration, screen: window?.screen) }
            previousFolderProgress = progress
            frameMeter.sample(for: duration)
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
        guard bounds.contains(point) else { return nil }
        if store.folderID != nil {
            if folder.frame.contains(point), store.folderProgress == 1 { return folder.hitTest(convert(point, to: folder)) ?? folder }
            return self
        }
        return super.hitTest(point)
    }
    public override func mouseDown(with event: NSEvent) { pointerStart = convert(event.locationInWindow, from: nil); pointerLast = pointerStart; pointerDragging = false }
    public override func mouseDragged(with event: NSEvent) {
        guard store.folderID == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointerDragging = true
        store.dragPage(delta: Double(point.x - pointerLast.x) * pagingSign); pointerLast = point
    }
    public override func mouseUp(with event: NSEvent) {
        if store.folderID != nil { store.closeFolder(); return }
        if pointerDragging { store.finishPageDrag() } else { store.dismiss() }
    }
    private var pagingSign: Double { store.preferences.interaction.reversePaging ? -1 : 1 }
    public func setWallpaper(_ image: NSImage) { wallpaper.image = image }

    /// 显示前先提交起始状态，避免观察更新合并掉入场动画的起点。
    public func prepareReveal() {
        layoutSubtreeIfNeeded()
        previousReveal = .nan
        render()
        CATransaction.flush()
    }

    /// 窗口显示后立即提交终点，不依赖异步 Observation 更新是否合并。
    public func performReveal() { render() }

    public override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            if delta != 0 { store.selectPage(store.activePage + (delta < 0 ? 1 : -1) * (store.preferences.interaction.reversePaging ? -1 : 1)) }
            return
        }
        if event.phase == .began { settleTask?.cancel(); store.resetPagePosition() }
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
    public func controlTextDidChange(_ notification: Notification) { store.query = search.stringValue; store.pageIndex = 0; store.selectedIndex = 0; store.resetPagePosition() }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
    @objc private func openSettings() { store.openSettings() }
    @objc private func toggleOrganizing() { store.organizing.toggle() }
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
        store.beginDrag(item.id)
        ghost.contents = tile.icon.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        ghost.bounds = tile.icon.bounds
        ghost.opacity = 0.9
        tile.alphaValue = 0.18
        moveTileDrag(event)
    }
    func moveTileDrag(_ event: NSEvent) {
        guard let source = dragSource else { return }
        let point = convert(event.locationInWindow, from: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true); ghost.position = point; CATransaction.commit()
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
            if key != lastPreview { lastPreview = key; store.previewMove(before: before) }
        }
    }
    func endTileDrag(_ event: NSEvent) {
        guard dragSource != nil else { return }
        if store.folderID != nil, !folder.frame.contains(convert(event.locationInWindow, from: nil)) { store.drop(onto: nil, page: store.pageIndex) }
        else { store.drop(onto: dragTarget, group: dragGroup && store.groupingReady) }
        dragSource = nil; dragTarget = nil; lastPreview = nil; ghost.opacity = 0
        queueRender()
    }
    private func cancelTileDrag() {
        store.cancelDrag(); dragSource = nil; dragTarget = nil; lastPreview = nil; ghost.opacity = 0; queueRender()
    }
}

