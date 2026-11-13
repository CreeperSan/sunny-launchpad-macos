// 旧启动台适配器：源文件仅普通读取；所有 SQLite 操作只发生在私有临时副本。
import Foundation
import Darwin
import CSQLite
import SunnyDomain

public actor LegacyLaunchpadImporter: LegacyLayoutImporting {
    private let maximumBytes = 128 * 1024 * 1024
    private let rootUUID = "ROOTPAGE"
    private let holdingPrefix = "HOLDINGPAGE"
    private enum NodeType: Int { case root = 1, folder = 2, page = 3, app = 4 }

    /// 旧表的字段集中声明，固定 SQL 不插入用户输入。
    private struct Node {
        let id: Int64
        let uuid: String
        let type: Int
        let parent: Int64
        let order: Int
        let name: String
        let bundleID: String
    }

    public init() {}

    public func discover() -> [URL] {
        var candidates: [URL] = []
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 {
            let directory = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            candidates.append(URL(fileURLWithPath: directory).appendingPathComponent("com.apple.dock.launchpad/db/db"))
        }
        let userRoot = FileManager.default.temporaryDirectory.deletingLastPathComponent()
        candidates.append(userRoot.appendingPathComponent("0/com.apple.dock.launchpad/db/db"))
        let dock = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dock")
        if let files = try? FileManager.default.contentsOfDirectory(at: dock, includingPropertiesForKeys: nil) {
            candidates += files.filter { $0.pathExtension == "db" && $0.lastPathComponent != "desktoppicture.db" }
        }
        var seen = Set<String>()
        return candidates.filter { FileManager.default.isReadableFile(atPath: $0.path) && seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    public func preview(from url: URL, catalog: [ApplicationRecord]) throws -> ImportPreview {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SunnyImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = try snapshot(url, into: directory)
        let nodes = try readNodes(copy)
        guard let root = nodes.first(where: { $0.uuid == rootUUID && $0.type == NodeType.root.rawValue }) else { throw SunnyError.unsupportedDatabase }
        let children = Dictionary(grouping: nodes, by: \.parent).mapValues { $0.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }
        let installed = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var importedCatalog: [ApplicationRecord] = []
        var seen = Set<String>()
        var matched = 0
        var missing = 0

        func appID(_ node: Node) -> String? {
            let id = node.bundleID.isEmpty ? "legacy:\(node.uuid.isEmpty ? String(node.id) : node.uuid)" : node.bundleID
            guard seen.insert(id).inserted else { return nil }
            if let app = installed[id] {
                importedCatalog.append(app)
                matched += 1
            } else {
                importedCatalog.append(ApplicationRecord(id: id, name: node.name.isEmpty ? id : node.name, bundleIdentifier: node.bundleID.isEmpty ? nil : node.bundleID, isAvailable: false))
                missing += 1
            }
            return id
        }

        var pages: [LayoutPage] = []
        for page in children[root.id, default: []] where page.type == NodeType.page.rawValue && !page.uuid.hasPrefix(holdingPrefix) {
            var items: [LayoutItem] = []
            for node in children[page.id, default: []] {
                if node.type == NodeType.app.rawValue, let id = appID(node) { items.append(.app(id)) }
                else if node.type == NodeType.folder.rawValue {
                    var folderPages: [[String]] = []
                    // 现代旧库为 folder → page → app；同时兼容直接挂在文件夹下的应用。
                    let directApps = children[node.id, default: []].filter { $0.type == NodeType.app.rawValue }.compactMap(appID)
                    folderPages += LayoutEditor.chunks(directApps, size: LaunchpadRules.folderCapacity)
                    for child in children[node.id, default: []] where child.type == NodeType.page.rawValue && !child.uuid.hasPrefix(holdingPrefix) {
                        let apps = children[child.id, default: []].filter { $0.type == NodeType.app.rawValue }.compactMap(appID)
                        folderPages += LayoutEditor.chunks(apps, size: LaunchpadRules.folderCapacity)
                    }
                    if !folderPages.isEmpty {
                        items.append(.folder(AppFolder(name: node.name.isEmpty ? LaunchpadRules.defaultFolderName : node.name, pages: folderPages)))
                    }
                }
            }
            let chunks = LayoutEditor.chunks(items, size: LaunchpadRules.pageCapacity)
            pages += chunks.isEmpty ? [LayoutPage()] : chunks.map { LayoutPage(items: $0) }
        }
        guard !seen.isEmpty else { throw SunnyError.emptyImport }
        var state = WorkspaceState(layout: LaunchpadLayout(pages: pages), catalog: importedCatalog)
        let pageCount = pages.count
        let folderCount = state.layout.folders.count
        // 不将旧布局之外的新应用填入原页面空位，以保留迁移后的页面空间记忆。
        let newApps = catalog.filter { !seen.contains($0.id) }
        if !newApps.isEmpty { state.layout.pages.append(LayoutPage()) }
        state.catalog.append(contentsOf: newApps)
        for app in newApps { LayoutEditor.append(.app(app.id), to: &state.layout) }
        try LayoutEditor.validate(state)
        return ImportPreview(state: state, source: url, matchedCount: matched, missingCount: missing, importedPageCount: pageCount, importedFolderCount: folderCount)
    }

    /// 两次完整读取比较主文件与 WAL；拒绝正在变化或存在回滚日志的输入。
    private func snapshot(_ source: URL, into directory: URL) throws -> URL {
        let journal = URL(fileURLWithPath: source.path + "-journal")
        if FileManager.default.fileExists(atPath: journal.path), (try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 { throw SunnyError.changingDatabase }
        func readFiles() throws -> [String: Data] {
            var files: [String: Data] = [:]
            for suffix in ["", "-wal"] {
                let path = URL(fileURLWithPath: source.path + suffix)
                if suffix.isEmpty || FileManager.default.fileExists(atPath: path.path) {
                    let values = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, (values.fileSize ?? 0) <= maximumBytes else { throw SunnyError.oversizedDatabase }
                    files[suffix] = try Data(contentsOf: path)
                }
            }
            return files
        }
        let first = try readFiles()
        let second = try readFiles()
        guard first == second else { throw SunnyError.changingDatabase }
        let copy = directory.appendingPathComponent("db")
        for (suffix, data) in first { try data.write(to: URL(fileURLWithPath: copy.path + suffix), options: .atomic) }
        return copy
    }

    /// SQLite 句柄不跨 actor 边界。查询错误和行数上限均终止导入。
    private func readNodes(_ url: URL) throws -> [Node] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw SunnyError.unsupportedDatabase
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK else { throw SunnyError.unsupportedDatabase }
        let checkStatus = sqlite3_step(check)
        let checkMessage = text(check, 0)
        let valid = checkStatus == SQLITE_ROW && checkMessage == "ok"
        sqlite3_finalize(check)
        guard valid else { throw SunnyError.corruptData }
        let query = """
            SELECT i.rowid, i.uuid, i.type, i.parent_id, i.ordering,
                   COALESCE(a.title, g.title, ''), COALESCE(a.bundleid, '')
            FROM items AS i
            LEFT JOIN apps AS a ON a.item_id = i.rowid
            LEFT JOIN groups AS g ON g.item_id = i.rowid
            ORDER BY i.parent_id, i.ordering, i.rowid
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw SunnyError.unsupportedDatabase }
        defer { sqlite3_finalize(statement) }
        var result: [Node] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard result.count < LaunchpadRules.maximumNodes else { throw SunnyError.oversizedDatabase }
            result.append(Node(id: sqlite3_column_int64(statement, 0), uuid: text(statement, 1), type: Int(sqlite3_column_int(statement, 2)), parent: sqlite3_column_int64(statement, 3), order: Int(sqlite3_column_int(statement, 4)), name: text(statement, 5), bundleID: text(statement, 6)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw SunnyError.corruptData }
        return result
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}
