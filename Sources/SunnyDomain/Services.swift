// 外部服务协议：可由测试替身或不同系统实现替换，不暴露基础设施类型。
import Foundation

public protocol ApplicationCatalog: Sendable {
    func scan() async throws -> [ApplicationRecord]
}

public protocol WorkspaceRepository: Sendable {
    func load() async throws -> WorkspaceState?
    func save(_ state: WorkspaceState) async throws
    func exportState(to url: URL) async throws
    func readBackup(from url: URL) async throws -> WorkspaceState
}

public protocol LegacyLayoutImporting: Sendable {
    func discover() async -> [URL]
    func preview(from url: URL, catalog: [ApplicationRecord]) async throws -> ImportPreview
}

@MainActor public protocol ApplicationLaunching {
    func launch(_ app: ApplicationRecord) async throws
}

/// 预览是不可自动提交的值；选择来源与应用结果必须是两个独立动作。
public struct ImportPreview: Sendable {
    public var state: WorkspaceState
    public var source: URL
    public var matchedCount: Int
    public var missingCount: Int
    public var importedPageCount: Int
    public var importedFolderCount: Int

    public init(state: WorkspaceState, source: URL, matchedCount: Int, missingCount: Int, importedPageCount: Int, importedFolderCount: Int) {
        self.state = state
        self.source = source
        self.matchedCount = matchedCount
        self.missingCount = missingCount
        self.importedPageCount = importedPageCount
        self.importedFolderCount = importedFolderCount
    }
}
