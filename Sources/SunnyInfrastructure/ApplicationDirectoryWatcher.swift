// 仅监听应用目录及一级分类目录，不扫描 .app 包内容，空闲时不轮询。
import Foundation
import Darwin

@MainActor public final class ApplicationDirectoryWatcher {
    private var sources: [any DispatchSourceFileSystemObject] = []
    private var debounce: Task<Void, Never>?
    public var onChange: () -> Void = {}
    public init() {}

    public func start() {
        stop()
        let manager = FileManager.default
        let roots = [manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices/Applications")]
        var directories = roots
        for root in roots {
            if let children = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]) {
                directories += children.filter { url in
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
                    return values.isDirectory == true && values.isPackage != true
                }
            }
        }
        var seen = Set<String>()
        for url in directories.prefix(128) where seen.insert(url.resolvingSymlinksInPath().path).inserted {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.debounce?.cancel()
                    self?.debounce = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        self?.onChange()
                    }
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }
    public func stop() { debounce?.cancel(); sources.forEach { $0.cancel() }; sources.removeAll() }
}
