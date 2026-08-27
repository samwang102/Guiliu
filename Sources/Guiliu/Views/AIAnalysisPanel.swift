import GuiliuCore
import SwiftUI

struct AIAnalysisLauncher: View {
    @Environment(AppModel.self) private var model

    let fileURL: URL
    let analysis: OllamaDocumentAnalysis
    let category: FileCategory
    let pendingItemID: UUID?

    var body: some View {
        Button {
            model.openAIAnalysisReader(
                for: fileURL,
                category: category,
                pendingItemID: pendingItemID
            )
        } label: {
            Label(buttonTitle, systemImage: "sparkles")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(analysis.suggestion.category == .researchPapers ? GuiliuTheme.brand : .purple)
        .help("在右侧阅读器中查看完整分析")
        .accessibilityLabel("查看\(buttonTitle)")
    }

    private var buttonTitle: String {
        analysis.suggestion.category == .researchPapers ? "论文解读" : "AI 结果"
    }
}

struct AIAnalysisReaderView: View {
    @Environment(AppModel.self) private var model

    let request: AIAnalysisReaderRequest

    private var analysis: OllamaDocumentAnalysis? {
        model.aiAnalysis(for: request.fileURL)
    }

    private var isProcessing: Bool {
        if let pendingItemID = request.pendingItemID {
            return model.aiProcessingItemIDs.contains(pendingItemID)
        }
        return model.isAIProcessing(request.fileURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                GuiliuIconTile(
                    symbol: "sparkles",
                    tint: request.category == .researchPapers ? GuiliuTheme.brand : .purple,
                    size: 42
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(request.category == .researchPapers ? "论文解读" : "本地 AI 分析")
                        .font(.headline.weight(.bold))
                    Text(request.fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    model.aiAnalysisReader = nil
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("关闭阅读器")
                .accessibilityLabel("关闭论文解读")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.7)

            GuiliuBackToTopScrollView {
                if let analysis {
                    AIAnalysisPanel(
                        analysis: analysis,
                        initiallyExpanded: true,
                        isProcessing: isProcessing,
                        onReanalyze: { model.reanalyze(request) }
                    )
                    .padding(18)
                } else {
                    ContentUnavailableView(
                        "分析结果不可用",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("可返回文件列表重新发起本地 AI 分析。")
                    )
                    .padding(24)
                }
            }
        }
        .background(GuiliuTheme.canvas)
    }
}

struct AIAnalysisPanel: View {
    let analysis: OllamaDocumentAnalysis
    let initiallyExpanded: Bool
    let isProcessing: Bool
    let onReanalyze: (() -> Void)?

    @State private var isExpanded: Bool

    init(
        analysis: OllamaDocumentAnalysis,
        initiallyExpanded: Bool = true,
        isProcessing: Bool = false,
        onReanalyze: (() -> Void)? = nil
    ) {
        self.analysis = analysis
        self.initiallyExpanded = initiallyExpanded
        self.isProcessing = isProcessing
        self.onReanalyze = onReanalyze
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if isPaper {
                    if let paperApproachText {
                        analysisSection(
                            title: "论文主要做法",
                            symbol: "point.3.connected.trianglepath.dotted",
                            tint: GuiliuTheme.brand,
                            text: paperApproachText
                        )
                    } else {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title3)
                                .foregroundStyle(GuiliuTheme.brand)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("需要重新分析")
                                    .font(.callout.weight(.semibold))
                                Text("当前结果缺少足够的创新点与实现细节。重新分析后将生成一份聚焦主要做法的深度说明。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .background(GuiliuTheme.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                } else {
                    resultRow(
                        title: "推荐分类",
                        symbol: analysis.suggestion.category.symbolName,
                        tint: analysis.suggestion.category.tint
                    ) {
                        Text(analysis.suggestion.category.displayName)
                            .font(.callout.weight(.semibold))
                        Text("置信度 \(Int((analysis.suggestion.confidence * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    resultRow(title: "分析依据", symbol: "text.quote", tint: .blue) {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    if !displayTags.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("智能标签", systemImage: "tag.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(displayTags, id: \.self) { title in
                                        AIResultTag(title: title)
                                    }
                                }
                            }
                        }
                    }

                    if let value = validSection(analysis.mainContent) {
                        analysisSection(title: "主要内容", symbol: "doc.text.magnifyingglass", tint: .purple, text: value)
                    }
                    if !displayKeyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("关键事项", systemImage: "list.bullet.rectangle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.teal)
                            ForEach(Array(displayKeyPoints.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .top, spacing: 7) {
                                    Circle().fill(Color.teal).frame(width: 5, height: 5).padding(.top, 7)
                                    Text(point)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }

                    if !hasStructuredContent, let summary = displaySummary {
                        analysisSection(
                            title: "主要内容",
                            symbol: "doc.text.magnifyingglass",
                            tint: .purple,
                            text: summary
                        )
                    } else if !hasStructuredContent {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.bubble.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("这次没有生成内容概括")
                                    .font(.callout.weight(.semibold))
                                Text("当前结果只包含分类。请点击下方“重新分析”，分析结果会优先说明文档讲了什么。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }

                HStack(spacing: 10) {
                    Text("\(analysis.model) · 分析于 \(analysis.analyzedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let onReanalyze {
                        Button {
                            onReanalyze()
                        } label: {
                            if isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("重新分析", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isProcessing)
                    }
                }
            }
            .padding(.top, 11)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .foregroundStyle(isPaper ? GuiliuTheme.brand : .purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPaper ? "论文主要做法" : "本地 AI 分析结果")
                        .font(.callout.weight(.semibold))
                    Text(isPaper ? "核心创新 · 具体实现" : "\(analysis.suggestion.category.displayName) · \(displayTags.count) 个标签")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [Color.purple.opacity(0.075), Color.blue.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.purple.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var reason: String {
        let raw = analysis.suggestion.reason.replacingOccurrences(of: "本地 AI：", with: "")
        guard raw.containsCJK, validSection(raw) != nil else {
            return "本地模型判断该文件适合归入“\(analysis.suggestion.category.displayName)”。当前结果没有提供有效的中文依据，可重新分析获取完整说明。"
        }
        return raw
    }

    private var isPaper: Bool {
        analysis.suggestion.category == .researchPapers
    }

    private var paperApproachText: String? {
        if let value = validSection(analysis.paperApproach) {
            return value
        }

        let innovation = validSection(analysis.keyIdea)
        let implementation = validSection(analysis.method)
        guard innovation != nil || implementation != nil else { return nil }
        return [
            innovation.map { "核心创新：\($0)" },
            implementation.map { "具体实现：\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    private var displaySummary: String? {
        guard let summary = analysis.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        if summary.contains("研究问题、主要方法、核心结论")
            || summary.contains("本次没有生成有效的中文内容概括")
            || !summary.containsCJK {
            return "本次没有生成有效的中文内容概括，请点击下方“重新分析”。"
        }
        return summary
    }

    private var hasStructuredContent: Bool {
        [analysis.keyIdea, analysis.method, analysis.experimentResults, analysis.limitations, analysis.mainContent]
            .contains { validSection($0) != nil } || analysis.keyPoints.contains { validSection($0) != nil }
    }

    private var displayKeyPoints: [String] {
        analysis.keyPoints.compactMap { validSection($0) }
    }

    private func validSection(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let invalidMarkers = [
            "当前提取内容未提供", "提取内容未提供", "正文未提供", "未能提取", "无法提取",
            "2 至 4 句说明", "3 至 6 句说明", "4 至 8 句说明", "返回空字符串", "返回空数组"
        ]
        guard !invalidMarkers.contains(where: { trimmed.contains($0) }) else { return nil }
        return trimmed
    }

    private var displayTags: [String] {
        var seen = Set<String>()
        return analysis.tags.compactMap { tag in
            let raw = tag.value.lowercased()
            let isCategoryToken = FileCategory.allCases.contains { $0.rawValue.lowercased() == raw }
            let isCategoryAssignment = FileCategory.allCases.contains {
                raw.contains($0.rawValue.lowercased()) && raw.contains("=")
            }
            let isPlaceholder = ["当前提取内容未提供", "提取内容未提供", "未能提取", "无法提取"]
                .contains { tag.value.contains($0) }
            let isFilenameAsProject = tag.kind == .project
                && ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx"]
                    .contains(URL(fileURLWithPath: tag.value).pathExtension.lowercased())
            guard !((tag.kind == .project || tag.kind == .organization) && isCategoryToken),
                  !isCategoryAssignment,
                  !isPlaceholder,
                  !isFilenameAsProject else { return nil }
            let title = tag.localizedAIName
            guard seen.insert(title).inserted else { return nil }
            return title
        }
    }

    private func resultRow<Content: View>(
        title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                content()
            }
        }
    }

    private func analysisSection(title: String, symbol: String, tint: Color, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct AIResultTag: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(0.09), in: Capsule())
            .overlay { Capsule().stroke(Color.purple.opacity(0.12), lineWidth: 1) }
    }

}

private extension SmartTag {
    var localizedAIName: String {
        let translations: [String: String] = [
            "researchpapers": "科研论文", "researchpaper": "研究论文",
            "paper": "研究论文", "presentation": "演示文稿", "slides": "演示文稿",
            "report": "报告", "contract": "合同", "manual": "使用手册",
            "high": "重要资料", "important": "重要资料", "critical": "重要资料",
            "medium": "一般资料", "normal": "一般资料", "low": "低优先级",
            "data analysis": "数据分析", "project management": "项目管理"
        ]
        let localizedValue = translations[value.lowercased()] ?? value
        switch kind {
        case .project: return "项目：\(localizedValue)"
        case .organization: return "机构：\(localizedValue)"
        case .source: return "来源：\(localizedValue)"
        case .importance, .documentType, .topic: return localizedValue
        }
    }
}

private extension String {
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
