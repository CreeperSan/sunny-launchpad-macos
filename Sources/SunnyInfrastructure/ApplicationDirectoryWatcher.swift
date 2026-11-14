// 监听应用目录及其分类目录，不进入 .app 包，空闲时不轮询。
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
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), values.isDirectory == true, values.isPackage != true else { continue }
                directories.append(url)
            }
        }
        var seen = Set<String>()
        for url in directories where seen.insert(url.resolvingSymlinksInPath().path).inserted {
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
