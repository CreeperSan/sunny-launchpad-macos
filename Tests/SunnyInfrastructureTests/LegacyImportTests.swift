// 合成旧库覆盖嵌套页、暂存页、WAL、缺失应用和源文件不变性，避免提交私人数据库。
import Foundation
import Testing
import CSQLite
import SunnyDomain
@testable import SunnyInfrastructure

struct LegacyImportTests {
    private func fixture(in directory: URL, wal: Bool) throws -> (URL, OpaquePointer) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("db")
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let handle = try #require(database)
        let schema = """
            CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid TEXT, type INTEGER, parent_id INTEGER, ordering INTEGER);
            CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title TEXT, bundleid TEXT);
            CREATE TABLE groups (item_id INTEGER PRIMARY KEY, title TEXT);
            INSERT INTO items VALUES (40, 'ROOTPAGE', 1, 0, 0), (41, 'page', 3, 40, 1), (42, 'HOLDINGPAGE', 3, 40, 0);
            INSERT INTO items VALUES (43, 'folder', 2, 41, 0), (44, 'folderpage', 3, 43, 0);
            INSERT INTO items VALUES (45, 'app1', 4, 44, 1), (46, 'app2', 4, 44, 0), (47, 'app3', 4, 41, 1), (48, 'hidden', 4, 42, 0);
            INSERT INTO groups VALUES (43, '工具');
            INSERT INTO apps VALUES (45, 'A', 'app.a'), (46, 'B', 'app.b'), (47, 'C', 'app.c'), (48, 'Hidden', 'app.hidden');
            """
        #expect(sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK)
        if wal {
            #expect(sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE groups SET title='WAL 工具';", nil, nil, nil) == SQLITE_OK)
        }
        return (url, handle)
    }

    @Test(arguments: [false, true]) func readsLayoutWithoutChangingSource(wal: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (url, database) = try fixture(in: directory, wal: wal)
        defer { sqlite3_close(database); try? FileManager.default.removeItem(at: directory) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        let before = try files.map { (try Data(contentsOf: $0), try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
        let catalog = [ApplicationRecord(id: "app.a", name: "Installed A"), ApplicationRecord(id: "new.app", name: "New")]
        let preview = try await LegacyLaunchpadImporter().preview(from: url, catalog: catalog)
        #expect(preview.importedPageCount == 1)
        #expect(preview.importedFolderCount == 1)
        #expect(preview.matchedCount == 1)
        #expect(preview.missingCount == 2)
        #expect(preview.state.layout.folders[0].name == (wal ? "WAL 工具" : "工具"))
        #expect(preview.state.layout.folders[0].appIDs == ["app.b", "app.a"])
        #expect(!preview.state.layout.appIDs.contains("app.hidden"))
        #expect(preview.state.layout.pages[1].items == [.app("new.app")])
        for (index, file) in files.enumerated() {
            #expect(try Data(contentsOf: file) == before[index].0)
            #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before[index].1)
        }
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == files.count)
    }

    @Test func invalidDatabaseFailsWithoutSourceWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bad.db")
        let bytes = Data("not a database".utf8)
        try bytes.write(to: file)
        await #expect(throws: (any Error).self) { try await LegacyLaunchpadImporter().preview(from: file, catalog: []) }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
