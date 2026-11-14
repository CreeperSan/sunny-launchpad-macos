// 使用系统递归目录事件监听应用变化，避免每个子目录持有一个文件句柄。
import Foundation
import CoreServices

@MainActor public final class ApplicationDirectoryWatcher {
    private static let eventLatency: CFTimeInterval = 0.5
    private var stream: FSEventStreamRef?
    private let roots: [URL]
    public var onChange: () -> Void = {}
    /// 可注入隔离目录用于验证递归事件；正式运行只监听系统应用位置。
    public init(roots: [URL]? = nil) {
        let manager = FileManager.default
        self.roots = roots ?? [manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices/Applications")]
    }
    isolated deinit { stop() }

    /// FSEvents 自动包含新增的分类目录，无需遍历应用目录或在每次通知后重建监听。
    public func start() {
        stop()
        let manager = FileManager.default
        let paths = roots.filter { manager.fileExists(atPath: $0.path) }.map { $0.resolvingSymlinksInPath().path }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, { _, pointer, _, _, _, _ in
            guard let pointer else { return }
            // 流固定投递到主队列，回调可直接调用主线程上的 Store 协调逻辑。
            MainActor.assumeIsolated {
                Unmanaged<ApplicationDirectoryWatcher>.fromOpaque(pointer).takeUnretainedValue().onChange()
            }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.eventLatency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// 先停止并使回调失效，再释放流，退出时不留下悬空的上下文指针。
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
