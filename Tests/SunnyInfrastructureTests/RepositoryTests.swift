// 验证真正的磁盘往返、备份与损坏保护，每个测试使用独立临时目录。
import Foundation
import Testing
import SunnyDomain
@testable import SunnyInfrastructure

struct RepositoryTests {
    @Test func atomicRoundTripAndBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONWorkspaceRepository(directory: directory)
        #expect(try await repository.load() == nil)
        var state = WorkspaceState()
        try await repository.save(state)
        state.preferences.language = .yueHant
        state.preferences.style = .classic
        state.preferences.theme = .light
        try await repository.save(state)
        #expect(try await repository.load() == state)
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        let previous = try await repository.readBackup(from: backups[0])
        #expect(previous.preferences.language == .system)
    }

    @Test func corruptOrNewerStateIsNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspace.json")
        let repository = JSONWorkspaceRepository(directory: directory)
        for content in ["broken", "{\"schemaVersion\":999}"] {
            let bytes = Data(content.utf8)
            try bytes.write(to: file)
            await #expect(throws: (any Error).self) { try await repository.save(WorkspaceState()) }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
}
