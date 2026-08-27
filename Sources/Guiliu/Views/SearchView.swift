import AppKit
import GuiliuCore
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .frame(maxWidth: 980)
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)

            results
        }
        .navigationTitle("文件搜索")
        .onChange(of: model.searchQuery) { _, _ in model.updateSearch() }
        .onChange(of: model.searchScope) { _, scope in
            if scope == .inbox {
                model.searchCategoryFilter = nil
            }
            model.updateSearch()
        }
        .onChange(of: model.searchMode) { _, _ in model.updateSearch() }
        .onChange(of: model.searchCategoryFilter) { _, _ in model.updateSearch() }
        .onAppear {
            if model.searchDocuments.isEmpty {
                model.rebuildSearchIndex()
            } else {
                model.updateSearch()
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.rebuildSearchIndex()
                } label: {
                    Label("重建索引", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("重新扫描待归类文件和归流文件库")
            }
        }
    }

    private var filterBar: some View {
        GuiliuListSurface {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 11) {
                    modePicker
                    scopePicker
                    categoryPicker
                    Divider().frame(height: 22)
                    quickFilters
                    Spacer(minLength: 0)
                    resultStatus
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        modePicker
                        Spacer()
                        resultStatus
                    }
                    HStack(spacing: 10) {
                        scopePicker
                        categoryPicker
                        Spacer(minLength: 0)
                    }
                    ViewThatFits(in: .horizontal) {
                        quickFilters
                        ScrollView(.horizontal, showsIndicators: false) { quickFilters }
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
        }
    }

    private var modePicker: some View {
        Picker("匹配内容", selection: searchModeBinding) {
            ForEach(SearchMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 142)
        .help(model.searchMode == .filename
            ? "普通关键词只匹配文件名；结构化条件仍然有效"
            : "搜索文件名、标签、分类、正文、AI 概括和路径")
        .accessibilityLabel("搜索匹配内容")
    }

    private var scopePicker: some View {
        Picker("搜索范围", selection: searchScopeBinding) {
            ForEach(SearchScope.allCases) { scope in
                Text(scope.displayName).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 196)
        .accessibilityLabel("搜索范围")
    }

    private var categoryPicker: some View {
        Menu {
            Button {
                model.searchCategoryFilter = nil
            } label: {
                if model.searchCategoryFilter == nil {
                    Label("全部分类", systemImage: "checkmark")
                } else {
                    Text("全部分类")
                }
            }

            Divider()

            ForEach(FileCategory.allCases) { category in
                Button {
                    model.searchScope = .library
                    model.searchCategoryFilter = category
                } label: {
                    if model.searchCategoryFilter == category {
                        Label(category.displayName, systemImage: "checkmark")
                    } else {
                        Label(category.displayName, systemImage: category.symbolName)
                    }
                }
            }
        } label: {
            Label(
                model.searchCategoryFilter?.displayName ?? "全部分类",
                systemImage: "folder"
            )
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按实际分类文件夹筛选")
        .accessibilityLabel("分类文件夹筛选")
    }

    private var quickFilters: some View {
        HStack(spacing: 6) {
            QuickFilter(title: "重要", symbol: "star.fill", tint: .orange) {
                model.searchQuery = "标签:重要资料"
            }
            QuickFilter(title: "待整理", symbol: "tray.full.fill", tint: .teal) {
                model.searchQuery = "分类:待整理"
            }
            QuickFilter(title: "文件库", symbol: "archivebox.fill", tint: .green) {
                model.searchQuery = "位置:文件库"
            }
            QuickFilter(title: "PDF", symbol: "doc.richtext", tint: .red) {
                model.searchQuery = "格式:pdf"
            }
        }
    }

    private var resultStatus: some View {
        HStack(spacing: 7) {
            if model.isIndexingSearch || model.isPreparingFullTextSearch {
                ProgressView()
                    .controlSize(.small)
            }
            Text(searchStatusText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var searchStatusText: String {
        if model.isIndexingSearch { return "正在更新文件名" }
        if model.isPreparingFullTextSearch { return "后台准备全文" }
        return "\(model.searchResults.count) 项"
    }

    private var searchModeBinding: Binding<SearchMode> {
        Binding(get: { model.searchMode }, set: { model.searchMode = $0 })
    }

    private var searchScopeBinding: Binding<SearchScope> {
        Binding(get: { model.searchScope }, set: { model.searchScope = $0 })
    }

    @ViewBuilder
    private var results: some View {
        if model.isIndexingSearch && model.searchDocuments.isEmpty {
            GuiliuEmptyState(
                symbol: "doc.text.magnifyingglass",
                title: "正在建立本地索引",
                message: "归流正在读取文件名、自动标签和可提取的正文，全程仅在这台 Mac 上完成。",
                tint: .blue
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        } else if model.searchResults.isEmpty {
            GuiliuEmptyState(
                symbol: model.searchQuery.isEmpty ? "sparkle.magnifyingglass" : "magnifyingglass",
                title: model.searchQuery.isEmpty ? "从任何线索开始" : "没有找到匹配文件",
                message: model.searchQuery.isEmpty
                    ? "可以搜索文件名和正文，也可以试试“标签:重要资料”“分类:待整理”或“格式:pdf”。"
                    : "试试缩短关键词、切换搜索范围，或使用上方的快捷筛选。",
                tint: .blue
            ) {
                if !model.searchQuery.isEmpty {
                    Button("清除条件") { model.searchQuery = "" }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            GuiliuBackToTopScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.searchResults) { hit in
                        SearchResultRow(
                            hit: hit,
                            isFirst: hit.id == model.searchResults.first?.id,
                            isLast: hit.id == model.searchResults.last?.id
                        )
                    }
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, 22)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct QuickFilter: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint.opacity(0.09), in: Capsule())
                .overlay { Capsule().stroke(tint.opacity(0.13), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选：\(title)")
    }
}

private struct SearchMetadataChip: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.09), in: Capsule())
    }
}

private struct SearchResultRow: View {
    @Environment(AppModel.self) private var model
    let hit: SearchHit
    let isFirst: Bool
    let isLast: Bool
    @State private var isHovering = false

    private var isPreviewSelected: Bool {
        model.filePreviewURL?.standardizedFileURL.path == hit.document.url.standardizedFileURL.path
    }

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Button {
                model.previewOrOpen(hit.document.url)
            } label: {
                HStack(alignment: .center, spacing: 13) {
                    Image(nsImage: GuiliuFileIcon.image(for: hit.document.url))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .padding(6)
                        .background(hit.document.category.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        highlightedText(
                            hit.document.url.lastPathComponent,
                            term: hit.matchedFields.contains(.filename) ? hit.highlightTerms.first : nil
                        )
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Label(hit.document.category.displayName, systemImage: hit.document.category.symbolName)
                                .foregroundStyle(hit.document.category.tint)
                            Text("·")
                            Text(hit.document.location.displayName)
                            if hit.document.origin != .unknown {
                                Text("·")
                                Text(hit.document.origin.displayName)
                            }
                            if let fileSizeText = hit.document.fileSizeText {
                                Text("·")
                                Text(fileSizeText)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                        HStack(spacing: 6) {
                            ForEach(hit.matchedFields, id: \.self) { field in
                                SearchMetadataChip(
                                    title: "命中\(field.displayName)",
                                    tint: field == .content ? .purple : GuiliuTheme.brand
                                )
                            }
                            ForEach(hit.document.tags.prefix(3)) { tag in
                                SearchMetadataChip(title: tag.displayName, tint: .secondary)
                            }
                            if hit.document.tags.count > 3 {
                                Text("+\(hit.document.tags.count - 3)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .lineLimit(1)

                        if let snippet = hit.snippet {
                            highlightedText(snippet, term: hit.highlightTerms.first)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 10)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("打开") { NSWorkspace.shared.open(hit.document.url) }
                Button("在访达中显示") { model.reveal(url: hit.document.url) }
                Divider()
                ForEach(hit.document.tags.prefix(6)) { tag in
                    Button("搜索标签：\(tag.displayName)") { model.search(for: tag) }
                }
                Divider()
                Button("复制路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hit.document.url.path, forType: .string)
                }
            } label: {
                Image(systemName: isPreviewSelected ? "ellipsis.circle.fill" : "ellipsis")
                    .foregroundStyle(isPreviewSelected ? hit.document.category.tint : Color.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help("更多操作")
            .accessibilityLabel("更多文件操作")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isPreviewSelected ? hit.document.category.tint.opacity(0.10) : (isHovering ? GuiliuTheme.hoverSurface : GuiliuTheme.surface))
        .overlay(alignment: .leading) {
            if isPreviewSelected {
                Capsule()
                    .fill(hit.document.category.tint)
                    .frame(width: 3, height: 30)
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast { GuiliuListDivider(leading: 64) }
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
        .onHover { isHovering = $0 }
        .accessibilityValue(isPreviewSelected ? "已选中，正在预览" : "")
        .contextMenu {
            Button("打开") { NSWorkspace.shared.open(hit.document.url) }
            Button("在访达中显示") { model.reveal(url: hit.document.url) }
            Divider()
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hit.document.url.path, forType: .string)
            }
        }
    }

    private func highlightedText(_ value: String, term: String?) -> Text {
        guard let term, !term.isEmpty,
              let range = value.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
              ) else {
            return Text(value)
        }
        return Text(value[..<range.lowerBound])
            + Text(value[range]).foregroundColor(GuiliuTheme.brand).bold()
            + Text(value[range.upperBound...])
    }
}
