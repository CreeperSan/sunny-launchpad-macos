// 回归第三方应用空显示名、空 bundle ID，避免出现无名称或身份冲突。
import Foundation
import Testing
import SunnyDomain
@testable import SunnyInfrastructure

struct CatalogTests {
    @Test func emptyMetadataFallsBackToFilenameAndPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["First", "Second"] {
            let contents = root.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "", "CFBundleName": "", "CFBundleDisplayName": ""]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let apps = try await MacApplicationCatalog(roots: [root]).scan()
        #expect(apps.map(\.name) == ["First", "Second"])
        #expect(Set(apps.map(\.id)).count == 2)
        #expect(apps.allSatisfy { $0.bundleIdentifier == nil })
    }
}
