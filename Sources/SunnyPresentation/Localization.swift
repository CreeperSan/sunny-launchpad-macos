// 本地化表独立于 SwiftUI 的系统语言，允许在应用内立即切换而不重启。
import Foundation
import SunnyDomain

public enum L10n {
    private static let tables: [AppLanguage: [String: String]] = {
        var result: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases where language != .system {
            if let url = Bundle.module.url(forResource: language.rawValue, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let table = try? JSONDecoder().decode([String: String].self, from: data) {
                result[language] = table
            }
        }
        return result
    }()

    /// 英文为明确兜底；测试验证所有受支持语言拥有相同的键集。
    public static func text(_ key: String, language: AppLanguage) -> String {
        tables[language.resolved()]?[key] ?? tables[.english]?[key] ?? key
    }

    public static func keys(for language: AppLanguage) -> Set<String> { Set(tables[language]?.keys.map { $0 } ?? []) }
}
