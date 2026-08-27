import GuiliuCore
import QuickLookThumbnailing
import SwiftUI

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var itemToDelete: InboxItem?
    @State private var selectedItemID: UUID?

    var body: some View {
        Group {
            if model.pendingItems.isEmpty {
                EmptyInboxView()
            } else {
                HStack(spacing: 0) {
                    triageQueue
                        .frame(width: 286)

                    Divider().opacity(0.7)

                    if let item = selectedItem {
                        GuiliuBackToTopScrollView {
                            VStack(spacing: 14) {
                                InboxHeader()

                                RoutingCard(item: item) {
                                    itemToDelete = item
                                }
                                .id(item.id)
                            }
                            .frame(maxWidth: 880)
                            .padding(.horizontal, 22)
                            .padding(.top, 18)
                            .padding(.bottom, 32)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .navigationTitle("待归类")
        .onAppear {
            selectFirstItemIfNeeded()
        }
        .onChange(of: model.pendingItems.map(\.id)) { _, _ in
            selectFirstItemIfNeeded()
        }
        .alert("将文件移到废纸篓？", isPresented: deleteAlertBinding) {
            Button("取消", role: .cancel) { itemToDelete = nil }
            Button("移到废纸篓", role: .destructive) {
                if let itemToDelete {
                    withAnimation(.snappy) { model.delete(itemToDelete) }
                }
                itemToDelete = nil
            }
        } message: {
            Text("“\(itemToDelete?.url.lastPathComponent ?? "这个文件")”会进入系统废纸篓，可以从归流的操作记录中恢复。")
        }
    }

    private var selectedItem: InboxItem? {
        if let selectedItemID,
           let item = model.pendingItems.first(where: { $0.id == selectedItemID }) {
            return item
        }
        return model.pendingItems.first
    }

    private var triageQueue: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("待处理队列")
                        .font(.headline.weight(.bold))
                    Spacer()
                    Text("\(model.pendingItems.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(GuiliuTheme.brand)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(GuiliuTheme.brand.opacity(0.11), in: Capsule())
                }
                Text("选中文件，在右侧一次完成判断与归档")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(15)

            GuiliuBackToTopScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.pendingItems) { item in
                        TriageQueueRow(
                            item: item,
                            selected: selectedItem?.id == item.id
                        ) {
                            selectedItemID = item.id
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 12)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(model.isMonitoring ? GuiliuTheme.success : .secondary)
                    .frame(width: 7, height: 7)
                Text(model.isMonitoring ? "新文件会自动加入队列" : "监控已暂停")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(13)
            .background(GuiliuTheme.surface)
            .overlay(alignment: .top) { Divider().opacity(0.55) }
        }
        .background(GuiliuTheme.sidebar.opacity(0.62))
    }

    private func selectFirstItemIfNeeded() {
        if let selectedItemID,
           model.pendingItems.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = model.pendingItems.first?.id
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { itemToDelete != nil },
            set: { if !$0 { itemToDelete = nil } }
        )
    }
}

private struct TriageQueueRow: View {
    let item: InboxItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: GuiliuFileIcon.image(for: item.url))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 27, height: 27)
                    .padding(4)
                    .background(
                        item.suggestion.category.tint.opacity(selected ? 0.15 : 0.09),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(item.suggestion.category.displayName)
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selected ? item.suggestion.category.tint : Color.secondary.opacity(0.55))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                selected ? item.suggestion.category.tint.opacity(0.105) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(item.suggestion.category.tint)
                        .frame(width: 3, height: 22)
                        .offset(x: -3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.url.lastPathComponent)，推荐归入 \(item.suggestion.category.displayName)")
    }
}

private struct InboxHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) { headerCopy; Spacer(); status }
            VStack(alignment: .leading, spacing: 14) { headerCopy; status }
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 4)
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("确认当前文件的去向")
                .font(.title3.weight(.bold))
            Text("左侧切换文件；推荐分类可以修改，处理完成后自动进入下一项。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        GuiliuStatusPill(
            title: model.isMonitoring ? "持续监控中" : "监控已暂停",
            symbol: model.isMonitoring ? "dot.radiowaves.left.and.right" : "pause.fill",
            tint: model.isMonitoring ? GuiliuTheme.success : .secondary
        )
    }
}

private struct EmptyInboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GuiliuEmptyState(
            symbol: "checkmark.seal.fill",
            title: "所有文件都已安放",
            message: model.isMonitoring
                ? "下载、截图或接收的新文件稳定写入后，右上角会出现快速归档浮窗。"
                : "当前没有待归类文件；启动监控后，归流会继续留意新文件。",
            tint: GuiliuTheme.success
        ) {
            Button("扫描现有文件") {
                model.importExistingFiles()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isImportingExistingFiles)

            Button(model.isMonitoring ? "暂停监控" : "开始监控") {
                model.toggleMonitoring()
            }
            .buttonStyle(.bordered)
        }
        .overlay(alignment: .bottom) {
            GuiliuPathLabel(path: model.downloadURL.path)
                .padding(20)
        }
    }
}

private struct RoutingCard: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem
    let onDelete: () -> Void

    @State private var selectedCategory: FileCategory
    @State private var rememberExtension = false
    @State private var isHovering = false

    private var isProcessing: Bool {
        model.processingItemIDs.contains(item.id)
    }

    init(item: InboxItem, onDelete: @escaping () -> Void) {
        self.item = item
        self.onDelete = onDelete
        _selectedCategory = State(initialValue: item.suggestion.category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    fileSummary
                    Spacer(minLength: 18)
                    destinationPicker
                        .frame(width: 220)
                }

                VStack(alignment: .leading, spacing: 15) {
                    fileSummary
                    destinationPicker
                }
            }

            if !item.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(item.tags.prefix(8)) { tag in
                            SmartTagChip(tag: tag) { model.search(for: tag) }
                        }
                    }
                }
                .accessibilityLabel("自动标签")
            }

            if let analysis = model.aiAnalysis(for: item.url) {
                AIAnalysisLauncher(
                    fileURL: item.url,
                    analysis: analysis,
                    category: item.suggestion.category,
                    pendingItemID: item.id
                )
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    fileOptions
                    Spacer(minLength: 12)
                    actions
                }

                VStack(alignment: .leading, spacing: 12) {
                    fileOptions
                    actions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(18)
        .background(GuiliuTheme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(isHovering ? GuiliuTheme.brand.opacity(0.25) : GuiliuTheme.hairline, lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { isHovering = $0 }
        .disabled(isProcessing)
        .opacity(isProcessing ? 0.72 : 1)
        .onChange(of: item.suggestion.category) { oldCategory, newCategory in
            if selectedCategory == oldCategory {
                selectedCategory = newCategory
            }
        }
    }

    private var fileSummary: some View {
        HStack(alignment: .top, spacing: 14) {
            FileThumbnail(url: item.url, tint: selectedCategory.tint)
                .frame(width: 66, height: 66)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.url.lastPathComponent)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Label(item.origin.displayName, systemImage: item.origin.symbolName)
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                    Text("·")
                    Text(GuiliuRelativeTime.text(for: item.detectedAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Button {
                    model.reveal(url: item.url)
                } label: {
                    Label(item.sourceDisplayName, systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(GuiliuTheme.brand)
                .help("在访达中查看")
                .accessibilityLabel("在访达中查看 \(item.url.lastPathComponent)")
            }
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("归档位置（可修改）")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedCategory == item.suggestion.category {
                    Label("推荐", systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GuiliuTheme.brand)
                }
            }

            HStack(spacing: 10) {
                GuiliuIconTile(symbol: selectedCategory.symbolName, tint: selectedCategory.tint, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Picker("归档位置", selection: $selectedCategory) {
                        ForEach(FileCategory.allCases) { category in
                            Label(category.displayName, systemImage: category.symbolName)
                                .tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.large)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(categoryDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(9)
            .background(selectedCategory.tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selectedCategory.tint.opacity(0.18), lineWidth: 1)
            }
            .accessibilityLabel("归档分类，当前为 \(selectedCategory.displayName)")
        }
    }

    private var categoryDetail: String {
        if selectedCategory == item.suggestion.category {
            return item.suggestion.reason
        }
        return "已手动选择；推荐为“\(item.suggestion.category.displayName)”"
    }

    private var fileOptions: some View {
        HStack(spacing: 11) {
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                Text("正在安全处理…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                operationPill
                if model.aiProcessingItemIDs.contains(item.id) {
                    GuiliuStatusPill(title: "本地 AI 分析中", symbol: "sparkles", tint: .purple)
                }
            }

            if !item.url.pathExtension.isEmpty {
                Toggle("以后 .\(item.url.pathExtension.lowercased()) 默认归入这里", isOn: $rememberExtension)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .fixedSize()
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            RenameFileButton(
                fileURL: item.url,
                isEnabled: model.canRename(item),
                unavailableHelp: "第三方 App 管理的原件不能直接改名"
            ) { baseName in
                model.renamePendingFile(item, toBaseName: baseName)
            }

            Menu {
                Button(item.aiAnalyzedAt == nil ? "使用本地 AI 分析" : "重新进行本地 AI 分析") {
                    model.analyzeWithOllama(item)
                }
                .disabled(!model.ollamaEnabled || model.isAIAnalysisBusy)

                Divider()
                Button("暂时忽略") {
                    withAnimation(.snappy) { model.ignore(item) }
                }
                if item.routingOperation == .move {
                    Divider()
                    Button("移到废纸篓", role: .destructive, action: onDelete)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("更多文件操作")

            Button {
                withAnimation(.snappy) {
                    model.route(item, to: selectedCategory, rememberExtension: rememberExtension)
                }
            } label: {
                Label(actionTitle, systemImage: actionSymbol)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("将 \(item.url.lastPathComponent) \(item.routingOperation.actionName)到 \(selectedCategory.displayName)")
        }
    }

    private var operationPill: some View {
        switch item.routingOperation {
        case .move:
            GuiliuStatusPill(title: "移动归档 · 不占额外空间", symbol: "arrow.right", tint: GuiliuTheme.success)
        case .copy:
            GuiliuStatusPill(title: "安全复制 · 保留原件", symbol: "doc.on.doc", tint: .blue)
        case .reference:
            GuiliuStatusPill(title: "引用归档 · 几乎不占空间", symbol: "link", tint: GuiliuTheme.brand)
        }
    }

    private var actionTitle: String {
        switch item.routingOperation {
        case .move: "移到“\(selectedCategory.displayName)”"
        case .copy: "复制到“\(selectedCategory.displayName)”"
        case .reference: "引用到“\(selectedCategory.displayName)”"
        }
    }

    private var actionSymbol: String {
        switch item.routingOperation {
        case .move: "arrow.right"
        case .copy: "doc.on.doc"
        case .reference: "link"
        }
    }
}

private struct FileThumbnail: View {
    let url: URL
    let tint: Color
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(tint.opacity(0.085))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(tint)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(tint.opacity(0.13), lineWidth: 1)
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 144, height: 144),
                scale: 2,
                representationTypes: .thumbnail
            )
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.nsImage
            }
        }
    }
}
