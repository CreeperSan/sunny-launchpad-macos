// 验证用户位置与数据不变量，不依赖窗口或真实安装目录。
import Testing
import Foundation
@testable import SunnyDomain

struct LayoutEditorTests {
    private let apps = ["a", "b", "c", "d"].map { ApplicationRecord(id: $0, name: $0) }

    @Test func groupingMovingAndRenamingPreservesApps() throws {
        var layout = LaunchpadLayout(pages: [LayoutPage(id: "first", items: [.app("a"), .app("b"), .app("c")]), LayoutPage(id: "second", items: [.app("d")])])
        layout = LayoutEditor.group("app:a", onto: "app:b", name: "工具", in: layout)
        let folder = try #require(layout.folders.first)
        #expect(folder.appIDs == ["b", "a"])
        layout = LayoutEditor.renameFolder(folder.id, name: " 工作 ", in: layout)
        #expect(layout.folders[0].name == "工作")
        layout = LayoutEditor.move("app:a", toPage: "second", before: "app:d", in: layout)
        #expect(layout.pages[1].items == [.app("a"), .app("d")])
        #expect(layout.folders[0].appIDs == ["b"])
        layout = LayoutEditor.move("app:b", toPage: "first", before: "app:c", in: layout)
        #expect(layout.folders.isEmpty)
        try LayoutEditor.validate(WorkspaceState(layout: layout, catalog: apps))
        #expect(Set(layout.appIDs) == Set(apps.map(\.id)))
    }

    @Test func refreshKeepsMissingAppsAndOrder() {
        let state = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.app("b"), .app("a")])]), catalog: Array(apps.prefix(2)))
        let refreshed = LayoutEditor.reconcile(state, discovered: [apps[0], apps[2]])
        #expect(refreshed.layout.appIDs == ["b", "a", "c"])
        #expect(refreshed.catalog.first { $0.id == "b" }?.isAvailable == false)
        #expect(LayoutEditor.reconcile(refreshed, discovered: [apps[0], apps[2]]) == refreshed)
    }

    @Test func overflowDoesNotDropApps() throws {
        let all = (0..<70).map { ApplicationRecord(id: "app\($0)", name: "App \($0)") }
        var state = LayoutEditor.reconcile(WorkspaceState(), discovered: all)
        let destination = state.layout.pages[0].id
        state.layout = LayoutEditor.move("app:app69", toPage: destination, before: "app:app0", in: state.layout)
        #expect(state.layout.pages[0].items[0] == .app("app69"))
        #expect(state.layout.appIDs.count == 70)
        try LayoutEditor.validate(state)
    }

    @Test func folderMoveCannotNestOrLoseUniqueChild() {
        let folder = AppFolder(id: "folder", name: "Tools", pages: [["a"]])
        let layout = LaunchpadLayout(pages: [LayoutPage(items: [.folder(folder), .app("b")])])
        #expect(LayoutEditor.group("folder:folder", onto: "app:b", name: "x", in: layout) == layout)
        #expect(LayoutEditor.moveIntoFolder("app:a", folderID: "folder", page: 0, before: nil, in: layout) == layout)
        let updated = LayoutEditor.moveIntoFolder("app:b", folderID: "folder", page: 0, before: "a", in: layout)
        #expect(updated.folders[0].appIDs == ["b", "a"])
    }

    @Test func invalidDataAndFutureSchemaAreRejected() {
        let duplicated = WorkspaceState(layout: LaunchpadLayout(pages: [LayoutPage(items: [.app("a"), .app("a")])]), catalog: apps)
        #expect(throws: SunnyError.invalidLayout) { try LayoutEditor.validate(duplicated) }
        var future = WorkspaceState()
        future.schemaVersion = 99
        #expect(throws: SunnyError.unsupportedVersion) { try LayoutEditor.validate(future) }
    }

    @Test func searchAndLanguageResolution() {
        let names = [ApplicationRecord(id: "1", name: "Café"), ApplicationRecord(id: "2", name: "备忘录")]
        #expect(LayoutEditor.search(names, query: " CAFE ").map(\.id) == ["1"])
        #expect(LayoutEditor.search(names, query: "备忘").map(\.id) == ["2"])
        #expect(AppLanguage.system.resolved(preferredLanguages: ["yue-Hans-CN"]) == .yueHans)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["yue-HK"]) == .yueHant)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-HK"]) == .zhHant)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "ja-JP"]) == .japanese)
        #expect(AppLanguage.korean.resolved(preferredLanguages: ["en-US"]) == .korean)
    }
}
