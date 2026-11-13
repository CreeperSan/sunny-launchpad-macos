// 验证多语言资源覆盖与不同显示器逻辑尺寸下的网格边界。
import Foundation
import Testing
import SunnyDomain
@testable import SunnyPresentation

struct PresentationTests {
    @Test func allLanguagesHaveCompleteResources() {
        let baseline = L10n.keys(for: .english)
        #expect(baseline.count > 70)
        for language in AppLanguage.allCases where language != .system {
            #expect(L10n.keys(for: language) == baseline)
            for key in baseline { #expect(!L10n.text(key, language: language).isEmpty) }
        }
        #expect(L10n.text("search", language: .yueHans) != L10n.text("search", language: .zhHans))
        #expect(L10n.text("search", language: .yueHant) != L10n.text("search", language: .zhHant))
    }

    @Test(arguments: [CGSize(width: 800, height: 480), CGSize(width: 1024, height: 650), CGSize(width: 1512, height: 850), CGSize(width: 1920, height: 1000), CGSize(width: 2560, height: 1360), CGSize(width: 1080, height: 1820)])
    func gridFitsScaledAndPortraitDisplays(size: CGSize) {
        let metrics = LauncherMetrics(availableSize: size)
        #expect(metrics.cellHeight * CGFloat(LaunchpadRules.rows) + LauncherMetrics.verticalChrome <= size.height)
        #expect(metrics.iconSize + 43 <= metrics.cellHeight)
        #expect(metrics.iconSize + 16 <= metrics.tileWidth)
        #expect(metrics.iconSize <= 88)
    }
}
