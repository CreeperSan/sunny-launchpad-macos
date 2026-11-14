// 原生设置页：AppKit 侧栏、表单、滑块和文件面板；仍只通过 Store 提交业务操作。
import AppKit
import Observation
import UniformTypeIdentifiers
import SunnyDomain

@MainActor public final class NativeSettingsView: NSView {
    private let store: LaunchpadStore
    private let dataDirectory: URL
    private let sidebar = NSStackView()
    private let scroll = NSScrollView()
    private let form = NSStackView()
    private var section = "general"
    private var actions: [NativeControlAction] = []
    private var key = ""
    private var errorShown: String?

    public init(store: LaunchpadStore, dataDirectory: URL) {
        self.store = store
        self.dataDirectory = dataDirectory
        super.init(frame: .zero)
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 10
        addSubview(sidebar)
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        addSubview(scroll)
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 20
        form.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        scroll.documentView = form
        form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([form.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        observe()
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var isFlipped: Bool { true }
    public override func layout() {
        super.layout()
        sidebar.frame = NSRect(x: 18, y: 28, width: 192, height: bounds.height - 56)
        scroll.frame = NSRect(x: 220, y: 0, width: max(400, bounds.width - 220), height: bounds.height)
    }
    private func observe() {
        withObservationTracking {
            _ = store.preferences; _ = store.canEdit; _ = store.sources; _ = store.importPreview; _ = store.notice; _ = store.errorMessage; _ = store.hotkeyError
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe(); self?.render() }
        }
    }
    private func render() {
        let nextKey = "\(store.preferences)|\(store.canEdit)|\(store.sources)|\(store.importPreview?.matchedCount ?? -1)|\(store.notice ?? "")|\(store.errorMessage ?? "")|\(store.hotkeyError ?? "")|\(section)"
        guard nextKey != key else { return }
        key = nextKey
        actions.removeAll()
        for view in sidebar.arrangedSubviews { sidebar.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in form.arrangedSubviews { form.removeArrangedSubview(view); view.removeFromSuperview() }
        let brand = NSTextField(labelWithString: "☀︎ Sunny Launchpad")
        brand.font = .systemFont(ofSize: 18, weight: .semibold)
        sidebar.addArrangedSubview(brand)
        for id in ["general", "appearance", "interaction", "import", "about"] {
            let button = makeButton(store.text(id)) { [weak self] in self?.section = id; self?.key = ""; self?.render() }
            button.bezelStyle = .rounded
            button.contentTintColor = section == id ? .controlAccentColor : .labelColor
            sidebar.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 192).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        title(store.text(section))
        if store.readOnly { label(store.text("readOnly")) }
        switch section {
        case "general": general()
        case "appearance": appearance()
        case "interaction": interaction()
        case "import": importLayout()
        default:
            title("Sunny Launchpad")
            label(store.text("previewVersion")); label(store.text("aboutText")); label("MIT · © 2026 CreeperSan")
        }
        if let notice = store.notice { label(notice) }
        if let error = store.errorMessage, error != errorShown, let window {
            errorShown = error
            let alert = NSAlert(); alert.messageText = store.text("error"); alert.informativeText = error
            alert.beginSheetModal(for: window) { [weak store] _ in Task { @MainActor in store?.errorMessage = nil } }
        }
    }
    private func title(_ text: String) { let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 26, weight: .bold); add(field) }
    private func label(_ text: String) { let field = NSTextField(wrappingLabelWithString: text); field.isSelectable = true; add(field) }
    private func add(_ view: NSView) {
        form.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -56).isActive = true
    }
    private func makeButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let target = NativeControlAction(action)
        actions.append(target)
        return NSButton(title: title, target: target, action: #selector(NativeControlAction.invokeAction))
    }
    private func button(_ key: String, action: @escaping () -> Void) { let control = makeButton(store.text(key), action: action); control.isEnabled = store.canEdit; add(control) }
    private func toggle(_ key: String, path: WritableKeyPath<Preferences, Bool>) {
        let control = NSButton(checkboxWithTitle: store.text(key), target: nil, action: nil)
        control.state = store.preferences[keyPath: path] ? .on : .off
        let target = NativeControlAction { [weak self, weak control] in
            guard let self, let control else { return }
            let value = control.state == .on
            Task { await self.store.setPreferences { $0[keyPath: path] = value } }
        }
        actions.append(target); control.target = target; control.action = #selector(NativeControlAction.invokeAction); control.isEnabled = store.canEdit; add(control)
    }
    private func picker<Value: Equatable>(_ key: String, values: [Value], names: [String], path: WritableKeyPath<Preferences, Value>) {
        label(store.text(key))
        if values.count < 5 {
            for (index, name) in names.enumerated() {
                let radio = makeButton(name) { [weak store] in
                    let value = values[index]
                    Task { await store?.setPreferences { $0[keyPath: path] = value } }
                }
                radio.setButtonType(.radio)
                radio.state = values[index] == store.preferences[keyPath: path] ? .on : .off
                radio.isEnabled = store.canEdit
                add(radio)
            }
            return
        }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: names)
        popup.selectItem(at: values.firstIndex(of: store.preferences[keyPath: path]) ?? 0)
        let target = NativeControlAction { [weak self, weak popup] in
            guard let self, let popup, values.indices.contains(popup.indexOfSelectedItem) else { return }
            let value = values[popup.indexOfSelectedItem]
            Task { await self.store.setPreferences { $0[keyPath: path] = value } }
        }
        actions.append(target); popup.target = target; popup.action = #selector(NativeControlAction.invokeAction); popup.isEnabled = store.canEdit; add(popup)
    }
    private func general() {
        picker("language", values: AppLanguage.allCases, names: AppLanguage.allCases.map { $0 == .system ? store.text("system") : $0.nativeName }, path: \.language)
        toggle("hotkey", path: \.hotKeyEnabled); label(store.text("hotkeyHelp"))
        if let error = store.hotkeyError { label(error) }
        toggle("rememberPage", path: \.rememberPage)
        button("refresh") { [weak store] in Task { await store?.refresh() } }
    }
    private func appearance() {
        picker("style", values: InterfaceStyle.allCases, names: InterfaceStyle.allCases.map { store.text($0.rawValue) }, path: \.style)
        picker("theme", values: Theme.allCases, names: Theme.allCases.map { store.text($0.rawValue) }, path: \.theme)
        toggle("reduceMotion", path: \.reduceMotion)
        numeric("backgroundBlur", value: store.preferences.interaction.backgroundBlur, range: 0...60, step: 1) { [weak store] value in Task { await store?.setPreferences { $0.interaction.backgroundBlur = value } } }
        label(store.text("dimColor"))
        let color = NSColorWell()
        let rgb = UInt32(store.preferences.interaction.dimColorHex, radix: 16) ?? 0
        color.color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        let action = NativeControlAction { [weak store, weak color] in
            guard let value = color?.color.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "%02X%02X%02X", Int((value.redComponent * 255).rounded()), Int((value.greenComponent * 255).rounded()), Int((value.blueComponent * 255).rounded()))
            Task { await store?.setPreferences { $0.interaction.dimColorHex = hex } }
        }
        actions.append(action); color.target = action; color.action = #selector(NativeControlAction.invokeAction); color.isEnabled = store.canEdit
        color.heightAnchor.constraint(equalToConstant: 32).isActive = true
        add(color)
        numeric("dimOpacity", value: store.preferences.interaction.dimOpacity, range: 0...1, step: 0.01, multiplier: 100) { [weak store] value in Task { await store?.setPreferences { $0.interaction.dimOpacity = value } } }
    }
    private func numeric(_ key: String, value: Double, range: ClosedRange<Double>, step: Double, multiplier: Double = 1, change: @escaping (Double) -> Void) {
        let row = NativeNumericControl(title: store.text(key), value: value, range: range, step: step, multiplier: multiplier, change: change)
        row.heightAnchor.constraint(equalToConstant: 64).isActive = true
        add(row)
    }
    private func number(_ key: String, path: WritableKeyPath<Preferences, Double>, range: ClosedRange<Double>, percentage: Bool = false) {
        numeric(key, value: store.preferences[keyPath: path], range: range, step: 0.05, multiplier: percentage ? 100 : 1) { [weak store] value in Task { await store?.setPreferences { $0[keyPath: path] = value } } }
    }
    private func interaction() {
        numeric("columns", value: Double(store.preferences.interaction.columns), range: 4...12, step: 1) { [weak store] value in Task { await store?.setPreferences { $0.interaction.columns = Int(value) } } }
        numeric("rows", value: Double(store.preferences.interaction.rows), range: 3...8, step: 1) { [weak store] value in Task { await store?.setPreferences { $0.interaction.rows = Int(value) } } }
        number("iconScale", path: \.interaction.iconScale, range: 0.5...1.5, percentage: true)
        number("spacingScale", path: \.interaction.spacingScale, range: 0.5...1.5, percentage: true)
        picker("pageAnimation", values: PageAnimation.allCases, names: PageAnimation.allCases.map { store.text($0.rawValue) }, path: \.interaction.pageAnimation)
        number("pageDuration", path: \.interaction.pageDuration, range: 0...1.5)
        picker("windowAnimation", values: WindowAnimation.allCases, names: WindowAnimation.allCases.map { store.text($0 == .classic ? "classicZoom" : $0.rawValue) }, path: \.interaction.windowAnimation)
        number("windowDuration", path: \.interaction.windowDuration, range: 0...1.5)
        picker("pagerStyle", values: PagerStyle.allCases, names: PagerStyle.allCases.map { store.text($0.rawValue) }, path: \.interaction.pagerStyle)
        toggle("reversePaging", path: \.interaction.reversePaging)
        toggle("coverSystemBars", path: \.interaction.coverSystemBars)
    }
    private func importLayout() {
        label(store.text("importHelp"))
        button("discover") { [weak store] in Task { await store?.discover() } }
        button("chooseDatabase") { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { Task { await self.store.preview(url) } }
        }
        if store.sources.count > 1 { for source in store.sources { let control = makeButton(source.path) { [weak store] in Task { await store?.preview(source) } }; add(control) } }
        if let preview = store.importPreview {
            label("\(store.text("preview")): \(preview.source.path)")
            label("\(store.text("pages")): \(preview.importedPageCount) · \(store.text("folders")): \(preview.importedFolderCount) · \(store.text("matched")): \(preview.matchedCount) · \(store.text("missingCount")): \(preview.missingCount)")
            for (index, page) in preview.state.layout.pages.prefix(preview.importedPageCount).enumerated() {
                let names = page.items.map { item in if case .folder(let folder) = item { "[\(folder.name)]" } else { preview.state.catalog.first { $0.id == item.appIDs.first }?.name ?? item.id } }
                label("\(store.text("page")) \(index + 1): \(names.joined(separator: " · "))")
            }
            label(store.text("importNote"))
            button("applyImport") { [weak store] in Task { await store?.applyImport() } }
            button("cancel") { [weak store] in store?.importPreview = nil }
        }
        button("export") { [weak self] in
            guard let self else { return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Sunny-Launchpad-Backup.json"
            if panel.runModal() == .OK, let url = panel.url { Task { await self.store.export(to: url) } }
        }
        button("restore") { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let confirm = NSAlert(); confirm.messageText = self.store.text("restoreConfirm"); confirm.addButton(withTitle: self.store.text("restore")); confirm.addButton(withTitle: self.store.text("cancel"))
            if confirm.runModal() == .alertFirstButtonReturn { Task { await self.store.restore(from: url) } }
        }
        button("openData") { [weak self] in if let self { NSWorkspace.shared.open(self.dataDirectory) } }
    }
}

@MainActor private final class NativeControlAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invokeAction() { action() }
}

/// 原生滑块和输入框共用值；滑块停止后短暂合并保存，避免连续写盘。
@MainActor private final class NativeNumericControl: NSView, NSTextFieldDelegate {
    private let title = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let field = NSTextField()
    private let range: ClosedRange<Double>
    private let step: Double
    private let multiplier: Double
    private let change: (Double) -> Void
    private var pending: Task<Void, Never>?
    init(title text: String, value: Double, range: ClosedRange<Double>, step: Double, multiplier: Double, change: @escaping (Double) -> Void) {
        self.range = range; self.step = step; self.multiplier = multiplier; self.change = change
        super.init(frame: .zero)
        title.stringValue = text
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound; slider.doubleValue = value
        slider.isContinuous = true; slider.target = self; slider.action = #selector(slid)
        field.doubleValue = value * multiplier; field.delegate = self; field.target = self; field.action = #selector(entered)
        addSubview(title); addSubview(slider); addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); title.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 24); slider.frame = NSRect(x: 0, y: 30, width: max(100, bounds.width - 100), height: 24); field.frame = NSRect(x: bounds.width - 88, y: 30, width: 88, height: 24) }
    @objc private func slid() {
        let value = min(max((slider.doubleValue / step).rounded() * step, range.lowerBound), range.upperBound)
        field.doubleValue = value * multiplier
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.change(value)
        }
    }
    @objc private func entered() {
        pending?.cancel()
        let value = min(max((field.doubleValue / multiplier / step).rounded() * step, range.lowerBound), range.upperBound)
        guard value.isFinite else { return }
        slider.doubleValue = value; field.doubleValue = value * multiplier; change(value)
    }
    func controlTextDidEndEditing(_ notification: Notification) { entered() }
}
