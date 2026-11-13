// 应用目录扫描：只遍历约定的应用目录，不进入 .app 包内部收集辅助进程。
import AppKit
import SunnyDomain

public actor MacApplicationCatalog: ApplicationCatalog {
    private let roots: [URL]

    public init(roots: [URL]? = nil) {
        self.roots = roots ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications")
        ]
    }

    public func scan() throws -> [ApplicationRecord] {
        var result: [String: ApplicationRecord] = [:]
        let manager = FileManager.default
        for root in roots {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                guard let bundle = Bundle(url: url), bundle.bundleIdentifier != LaunchpadRules.bundleIdentifier,
                      bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true else { continue }
                // 部分第三方应用显式提供空显示名，必须继续回退而不是显示无名称图标。
                let names = [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, url.deletingPathExtension().lastPathComponent]
                let name = names.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? url.lastPathComponent
                let bundleID = bundle.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
                let id = bundleID ?? url.standardizedFileURL.path
                if result[id] == nil {
                    result[id] = ApplicationRecord(id: id, name: name, bundleIdentifier: bundleID, path: url.path)
                }
            }
        }
        return result.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

}

/// 启动只接受当前目录中的应用路径，交给系统 LaunchServices 处理。
@MainActor public final class MacApplicationLauncher: ApplicationLaunching {
    public init() {}

    public func launch(_ app: ApplicationRecord) async throws {
        guard app.isAvailable, let path = app.path, FileManager.default.fileExists(atPath: path) else { throw SunnyError.unavailableApp }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }
}
