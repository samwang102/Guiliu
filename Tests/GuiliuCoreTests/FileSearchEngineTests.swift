import Foundation
import Testing
@testable import GuiliuCore

@Suite("文件检索")
struct FileSearchEngineTests {
    private let engine = FileSearchEngine()

    @Test("全文内容按文件身份缓存且文件变化后失效")
    func fullTextCacheUsesFileIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuSearchCache-\(UUID().uuidString)", isDirectory: true)
        let categoryRoot = root.appendingPathComponent(FileCategory.documentsReports.displayName, isDirectory: true)
        try FileManager.default.createDirectory(at: categoryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = categoryRoot.appendingPathComponent("缓存验证.txt")
        try Data("第一版正文，包含示例计划。".utf8).write(to: url)

        let builder = SearchIndexBuilder()
        let metadata = builder.buildSnapshot(
            libraryRoot: root,
            pendingItems: [],
            history: [],
            includeFileContent: false
        )
        #expect(metadata.documents.first?.contentText.isEmpty == true)

        let enriched = builder.buildSnapshot(
            libraryRoot: root,
            pendingItems: [],
            history: [],
            includeFileContent: true,
            cachedContent: metadata.contentCache
        )
        #expect(enriched.documents.first?.contentText.contains("示例计划") == true)
        #expect(enriched.contentCache.count == 1)

        let reused = builder.buildSnapshot(
            libraryRoot: root,
            pendingItems: [],
            history: [],
            includeFileContent: false,
            cachedContent: enriched.contentCache
        )
        #expect(reused.documents.first?.contentText.contains("示例计划") == true)

        try Data("第二版正文更长，旧缓存必须失效。".utf8).write(to: url)
        let invalidated = builder.buildSnapshot(
            libraryRoot: root,
            pendingItems: [],
            history: [],
            includeFileContent: false,
            cachedContent: enriched.contentCache
        )
        #expect(invalidated.documents.first?.contentText.isEmpty == true)
        #expect(invalidated.contentCache.isEmpty)
    }

    @Test("Office 文档不依赖 Spotlight 也能提取正文")
    func extractsOfficeTextWithTextUtil() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuOfficeText-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("演讲稿.rtf")
        let rtf = #"{\rtf1\ansi Guiliu should extract this office document body and key action.}"#
        try Data(rtf.utf8).write(to: url)

        let text = FileTextExtractor().text(for: url)

        #expect(text.contains("office document body"))
        #expect(text.contains("key action"))
    }

    @Test("支持中文检索且文件名命中优先于正文")
    func searchesChineseAndPrioritizesFilename() {
        let filenameMatch = document(
            named: "示例主题路线图.pdf",
            contentText: "研究计划"
        )
        let bodyMatch = document(
            named: "研究笔记.txt",
            contentText: "这里记录了示例主题的发展路线。"
        )

        let hits = engine.search("示例主题", in: [bodyMatch, filenameMatch])

        #expect(hits.map(\.document.id) == [filenameMatch.id, bodyMatch.id])
        #expect(hits[0].score > hits[1].score)
        #expect(hits[1].snippet?.contains("示例主题") == true)
    }

    @Test("英文检索忽略大小写")
    func searchesEnglishCaseInsensitively() {
        let match = document(named: "Project Example FINAL.pdf")
        let other = document(named: "普通记录.pdf")

        let hits = engine.search("pRoJeCt eXaMpLe", in: [other, match])

        #expect(hits.map(\.document.id) == [match.id])
    }

    @Test("仅文件名模式排除正文和标签中的普通关键词")
    func filenameOnlyModeAvoidsHiddenFieldMatches() {
        let filenameMatch = document(named: "Example Topic Overview.pdf")
        let bodyOnly = document(
            named: "普通论文.pdf",
            tags: [SmartTag(kind: .topic, value: "Example Topic")],
            contentText: "This document studies an example topic."
        )

        let hits = engine.search("Example Topic", in: [bodyOnly, filenameMatch], mode: .filename)

        #expect(hits.map(\.document.id) == [filenameMatch.id])
        #expect(hits.first?.matchedFields == [.filename])
    }

    @Test("全文模式说明正文命中并返回上下文")
    func fullTextModeExplainsContentMatch() throws {
        let bodyOnly = document(
            named: "普通论文.pdf",
            contentText: "The proposed document discusses an example topic."
        )

        let hit = try #require(engine.search("example topic", in: [bodyOnly], mode: .fullText).first)

        #expect(hit.matchedFields == [.content])
        #expect(hit.snippet?.contains("example topic") == true)
    }

    @Test("短英文缩写在全文中按完整词匹配")
    func shortAbbreviationUsesWordBoundaries() {
        let falsePositive = document(named: "训练.pdf", contentText: "training pipeline")
        let realMatch = document(named: "系统.pdf", contentText: "an AI model")

        let hits = engine.search("AI", in: [falsePositive, realMatch], mode: .fullText)

        #expect(hits.map(\.document.id) == [realMatch.id])
    }

    @Test("支持文件名和正文精确字段")
    func searchesFilenameAndContentFields() {
        let filenameMatch = document(named: "renamed-document.pdf", contentText: "generic content")
        let contentMatch = document(named: "普通论文.pdf", contentText: "rename appears in the method")

        #expect(engine.search("文件名:rename", in: [contentMatch, filenameMatch], mode: .filename).map(\.document.id) == [filenameMatch.id])
        #expect(engine.search("正文:rename", in: [contentMatch, filenameMatch], mode: .filename).map(\.document.id) == [contentMatch.id])
    }

    @Test("支持标签、分类、来源、格式和位置结构化检索")
    func searchesStructuredFields() {
        let target = document(
            named: "示例项目合同.PDF",
            category: .researchPapers,
            origin: .wechat,
            tags: [
                SmartTag(kind: .project, value: "示例项目"),
                SmartTag(kind: .documentType, value: "合同")
            ],
            location: .library
        )
        let distractor = document(
            named: "示例项目进度.docx",
            category: .documentsReports,
            origin: .qq,
            tags: [SmartTag(kind: .project, value: "示例项目")],
            location: .inbox
        )

        let queries = [
            "标签:合同",
            "分类:科研论文",
            "来源:微信",
            "格式:.PDF",
            "位置:文件库"
        ]
        for query in queries {
            let hits = engine.search(query, in: [distractor, target])
            #expect(hits.map(\.document.id) == [target.id], "结构化条件 \(query) 应只命中目标文件")
        }
    }

    @Test("多个词采用 AND 语义")
    func requiresEverySearchTerm() {
        let complete = document(
            named: "资料.pdf",
            tags: [
                SmartTag(kind: .project, value: "示例项目"),
                SmartTag(kind: .documentType, value: "合同")
            ]
        )
        let partial = document(
            named: "示例项目进度.pdf",
            tags: [SmartTag(kind: .project, value: "示例项目")]
        )

        let hits = engine.search("示例项目 合同", in: [partial, complete])

        #expect(hits.map(\.document.id) == [complete.id])
    }

    @Test("物理分类筛选只返回所选文件夹中的已归档文件")
    func filtersByPhysicalCategoryFolder() {
        let paper = document(
            named: "Example Topic.pdf",
            category: .researchPapers,
            location: .library
        )
        let report = document(
            named: "Example Topic Report.docx",
            category: .documentsReports,
            location: .library
        )
        let pendingPaper = document(
            named: "Example Topic Pending.pdf",
            category: .researchPapers,
            location: .inbox
        )

        let hits = engine.search(
            "Example Topic",
            in: [report, pendingPaper, paper],
            scope: .all,
            category: .researchPapers
        )

        #expect(hits.map(\.document.id) == [paper.id])
    }

    @Test("待归类索引保留持久化标签且使用当前所选分类标签")
    func pendingIndexKeepsPersistedTagsSearchable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuPendingSearch-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let contents = Data("没有可用于推断该项目标签的正文".utf8)
        let url = inbox.appendingPathComponent("普通资料.txt")
        try contents.write(to: url)
        let persisted = SmartTag(kind: .project, value: "示例计划")
        let staleCategory = SmartTagger().categoryTag(for: .needsReview)
        let selectedCategory = SmartTagger().categoryTag(for: .documentsReports)
        let item = InboxItem(
            url: url,
            fileSize: Int64(contents.count),
            suggestion: ClassificationSuggestion(
                category: .documentsReports,
                reason: "用户已选择",
                confidence: 1
            ),
            origin: .downloads,
            tags: [persisted, persisted, staleCategory]
        )

        let documents = SearchIndexBuilder().build(
            libraryRoot: library,
            pendingItems: [item],
            history: []
        )
        let indexed = try #require(documents.first { $0.id == url.standardizedFileURL.path })

        #expect(indexed.tags.filter { $0.id == persisted.id }.count == 1)
        #expect(indexed.tags.contains(selectedCategory))
        #expect(!indexed.tags.contains(staleCategory))

        // This is the same structured query generated when a user clicks a tag chip.
        let hits = engine.search("标签:\(persisted.value)", in: documents)
        #expect(hits.map(\.document.id) == [indexed.id])
    }

    private func document(
        named name: String,
        category: FileCategory = .needsReview,
        origin: FileOrigin = .unknown,
        tags: [SmartTag] = [],
        location: SearchDocumentLocation = .library,
        contentText: String = ""
    ) -> SearchDocument {
        SearchDocument(
            url: URL(fileURLWithPath: "/tmp/SearchTests/\(name)"),
            category: category,
            origin: origin,
            tags: tags,
            location: location,
            contentText: contentText
        )
    }
}
