// 启动台视图：网格、搜索、文件夹与拖放表现；业务变更统一交给 Store。
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SunnyDomain

public struct LauncherView: View {
    @Bindable var store: LaunchpadStore
    var wallpaper: NSImage?
    var screenInsets: EdgeInsets
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var folderName = ""

    public init(store: LaunchpadStore, wallpaper: NSImage?, screenInsets: EdgeInsets = EdgeInsets()) {
        self.store = store
        self.wallpaper = wallpaper
        self.screenInsets = screenInsets
    }

    public var body: some View {
        GeometryReader { geometry in
            let usableSize = CGSize(width: geometry.size.width - screenInsets.leading - screenInsets.trailing, height: geometry.size.height - screenInsets.top - screenInsets.bottom)
            let metrics = LauncherMetrics(availableSize: usableSize)
            let cellHeight = metrics.cellHeight
            let iconSize = metrics.iconSize
            ZStack {
                WallpaperView(wallpaper: wallpaper).onTapGesture {
                    if store.folderID != nil { store.folderID = nil } else { store.dismiss() }
                }
                VStack(spacing: 12) {
                    searchBar.padding(.top, 12)
                    if store.readOnly { Text(store.text("readOnly")).font(.callout).foregroundStyle(.orange) }
                    Spacer(minLength: 0)
                    let items = store.folder != nil && !store.isSearching ? store.state.layout.pages[store.pageIndex].items : store.visibleItems
                    grid(items, iconSize: iconSize, cellHeight: cellHeight, inFolder: false)
                        .blur(radius: store.folder != nil && !store.isSearching ? 10 : 0)
                        .allowsHitTesting(store.folder == nil || store.isSearching)
                        .accessibilityHidden(store.folder != nil && !store.isSearching)
                    Spacer(minLength: 0)
                    if store.folder == nil || store.isSearching { pageControl }
                    footer.padding(.bottom, 12)
                }
                .frame(height: usableSize.height)
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(screenInsets)
                if store.folder != nil && !store.isSearching {
                    Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { store.folderID = nil }
                        .onDrop(of: [.text], isTargeted: nil) { _ in
                            store.drop(onto: nil, page: store.pageIndex)
                            return true
                        }
                    folderPanel(iconSize: min(iconSize, 72), cellHeight: min(cellHeight, 130))
                        .frame(maxWidth: min(usableSize.width - 60, 1120))
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .background(LauncherEventBridge(store: store))
            .animation(systemReduceMotion || store.preferences.reduceMotion ? nil : .easeInOut(duration: 0.20), value: store.folderID)
            .animation(systemReduceMotion || store.preferences.reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.activePage)
        }
        .preferredColorScheme(store.preferences.theme.colorScheme)
        .onChange(of: store.query) { _, _ in store.pageIndex = 0; store.selectedIndex = 0 }
        .onChange(of: store.presentationID) { _, _ in searchFocused = true }
        .onChange(of: store.folderID) { previous, _ in
            if let previous, let original = store.state.layout.folders.first(where: { $0.id == previous }), original.name != folderName {
                store.renameFolder(previous, name: folderName)
            }
            folderName = store.folder?.name ?? ""
            searchFocused = store.folderID == nil
        }
        .onAppear { searchFocused = true }
        .alert(store.text("error"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(store.text("done")) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(store.text("search"), text: $store.query)
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { if let item = store.visibleItems[safe: store.selectedIndex] { store.activate(item) } }
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel(store.text("clearSearch"))
            }
        }
        .font(.system(size: 15)).padding(.horizontal, 16).padding(.vertical, 11).frame(width: 300)
        .modifier(PanelSurface(style: store.preferences.style, radius: store.preferences.style == .classic ? 9 : 24))
    }

    private func grid(_ items: [LayoutItem], iconSize: CGFloat, cellHeight: CGFloat, inFolder: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: LaunchpadRules.columns), spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                GeometryReader { geometry in
                    AppTile(item: item, nextItem: items[safe: index + 1], store: store, iconSize: iconSize, tileWidth: geometry.size.width, selected: store.selectedIndex == index, inFolder: inFolder)
                }.frame(height: cellHeight)
            }
        }
        .frame(maxWidth: 1240)
        .frame(height: cellHeight * CGFloat(inFolder ? LaunchpadRules.folderRows : LaunchpadRules.rows), alignment: .top)
        .overlay {
            if items.isEmpty {
                VStack(spacing: 12) {
                    if store.busy { ProgressView() }
                    else { Image(systemName: store.isSearching ? "magnifyingglass" : "square.grid.3x3").font(.largeTitle) }
                    Text(store.text(store.busy ? "loading" : store.isSearching ? "noResults" : "empty")).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func folderPanel(iconSize: CGFloat, cellHeight: CGFloat) -> some View {
        VStack(spacing: 22) {
            HStack {
                TextField(store.text("folderName"), text: $folderName)
                    .font(.title2.weight(.medium)).textFieldStyle(.plain).multilineTextAlignment(.center)
                    .onSubmit { if let id = store.folderID { store.renameFolder(id, name: folderName) } }
                    .disabled(!store.canEdit)
                Button {
                    if let id = store.folderID { store.renameFolder(id, name: folderName) }
                    store.folderID = nil
                } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                .buttonStyle(.plain).accessibilityLabel(store.text("close"))
            }
            grid(store.visibleItems, iconSize: iconSize, cellHeight: cellHeight, inFolder: true)
            pageControl
        }
        .padding(30)
        .modifier(PanelSurface(style: store.preferences.style, radius: store.preferences.style == .classic ? 20 : 36))
        .onDrop(of: [.text], isTargeted: nil) { _ in store.drop(onto: nil); return true }
    }

    private var pageControl: some View {
        HStack(spacing: 12) {
            Button { store.selectPage(store.activePage - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(store.activePage == 0).accessibilityLabel(store.text("previousPage"))
            ForEach(0..<store.pageCount, id: \.self) { index in
                Button { store.selectPage(index) } label: {
                    Circle().fill(.primary.opacity(index == store.activePage ? 0.9 : 0.25)).frame(width: 7, height: 7).padding(5)
                }
                .accessibilityLabel("\(store.text("page")) \(index + 1)")
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    if store.folder != nil { store.selectPage(index); store.drop(onto: nil) }
                    else { store.drop(onto: nil, page: index); store.selectPage(index) }
                    return true
                }
            }
            Button { store.selectPage(store.activePage + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(store.activePage == store.pageCount - 1).accessibilityLabel(store.text("nextPage"))
        }
        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 14).padding(.vertical, 7)
        .modifier(PanelSurface(style: store.preferences.style, radius: 22))
    }

    private var footer: some View {
        HStack {
            Text(store.organizing ? store.text("dragHint") : "Sunny Launchpad").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button(store.text(store.organizing ? "done" : "organize")) { store.organizing.toggle() }
                .disabled(!store.canEdit || store.isSearching)
            Button { store.openSettings() } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(store.text("settings"))
        }
        .buttonStyle(.plain).font(.system(size: 13))
    }
}

/// 应用图标不包裹玻璃卡片，避免打断旧启动台的图标识别和空间记忆。
private struct AppTile: View {
    let item: LayoutItem
    let nextItem: LayoutItem?
    @Bindable var store: LaunchpadStore
    let iconSize: CGFloat
    let tileWidth: CGFloat
    let selected: Bool
    let inFolder: Bool
    @State private var dropTarget = false
    @State private var hover = false

    var body: some View {
        Button { store.activate(item) } label: {
            VStack(spacing: 5) {
                icon.frame(width: iconSize, height: iconSize)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 22).fill(.primary.opacity(dropTarget ? 0.18 : hover ? 0.08 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(.primary.opacity(selected && store.isSearching ? 0.4 : 0), lineWidth: 2))
                Text(title).font(.system(size: iconSize < 40 ? 11 : 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 30, alignment: .top)
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .accessibilityLabel(title)
        .help(title)
        .onLongPressGesture(minimumDuration: 0.6) { if store.canEdit { store.organizing = true } }
        .onDrag {
            guard store.canEdit, !store.isSearching else { return NSItemProvider() }
            store.draggedID = item.id
            return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(of: [.text], delegate: TileDropDelegate(store: store, target: item, nextTarget: nextItem, inFolder: inFolder, iconSize: iconSize, tileWidth: tileWidth, highlighted: $dropTarget))
        .contextMenu {
            if case .app(let id) = item, let path = store.app(id)?.path {
                Button(store.text("reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            if inFolder {
                Button(store.text("moveOut")) { store.move(item, to: store.pageIndex) }.disabled(!store.canEdit)
            }
            Menu(store.text("movePage")) {
                ForEach(store.state.layout.pages.indices, id: \.self) { page in
                    Button("\(store.text("page")) \(page + 1)") { store.move(item, to: page) }
                }
                Button(store.text("newPage")) { store.move(item, to: store.state.layout.pages.count) }
            }
            .disabled(!store.canEdit || store.isSearching)
        }
    }

    private var title: String {
        switch item {
        case .app(let id):
            let app = store.app(id)
            return (app?.name ?? id) + (app?.isAvailable == false ? " · \(store.text("missing"))" : "")
        case .folder(let folder): return folder.name
        }
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .app(let id): Image(nsImage: AppIconCache.shared.image(for: store.app(id))).resizable().scaledToFit().opacity(store.app(id)?.isAvailable == false ? 0.5 : 1)
        case .folder(let folder):
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(Array(folder.appIDs.prefix(9)), id: \.self) { id in
                    Image(nsImage: AppIconCache.shared.image(for: store.app(id))).resizable().scaledToFit()
                }
            }
            .padding(9).frame(width: iconSize, height: iconSize)
            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

/// 中心区域成组、边缘插入；只在最终落下时提交，拖动取消不会写盘。
private struct TileDropDelegate: DropDelegate {
    let store: LaunchpadStore
    let target: LayoutItem
    let nextTarget: LayoutItem?
    let inFolder: Bool
    let iconSize: CGFloat
    let tileWidth: CGFloat
    @Binding var highlighted: Bool

    func validateDrop(info: DropInfo) -> Bool { store.canEdit && !store.isSearching && store.draggedID != nil && store.draggedID != target.id }
    func dropEntered(info: DropInfo) { highlighted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { highlighted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        highlighted = false
        guard validateDrop(info: info) else { return false }
        let center = abs(info.location.x - tileWidth / 2) < iconSize * 0.4 && info.location.y < iconSize + 20
        let shouldGroup = !inFolder && center
        let insertionTarget = !shouldGroup && info.location.x > tileWidth / 2 ? nextTarget : target
        store.drop(onto: insertionTarget, group: shouldGroup)
        return true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
