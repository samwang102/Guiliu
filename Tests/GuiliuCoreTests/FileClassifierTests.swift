import Foundation
import Testing
@testable import GuiliuCore

@Suite("固定用途分类器")
struct FileClassifierTests {
    private let classifier = FileClassifier()

    @Test("通用机构资料分类可以持久化")
    func organizationMaterialsCategoryPersists() throws {
        let category = FileCategory.organizationMaterials
        #expect(category.displayName == "机构资料")
        #expect(FileCategory.allCases.contains(category))

        let data = try JSONEncoder().encode(category)
        #expect(try JSONDecoder().decode(FileCategory.self, from: data) == category)
    }

    @Test("明确格式进入对应用途分类", arguments: [
        ("slides.pptx", FileCategory.presentations),
        ("photo.heic", FileCategory.visualMedia),
        ("installer.dmg", FileCategory.software),
        ("dataset.csv", FileCategory.dataModels),
        ("source.swift", FileCategory.codeProjects),
        ("book.epub", FileCategory.readingMaterials),
        ("movie.mov", FileCategory.visualMedia),
        ("letter.docx", FileCategory.documentsReports),
        ("示例登记表.pdf", FileCategory.recordsForms),
        ("示例项目报告.pdf", FileCategory.documentsReports),
        ("示例阅读指南.pdf", FileCategory.readingMaterials),
        ("9999.99999.pdf", FileCategory.researchPapers),
        ("sample_model.tar", FileCategory.dataModels),
        ("example-installer.dmg", FileCategory.software)
    ])
    func classifiesKnownUsage(filename: String, expected: FileCategory) {
        let suggestion = classifier.suggest(for: URL(fileURLWithPath: "/tmp/\(filename)"))
        #expect(suggestion.category == expected)
    }

    @Test("未知格式只进入待整理而不创建新分类")
    func unknownFilesNeedReview() {
        let suggestion = classifier.suggest(for: URL(fileURLWithPath: "/tmp/example.weird-format"))
        #expect(suggestion.category == .needsReview)
    }

    @Test("未知压缩包不会按格式粗暴分类")
    func unknownArchiveNeedsReview() {
        let suggestion = classifier.suggest(for: URL(fileURLWithPath: "/tmp/download.zip"))
        #expect(suggestion.category == .needsReview)
    }

    @Test("用户规则优先于内建文件规则")
    func customRuleWins() {
        let url = URL(fileURLWithPath: "/tmp/talk.pdf")
        let suggestion = classifier.suggest(for: url, customRules: ["pdf": .presentations])
        #expect(suggestion.category == .presentations)
        #expect(suggestion.confidence == 1)
    }

    @Test("文件夹依据名称和内部结构分类")
    func classifiesDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuDirectoryClassification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("SampleProject", isDirectory: true)
        let dataset = root.appendingPathComponent("sample_dataset", isDirectory: true)
        let papers = root.appendingPathComponent("ResearchPapers", isDirectory: true)
        let app = root.appendingPathComponent("ExampleApp.app", isDirectory: true)

        for directory in [project, dataset, papers, app] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: project.appendingPathComponent("main.py"))
        try Data().write(to: project.appendingPathComponent("train.py"))
        try Data().write(to: dataset.appendingPathComponent("samples.hdf5"))

        #expect(classifier.suggest(for: project).category == .codeProjects)
        #expect(classifier.suggest(for: dataset).category == .dataModels)
        #expect(classifier.suggest(for: papers).category == .researchPapers)
        #expect(classifier.suggest(for: app).category == .software)
    }
}
