// 展示状态与用例协调：注入协议，提交成功之后才更新用户可见布局。
import AppKit
import Observation
import SunnyDomain

@Observable @MainActor public final class LaunchpadStore {
    public private(set) var state = WorkspaceState() {
        didSet { layoutRevision += 1; catalogIndex = Dictionary(state.catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    public private(set) var layoutRevision = 0
    public var pageDragging = false
    public var folderProgress = 0.0
    private var folderCloseTask: Task<Void, Never>?
    private var dragOriginal: LaunchpadLayout?
    public var dragPreviewActive = false
    public var previewLayout: LaunchpadLayout?
    public var displayedLayout: LaunchpadLayout { previewLayout ?? state.layout }
    private var catalogIndex: [String: ApplicationRecord] = [:]
    public private(set) var busy = false
    public private(set) var readOnly = false
    public var query = ""
    public var pageIndex = 0
    public var folderID: String?
    public var folderPage = 0
    public var selectedIndex = 0
    public var keyboardSelection = false
    public var pagePosition = 0.0
    public var pageWidth = 1000.0
    public var revealProgress = 1.0
    public var groupingTarget: String?
    public var groupingReady = false
    private var groupingTask: Task<Void, Never>?
    public var motion: Double? {
        preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : preferences.interaction.pageDuration
    }
    public var organizing = false
    public var draggedID: String?
    public var errorMessage: String?
    public var notice: String?
    public var importPreview: ImportPreview?
    public var sources: [URL] = []
    public var hotkeyError: String?
    public var presentationID = UUID()
    public var dismiss: () -> Void = {}
    public var openSettings: () -> Void = {}
    public var preferencesChanged: (Preferences) -> Void = { _ in }
    private let catalogService: any ApplicationCatalog
    private let repository: any WorkspaceRepository
    private let importer: any LegacyLayoutImporting
    private let launcher: any ApplicationLaunching
    private var loaded = false
    private var lastScan = Date.distantPast
    private var catalogDirty = false
    private var catalogChangeRevision = 0
    private var refreshing = false
    private let scanInterval: TimeInterval = 60 * 60
    public var catalogLoading: Bool { !loaded || (state.catalog.isEmpty && busy) }

    /// 目录变化只标记失效；可见时静默刷新，隐藏时在下次显示处理。
    public func markCatalogDirty() { catalogDirty = true; catalogChangeRevision += 1 }


    public init(catalog: any ApplicationCatalog, repository: any WorkspaceRepository, importer: any LegacyLayoutImporting, launcher: any ApplicationLaunching) {
        catalogService = catalog
        self.repository = repository
        self.importer = importer
        self.launcher = launcher
    }

    public var preferences: Preferences { state.preferences }
    public var canEdit: Bool { !busy && !readOnly }
    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var folder: AppFolder? { displayedLayout.folders.first { $0.id == folderID } }
    public var searchResults: [ApplicationRecord] { LayoutEditor.search(state.catalog, query: query) }
    public var pageCount: Int {
        if isSearching { return max(1, Int(ceil(Double(searchResults.count) / Double(preferences.interaction.capacity)))) }
        if let folder { return max(1, folder.pages.count) }
        return max(1, state.layout.pages.count)
    }
    public var activePage: Int { folder != nil && !isSearching ? folderPage : pageIndex }
    public var visibleItems: [LayoutItem] { items(on: activePage) }

    public func items(on index: Int) -> [LayoutItem] {
        guard index >= 0 && index < pageCount else { return [] }
        if isSearching {
            return Array(searchResults.dropFirst(index * preferences.interaction.capacity).prefix(preferences.interaction.capacity)).map { .app($0.id) }
        }
        if let folder { return folder.pages[min(index, folder.pages.count - 1)].map { .app($0) } }
        return displayedLayout.pages[min(index, displayedLayout.pages.count - 1)].items
    }

    public func text(_ key: String) -> String { L10n.text(key, language: preferences.language) }
    public func app(_ id: String) -> ApplicationRecord? { catalogIndex[id] }

    /// 初始化数据读取失败后进入保护模式，仍允许扫描和启动已安装应用。
    public func prepare() async {
        presentationID = UUID()
        query = ""
        folderID = nil
        organizing = false
        keyboardSelection = false
        if !preferences.rememberPage { pageIndex = 0 }
        guard !busy else { return }
        if !loaded {
            busy = true
            do {
                if let cached = try await repository.load() {
                    state = cached
                    // 缓存先显示，后续由目录通知或一小时兜底触发静默校验。
                    lastScan = cached.catalogUpdatedAt ?? .distantPast
                }
            }
            catch { readOnly = true; report(error) }
            loaded = true
            busy = false
            preferencesChanged(preferences)
        }
        if state.catalog.isEmpty || catalogDirty || Date().timeIntervalSince(lastScan) >= scanInterval { await refresh() }
        clampPage()
    }

    public func refresh() async {
        guard !busy, !refreshing else { return }
        refreshing = true
        let scanRevision = catalogChangeRevision
        let firstLoad = state.catalog.isEmpty
        if firstLoad { busy = true }
        defer { refreshing = false; if firstLoad { busy = false } }
        do {
            let discovered = try await catalogService.scan()
            // 扫描期间允许使用缓存；提交阶段才短暂串行，避免覆盖正在编辑的布局。
            if !firstLoad && (busy || draggedID != nil) { return }
            busy = true
            defer { busy = false }
            var updated = LayoutEditor.reconcile(state, discovered: discovered)
            updated.catalogUpdatedAt = Date()
            if !readOnly { try await repository.save(updated) }
            state = updated
            lastScan = Date()
            // 扫描期间若又有安装／删除事件，保留失效标记，下一次显示继续校验。
            catalogDirty = scanRevision != catalogChangeRevision
            clampPage()
        } catch { report(error) }
    }

    public func setPreferences(_ change: (inout Preferences) -> Void) async {
        guard canEdit else { return }
        var updated = state
        change(&updated.preferences)
        if updated.preferences.interaction.capacity != preferences.interaction.capacity || updated.preferences.interaction.columns != preferences.interaction.columns {
            updated.layout = LayoutEditor.repaginate(updated.layout, capacity: updated.preferences.interaction.capacity)
        }
        if updated != state { await commit(updated) }
    }

    public func activate(_ item: LayoutItem) {
        switch item {
        case .folder(let folder):
            guard folderID == nil else { return }
            folderCloseTask?.cancel()
            folderProgress = 0
            folderID = folder.id
            folderPage = 0
            pagePosition = 0
            selectedIndex = 0
            Task { await Task.yield(); folderProgress = 1 }
        case .app(let id):
            guard !organizing, let app = app(id) else { return }
            if let folder, !folder.appIDs.contains(id) { return }
            Task {
                do { try await launcher.launch(app); dismiss() }
                catch { report(error) }
            }
        }
    }

    public func escape() {
        if !query.isEmpty { query = ""; pageIndex = 0 }
        else if folderID != nil { closeFolder() }
        else if organizing { organizing = false }
        else { dismiss() }
    }

    public func selectPage(_ index: Int) {
        let target = min(max(index, 0), pageCount - 1)
        if folder != nil && !isSearching { folderPage = target } else { pageIndex = target }
        selectedIndex = 0
        pageDragging = false
        pagePosition = Double(target)
    }

    /// 手势阶段直接更新浮点页位置；结束后吸附，取消时回到当前页。
    public func dragPage(delta: Double) {
        pageDragging = true
        pagePosition = min(max(pagePosition - delta / max(pageWidth, 1), -0.15), Double(pageCount - 1) + 0.15)
    }
    public func finishPageDrag(cancelled: Bool = false) {
        let distance = pagePosition - Double(activePage)
        let target = abs(distance) > 0.18 ? activePage + (distance > 0 ? 1 : -1) : activePage
        selectPage(cancelled ? activePage : target)
    }
    public func resetPagePosition() { pagePosition = Double(activePage) }

    /// 中心悬停后才允许成组，移开或取消时撤销待成组状态。
    public func hoverGroup(_ id: String?) {
        guard id != groupingTarget else { return }
        groupingTask?.cancel()
        groupingTarget = id
        groupingReady = false
        guard id != nil else { return }
        groupingTask = Task { [weak self] in
            try? await Task.sleep(for: LayerAnimation.folderHoverDelay)
            guard !Task.isCancelled, let self else { return }
            self.groupingReady = true
            // 既有文件夹悬停展开，拖动源仍在原布局，松手前不写盘。
            if let id = self.groupingTarget, let folder = self.state.layout.folders.first(where: { "folder:\($0.id)" == id }), self.draggedID != nil {
                self.folderID = folder.id
                self.folderPage = 0
                self.pagePosition = 0
                self.folderProgress = 0
                await Task.yield()
                self.folderProgress = 1
            }
        }
    }

    /// 文件夹关闭期间保持模态，不提前移除视图，保证回缩动画可见。
    public func closeFolder() {
        guard folderID != nil, folderProgress != 0 else { return }
        folderCloseTask?.cancel()
        folderProgress = 0
        folderCloseTask = Task {
            if motion != nil { try? await Task.sleep(for: .seconds(LayerAnimation.folderDuration)) }
            guard !Task.isCancelled else { return }
            folderID = nil
            folderPage = 0
            resetPagePosition()
        }
    }

    /// 只修改内存中的排位预览；落下前不保存，取消可完整恢复原顺序。
    public func beginDrag(_ id: String) {
        dragPreviewActive = true
        dragOriginal = state.layout
        previewLayout = state.layout
        draggedID = id
        hoverGroup(nil)
    }
    public func previewMove(before target: LayoutItem?) {
        guard canEdit, let source = draggedID, let original = dragOriginal else { return }
        let layout: LaunchpadLayout
        if let folder {
            let targetApp: String? = if case .app(let id) = target { id } else { nil }
            layout = LayoutEditor.moveIntoFolder(source, folderID: folder.id, page: folderPage, before: targetApp, in: original, capacity: preferences.interaction.capacity)
        } else {
            layout = LayoutEditor.move(source, toPage: original.pages[pageIndex].id, before: target?.id, in: original, capacity: preferences.interaction.capacity)
        }
        guard layout != previewLayout else { return }
        previewLayout = layout; layoutRevision += 1
    }
    public func cancelDrag() {
        previewLayout = nil; layoutRevision += 1
        dragOriginal = nil
        draggedID = nil
        hoverGroup(nil)
        Task {
            try? await Task.sleep(for: .seconds(LayerAnimation.reorderDuration))
            if draggedID == nil { dragPreviewActive = false }
        }
    }

    public func navigate(_ offset: Int) {
        guard !visibleItems.isEmpty else { return }
        if !keyboardSelection { keyboardSelection = true; selectedIndex = 0; return }
        let index = selectedIndex + offset
        if index < 0 && activePage > 0 { selectPage(activePage - 1); selectedIndex = max(visibleItems.count - 1, 0) }
        else if index >= visibleItems.count && activePage + 1 < pageCount { selectPage(activePage + 1) }
        else { selectedIndex = min(max(index, 0), visibleItems.count - 1) }
    }

    /// 拖放只接受当前进程正在拖动的条目，不执行外部文本或文件路径。
    public func drop(onto target: LayoutItem?, group: Bool = false, page: Int? = nil) {
        guard canEdit, !isSearching, let source = draggedID else { return }
        draggedID = nil
        hoverGroup(nil)
        var updated = state
        if !group, let previewLayout { updated.layout = previewLayout }
        dragOriginal = nil
        if !group && page == nil && folder == nil, previewLayout != nil {
            // 实时预览已经计算最终位置，松手时直接提交，避免二次移动导致落到末尾。
        } else if let page {
            guard updated.layout.pages.indices.contains(page) else { return }
            updated.layout = LayoutEditor.move(source, toPage: updated.layout.pages[page].id, before: target?.id, in: updated.layout, capacity: preferences.interaction.capacity)
        } else if let folder {
            let targetApp: String? = if case .app(let id) = target { id } else { nil }
            updated.layout = LayoutEditor.moveIntoFolder(source, folderID: folder.id, page: folderPage, before: targetApp, in: updated.layout, capacity: preferences.interaction.capacity)
        } else if group, let target {
            updated.layout = LayoutEditor.group(source, onto: target.id, name: text("newFolder"), in: updated.layout, capacity: preferences.interaction.capacity)
        } else {
            updated.layout = LayoutEditor.move(source, toPage: updated.layout.pages[pageIndex].id, before: target?.id, in: updated.layout, capacity: preferences.interaction.capacity)
        }
        Task {
            _ = await commit(updated)
            previewLayout = nil
            dragPreviewActive = false
            layoutRevision += 1
        }
    }

    public func move(_ item: LayoutItem, to page: Int) {
        guard canEdit else { return }
        var updated = state
        if page == updated.layout.pages.count { updated.layout.pages.append(LayoutPage()) }
        guard updated.layout.pages.indices.contains(page) else { return }
        updated.layout = LayoutEditor.move(item.id, toPage: updated.layout.pages[page].id, before: nil, in: updated.layout, capacity: preferences.interaction.capacity)
        Task { await commit(updated) }
    }

    public func renameFolder(_ id: String, name: String) {
        guard canEdit else { return }
        var updated = state
        updated.layout = LayoutEditor.renameFolder(id, name: name, in: updated.layout, capacity: preferences.interaction.capacity)
        Task { await commit(updated) }
    }

    public func discover() async {
        guard canEdit else { return }
        sources = await importer.discover()
        if sources.isEmpty { notice = text("noDatabase") }
        if sources.count == 1 { await preview(sources[0]) }
    }

    public func preview(_ url: URL) async {
        guard canEdit else { return }
        busy = true
        importPreview = nil
        defer { busy = false }
        do { importPreview = try await importer.preview(from: url, catalog: state.catalog) }
        catch { report(error) }
    }

    public func applyImport() async {
        guard canEdit, var updated = importPreview?.state else { return }
        updated.preferences = preferences
        if updated.layout.pages.contains(where: { $0.items.count > preferences.interaction.capacity }) { updated.layout = LayoutEditor.repaginate(updated.layout, capacity: preferences.interaction.capacity) }
        if await commit(updated) {
            importPreview = nil
            pageIndex = 0
            folderID = nil
            notice = text("saved")
        }
    }

    public func export(to url: URL) async {
        do { try await repository.exportState(to: url); notice = text("saved") }
        catch { report(error) }
    }

    public func restore(from url: URL) async {
        guard canEdit else { return }
        busy = true
        do {
            let backup = try await repository.readBackup(from: url)
            let discovered = try await catalogService.scan()
            let updated = LayoutEditor.reconcile(backup, discovered: discovered)
            try await repository.save(updated)
            state = updated; clampPage()
            preferencesChanged(preferences)
            notice = text("saved")
        } catch { report(error) }
        busy = false
    }

    @discardableResult private func commit(_ updated: WorkspaceState) async -> Bool {
        guard canEdit else { return false }
        busy = true
        defer { busy = false }
        do {
            try await repository.save(updated)
            state = updated; clampPage()
            preferencesChanged(preferences)
            return true
        } catch { report(error); return false }
    }

    private func clampPage() {
        pageIndex = min(max(pageIndex, 0), max(state.layout.pages.count - 1, 0))
        if let folder { folderPage = min(folderPage, max(folder.pages.count - 1, 0)) }
        else { folderID = nil }
        selectedIndex = min(selectedIndex, max(visibleItems.count - 1, 0))
        resetPagePosition()
    }

    private func report(_ error: Error) {
        if let error = error as? SunnyError { errorMessage = text(error.rawValue) }
        else { errorMessage = text("error") + "\n" + error.localizedDescription }
    }
}
