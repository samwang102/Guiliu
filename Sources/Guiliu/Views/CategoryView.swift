import AppKit
import GuiliuCore
import SwiftUI

private enum FacetFilterSelection: Hashable {
    case value(String)
    case uncategorized

    var title: String {
        switch self {
        case .value(let value): value
        case .uncategorized: VirtualFacetDefaults.uncategorizedTitle
        }
    }
}

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    let category: FileCategory
    let searchQuery: String

    @State private var files: [CategoryFile] = []
    @State private var fileToDelete: CategoryFile?
    @State private var selectedDimensionID: String?
    @State private var selectedFacetFilter: FacetFilterSelection?
    @State private var isCreatingDimension = false
    @State private var showsAllFacetValues = false

    var body: some View {
        // Filtering may include a full search-index query. Resolve it once per
        // render instead of repeating it for the empty state, count and list.
        let visibleFiles = filteredFiles

        GuiliuBackToTopScrollView {
            LazyVStack(spacing: 0) {
                if !files.isEmpty {
                    facetBrowser
                        .padding(.bottom, 13)
                }

                if files.isEmpty {
                    GuiliuCard {
                        GuiliuEmptyState(
                            symbol: category.symbolName,
                            title: "这里还很安静",
                            message: "从待归类中确认文件后，它会出现在“\(category.displayName)”中。",
                            tint: category.tint
                        ) {
                            Button("在访达中打开") {
                                model.openCategory(category)
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(minHeight: 330)
                    }
                } else {
                    GuiliuSectionTitle(
                        title: resultTitle,
                        detail: resultDetail(visibleFileCount: visibleFiles.count)
                    )
                        .padding(.horizontal, 3)
                        .padding(.bottom, 9)

                    if visibleFiles.isEmpty {
                        GuiliuCard {
                            GuiliuEmptyState(
                                symbol: "line.3.horizontal.decrease.circle",
                                title: normalizedSearchQuery.isEmpty ? "这个细分中还没有文件" : "当前分类中没有匹配文件",
                                message: normalizedSearchQuery.isEmpty
                                    ? "点击其他选项，或用文件行里的“细分”按钮添加。"
                                    : "结果仅来自“\(category.displayName)”，请尝试缩短关键词或清除搜索。",
                                tint: category.tint
                            ) { }
                            .frame(minHeight: 210)
                        }
                        .padding(.bottom, 10)
                    }

                    ForEach(visibleFiles) { file in
                        CategoryFileRow(
                            file: file,
                            category: category,
                            preferredFacetDimensionID: selectedDimension?.id,
                            isFirst: file.id == visibleFiles.first?.id,
                            isLast: file.id == visibleFiles.last?.id
                        ) {
                            fileToDelete = file
                        }
                    }
                }
            }
            .frame(maxWidth: 920)
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(category.displayName)
        .toolbar {
            Button {
                model.openCategory(category)
            } label: {
                Label("在访达中打开", systemImage: "folder")
            }
        }
        .task(id: reloadToken) {
            await reload()
            if selectedDimensionID == nil {
                selectedDimensionID = dimensions.first?.id
            }
        }
        .sheet(isPresented: $isCreatingDimension) {
            NewFacetDimensionSheet(category: category)
                .environment(model)
        }
        .alert("将文件移到废纸篓？", isPresented: deleteAlertBinding) {
            Button("取消", role: .cancel) { fileToDelete = nil }
            Button("移到废纸篓", role: .destructive) {
                if let fileToDelete {
                    withAnimation(.snappy) {
                        model.deleteArchivedFile(fileToDelete.url, category: category)
                    }
                }
                fileToDelete = nil
            }
        } message: {
            Text("“\(fileToDelete?.url.lastPathComponent ?? "这个文件")”会进入系统废纸篓。若它是微信等应用的引用，只会删除引用，不会影响原件。")
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { fileToDelete != nil },
            set: { if !$0 { fileToDelete = nil } }
        )
    }

    private var dimensions: [VirtualFacetDimension] {
        model.facetDimensions(for: category)
    }

    private var selectedDimension: VirtualFacetDimension? {
        dimensions.first(where: { $0.id == selectedDimensionID }) ?? dimensions.first
    }

    private var filteredFiles: [CategoryFile] {
        let facetFiltered: [CategoryFile]
        if let selectedDimension, let selectedFacetFilter {
            facetFiltered = files.filter { file in
                let values = model.facetValues(for: file.url, dimensionID: selectedDimension.id)
                switch selectedFacetFilter {
                case .value(let value):
                    return values.contains(value)
                case .uncategorized:
                    return VirtualFacetDefaults.isUncategorized(values)
                }
            }
        } else {
            facetFiltered = files
        }

        guard !normalizedSearchQuery.isEmpty else { return facetFiltered }
        return facetFiltered.filter { file in
            file.url.lastPathComponent.localizedCaseInsensitiveContains(normalizedSearchQuery)
        }
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resultTitle: String {
        if !normalizedSearchQuery.isEmpty {
            return "“\(normalizedSearchQuery)”的结果"
        }
        return selectedFacetFilter?.title ?? "全部文件"
    }

    private func resultDetail(visibleFileCount: Int) -> String {
        if !normalizedSearchQuery.isEmpty {
            return "\(visibleFileCount) 个文件 · 仅搜索 \(category.displayName)"
        }
        return selectedFacetFilter == nil
            ? "按最近修改时间排列"
            : "\(visibleFileCount) 个文件 · 虚拟分类，不改变实际位置"
    }

    private var facetBrowser: some View {
        let counts = facetCountSnapshot()
        return GuiliuListSurface {
            VStack(alignment: .leading, spacing: 8) {
                compactFacetToolbar

                if showsAllFacetValues {
                    FacetFlowLayout(spacing: 7) {
                        facetChips(counts: counts)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            facetChips(counts: counts)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .padding(10)
        }
    }

    private func facetCountSnapshot() -> [String: Int] {
        guard let selectedDimension else { return [:] }
        var counts: [String: Int] = [VirtualFacetDefaults.uncategorizedTitle: 0]
        for value in selectedDimension.values { counts[value] = 0 }
        for file in files {
            let values = model.facetValues(for: file.url, dimensionID: selectedDimension.id)
            if VirtualFacetDefaults.isUncategorized(values) {
                counts[VirtualFacetDefaults.uncategorizedTitle, default: 0] += 1
            } else {
                for value in values { counts[value, default: 0] += 1 }
            }
        }
        return counts
    }

    @ViewBuilder
    private func facetChips(counts: [String: Int]) -> some View {
        FacetFilterChip(
            title: "全部",
            count: files.count,
            selected: selectedFacetFilter == nil,
            tint: category.tint
        ) { selectedFacetFilter = nil }

        if let selectedDimension {
            FacetFilterChip(
                title: VirtualFacetDefaults.uncategorizedTitle,
                count: counts[VirtualFacetDefaults.uncategorizedTitle, default: 0],
                selected: selectedFacetFilter == .uncategorized,
                tint: category.tint
            ) {
                selectedFacetFilter = selectedFacetFilter == .uncategorized ? nil : .uncategorized
            }

            ForEach(selectedDimension.values, id: \.self) { value in
                FacetFilterChip(
                    title: value,
                    count: counts[value, default: 0],
                    selected: selectedFacetFilter == .value(value),
                    tint: category.tint
                ) {
                    let selection = FacetFilterSelection.value(value)
                    selectedFacetFilter = selectedFacetFilter == selection ? nil : selection
                }
            }
        }
    }

    private var compactFacetToolbar: some View {
        HStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(dimensions) { dimension in
                        Button {
                            selectedDimensionID = dimension.id
                            selectedFacetFilter = nil
                        } label: {
                            Text(dimension.name)
                                .font(.caption.weight(selectedDimension?.id == dimension.id ? .semibold : .medium))
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(
                                    selectedDimension?.id == dimension.id
                                        ? category.tint.opacity(0.12)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selectedDimension?.id == dimension.id ? category.tint : .secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                showsAllFacetValues.toggle()
            } label: {
                Label(showsAllFacetValues ? "收起" : "展开", systemImage: showsAllFacetValues ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .fixedSize()

            Button {
                isCreatingDimension = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("新建分类标准")
            .accessibilityLabel("新建分类标准")
        }
    }

    private var reloadToken: String {
        "\(category.rawValue)|\(model.count(for: category))|\(model.libraryContentRevision)"
    }

    private func reload() async {
        let directory = model.libraryURL.appendingPathComponent(category.displayName, isDirectory: true)
        if let cached = CategoryFileSnapshotCache.value(for: reloadToken) {
            files = cached
        } else {
            files = []
        }
        let loadedFiles = await Task.detached(priority: .userInitiated) {
            Self.loadFiles(at: directory)
        }.value
        guard !Task.isCancelled else { return }
        CategoryFileSnapshotCache.store(loadedFiles, for: reloadToken)
        if files != loadedFiles {
            files = loadedFiles
        }
    }

    private nonisolated static func loadFiles(at directory: URL) -> [CategoryFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.map(CategoryFile.init(url:)).sorted {
            ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast)
        }
    }
}

private struct CategoryFile: Identifiable, Sendable, Equatable {
    let url: URL
    let modificationDate: Date?
    let fileSize: Int64
    let isDirectory: Bool
    let fileSizeText: String?
    let modificationText: String?

    var id: String { url.standardizedFileURL.path }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey
        ])
        modificationDate = values?.contentModificationDate
        fileSize = Int64(values?.fileSize ?? 0)
        isDirectory = values?.isDirectory ?? false
        fileSizeText = fileSize > 0 && !isDirectory
            ? ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            : nil
        modificationText = modificationDate.map { GuiliuRelativeTime.text(for: $0) }
    }
}

@MainActor
private enum CategoryFileSnapshotCache {
    private static var values: [String: [CategoryFile]] = [:]

    static func value(for key: String) -> [CategoryFile]? {
        values[key]
    }

    static func store(_ files: [CategoryFile], for key: String) {
        let categoryPrefix = key.split(separator: "|", maxSplits: 1).first.map(String.init)
        if let categoryPrefix {
            values = values.filter { existingKey, _ in
                existingKey == key || !existingKey.hasPrefix("\(categoryPrefix)|")
            }
        }
        values[key] = files
        if values.count > FileCategory.allCases.count {
            values.removeAll(keepingCapacity: true)
            values[key] = files
        }
    }
}

private struct CategoryFileRow: View {
    @Environment(AppModel.self) private var model
    let file: CategoryFile
    let category: FileCategory
    let preferredFacetDimensionID: String?
    let isFirst: Bool
    let isLast: Bool
    let onDelete: () -> Void
    @State private var isHovering = false

    private var isProcessing: Bool {
        model.processingLibraryPaths.contains(file.url.standardizedFileURL.path)
    }

    private var aiAnalysis: OllamaDocumentAnalysis? {
        model.aiAnalysis(for: file.url)
    }

    private var isPreviewSelected: Bool {
        model.filePreviewURL?.standardizedFileURL.path == file.url.standardizedFileURL.path
    }

    private var showsSecondaryActions: Bool {
        isHovering || isPreviewSelected
    }

    var body: some View {
        HStack(spacing: 8) {
            fileIdentityButton
            rowActions
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(isPreviewSelected ? category.tint.opacity(0.105) : (isHovering ? GuiliuTheme.hoverSurface : GuiliuTheme.surface))
        .overlay(alignment: .leading) {
            if isPreviewSelected {
                Capsule()
                    .fill(category.tint)
                    .frame(width: 3, height: 28)
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                GuiliuListDivider(leading: 62)
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: isFirst ? 14 : 0,
                bottomLeadingRadius: isLast ? 14 : 0,
                bottomTrailingRadius: isLast ? 14 : 0,
                topTrailingRadius: isFirst ? 14 : 0,
                style: .continuous
            )
        )
        .overlay {
            if isFirst || isLast {
                UnevenRoundedRectangle(
                    topLeadingRadius: isFirst ? 14 : 0,
                    bottomLeadingRadius: isLast ? 14 : 0,
                    bottomTrailingRadius: isLast ? 14 : 0,
                    topTrailingRadius: isFirst ? 14 : 0,
                    style: .continuous
                )
                .stroke(GuiliuTheme.hairline, lineWidth: 1)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("打开") { NSWorkspace.shared.open(file.url) }
            Button("在访达中查看") { model.reveal(url: file.url) }
            if !file.isDirectory {
                Button(aiAnalysis == nil ? "使用本地 AI 分析" : "重新进行本地 AI 分析") {
                    model.analyzeArchivedFile(file.url, category: category)
                }
                .disabled(!model.ollamaEnabled || model.isAIAnalysisBusy)

                Divider()
                Menu("更改分类") {
                    ForEach(FileCategory.allCases.filter { $0 != category }) { destination in
                        Button(destination.displayName) {
                            model.reclassify(file: file.url, from: category, to: destination)
                        }
                    }
                }

                Divider()
                Button("移到废纸篓", role: .destructive, action: onDelete)
            }
            Divider()
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
            }
        }
        .disabled(isProcessing)
        .accessibilityElement(children: .contain)
        .accessibilityValue(isPreviewSelected ? "已选中，正在预览" : "")
    }

    private var fileIdentityButton: some View {
        Button {
            model.previewOrOpen(file.url)
        } label: {
            HStack(spacing: 13) {
                Image(nsImage: GuiliuFileIcon.image(for: file.url, isDirectory: file.isDirectory))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .padding(5)
                    .background(category.tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(file.url.lastPathComponent)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(file.isDirectory ? "文件夹" : (file.url.pathExtension.isEmpty ? "文件" : file.url.pathExtension.uppercased()))
                        if let fileSizeText = file.fileSizeText {
                            Text("·")
                            Text(fileSizeText)
                        }
                        if let modificationText = file.modificationText {
                            Text("·")
                            Text("修改于 \(modificationText)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rowActions: some View {
        if model.isAIProcessing(file.url) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("分析中")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .help("本地 AI 正在分析")
        } else if let aiAnalysis, !file.isDirectory {
                AIAnalysisLauncher(
                    fileURL: file.url,
                    analysis: aiAnalysis,
                    category: category,
                    pendingItemID: nil
                )
        } else if !file.isDirectory {
                Button {
                    model.analyzeArchivedFile(file.url, category: category)
                } label: {
                    Label("AI 分析", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.ollamaEnabled || model.isAIAnalysisBusy)
                .help("使用本地 AI 分析")
                .accessibilityLabel("AI 分析")
        }

        if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28)
                    .accessibilityLabel("正在更改分类")
        } else if !file.isDirectory, showsSecondaryActions {
                RenameFileButton(fileURL: file.url) { baseName in
                    model.renameArchivedFile(file.url, category: category, toBaseName: baseName)
                }

                FacetEditorButton(
                    file: file.url,
                    category: category,
                    preferredDimensionID: preferredFacetDimensionID
                )

                Menu {
                    ForEach(FileCategory.allCases.filter { $0 != category }) { destination in
                        Button {
                            model.reclassify(file: file.url, from: category, to: destination)
                        } label: {
                            Label(destination.displayName, systemImage: destination.symbolName)
                        }
                    }
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .help("更改分类")
                .accessibilityLabel("更改 \(file.url.lastPathComponent) 的分类")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("移到废纸篓")
                .accessibilityLabel("将 \(file.url.lastPathComponent) 移到废纸篓")
        } else if !file.isDirectory {
                Menu {
                    Button("打开") { NSWorkspace.shared.open(file.url) }
                    Button("在访达中显示") { model.reveal(url: file.url) }
                    Button(aiAnalysis == nil ? "使用本地 AI 分析" : "查看论文解读") {
                        if aiAnalysis != nil {
                            model.openAIAnalysisReader(for: file.url, category: category)
                        } else {
                            model.analyzeArchivedFile(file.url, category: category)
                        }
                    }
                    .disabled(aiAnalysis == nil && (!model.ollamaEnabled || model.isAIAnalysisBusy))
                    Divider()
                    Menu("更改分类") {
                        ForEach(FileCategory.allCases.filter { $0 != category }) { destination in
                            Button(destination.displayName) {
                                model.reclassify(file: file.url, from: category, to: destination)
                            }
                        }
                    }
                    Divider()
                    Button("移到废纸篓", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.tertiary)
                .help("更多操作")
                .accessibilityLabel("更多文件操作")
        } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovering ? category.tint : Color.secondary.opacity(0.55))
                    .frame(width: 28)
        }
    }
}

private struct FacetFilterChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(selected ? tint : .secondary)
            }
            .font(.caption.weight(selected ? .semibold : .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(selected ? tint : .primary)
            .background(selected ? tint.opacity(0.12) : Color.primary.opacity(0.035), in: Capsule())
            .overlay { Capsule().stroke(selected ? tint.opacity(0.28) : GuiliuTheme.hairline, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct FacetFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestLine: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = lineWidth == 0 ? size.width : lineWidth + spacing + size.width
            if proposedWidth > maximumWidth, lineWidth > 0 {
                widestLine = max(widestLine, lineWidth)
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth = proposedWidth
                lineHeight = max(lineHeight, size.height)
            }
        }
        widestLine = max(widestLine, lineWidth)
        totalHeight += lineHeight
        return CGSize(width: proposal.width ?? widestLine, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct FacetEditorButton: View {
    @Environment(AppModel.self) private var model
    let file: URL
    let category: FileCategory
    let preferredDimensionID: String?
    @State private var isPresented = false

    private var assignmentCount: Int {
        model.facetDimensions(for: category).reduce(into: 0) { count, dimension in
            count += model.facetValues(for: file, dimensionID: dimension.id).count
        }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: assignmentCount == 0 ? "tag" : "tag.fill")
                if assignmentCount > 0 {
                    Text("\(assignmentCount)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                }
            }
            .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.borderless)
        .help("细分到虚拟分类")
        .accessibilityLabel("细分 \(file.lastPathComponent)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FacetEditorPopover(
                file: file,
                category: category,
                preferredDimensionID: preferredDimensionID
            )
                .environment(model)
        }
    }
}

private struct FacetEditorPopover: View {
    @Environment(AppModel.self) private var model
    let file: URL
    let category: FileCategory
    let preferredDimensionID: String?
    @State private var selectedDimensionID: String?
    @State private var newValue = ""

    init(file: URL, category: FileCategory, preferredDimensionID: String?) {
        self.file = file
        self.category = category
        self.preferredDimensionID = preferredDimensionID
        _selectedDimensionID = State(initialValue: preferredDimensionID)
    }

    private var dimensions: [VirtualFacetDimension] { model.facetDimensions(for: category) }
    private var selectedDimension: VirtualFacetDimension? {
        let resolvedID = VirtualFacetDefaults.resolvedDimensionID(
            preferred: selectedDimensionID ?? preferredDimensionID,
            in: dimensions
        )
        return dimensions.first(where: { $0.id == resolvedID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 3) {
                Text("细分文件")
                    .font(.headline)
                Text(file.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Picker("分类标准", selection: Binding(
                get: { selectedDimension?.id ?? "" },
                set: { selectedDimensionID = $0 }
            )) {
                ForEach(dimensions) { dimension in
                    Text(dimension.name).tag(dimension.id)
                }
            }
            .pickerStyle(.menu)

            if let selectedDimension {
                GuiliuBackToTopScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 7)], spacing: 7) {
                        ForEach(selectedDimension.values, id: \.self) { value in
                            let isSelected = model.facetValues(
                                for: file,
                                dimensionID: selectedDimension.id
                            ).contains(value)
                            Button {
                                model.toggleFacetValue(
                                    value,
                                    for: file,
                                    dimension: selectedDimension,
                                    category: category
                                )
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    Text(value).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? category.tint : .primary)
                                .padding(.horizontal, 9)
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                .background(isSelected ? category.tint.opacity(0.11) : Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 210)

                HStack(spacing: 7) {
                    TextField("添加新选项", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addValue(to: selectedDimension) }
                    Button {
                        addValue(to: selectedDimension)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text(selectedDimension.selectionMode == .single
                     ? "此标准只选一个；选择新项会自动替换旧项。"
                     : "此标准可以多选。所有细分只存在于归流视图中，不会创建文件夹。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 430)
        .onAppear { selectedDimensionID = selectedDimension?.id }
    }

    private func addValue(to dimension: VirtualFacetDimension) {
        let value = newValue
        guard let added = model.addFacetValue(value, to: dimension.id, category: category) else { return }
        if !model.facetValues(for: file, dimensionID: dimension.id).contains(added) {
            model.toggleFacetValue(added, for: file, dimension: dimension, category: category)
        }
        newValue = ""
    }
}

private struct NewFacetDimensionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let category: FileCategory
    @State private var name = ""
    @State private var allowsMultiple = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                GuiliuIconTile(symbol: "square.grid.3x1.folder.badge.plus", tint: category.tint, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("新建分类标准")
                        .font(.title3.bold())
                    Text("例如：研究方向、数据来源、项目阶段")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("标准名称", text: $name)
                .textFieldStyle(.roundedBorder)

            Toggle("允许一份文件同时选择多个选项", isOn: $allowsMultiple)

            Text("这是抽象视图，不会创建子文件夹，也不会移动任何文件。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    _ = model.addFacetDimension(
                        to: category,
                        name: name,
                        selectionMode: allowsMultiple ? .multiple : .single
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}
