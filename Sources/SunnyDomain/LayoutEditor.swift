// 纯布局规则：所有编辑先在值副本执行，再由上层持久化成功后发布。
import Foundation

public enum LayoutEditor {
    /// 保存前校验引用、唯一性和文件夹边界；拒绝未来版本与损坏状态。
    public static func validate(_ state: WorkspaceState) throws {
        guard state.schemaVersion == LaunchpadRules.schemaVersion else { throw SunnyError.unsupportedVersion }
        let appIDs = state.catalog.map(\.id)
        let placedIDs = state.layout.appIDs
        let pageIDs = state.layout.pages.map(\.id)
        let folderIDs = state.layout.folders.map(\.id)
        guard state.preferences.interaction.isValid, !pageIDs.isEmpty, state.catalog.count <= LaunchpadRules.maximumNodes,
              Set(appIDs).count == appIDs.count, Set(placedIDs).count == placedIDs.count,
              Set(placedIDs).isSubset(of: Set(appIDs)), Set(pageIDs).count == pageIDs.count,
              Set(folderIDs).count == folderIDs.count,
              state.layout.pages.allSatisfy({ $0.items.count <= state.preferences.interaction.capacity }),
              state.layout.folders.allSatisfy({ !$0.appIDs.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.pages.allSatisfy { !$0.isEmpty && $0.count <= LaunchpadRules.folderCapacity } })
        else { throw SunnyError.invalidLayout }
    }

    /// 刷新只更新应用元数据并追加新应用；未发现应用保留原位置作为占位。
    public static func reconcile(_ state: WorkspaceState, discovered: [ApplicationRecord]) -> WorkspaceState {
        var result = state
        let scanned = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previous = Set(state.catalog.map(\.id))
        result.catalog = state.catalog.map { old in
            if let current = scanned[old.id] { return current }
            var missing = old
            missing.isAvailable = false
            return missing
        }
        let added = discovered.filter { !previous.contains($0.id) }
        result.catalog.append(contentsOf: added)
        for app in added { append(.app(app.id), to: &result.layout, capacity: state.preferences.interaction.capacity) }
        return result
    }

    /// 搜索保持目录顺序，忽略大小写、重音和首尾空白，不在此猜测拼音。
    public static func search(_ catalog: [ApplicationRecord], query: String) -> [ApplicationRecord] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.filter { term.isEmpty || $0.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil || $0.bundleIdentifier?.range(of: term, options: [.caseInsensitive]) != nil }
    }

    /// 移动应用或整组到主页面；显式保留用户的页边界，只将溢出项顺延。
    public static func move(_ itemID: String, toPage pageID: String, before targetID: String?, in layout: LaunchpadLayout, capacity: Int = LaunchpadRules.pageCapacity) -> LaunchpadLayout {
        guard itemID != targetID, layout.pages.contains(where: { $0.id == pageID }) else { return layout }
        var result = layout
        guard let item = remove(itemID, from: &result), let pageIndex = result.pages.firstIndex(where: { $0.id == pageID }) else { return layout }
        let index = targetID.flatMap { target in result.pages[pageIndex].items.firstIndex { $0.id == target } } ?? result.pages[pageIndex].items.count
        result.pages[pageIndex].items.insert(item, at: index)
        normalize(&result, capacity: capacity)
        return result
    }

    /// 中心落点创建或加入文件夹；已有文件夹不能被装进另一个文件夹。
    public static func group(_ sourceID: String, onto targetID: String, name: String, in layout: LaunchpadLayout, capacity: Int = LaunchpadRules.pageCapacity) -> LaunchpadLayout {
        guard sourceID != targetID, sourceID.hasPrefix("app:") else { return layout }
        var result = layout
        guard case .app(let appID) = remove(sourceID, from: &result) else { return layout }
        for page in result.pages.indices {
            guard let index = result.pages[page].items.firstIndex(where: { $0.id == targetID }) else { continue }
            switch result.pages[page].items[index] {
            case .app(let targetApp):
                result.pages[page].items[index] = .folder(AppFolder(name: name, pages: [[targetApp, appID]]))
            case .folder(var folder):
                if folder.pages.last!.count >= LaunchpadRules.folderCapacity { folder.pages.append([]) }
                folder.pages[folder.pages.count - 1].append(appID)
                result.pages[page].items[index] = .folder(folder)
            }
            normalize(&result, capacity: capacity)
            return result
        }
        return layout
    }

    /// 文件夹内部排序支持跨内部页面，保留其他页面的顺序。
    public static func moveIntoFolder(_ sourceID: String, folderID: String, page: Int, before target: String?, in layout: LaunchpadLayout, capacity: Int = LaunchpadRules.pageCapacity) -> LaunchpadLayout {
        guard sourceID.hasPrefix("app:"), sourceID != target.map({ "app:\($0)" }) else { return layout }
        var result = layout
        // 先记录目标文件夹，处理移动唯一子项时 remove 自动清理空文件夹的情况。
        guard let original = result.folders.first(where: { $0.id == folderID }) else { return layout }
        if original.appIDs.count == 1 && sourceID == "app:\(original.appIDs[0])" { return layout }
        if let appID = original.appIDs.first(where: { "app:\($0)" == sourceID }) {
            // 先保留原始页索引，再移除源项；否则源页变空时目标页会错位。
            updateFolder(folderID, in: &result) { folder in
                var pages = folder.pages.map { $0.filter { $0 != appID } }
                let pageIndex = min(max(page, 0), pages.count - 1)
                let index = target.flatMap { pages[pageIndex].firstIndex(of: $0) } ?? pages[pageIndex].count
                pages[pageIndex].insert(appID, at: index)
                folder.pages = chunks(pages.flatMap { $0 }, size: LaunchpadRules.folderCapacity)
            }
            normalize(&result, capacity: capacity)
            return result
        }
        guard case .app(let appID) = remove(sourceID, from: &result) else { return layout }
        updateFolder(folderID, in: &result) { folder in
            let pageIndex = min(max(page, 0), max(folder.pages.count - 1, 0))
            if folder.pages.isEmpty { folder.pages = [[]] }
            let index = target.flatMap { folder.pages[pageIndex].firstIndex(of: $0) } ?? folder.pages[pageIndex].count
            folder.pages[pageIndex].insert(appID, at: index)
            folder.pages = chunks(folder.appIDs, size: LaunchpadRules.folderCapacity)
        }
        normalize(&result, capacity: capacity)
        return result
    }

    public static func renameFolder(_ id: String, name: String, in layout: LaunchpadLayout, capacity: Int = LaunchpadRules.pageCapacity) -> LaunchpadLayout {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return layout }
        var result = layout
        updateFolder(id, in: &result) { $0.name = trimmed }
        return result
    }

    /// 分块算法同时服务新布局和旧库超容量页，不产生空尾页。
    public static func chunks<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }

    public static func append(_ item: LayoutItem, to layout: inout LaunchpadLayout, capacity: Int = LaunchpadRules.pageCapacity) {
        if layout.pages.isEmpty || layout.pages.last!.items.count >= capacity { layout.pages.append(LayoutPage()) }
        layout.pages[layout.pages.count - 1].items.append(item)
    }

    /// 修改行列时保留线性顺序与文件夹身份，按新容量重新分配主页面。
    public static func repaginate(_ layout: LaunchpadLayout, capacity: Int) -> LaunchpadLayout {
        let pages = chunks(layout.pages.flatMap(\.items), size: capacity).map { LayoutPage(items: $0) }
        return LaunchpadLayout(pages: pages.isEmpty ? [LayoutPage()] : pages)
    }

    private static func updateFolder(_ id: String, in layout: inout LaunchpadLayout, change: (inout AppFolder) -> Void) {
        for page in layout.pages.indices {
            for index in layout.pages[page].items.indices {
                if case .folder(var folder) = layout.pages[page].items[index], folder.id == id {
                    change(&folder)
                    layout.pages[page].items[index] = .folder(folder)
                    return
                }
            }
        }
    }

    private static func remove(_ id: String, from layout: inout LaunchpadLayout) -> LayoutItem? {
        for page in layout.pages.indices {
            for index in layout.pages[page].items.indices {
                let item = layout.pages[page].items[index]
                if item.id == id { return layout.pages[page].items.remove(at: index) }
                if case .folder(var folder) = item, let app = folder.appIDs.first(where: { "app:\($0)" == id }) {
                    folder.pages = folder.pages.map { $0.filter { $0 != app } }.filter { !$0.isEmpty }
                    if folder.appIDs.isEmpty { layout.pages[page].items.remove(at: index) }
                    else { layout.pages[page].items[index] = .folder(folder) }
                    return .app(app)
                }
            }
        }
        return nil
    }

    private static func normalize(_ layout: inout LaunchpadLayout, capacity: Int) {
        // 移出后只剩一个应用的文件夹解体，动画由展示层的稳定应用 ID 承接。
        for index in layout.pages.indices {
            layout.pages[index].items = layout.pages[index].items.map { item in
                if case .folder(let folder) = item, folder.appIDs.count == 1 { return .app(folder.appIDs[0]) }
                return item
            }
        }
        var page = 0
        while page < layout.pages.count {
            let overflow = Array(layout.pages[page].items.dropFirst(capacity))
            layout.pages[page].items = Array(layout.pages[page].items.prefix(capacity))
            if !overflow.isEmpty {
                if page + 1 == layout.pages.count { layout.pages.append(LayoutPage()) }
                layout.pages[page + 1].items.insert(contentsOf: overflow, at: 0)
            }
            page += 1
        }
        // 中间空页保留用于跨页落点；尾部最多保留一个空页。
        while layout.pages.count > 1 && layout.pages.last!.items.isEmpty && layout.pages[layout.pages.count - 2].items.isEmpty { layout.pages.removeLast() }
    }
}
