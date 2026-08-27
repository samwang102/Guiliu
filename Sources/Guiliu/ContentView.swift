import GuiliuCore
import SwiftUI

private enum WorkspaceLayout {
    static let minimumWindowWidth: CGFloat = 1_032
    static let minimumWorkspaceWidth: CGFloat = 620
    static let compactWorkspaceMinimumWidth: CGFloat = 430
    static let sidebarWidth: CGFloat = 258
    static let readerDividerWidth: CGFloat = 8
    static let analysisReaderMinimumWidth: CGFloat = 320
    static let analysisReaderIdealWidth: CGFloat = 420
    static let analysisReaderMaximumWidth: CGFloat = 560
    static let filePreviewMinimumWidth: CGFloat = 320
    static let filePreviewIdealWidth: CGFloat = 420
    static let filePreviewMaximumWidth: CGFloat = 560
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsLibrary = true
    @State private var quickSearch = ""
    @State private var categorySearch = ""
    @State private var contextReaderWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "contextReaderWidth")
        return saved > 0 ? saved : WorkspaceLayout.filePreviewIdealWidth
    }()
    @State private var readerDragStartWidth: CGFloat?
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            workspaceLayout(availableWidth: geometry.size.width)
        }
        .frame(minWidth: WorkspaceLayout.minimumWindowWidth)
        .background(GuiliuTheme.canvas)
        .tint(GuiliuTheme.brand)
        .onAppear {
            model.reconcilePendingFileExistence()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.reconcilePendingFileExistence()
            }
        }
        .onChange(of: model.selection) { oldSelection, newSelection in
            guard oldSelection != newSelection else { return }
            switch newSelection {
            case .category:
                quickSearch = ""
                categorySearch = ""
            case .search:
                quickSearch = model.searchQuery
            default:
                quickSearch = ""
            }
        }
        .onChange(of: model.searchQuery) { _, query in
            if model.selection == .search {
                quickSearch = query
            }
        }
        .onChange(of: model.searchFocusGeneration) { _, _ in
            searchFieldFocused = true
        }
        .onChange(of: quickSearch) { _, query in
            switch model.selection {
            case .search:
                if model.searchQuery != query { model.searchQuery = query }
            case .category:
                categorySearch = query
            default:
                break
            }
        }
        .alert("归流未能完成操作", isPresented: errorBinding) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private func workspaceLayout(availableWidth: CGFloat) -> some View {
        let libraryBinding = Binding(
            get: { showsLibrary },
            set: { showsLibrary = $0 }
        )
        let libraryIsVisible = showsLibrary
        let workspaceMinimum = adaptiveWorkspaceMinimum(libraryIsVisible: libraryIsVisible)
        let splitWidth = max(
            workspaceMinimum,
            availableWidth
                - (libraryIsVisible ? WorkspaceLayout.sidebarWidth : 0)
        )
        let readerWidth = adaptiveReaderWidth(
            splitWidth: splitWidth,
            workspaceMinimum: workspaceMinimum
        )
        let mainWidth = hasContextReader
            ? splitWidth - readerWidth - WorkspaceLayout.readerDividerWidth
            : splitWidth

        return HStack(spacing: 0) {
            if libraryIsVisible {
                UnifiedSidebar()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    WorkspaceCommandBar(
                        query: $quickSearch,
                        showsLibrary: libraryBinding,
                        searchFocus: $searchFieldFocused,
                        submitSearch: submitSearch,
                        clearSearch: clearSearch
                    )

                    Divider().opacity(0.55)

                    NavigationStack {
                        ZStack {
                            GuiliuPageBackground()
                            detail
                        }
                    }
                }
                .frame(width: mainWidth)
                .frame(maxHeight: .infinity)

                if let request = model.aiAnalysisReader {
                    readerDivider(
                        splitWidth: splitWidth,
                        workspaceMinimum: workspaceMinimum
                    )

                    AIAnalysisReaderView(request: request)
                        .id("ai:\(request.id)")
                        .environment(model)
                        .frame(width: readerWidth)
                        .frame(maxHeight: .infinity)
                } else if let fileURL = model.filePreviewURL {
                    readerDivider(
                        splitWidth: splitWidth,
                        workspaceMinimum: workspaceMinimum
                    )

                    FilePreviewReaderView(fileURL: fileURL)
                        .environment(model)
                        .frame(width: readerWidth)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: splitWidth)
            .frame(maxHeight: .infinity)
            .clipped()
            .layoutPriority(1)
        }
    }

    private var hasContextReader: Bool {
        model.aiAnalysisReader != nil || model.filePreviewURL != nil
    }

    private func adaptiveWorkspaceMinimum(libraryIsVisible: Bool) -> CGFloat {
        guard hasContextReader else { return WorkspaceLayout.minimumWorkspaceWidth }
        // Opening a reader compresses the central workspace, exactly like the
        // AI reader. The library remains present so categories stay one click
        // away; users may still collapse it explicitly when they want room.
        return libraryIsVisible
            ? WorkspaceLayout.compactWorkspaceMinimumWidth
            : min(500, WorkspaceLayout.minimumWorkspaceWidth)
    }

    private func adaptiveReaderWidth(
        splitWidth: CGFloat,
        workspaceMinimum: CGFloat
    ) -> CGFloat {
        guard hasContextReader else { return 0 }
        let upperBound = min(
            WorkspaceLayout.filePreviewMaximumWidth,
            max(0, splitWidth - workspaceMinimum - WorkspaceLayout.readerDividerWidth)
        )
        let lowerBound = min(WorkspaceLayout.filePreviewMinimumWidth, upperBound)
        return min(max(contextReaderWidth, lowerBound), upperBound)
    }

    @ViewBuilder
    private func readerDivider(
        splitWidth: CGFloat,
        workspaceMinimum: CGFloat
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(GuiliuTheme.hairline)
                .frame(width: 1)
        }
        .frame(width: WorkspaceLayout.readerDividerWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let startingWidth = readerDragStartWidth ?? contextReaderWidth
                    if readerDragStartWidth == nil {
                        readerDragStartWidth = startingWidth
                    }
                    setReaderWidth(
                        startingWidth - value.translation.width,
                        splitWidth: splitWidth,
                        workspaceMinimum: workspaceMinimum
                    )
                }
                .onEnded { _ in
                    readerDragStartWidth = nil
                    UserDefaults.standard.set(Double(contextReaderWidth), forKey: "contextReaderWidth")
                }
        )
        .onTapGesture(count: 2) {
            setReaderWidth(
                WorkspaceLayout.filePreviewIdealWidth,
                splitWidth: splitWidth,
                workspaceMinimum: workspaceMinimum
            )
            UserDefaults.standard.set(Double(contextReaderWidth), forKey: "contextReaderWidth")
        }
        .help("拖动调整阅读器宽度；双击恢复默认")
        .accessibilityLabel("调整预览宽度")
        .accessibilityAdjustableAction { direction in
            let change: CGFloat = direction == .increment ? 24 : -24
            setReaderWidth(
                contextReaderWidth + change,
                splitWidth: splitWidth,
                workspaceMinimum: workspaceMinimum
            )
        }
    }

    private func setReaderWidth(
        _ proposedWidth: CGFloat,
        splitWidth: CGFloat,
        workspaceMinimum: CGFloat
    ) {
        let upperBound = min(
            WorkspaceLayout.filePreviewMaximumWidth,
            max(0, splitWidth - workspaceMinimum - WorkspaceLayout.readerDividerWidth)
        )
        let lowerBound = min(WorkspaceLayout.filePreviewMinimumWidth, upperBound)
        contextReaderWidth = min(max(proposedWidth, lowerBound), upperBound)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .inbox {
        case .inbox:
            InboxView()
        case .search:
            SearchView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        case .category(let category):
            CategoryView(category: category, searchQuery: categorySearch)
                .id(category.rawValue)
        }
    }

    private func submitSearch() {
        let cleaned = quickSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if case .category = model.selection {
            categorySearch = cleaned
            return
        }
        model.searchQuery = cleaned
        model.navigate(to: .search)
    }

    private func clearSearch() {
        quickSearch = ""
        if case .category = model.selection {
            categorySearch = ""
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

}

private struct UnifiedSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    private var visibleCategories: [FileCategory] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return FileCategory.allCases }
        return FileCategory.allCases.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var totalCount: Int {
        FileCategory.allCases.reduce(0) { $0 + model.count(for: $1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(GuiliuTheme.brandGradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("归流")
                        .font(.headline.weight(.bold))
                    Text("\(totalCount) 个文件")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button { model.reveal(url: model.libraryURL) } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("在访达中打开文件库")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            VStack(spacing: 3) {
                SidebarDestinationRow(
                    title: "待归类",
                    subtitle: model.pendingItems.isEmpty ? nil : "\(model.pendingItems.count) 个待确认",
                    symbol: "tray.and.arrow.down.fill",
                    tint: GuiliuTheme.brand,
                    selected: model.selection == .inbox,
                    badge: model.pendingItems.count
                ) { model.navigate(to: .inbox) }

                SidebarDestinationRow(
                    title: "全局检索",
                    subtitle: nil,
                    symbol: "magnifyingglass",
                    tint: .indigo,
                    selected: model.selection == .search
                ) { model.navigate(to: .search) }

                SidebarDestinationRow(
                    title: "操作记录",
                    subtitle: nil,
                    symbol: "clock.arrow.circlepath",
                    tint: .purple,
                    selected: model.selection == .history
                ) { model.navigate(to: .history) }
            }
            .padding(.horizontal, 9)

            HStack {
                Text("文件库")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(FileCategory.allCases.count) 个分类")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 17)
            .padding(.bottom, 7)

            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("筛选分类", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(GuiliuTheme.sidebarField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(visibleCategories) { category in
                        LibraryCategoryRow(
                            category: category,
                            count: model.count(for: category),
                            selected: model.selection == .category(category)
                        ) {
                            model.navigate(to: .category(category))
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 12)
            }

            VStack(spacing: 3) {
                Button { model.toggleMonitoring() } label: {
                    HStack(spacing: 9) {
                        ZStack {
                            Circle()
                                .fill(model.isMonitoring ? GuiliuTheme.success.opacity(0.14) : Color.secondary.opacity(0.12))
                                .frame(width: 28, height: 28)
                            Circle()
                                .fill(model.isMonitoring ? GuiliuTheme.success : Color.secondary)
                                .frame(width: 7, height: 7)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.isMonitoring ? "正在监控" : "监控已暂停")
                                .font(.callout.weight(.medium))
                            Text(model.isMonitoring ? "自动发现新文件" : "点按恢复")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: model.isMonitoring ? "pause.circle" : "play.circle")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                SidebarDestinationRow(
                    title: "设置",
                    subtitle: nil,
                    symbol: "gearshape.fill",
                    tint: .secondary,
                    selected: model.selection == .settings
                ) { model.navigate(to: .settings) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Divider().opacity(0.55) }
        }
        .frame(width: WorkspaceLayout.sidebarWidth)
        .background(GuiliuTheme.sidebar)
        .overlay(alignment: .trailing) { Divider().opacity(0.55) }
    }
}

private struct SidebarDestinationRow: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    let selected: Bool
    var badge = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? tint : Color.secondary)
                    .frame(width: 29, height: 29)
                    .background(
                        selected ? tint.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(selected ? tint : Color.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 19)
                        .background((selected ? tint : Color.secondary).opacity(0.11), in: Capsule())
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: subtitle == nil ? 37 : 43, alignment: .leading)
            .background(
                selected ? tint.opacity(0.095) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: 19)
                        .offset(x: -3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title)，\(badge) 项" : title)
    }
}

private struct LibraryCategoryRow: View {
    let category: FileCategory
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(category.tint)
                    .frame(width: 30, height: 30)
                    .background(
                        category.tint.opacity(selected ? 0.14 : 0.09),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                Text(category.displayName)
                    .font(.callout.weight(selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(selected ? category.tint : Color.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .frame(height: 39)
            .background(
                selected ? AnyShapeStyle(category.tint.opacity(0.105)) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(category.tint)
                        .frame(width: 3, height: 19)
                        .offset(x: -3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.displayName)，\(count) 个文件")
    }
}

private struct WorkspaceCommandBar: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    @Binding var showsLibrary: Bool
    let searchFocus: FocusState<Bool>.Binding
    let submitSearch: () -> Void
    let clearSearch: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularBar
            compactBar
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(GuiliuTheme.surface)
    }

    private var regularBar: some View {
        HStack(spacing: 12) {
            Button { showsLibrary.toggle() } label: {
                Image(systemName: showsLibrary ? "sidebar.left" : "sidebar.right")
                    .frame(width: 30, height: 30)
                    .background(GuiliuTheme.subduedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showsLibrary ? "收起文件库" : "展开文件库")

            VStack(alignment: .leading, spacing: 1) {
                Text(sectionTitle)
                    .font(.headline.weight(.semibold))
                Text(sectionSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .focused(searchFocus)
                    .onSubmit(submitSearch)
                if !query.isEmpty {
                    Button(action: clearSearch) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(width: 292, height: 33)
            .background(query.isEmpty ? GuiliuTheme.subduedSurface : GuiliuTheme.brand.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(query.isEmpty ? GuiliuTheme.hairline : GuiliuTheme.brand.opacity(0.24), lineWidth: 1)
            }

            Button {
                model.importExistingFiles()
            } label: {
                Label(model.isImportingExistingFiles ? "扫描中" : "扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isImportingExistingFiles)
            .help("扫描当前监控位置中的现有文件")
        }
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            Button { showsLibrary.toggle() } label: {
                Image(systemName: showsLibrary ? "sidebar.left" : "sidebar.right")
                    .frame(width: 28, height: 28)
                    .background(GuiliuTheme.subduedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showsLibrary ? "收起文件库" : "展开文件库")

            Text(sectionTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 2)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .focused(searchFocus)
                    .onSubmit(submitSearch)
                if !query.isEmpty {
                    Button(action: clearSearch) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(minWidth: 132, maxWidth: 210, minHeight: 32, maxHeight: 32)
            .background(GuiliuTheme.subduedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(GuiliuTheme.hairline, lineWidth: 1)
            }

            Button {
                model.importExistingFiles()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isImportingExistingFiles)
            .help("扫描当前监控位置中的现有文件")
            .accessibilityLabel(model.isImportingExistingFiles ? "扫描中" : "扫描")
        }
    }

    private var sectionTitle: String {
        switch model.selection ?? .inbox {
        case .inbox: "分拣台"
        case .search: "全局检索"
        case .history: "操作记录"
        case .settings: "设置"
        case .category(let category): category.displayName
        }
    }

    private var searchPlaceholder: String {
        if case .category(let category) = model.selection {
            return "搜索当前分类：\(category.displayName)"
        }
        return "搜索文件、标签或正文"
    }

    private var sectionSubtitle: String {
        switch model.selection ?? .inbox {
        case .inbox: model.pendingItems.isEmpty ? "当前没有待处理文件" : "\(model.pendingItems.count) 个文件等待确认"
        case .search: "文件名、标签、来源与正文统一搜索"
        case .history: "归档、删除与恢复均可追溯"
        case .settings: "来源、文件库与本地 AI"
        case .category(let category): "\(model.count(for: category)) 个文件"
        }
    }
}
