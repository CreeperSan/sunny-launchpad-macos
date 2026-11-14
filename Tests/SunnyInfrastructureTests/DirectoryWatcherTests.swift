// 递归监听回归：启动后新建的分类目录也能触发通知，不依赖重新遍历并打开子目录。
import Foundation
import Testing
@testable import SunnyInfrastructure

@MainActor struct DirectoryWatcherTests {
    @Test func detectsApplicationsInNewSubdirectories() async throws {
        // 系统可能不记录临时目录事件，使用工程内独立目录验证实际事件投递。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = ApplicationDirectoryWatcher(roots: [root])
        var notifications = 0
        watcher.onChange = { notifications += 1 }
        watcher.start()
        defer { watcher.stop() }
        let category = root.appendingPathComponent("New Category")
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(5)
        while notifications == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(notifications > 0)
        let previous = notifications
        try FileManager.default.createDirectory(at: category.appendingPathComponent("Example.app"), withIntermediateDirectories: true)
        let nestedDeadline = Date().addingTimeInterval(5)
        while notifications == previous, Date() < nestedDeadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(notifications > previous)
        watcher.stop()
        let stopped = notifications
        try FileManager.default.createDirectory(at: category.appendingPathComponent("After Stop.app"), withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(700))
        #expect(notifications == stopped)
    }
}
