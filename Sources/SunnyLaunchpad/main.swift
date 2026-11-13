// 原生应用入口。诊断模式只输出导入统计，不保存用户布局或启动其他应用。
import AppKit
import SunnyDomain
import SunnyInfrastructure

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--inspect-legacy" {
    let source = URL(fileURLWithPath: CommandLine.arguments[2])
    Task {
        do {
            let catalog = try await MacApplicationCatalog().scan()
            let preview = try await LegacyLaunchpadImporter().preview(from: source, catalog: catalog)
            print("pages=\(preview.importedPageCount) folders=\(preview.importedFolderCount) matched=\(preview.matchedCount) missing=\(preview.missingCount)")
            exit(EXIT_SUCCESS)
        } catch {
            print("Import failed: \(error)")
            exit(EXIT_FAILURE)
        }
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
