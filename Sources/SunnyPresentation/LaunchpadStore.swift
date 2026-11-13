// 展示状态与用例协调：注入协议，提交成功之后才更新用户可见布局。
import AppKit
import Observation
import SunnyDomain

@Observable @MainActor public final class LaunchpadStore {
    public private(set) var state = WorkspaceState()
    public private(set) var busy = false
    public private(set) var readOnly = false
    public var query = ""
    public var pageIndex = 0
    public var folderID: String?
    public var folderPage = 0
    public var selectedIndex = 0
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
    private let scanInterval: TimeInterval = 30

    public init(catalog: any ApplicationCatalog, repository: any WorkspaceRepository, importer: any LegacyLayoutImporting, launcher: any ApplicationLaunching) {
        catalogService = catalog
        self.repository = repository
        self.importer = importer
        self.launcher = launcher
    }

    public var preferences: Preferences { state.preferences }
    public var canEdit: Bool { !busy && !readOnly }
    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var folder: AppFolder? { state.layout.folders.first { $0.id == folderID } }
    public var searchResults: [ApplicationRecord] { LayoutEditor.search(state.catalog, query: query) }
    public var pageCount: Int {
        if isSearching { return max(1, Int(ceil(Double(searchResults.count) / Double(LaunchpadRules.pageCapacity)))) }
        if let folder { return max(1, folder.pages.count) }
        return max(1, state.layout.pages.count)
    }
    public var activePage: Int { folder != nil && !isSearching ? folderPage : pageIndex }
    public var visibleItems: [LayoutItem] {
        if isSearching {
            return Array(searchResults.dropFirst(pageIndex * LaunchpadRules.pageCapacity).prefix(LaunchpadRules.pageCapacity)).map { .app($0.id) }
        }
        if let folder { return folder.pages[min(folderPage, folder.pages.count - 1)].map { .app($0) } }
        return state.layout.pages[min(pageIndex, state.layout.pages.count - 1)].items
    }

    public func text(_ key: String) -> String { L10n.text(key, language: preferences.language) }
    public func app(_ id: String) -> ApplicationRecord? { state.catalog.first { $0.id == id } }

    /// 初始化数据读取失败后进入保护模式，仍允许扫描和启动已安装应用。
    public func prepare() async {
        presentationID = UUID()
        query = ""
        folderID = nil
        organizing = false
        if !preferences.rememberPage { pageIndex = 0 }
        guard !busy else { return }
        if !loaded {
            busy = true
            do { state = try await repository.load() ?? WorkspaceState() }
            catch { readOnly = true; report(error) }
            loaded = true
            busy = false
            preferencesChanged(preferences)
        }
        if Date().timeIntervalSince(lastScan) >= scanInterval { await refresh() }
        clampPage()
    }

    public func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let discovered = try await catalogService.scan()
            let updated = LayoutEditor.reconcile(state, discovered: discovered)
            if !readOnly { try await repository.save(updated) }
            state = updated
            lastScan = Date()
            clampPage()
        } catch { report(error) }
    }

    public func setPreferences(_ change: (inout Preferences) -> Void) async {
        guard canEdit else { return }
        var updated = state
        change(&updated.preferences)
        await commit(updated)
    }

    public func activate(_ item: LayoutItem) {
        switch item {
        case .folder(let folder):
            folderID = folder.id
            folderPage = 0
            selectedIndex = 0
        case .app(let id):
            guard !organizing, let app = app(id) else { return }
            Task {
                do { try await launcher.launch(app); dismiss() }
                catch { report(error) }
            }
        }
    }

    public func escape() {
        if !query.isEmpty { query = ""; pageIndex = 0 }
        else if folderID != nil { folderID = nil; folderPage = 0 }
        else if organizing { organizing = false }
        else { dismiss() }
    }

    public func selectPage(_ index: Int) {
        let target = min(max(index, 0), pageCount - 1)
        if folder != nil && !isSearching { folderPage = target } else { pageIndex = target }
        selectedIndex = 0
    }

    public func navigate(_ offset: Int) {
        guard !visibleItems.isEmpty else { return }
        let index = selectedIndex + offset
        if index < 0 && activePage > 0 { selectPage(activePage - 1); selectedIndex = max(visibleItems.count - 1, 0) }
        else if index >= visibleItems.count && activePage + 1 < pageCount { selectPage(activePage + 1) }
        else { selectedIndex = min(max(index, 0), visibleItems.count - 1) }
    }

    /// 拖放只接受当前进程正在拖动的条目，不执行外部文本或文件路径。
    public func drop(onto target: LayoutItem?, group: Bool = false, page: Int? = nil) {
        guard canEdit, !isSearching, let source = draggedID else { return }
        draggedID = nil
        var updated = state
        if let page {
            guard updated.layout.pages.indices.contains(page) else { return }
            updated.layout = LayoutEditor.move(source, toPage: updated.layout.pages[page].id, before: target?.id, in: updated.layout)
        } else if let folder {
            let targetApp: String? = if case .app(let id) = target { id } else { nil }
            updated.layout = LayoutEditor.moveIntoFolder(source, folderID: folder.id, page: folderPage, before: targetApp, in: updated.layout)
        } else if group, let target {
            updated.layout = LayoutEditor.group(source, onto: target.id, name: text("newFolder"), in: updated.layout)
        } else {
            updated.layout = LayoutEditor.move(source, toPage: updated.layout.pages[pageIndex].id, before: target?.id, in: updated.layout)
        }
        Task { await commit(updated) }
    }

    public func move(_ item: LayoutItem, to page: Int) {
        guard canEdit else { return }
        var updated = state
        if page == updated.layout.pages.count { updated.layout.pages.append(LayoutPage()) }
        guard updated.layout.pages.indices.contains(page) else { return }
        updated.layout = LayoutEditor.move(item.id, toPage: updated.layout.pages[page].id, before: nil, in: updated.layout)
        Task { await commit(updated) }
    }

    public func renameFolder(_ id: String, name: String) {
        guard canEdit else { return }
        var updated = state
        updated.layout = LayoutEditor.renameFolder(id, name: name, in: updated.layout)
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
            state = updated
            clampPage()
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
            state = updated
            clampPage()
            preferencesChanged(preferences)
            return true
        } catch { report(error); return false }
    }

    private func clampPage() {
        pageIndex = min(max(pageIndex, 0), max(state.layout.pages.count - 1, 0))
        if let folder { folderPage = min(folderPage, max(folder.pages.count - 1, 0)) }
        else { folderID = nil }
        selectedIndex = min(selectedIndex, max(visibleItems.count - 1, 0))
    }

    private func report(_ error: Error) {
        if let error = error as? SunnyError { errorMessage = text(error.rawValue) }
        else { errorMessage = text("error") + "\n" + error.localizedDescription }
    }
}
