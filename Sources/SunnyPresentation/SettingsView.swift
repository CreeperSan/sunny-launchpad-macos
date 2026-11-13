// 独立设置窗口：分区管理通用行为、视觉偏好和可预览的布局迁移。
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SunnyDomain

public struct SettingsView: View {
    @Bindable var store: LaunchpadStore
    let dataDirectory: URL
    @State private var section: Section = .general
    @State private var restoreURL: URL?
    private enum Section: String, CaseIterable, Identifiable {
        case general, appearance, importLayout = "import", about
        var id: String { rawValue }
        var symbol: String {
            switch self { case .general: "slider.horizontal.3"; case .appearance: "paintpalette"; case .importLayout: "square.grid.3x3"; case .about: "sun.max" }
        }
    }

    public init(store: LaunchpadStore, dataDirectory: URL) {
        self.store = store
        self.dataDirectory = dataDirectory
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "sun.max.fill").font(.title).foregroundStyle(.orange)
                    Text("Sunny\nLaunchpad").font(.system(size: 16, weight: .semibold))
                }.padding(.bottom, 22)
                ForEach(Section.allCases) { item in
                    Button { section = item } label: {
                        Label(store.text(item.rawValue), systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                            .background(section == item ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("0.1.0").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20).frame(width: 210).frame(maxHeight: .infinity)
            .modifier(PanelSurface(style: store.preferences.style, radius: 0))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(store.text(section.rawValue)).font(.largeTitle.bold())
                    if store.readOnly { Text(store.text("readOnly")).foregroundStyle(.orange) }
                    switch section {
                    case .general: general
                    case .appearance: appearance
                    case .importLayout: importLayout
                    case .about: about
                    }
                    if store.busy { ProgressView().controlSize(.small) }
                    if let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(32)
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(store.preferences.style == .classic ? 1 : 0.65))
        }
        .frame(minWidth: 820, minHeight: 620)
        .preferredColorScheme(store.preferences.theme.colorScheme)
        .alert(store.text("error"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(store.text("done")) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog(store.text("restoreConfirm"), isPresented: Binding(get: { restoreURL != nil }, set: { if !$0 { restoreURL = nil } }), titleVisibility: .visible) {
            Button(store.text("restore")) { if let url = restoreURL { Task { await store.restore(from: url) } }; restoreURL = nil }
            Button(store.text("cancel"), role: .cancel) { restoreURL = nil }
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker(store.text("language"), selection: preference(\.language)) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language == .system ? store.text("system") : language.nativeName).tag(language)
                }
            }.pickerStyle(.menu)
            Divider()
            Toggle(store.text("hotkey"), isOn: preference(\.hotKeyEnabled))
            Text(store.text("hotkeyHelp")).font(.callout).foregroundStyle(.secondary)
            if let error = store.hotkeyError { Text(error).foregroundStyle(.orange) }
            Toggle(store.text("rememberPage"), isOn: preference(\.rememberPage))
            Button(store.text("refresh")) { Task { await store.refresh() } }
        }.disabled(!store.canEdit)
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 26) {
            Picker(store.text("style"), selection: preference(\.style)) {
                ForEach(InterfaceStyle.allCases, id: \.self) { style in Text(store.text(style.rawValue)).tag(style) }
            }.pickerStyle(.radioGroup)
            Text(store.text("styleHelp")).font(.callout).foregroundStyle(.secondary)
            Divider()
            Picker(store.text("theme"), selection: preference(\.theme)) {
                ForEach(Theme.allCases, id: \.self) { theme in Text(store.text(theme.rawValue)).tag(theme) }
            }.pickerStyle(.radioGroup)
            Divider()
            Toggle(store.text("reduceMotion"), isOn: preference(\.reduceMotion))
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                Text("Sunny Launchpad").font(.headline)
            }
            .padding(24).frame(maxWidth: .infinity)
            .modifier(PanelSurface(style: store.preferences.style))
        }.disabled(!store.canEdit)
    }

    private var importLayout: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.text("importTitle")).font(.title2.weight(.semibold))
            Text(store.text("importHelp")).foregroundStyle(.secondary)
            HStack {
                Button(store.text("discover")) { Task { await store.discover() } }
                Button(store.text("chooseDatabase")) { chooseDatabase() }
            }.disabled(!store.canEdit)
            if store.sources.count > 1 {
                ForEach(store.sources, id: \.self) { source in
                    Button(source.path) { Task { await store.preview(source) } }.font(.caption).disabled(!store.canEdit)
                }
            }
            if let preview = store.importPreview {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.text("preview")).font(.headline)
                    Text(preview.source.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack(spacing: 20) {
                        metric("pages", preview.importedPageCount)
                        metric("folders", preview.importedFolderCount)
                        metric("matched", preview.matchedCount)
                        metric("missingCount", preview.missingCount)
                    }
                    // 预览不只给数字，也展示原页面和文件夹名称，便于用户核对导入结果。
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(preview.state.layout.pages.prefix(preview.importedPageCount).enumerated()), id: \.element.id) { index, page in
                                Text("\(store.text("page")) \(index + 1)").font(.subheadline.bold())
                                Text(page.items.map { item in
                                    switch item {
                                    case .app(let id): preview.state.catalog.first(where: { $0.id == id })?.name ?? id
                                    case .folder(let folder): "[\(folder.name) · \(folder.appIDs.count)]"
                                    }
                                }.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140)
                    Text(store.text("importNote")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(store.text("applyImport")) { Task { await store.applyImport() } }.buttonStyle(.borderedProminent).disabled(!store.canEdit)
                        Button(store.text("cancel")) { store.importPreview = nil }
                    }
                }.padding(18).modifier(PanelSurface(style: store.preferences.style))
            }
            Divider()
            Text(store.text("backup")).font(.headline)
            HStack {
                Button(store.text("export")) { exportBackup() }
                Button(store.text("restore")) { chooseBackup() }
            }.disabled(!store.canEdit)
            Button(store.text("openData")) { NSWorkspace.shared.open(dataDirectory) }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "sun.max.fill").font(.system(size: 68)).foregroundStyle(.orange)
            Text("Sunny Launchpad").font(.title.bold())
            Text(store.text("previewVersion")).foregroundStyle(.secondary)
            Text(store.text("aboutText")).lineSpacing(6)
            Text("MIT · © 2026 CreeperSan").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metric(_ key: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text("\(count)").font(.title2.bold()); Text(store.text(key)).font(.caption).foregroundStyle(.secondary) }
    }

    /// 偏好一律经仓储提交；保存失败时控件自动回到已持久化的值。
    private func preference<Value>(_ path: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { store.preferences[keyPath: path] }, set: { value in Task { await store.setPreferences { $0[keyPath: path] = value } } })
    }

    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.title = store.text("chooseDatabase")
        panel.prompt = store.text("preview")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { Task { await store.preview(url) } }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = store.text("export")
        panel.nameFieldStringValue = "Sunny-Launchpad-Backup.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { Task { await store.export(to: url) } }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.title = store.text("restore")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { restoreURL = panel.url }
    }
}
