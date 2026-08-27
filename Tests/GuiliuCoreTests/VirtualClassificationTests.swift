import Foundation
import Testing
@testable import GuiliuCore

@Suite("虚拟细分分类")
struct VirtualClassificationTests {
    @Test("细分编辑默认跟随页面当前分类标准")
    func preferredDimensionFollowsCurrentBrowserDimension() {
        let dimensions = VirtualFacetDefaults.dimensions(for: .researchPapers)
        let stageID = VirtualFacetDefaults.paperStageID

        #expect(VirtualFacetDefaults.resolvedDimensionID(preferred: stageID, in: dimensions) == stageID)
        #expect(VirtualFacetDefaults.resolvedDimensionID(preferred: "missing", in: dimensions) == dimensions.first?.id)
    }

    @Test("未分配当前标准的文件自动归入尚未分类")
    func uncategorizedIsDerivedFromEmptyAssignments() {
        #expect(VirtualFacetDefaults.uncategorizedTitle == "尚未分类")
        #expect(VirtualFacetDefaults.isUncategorized([]))
        #expect(!VirtualFacetDefaults.isUncategorized(["示例标签"]))

        for dimension in VirtualFacetDefaults.dimensions(for: .researchPapers) {
            #expect(!dimension.values.contains(VirtualFacetDefaults.uncategorizedTitle))
        }
    }

    @Test("科研论文提供彼此独立的多维默认标准")
    func researchPaperDefaultsAreMultiDimensional() {
        let dimensions = VirtualFacetDefaults.dimensions(for: .researchPapers)

        #expect(dimensions.map(\.name) == ["研究主题", "研究方法", "阅读状态"])
        #expect(dimensions[0].selectionMode == .single)
        #expect(dimensions[0].values.isEmpty)
        #expect(dimensions[1].selectionMode == .multiple)
        #expect(dimensions[1].values.isEmpty)
        #expect(dimensions[2].selectionMode == .single)
        #expect(dimensions[2].values == ["待读", "阅读中", "已读"])
    }

    @Test("虚拟分类进入统一搜索但不需要创建子目录")
    func virtualFacetIsSearchable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuVirtualFacet-\(UUID().uuidString)", isDirectory: true)
        let categoryRoot = root.appendingPathComponent(FileCategory.researchPapers.displayName, isDirectory: true)
        try FileManager.default.createDirectory(at: categoryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paper = categoryRoot.appendingPathComponent("policy.pdf")
        try Data("paper".utf8).write(to: paper)
        let documents = SearchIndexBuilder().build(
            libraryRoot: root,
            pendingItems: [],
            history: [],
            virtualTags: [
                paper.standardizedFileURL.path: [SmartTag(kind: .topic, value: "示例主题")]
            ]
        )

        let hits = FileSearchEngine().search("标签:示例主题", in: documents)
        #expect(hits.map(\.document.url.lastPathComponent) == ["policy.pdf"])
        #expect(!FileManager.default.fileExists(atPath: categoryRoot.appendingPathComponent("示例主题").path))
    }
}
