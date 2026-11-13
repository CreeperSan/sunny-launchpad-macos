// 自有状态仓储：串行保存、原子替换、覆盖前备份；绝不访问 Dock 数据目录。
import Foundation
import SunnyDomain

public actor JSONWorkspaceRepository: WorkspaceRepository {
    public let directory: URL
    private let stateURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let maximumBackupCount = 30
    private let maximumFileSize = 16 * 1024 * 1024

    public init(directory: URL) {
        self.directory = directory
        stateURL = directory.appendingPathComponent("workspace.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SUNNY_DATA_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(LaunchpadRules.bundleIdentifier, isDirectory: true)
    }

    public func load() throws -> WorkspaceState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try readBackup(from: stateURL)
    }

    public func readBackup(from url: URL) throws -> WorkspaceState {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize else { throw SunnyError.corruptData }
        let data = try Data(contentsOf: url)
        // 先读取版本，保证未来模型即使字段不同也明确报“版本不支持”。
        struct Header: Decodable { let schemaVersion: Int }
        guard let header = try? decoder.decode(Header.self, from: data) else { throw SunnyError.corruptData }
        guard header.schemaVersion == LaunchpadRules.schemaVersion else { throw SunnyError.unsupportedVersion }
        guard let state = try? decoder.decode(WorkspaceState.self, from: data) else { throw SunnyError.corruptData }
        try LayoutEditor.validate(state)
        return state
    }

    public func save(_ state: WorkspaceState) throws {
        try LayoutEditor.validate(state)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let backups = directory.appendingPathComponent("Backups", isDirectory: true)
        if manager.fileExists(atPath: stateURL.path) {
            // 再次校验磁盘原件，拒绝覆盖其他版本或外部损坏的数据。
            let previous = try readBackup(from: stateURL)
            if previous == state { return }
            try manager.createDirectory(at: backups, withIntermediateDirectories: true)
            let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
            try manager.copyItem(at: stateURL, to: backups.appendingPathComponent(name))
        }
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        // 清理仅作用于自有备份目录，失败不影响已经成功保存的状态。
        if let files = try? manager.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil) {
            for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(maximumBackupCount) {
                try? manager.removeItem(at: file)
            }
        }
    }

    public func exportState(to url: URL) throws {
        guard let state = try load() else { throw SunnyError.storageUnavailable }
        guard url.standardizedFileURL != stateURL.standardizedFileURL else { return }
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
