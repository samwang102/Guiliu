import Foundation
import PDFKit
import UniformTypeIdentifiers

public struct ClassificationSuggestion: Codable, Equatable, Hashable, Sendable {
    public let category: FileCategory
    public let reason: String
    public let confidence: Double

    public init(category: FileCategory, reason: String, confidence: Double) {
        self.category = category
        self.reason = reason
        self.confidence = confidence
    }
}

public struct FileClassifier: Sendable {
    private static let presentationExtensions: Set<String> = ["ppt", "pptx", "key", "odp"]
    private static let documentExtensions: Set<String> = ["doc", "docx", "pages", "rtf", "rtfd", "odt"]
    private static let spreadsheetExtensions: Set<String> = ["xls", "xlsx", "xlsm", "numbers", "ods"]
    private static let tabularDataExtensions: Set<String> = ["csv", "tsv", "parquet", "jsonl"]
    private static let bookExtensions: Set<String> = ["epub", "mobi", "azw", "azw3", "djvu"]
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "cs", "java", "kt", "kts", "py", "rb", "go", "rs",
        "js", "jsx", "ts", "tsx", "vue", "svelte", "html", "css", "scss", "sql", "sh", "zsh", "fish",
        "yaml", "yml", "toml", "xml", "ipynb", "md", "markdown"
    ]
    private static let dataModelExtensions: Set<String> = [
        "npy", "npz", "h5", "hdf5", "pt", "pth", "ckpt", "safetensors", "onnx", "obj", "fbx", "glb", "gltf", "ply"
    ]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"]
    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "app"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "cr2", "nef"]
    private static let mediaExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "mp4", "mov", "mkv", "avi", "webm", "m4v"]

    private static let recordKeywords = [
        "表单", "清单", "申请表", "登记表", "记录表", "form", "checklist"
    ]
    private static let documentKeywords = [
        "报告", "说明", "方案", "总结", "记录", "proposal", "report"
    ]
    private static let readingKeywords = [
        "阅读", "参考", "指南", "教程", "手册", "电子书", "reading", "reference", "guide", "manual"
    ]
    private static let dataKeywords = ["dataset", "data", "model", "模型", "数据集", "权重", "checkpoint", "texture", "embedding"]
    private static let softwareKeywords = ["installer", "安装", "setup", "uninstall"]

    public init() {}

    public func suggest(for url: URL, customRules: [String: FileCategory] = [:]) -> ClassificationSuggestion {
        let ext = url.pathExtension.lowercased()
        let name = normalizedName(url.deletingPathExtension().lastPathComponent)

        if isDirectory(url) {
            return classifyDirectory(at: url, normalizedName: name)
        }

        if let custom = customRules[ext] {
            return .init(category: custom, reason: "使用你为 .\(ext) 设置的规则", confidence: 1)
        }

        if Self.installerExtensions.contains(ext) || containsAny(name, Self.softwareKeywords) {
            return .init(category: .software, reason: "识别为软件或安装文件", confidence: 0.98)
        }
        if Self.presentationExtensions.contains(ext) {
            return .init(category: .presentations, reason: "识别为演示文稿", confidence: 0.99)
        }
        if Self.dataModelExtensions.contains(ext) || Self.tabularDataExtensions.contains(ext) {
            return .init(category: .dataModels, reason: "识别为实验数据或模型资源", confidence: 0.96)
        }
        if Self.imageExtensions.contains(ext) || Self.mediaExtensions.contains(ext) {
            return .init(category: .visualMedia, reason: "识别为图片、音频或视频", confidence: 0.98)
        }
        if Self.bookExtensions.contains(ext) {
            return .init(category: .readingMaterials, reason: "识别为电子书或阅读资料", confidence: 0.9)
        }
        if ext == "pdf" {
            return classifyPDF(at: url, normalizedName: name)
        }
        if Self.documentExtensions.contains(ext) {
            return classifyDocument(normalizedName: name)
        }
        if Self.spreadsheetExtensions.contains(ext) {
            if containsAny(name, Self.dataKeywords) {
                return .init(category: .dataModels, reason: "表格名称具有数据集特征", confidence: 0.86)
            }
            return .init(category: .recordsForms, reason: "常见表格通常用于表单、清单或记录", confidence: 0.68)
        }
        if Self.archiveExtensions.contains(ext) {
            return classifyArchive(normalizedName: name)
        }
        if Self.codeExtensions.contains(ext) || ext == "txt" || ext == "json" {
            if ext == "sh", containsAny(name, Self.softwareKeywords) {
                return .init(category: .software, reason: "脚本名称具有安装程序特征", confidence: 0.9)
            }
            return .init(category: .codeProjects, reason: "识别为代码、配置或项目说明", confidence: 0.91)
        }

        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) || type.conforms(to: .audiovisualContent) {
                return .init(category: .visualMedia, reason: "根据系统文件类型识别为媒体", confidence: 0.86)
            }
        }

        return .init(category: .needsReview, reason: "没有足够稳定的用途特征，需要你确认", confidence: 0.25)
    }

    private func classifyDocument(normalizedName name: String) -> ClassificationSuggestion {
        if containsAny(name, Self.recordKeywords) {
            return .init(category: .recordsForms, reason: "名称具有表单、清单或记录特征", confidence: 0.9)
        }
        if containsAny(name, Self.documentKeywords) {
            return .init(category: .documentsReports, reason: "名称具有说明、方案或报告特征", confidence: 0.94)
        }
        if containsAny(name, Self.readingKeywords) {
            return .init(category: .readingMaterials, reason: "名称具有阅读或参考资料特征", confidence: 0.88)
        }
        return .init(category: .documentsReports, reason: "常见文字文档通常用于说明、记录或报告", confidence: 0.62)
    }

    private func classifyPDF(at url: URL, normalizedName name: String) -> ClassificationSuggestion {
        if containsAny(name, Self.recordKeywords) {
            return .init(category: .recordsForms, reason: "PDF 名称具有表单或记录特征", confidence: 0.92)
        }
        if containsAny(name, Self.documentKeywords) {
            return .init(category: .documentsReports, reason: "PDF 名称具有说明、方案或报告特征", confidence: 0.95)
        }
        if containsAny(name, Self.readingKeywords) {
            return .init(category: .readingMaterials, reason: "PDF 名称具有阅读或参考资料特征", confidence: 0.92)
        }
        if name.range(of: #"^\d{4}\.\d{4,5}v?\d*$"#, options: .regularExpression) != nil {
            return .init(category: .researchPapers, reason: "文件名符合 arXiv 论文编号", confidence: 0.95)
        }
        if name.contains("导出pdf") {
            return .init(category: .needsReview, reason: "通用导出文件名没有体现用途", confidence: 0.3)
        }

        guard FileManager.default.fileExists(atPath: url.path),
              let document = PDFDocument(url: url) else {
            return .init(category: .researchPapers, reason: "仅凭 PDF 文件名无法确定用途；暂按研究文献推荐", confidence: 0.52)
        }

        let pageLimit = min(document.pageCount, 3)
        let sample = (0..<pageLimit)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
            .lowercased()

        let strongSignals = ["abstract", "摘要", "arxiv:", "doi.org", "keywords", "关键词"]
        let secondarySignals = ["introduction", "related work", "methodology", "corresponding author", "university", "institute"]
        let strongCount = strongSignals.reduce(into: 0) { count, signal in
            if sample.contains(signal) { count += 1 }
        }
        let secondaryCount = secondarySignals.reduce(into: 0) { count, signal in
            if sample.contains(signal) { count += 1 }
        }

        if strongCount >= 1 && secondaryCount >= 1 {
            return .init(category: .researchPapers, reason: "PDF 正文具有摘要和论文结构特征", confidence: 0.91)
        }

        return .init(category: .researchPapers, reason: "PDF 可能是研究文献；请确认", confidence: 0.58)
    }

    private func classifyArchive(normalizedName name: String) -> ClassificationSuggestion {
        if containsAny(name, Self.documentKeywords) {
            return .init(category: .documentsReports, reason: "压缩包名称具有说明或报告特征", confidence: 0.9)
        }
        if containsAny(name, Self.softwareKeywords) {
            return .init(category: .software, reason: "压缩包名称具有安装程序特征", confidence: 0.9)
        }
        if containsAny(name, Self.dataKeywords) {
            return .init(category: .dataModels, reason: "压缩包名称具有数据或模型特征", confidence: 0.85)
        }
        if containsAny(name, Self.readingKeywords) {
            return .init(category: .readingMaterials, reason: "压缩包名称具有阅读资料特征", confidence: 0.8)
        }
        if containsAny(name, ["source", "master", "project", "项目", "代码"] ) {
            return .init(category: .codeProjects, reason: "压缩包名称具有代码项目特征", confidence: 0.82)
        }
        return .init(category: .needsReview, reason: "压缩格式不能代表实际用途，需要确认内容", confidence: 0.35)
    }

    private func classifyDirectory(at url: URL, normalizedName name: String) -> ClassificationSuggestion {
        if url.pathExtension.lowercased() == "app" || containsAny(name, Self.softwareKeywords) {
            return .init(category: .software, reason: "识别为 App 或安装目录", confidence: 0.98)
        }
        if containsAny(name, ["paper", "论文", "文献"]) {
            return .init(category: .researchPapers, reason: "文件夹名称具有论文或文献特征", confidence: 0.92)
        }
        if containsAny(name, ["ppt", "模板", "演示", "汇报"]) {
            return .init(category: .presentations, reason: "文件夹名称具有演示文稿特征", confidence: 0.92)
        }
        if containsAny(name, Self.documentKeywords) {
            return .init(category: .documentsReports, reason: "文件夹名称具有说明或报告特征", confidence: 0.94)
        }
        if containsAny(name, Self.readingKeywords) {
            return .init(category: .readingMaterials, reason: "文件夹名称具有阅读资料特征", confidence: 0.88)
        }
        if containsAny(name, Self.dataKeywords) {
            return .init(category: .dataModels, reason: "文件夹名称具有数据或模型特征", confidence: 0.9)
        }

        let profile = directoryProfile(at: url)
        if profile.dataFiles >= 1 && profile.dataFiles >= profile.codeFiles {
            return .init(category: .dataModels, reason: "文件夹内主要是数据或模型文件", confidence: 0.82)
        }
        if profile.paperFiles >= 3 && profile.paperFiles > profile.codeFiles {
            return .init(category: .researchPapers, reason: "文件夹内主要是 PDF 文献", confidence: 0.85)
        }
        if profile.presentationFiles >= 2 && profile.presentationFiles > profile.codeFiles {
            return .init(category: .presentations, reason: "文件夹内主要是演示文稿", confidence: 0.84)
        }
        if profile.codeFiles >= 2 {
            return .init(category: .codeProjects, reason: "文件夹内包含成组代码和配置文件", confidence: 0.86)
        }

        return .init(category: .needsReview, reason: "无法仅凭文件夹名称和内容结构判断用途", confidence: 0.3)
    }

    private struct DirectoryProfile {
        var codeFiles = 0
        var dataFiles = 0
        var paperFiles = 0
        var presentationFiles = 0
    }

    private func directoryProfile(at url: URL) -> DirectoryProfile {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return DirectoryProfile() }

        var profile = DirectoryProfile()
        var examinedFiles = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            examinedFiles += 1
            if examinedFiles > 400 { break }
            let ext = child.pathExtension.lowercased()
            if Self.codeExtensions.contains(ext) { profile.codeFiles += 1 }
            if Self.dataModelExtensions.contains(ext) || Self.tabularDataExtensions.contains(ext) { profile.dataFiles += 1 }
            if ext == "pdf" { profile.paperFiles += 1 }
            if Self.presentationExtensions.contains(ext) { profile.presentationFiles += 1 }
        }
        return profile
    }

    private func normalizedName(_ value: String) -> String {
        (value.removingPercentEncoding ?? value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func containsAny(_ value: String, _ keywords: [String]) -> Bool {
        keywords.contains { value.contains($0.lowercased()) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
