// 领域模型：只表达应用身份与布局，不包含任何窗口、图标或数据库对象。
import Foundation

/// 集中定义产品约束，避免分页、导入和视图使用不同容量。
public enum LaunchpadRules {
    public static let schemaVersion = 1
    public static let columns = 7
    public static let rows = 5
    public static let folderRows = 5
    public static let pageCapacity = columns * rows
    public static let folderCapacity = columns * folderRows
    public static let maximumNodes = 10_000
    public static let defaultFolderName = "New Folder"
    public static let bundleIdentifier = "com.creepersan.SunnyLaunchpad"
}

/// 同一 bundle 的位置与安装路径解耦；暂时失联时保留图标占位。
public struct ApplicationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundleIdentifier: String?
    public var path: String?
    public var isAvailable: Bool

    public init(id: String, name: String, bundleIdentifier: String? = nil, path: String? = nil, isAvailable: Bool = true) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.isAvailable = isAvailable
    }
}

/// 页面有稳定身份；翻页和移动不会依赖临时数组索引充当主键。
public struct LayoutPage: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var items: [LayoutItem]

    public init(id: String = UUID().uuidString, items: [LayoutItem] = []) {
        self.id = id
        self.items = items
    }
}

/// 文件夹只允许保存应用引用，类型层面排除嵌套文件夹。
public struct AppFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var pages: [[String]]

    public init(id: String = UUID().uuidString, name: String, pages: [[String]]) {
        self.id = id
        self.name = name
        self.pages = pages
    }

    public var appIDs: [String] { pages.flatMap { $0 } }
}

/// 文件夹和应用使用带类型的身份，避免 bundle ID 与文件夹 UUID 冲突。
public enum LayoutItem: Codable, Equatable, Identifiable, Sendable {
    case app(String)
    case folder(AppFolder)

    public var id: String {
        switch self {
        case .app(let id): "app:\(id)"
        case .folder(let folder): "folder:\(folder.id)"
        }
    }

    public var appIDs: [String] {
        switch self {
        case .app(let id): [id]
        case .folder(let folder): folder.appIDs
        }
    }
}

public struct LaunchpadLayout: Codable, Equatable, Sendable {
    public var pages: [LayoutPage]

    public init(pages: [LayoutPage] = [LayoutPage()]) { self.pages = pages }
    public var appIDs: [String] { pages.flatMap { $0.items.flatMap(\.appIDs) } }
    public var folders: [AppFolder] {
        pages.flatMap(\.items).compactMap { if case .folder(let folder) = $0 { folder } else { nil } }
    }
}

/// 用户偏好相互独立；风格不改变主题、语言或布局。
public enum InterfaceStyle: String, Codable, CaseIterable, Sendable { case classic, liquidGlass }
public enum Theme: String, Codable, CaseIterable, Sendable { case system, dark, light }
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system, zhHans = "zh-Hans", yueHans = "yue-Hans", zhHant = "zh-Hant", yueHant = "yue-Hant", english = "en", japanese = "ja", korean = "ko"

    /// 粤语优先于中文匹配；香港中文默认为繁体中文，只有 yue 才选择广东话。
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for language in preferredLanguages {
            let tag = language.lowercased()
            if tag.hasPrefix("yue") { return tag.contains("hans") || tag.contains("cn") ? .yueHans : .yueHant }
            if tag.hasPrefix("zh") { return tag.contains("hant") || tag.contains("tw") || tag.contains("hk") || tag.contains("mo") ? .zhHant : .zhHans }
            if tag.hasPrefix("en") { return .english }
            if tag.hasPrefix("ja") { return .japanese }
            if tag.hasPrefix("ko") { return .korean }
        }
        return .english
    }

    public var nativeName: String {
        switch self {
        case .system: "System"
        case .zhHans: "简体中文"
        case .yueHans: "简体粤语"
        case .zhHant: "繁體中文"
        case .yueHant: "繁體廣東話"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var style: InterfaceStyle = .liquidGlass
    public var theme: Theme = .system
    public var language: AppLanguage = .system
    public var hotKeyEnabled = true
    public var rememberPage = true
    public var reduceMotion = false
    public init() {}
}

/// 单个版本化状态文件保证偏好和布局提交的一致性。
public struct WorkspaceState: Codable, Equatable, Sendable {
    public var schemaVersion = LaunchpadRules.schemaVersion
    public var layout: LaunchpadLayout
    public var catalog: [ApplicationRecord]
    public var preferences: Preferences

    public init(layout: LaunchpadLayout = LaunchpadLayout(), catalog: [ApplicationRecord] = [], preferences: Preferences = Preferences()) {
        self.layout = layout
        self.catalog = catalog
        self.preferences = preferences
    }
}

/// 业务错误使用稳定代码，具体语句由展示层按当前语言生成。
public enum SunnyError: String, Error, LocalizedError, Sendable {
    case invalidLayout, unsupportedVersion, corruptData, unavailableApp, unsupportedDatabase, changingDatabase, oversizedDatabase, emptyImport, storageUnavailable
    public var errorDescription: String? { rawValue }
}
