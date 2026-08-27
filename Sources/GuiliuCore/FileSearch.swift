import CoreServices
import Foundation
import PDFKit

public enum SearchDocumentLocation: String, Codable, CaseIterable, Sendable {
    case inbox
    case library

    public var displayName: String {
        switch self {
        case .inbox: "待归类"
        case .library: "文件库"
        }
    }
}

public struct SearchDocument: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let category: FileCategory
    public let origin: FileOrigin
    public let tags: [SmartTag]
    public let location: SearchDocumentLocation
    public let fileSize: Int64
    public let fileSizeText: String?
    public let modificationDate: Date?
    public let contentText: String
    public let isDirectory: Bool

    public init(
        url: URL,
        category: FileCategory,
        origin: FileOrigin,
        tags: [SmartTag],
        location: SearchDocumentLocation,
        fileSize: Int64 = 0,
        modificationDate: Date? = nil,
        contentText: String = "",
        isDirectory: Bool = false
    ) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.category = category
        self.origin = origin
        self.tags = tags
        self.location = location
        self.fileSize = fileSize
        self.fileSizeText = fileSize > 0
            ? ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            : nil
        self.modificationDate = modificationDate
        self.contentText = contentText
        self.isDirectory = isDirectory
    }

    public func replacingContentText(_ contentText: String) -> SearchDocument {
        SearchDocument(
            url: url,
            category: category,
            origin: origin,
            tags: tags,
            location: location,
            fileSize: fileSize,
            modificationDate: modificationDate,
            contentText: contentText,
            isDirectory: isDirectory
        )
    }
}

public struct SearchContentCacheKey: Hashable, Sendable {
    public let path: String
    public let fileSize: Int64
    public let modificationTime: TimeInterval

    public init(url: URL, fileSize: Int64, modificationDate: Date?) {
        path = url.standardizedFileURL.path
        self.fileSize = fileSize
        modificationTime = modificationDate?.timeIntervalSinceReferenceDate ?? 0
    }
}

public struct SearchIndexSnapshot: Sendable {
    public let documents: [SearchDocument]
    public let contentCache: [SearchContentCacheKey: String]

    public init(
        documents: [SearchDocument],
        contentCache: [SearchContentCacheKey: String]
    ) {
        self.documents = documents
        self.contentCache = contentCache
    }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public let document: SearchDocument
    public let score: Int
    public let snippet: String?
    public let matchedFields: [SearchMatchField]
    public let highlightTerms: [String]

    public var id: String { document.id }
}

public enum SearchMode: String, CaseIterable, Identifiable, Sendable {
    case filename
    case fullText

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .filename: "仅文件名"
        case .fullText: "全文"
        }
    }
}

public enum SearchMatchField: String, Hashable, Sendable {
    case filename
    case tag
    case category
    case source
    case content
    case path
    case fileType
    case location

    public var displayName: String {
        switch self {
        case .filename: "文件名"
        case .tag: "标签"
        case .category: "分类"
        case .source: "来源"
        case .content: "正文 / AI 概括"
        case .path: "路径"
        case .fileType: "格式"
        case .location: "位置"
        }
    }
}

public enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case inbox
    case library

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "全部"
        case .inbox: "待归类"
        case .library: "文件库"
        }
    }
}

public struct FileSearchEngine: Sendable {
    public init() {}

    public func search(
        _ query: String,
        in documents: [SearchDocument],
        scope: SearchScope = .all,
        category: FileCategory? = nil,
        mode: SearchMode = .fullText
    ) -> [SearchHit] {
        var scoped: [SearchDocument] = []
        scoped.reserveCapacity(documents.count)
        for (index, document) in documents.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            let matchesScope = switch scope {
            case .all: true
            case .inbox: document.location == .inbox
            case .library: document.location == .library
            }
            let matchesCategory = category == nil
                || (document.location == .library && document.category == category)
            if matchesScope && matchesCategory {
                scoped.append(document)
            }
        }
        let terms = parse(query)

        if terms.isEmpty {
            return scoped
                .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
                .prefix(300)
                .map { SearchHit(document: $0, score: 0, snippet: nil, matchedFields: [], highlightTerms: []) }
        }

        var hits: [SearchHit] = []
        hits.reserveCapacity(min(scoped.count, 300))
        for (index, document) in scoped.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            if let hit = match(document, terms: terms, mode: mode) {
                hits.append(hit)
            }
        }
        guard !Task.isCancelled else { return [] }
        return hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.document.modificationDate ?? .distantPast) > ($1.document.modificationDate ?? .distantPast)
        }
        .prefix(300)
        .map { $0 }
    }

    private enum Field {
        case any
        case tag
        case category
        case source
        case fileType
        case location
        case filename
        case content
        case path
    }

    private struct Term {
        let field: Field
        let value: String
    }

    private func parse(_ query: String) -> [Term] {
        let pattern = #"[^\s\"]+|\"[^\"]*\""#
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(query.startIndex..., in: query)
        let tokens = expression?.matches(in: query, range: range).compactMap { match -> String? in
            guard let tokenRange = Range(match.range, in: query) else { return nil }
            return String(query[tokenRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } ?? []

        return tokens.compactMap { token in
            let components = token.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "：" })
            guard components.count == 2 else {
                let value = token.foldingForSearch
                return value.isEmpty ? nil : Term(field: .any, value: value)
            }

            let key = String(components[0]).foldingForSearch
            let value = String(components[1]).foldingForSearch
            guard !value.isEmpty else { return nil }
            let field: Field = switch key {
            case "标签", "tag": .tag
            case "分类", "category", "cat": .category
            case "来源", "source", "from": .source
            case "格式", "类型", "type", "ext": .fileType
            case "位置", "location", "in": .location
            case "文件名", "名称", "name", "filename": .filename
            case "正文", "内容", "content", "text": .content
            case "路径", "path": .path
            default: .any
            }
            return Term(field: field, value: value)
        }
    }

    private func match(_ document: SearchDocument, terms: [Term], mode: SearchMode) -> SearchHit? {
        let name = document.url.lastPathComponent.foldingForSearch
        let path = document.url.path.foldingForSearch
        let category = document.category.displayName.foldingForSearch
        let source = document.origin.displayName.foldingForSearch
        let fileType = document.url.pathExtension.foldingForSearch
        let location = document.location.displayName.foldingForSearch
        let tagText = document.tags.map { "\($0.kind.displayName) \($0.displayName) \($0.value)" }
            .joined(separator: " ")
            .foldingForSearch
        var score = 0
        var snippetTerm: String?
        var matchedFields: [SearchMatchField] = []
        for term in terms {
            switch term.field {
            case .any:
                if name == term.value {
                    score += 140
                    matchedFields.append(.filename)
                } else if name.hasPrefix(term.value) {
                    score += 110
                    matchedFields.append(.filename)
                } else if name.contains(term.value) {
                    score += 90
                    matchedFields.append(.filename)
                } else if mode == .filename {
                    return nil
                } else if containsSearchTerm(tagText, term.value) {
                    score += 70
                    matchedFields.append(.tag)
                } else if containsSearchTerm(category, term.value) {
                    score += 55
                    matchedFields.append(.category)
                } else if containsSearchTerm(source, term.value) {
                    score += 55
                    matchedFields.append(.source)
                } else if containsContentTerm(document.contentText, term.value) {
                    score += 35
                    snippetTerm = snippetTerm ?? term.value
                    matchedFields.append(.content)
                } else if containsSearchTerm(path, term.value) {
                    score += 20
                    matchedFields.append(.path)
                } else {
                    return nil
                }
            case .tag:
                guard containsSearchTerm(tagText, term.value) else { return nil }
                score += 100
                matchedFields.append(.tag)
            case .category:
                guard containsSearchTerm(category, term.value) else { return nil }
                score += 100
                matchedFields.append(.category)
            case .source:
                guard containsSearchTerm(source, term.value) else { return nil }
                score += 100
                matchedFields.append(.source)
            case .fileType:
                guard fileType == term.value.trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return nil }
                score += 100
                matchedFields.append(.fileType)
            case .location:
                guard containsSearchTerm(location, term.value) else { return nil }
                score += 100
                matchedFields.append(.location)
            case .filename:
                guard name.contains(term.value) else { return nil }
                score += 120
                matchedFields.append(.filename)
            case .content:
                guard containsContentTerm(document.contentText, term.value) else { return nil }
                score += 100
                snippetTerm = snippetTerm ?? term.value
                matchedFields.append(.content)
            case .path:
                guard containsSearchTerm(path, term.value) else { return nil }
                score += 100
                matchedFields.append(.path)
            }
        }

        return SearchHit(
            document: document,
            score: score,
            snippet: snippetTerm.flatMap { makeSnippet(content: document.contentText, around: $0) },
            matchedFields: matchedFields.reduce(into: []) { result, field in
                if !result.contains(field) { result.append(field) }
            },
            highlightTerms: terms.map(\.value)
        )
    }

    /// Very short English abbreviations otherwise produce misleading matches:
    /// for example `AI` used to match the middle of `training`. File names keep
    /// flexible substring matching, while metadata and full text require token
    /// boundaries for 1–3 character Latin terms.
    private func containsSearchTerm(_ text: String, _ term: String) -> Bool {
        guard isShortLatinAbbreviation(term) else { return text.contains(term) }
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: term, range: searchStart..<text.endIndex) {
            let leadingIsToken = range.lowerBound > text.startIndex
                && isASCIILetterOrDigit(text[text.index(before: range.lowerBound)])
            let trailingIsToken = range.upperBound < text.endIndex
                && isASCIILetterOrDigit(text[range.upperBound])
            if !leadingIsToken && !trailingIsToken { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Searches potentially large extracted bodies without first allocating a
    /// second, fully-folded copy for every document on every keystroke. This is
    /// especially important while Ollama is resident and memory bandwidth is
    /// the scarce resource.
    private func containsContentTerm(_ text: String, _ term: String) -> Bool {
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive
        ]
        guard isShortLatinAbbreviation(term) else {
            return text.range(of: term, options: options) != nil
        }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: term,
                options: options,
                range: searchStart..<text.endIndex
              ) {
            let leadingIsToken = range.lowerBound > text.startIndex
                && isASCIILetterOrDigit(text[text.index(before: range.lowerBound)])
            let trailingIsToken = range.upperBound < text.endIndex
                && isASCIILetterOrDigit(text[range.upperBound])
            if !leadingIsToken && !trailingIsToken { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private func isASCIILetterOrDigit(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (65...90).contains($0.value)
                || (97...122).contains($0.value)
        }
    }

    private func isShortLatinAbbreviation(_ term: String) -> Bool {
        guard (1...3).contains(term.count), term.unicodeScalars.contains(where: { (97...122).contains($0.value) }) else {
            return false
        }
        return term.unicodeScalars.allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) }
    }

    private func makeSnippet(content: String, around term: String) -> String? {
        guard let range = content.range(
            of: term,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) else { return nil }
        let start = content.index(range.lowerBound, offsetBy: -45, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(range.upperBound, offsetBy: 80, limitedBy: content.endIndex) ?? content.endIndex
        let excerpt = content[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return "…\(excerpt.trimmingCharacters(in: .whitespacesAndNewlines))…"
    }
}

public struct FileTextExtractor: Sendable {
    public init() {}

    /// A search index needs representative text, not the method-focused PDF
    /// sampling used for AI analysis. Prefer Spotlight's already-indexed text
    /// and, when it is unavailable, touch only a few representative PDF pages.
    /// This keeps full-text indexing cooperative on machines that are also
    /// running a local model.
    public func searchText(
        for url: URL,
        maximumCharacters: Int = 6_000
    ) -> String {
        guard maximumCharacters > 0 else { return "" }
        if let metadata = metadataText(for: url) {
            return normalizedText(metadata, maximumCharacters: maximumCharacters)
        }

        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let document = PDFDocument(url: url) {
            let count = document.pageCount
            let candidates = [0, 1, count / 2, max(0, count - 2), max(0, count - 1)]
            let indexes = Array(Set(candidates.filter { $0 >= 0 && $0 < count })).sorted()
            let perPageLimit = max(700, maximumCharacters / max(1, indexes.count))
            var value = ""
            for index in indexes {
                if Task.isCancelled { return "" }
                if let pageText = document.page(at: index)?.string {
                    value += String(pageText.prefix(perPageLimit)) + "\n"
                    if value.count >= maximumCharacters { break }
                }
            }
            return normalizedText(value, maximumCharacters: maximumCharacters)
        }

        return text(
            for: url,
            maximumCharacters: maximumCharacters,
            allowOfficeConversion: false
        )
    }

    public func text(
        for url: URL,
        maximumCharacters: Int = 8_000,
        allowOfficeConversion: Bool = true
    ) -> String {
        guard maximumCharacters > 0 else { return "" }
        let ext = url.pathExtension.lowercased()

        if ext == "pdf", let document = PDFDocument(url: url) {
            var value = ""
            let count = document.pageCount
            let scanLimit = min(count, 80)
            var pageTexts: [Int: String] = [:]
            var methodScores: [(index: Int, score: Int)] = []

            for index in 0..<scanLimit {
                guard let pageText = document.page(at: index)?.string, !pageText.isEmpty else { continue }
                pageTexts[index] = pageText
                let searchable = String(pageText.prefix(5_000)).lowercased()
                let heading = String(searchable.prefix(700))
                let keywords = [
                    "method", "approach", "architecture", "framework", "implementation",
                    "training objective", "loss function", "algorithm", "方法", "模型架构",
                    "网络结构", "实现", "训练目标", "损失函数", "推理", "算法"
                ]
                let score = keywords.reduce(0) { partial, keyword in
                    partial
                        + (searchable.contains(keyword) ? 2 : 0)
                        + (heading.contains(keyword) ? 5 : 0)
                }
                if score > 0 { methodScores.append((index, score)) }
            }

            let methodPages = methodScores
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.index < $1.index
                }
                .prefix(5)
                .map(\.index)
            let candidates = [0, 1, 2] + methodPages + [
                count / 2, max(0, count - 2), max(0, count - 1)
            ]
            let pageIndexes = Array(Set(candidates.filter { $0 >= 0 && $0 < count })).sorted()
            let perPageLimit = max(900, maximumCharacters / max(1, pageIndexes.count))
            for index in pageIndexes {
                if let pageText = pageTexts[index] ?? document.page(at: index)?.string {
                    value += "[第 \(index + 1) 页]\n" + String(pageText.prefix(perPageLimit)) + "\n"
                    if value.count >= maximumCharacters { break }
                }
            }
            return normalizedText(value, maximumCharacters: maximumCharacters)
        }

        let plainTextExtensions: Set<String> = [
            "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml", "html", "css", "swift", "m", "mm",
            "h", "c", "cc", "cpp", "py", "rb", "go", "rs", "java", "kt", "js", "jsx", "ts", "tsx", "vue",
            "sql", "sh", "zsh", "yaml", "yml", "toml", "log"
        ]
        if plainTextExtensions.contains(ext),
           let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: min(maximumCharacters * 4, 128_000))) ?? Data()
            return normalizedText(String(decoding: data, as: UTF8.self), maximumCharacters: maximumCharacters)
        }

        let officeExtensions: Set<String> = ["doc", "docx", "pages", "rtf", "rtfd", "odt"]
        if allowOfficeConversion,
           officeExtensions.contains(ext),
           let converted = textUsingTextUtil(for: url) {
            return normalizedText(converted, maximumCharacters: maximumCharacters)
        }

        if let metadataText = metadataText(for: url) {
            return normalizedText(metadataText, maximumCharacters: maximumCharacters)
        }
        return ""
    }

    private func metadataText(for url: URL) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemTextContent) as? String
    }

    private func textUsingTextUtil(for url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func normalizedText(_ text: String, maximumCharacters: Int) -> String {
        let lines = text
            .replacingOccurrences(of: "\u{0000}", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var previousWasEmpty = false
        var normalized: [String] = []
        for line in lines {
            let isEmpty = line.isEmpty
            if isEmpty && previousWasEmpty { continue }
            normalized.append(line)
            previousWasEmpty = isEmpty
        }
        return String(normalized.joined(separator: "\n").prefix(maximumCharacters))
    }
}

public struct SearchIndexBuilder: Sendable {
    private let extractor = FileTextExtractor()
    private let tagger = SmartTagger()

    public init() {}

    public func build(
        libraryRoot: URL,
        pendingItems: [InboxItem],
        history: [RoutingRecord],
        aiAnalyses: [String: OllamaDocumentAnalysis] = [:],
        virtualTags: [String: [SmartTag]] = [:],
        maximumDocuments: Int = 50_000
    ) -> [SearchDocument] {
        buildSnapshot(
            libraryRoot: libraryRoot,
            pendingItems: pendingItems,
            history: history,
            aiAnalyses: aiAnalyses,
            virtualTags: virtualTags,
            maximumDocuments: maximumDocuments,
            includeFileContent: true
        ).documents
    }

    /// Builds the cheap filename/metadata layer immediately and optionally
    /// enriches it with extracted body text. Callers can retain the bounded
    /// identity cache between builds, so changing one label doesn't reopen
    /// thousands of unchanged PDFs.
    public func buildSnapshot(
        libraryRoot: URL,
        pendingItems: [InboxItem],
        history: [RoutingRecord],
        aiAnalyses: [String: OllamaDocumentAnalysis] = [:],
        virtualTags: [String: [SmartTag]] = [:],
        maximumDocuments: Int = 50_000,
        includeFileContent: Bool,
        cachedContent: [SearchContentCacheKey: String] = [:]
    ) -> SearchIndexSnapshot {
        var usedContentCache: [SearchContentCacheKey: String] = [:]

        func indexedFileContent(
            for url: URL,
            fileSize: Int64,
            modificationDate: Date?,
            isRegularFile: Bool
        ) -> String {
            guard isRegularFile else { return "" }
            let key = SearchContentCacheKey(
                url: url,
                fileSize: fileSize,
                modificationDate: modificationDate
            )
            if let cached = cachedContent[key] {
                usedContentCache[key] = cached
                return cached
            }
            guard includeFileContent, !Task.isCancelled else { return "" }
            let extracted = extractor.searchText(for: url)
            usedContentCache[key] = extracted
            return extracted
        }

        var documents: [SearchDocument] = pendingItems.map { item in
            let values = try? item.url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let analysis = aiAnalyses[item.url.standardizedFileURL.path]
            let modificationDate = values?.contentModificationDate ?? item.detectedAt
            let isDirectory = values?.isDirectory == true
            let extractedContent = indexedFileContent(
                for: item.url,
                fileSize: item.fileSize,
                modificationDate: modificationDate,
                isRegularFile: !isDirectory
            )
            let content = [extractedContent, analysis?.summary]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let inferredTags = tagger.tags(
                for: item.url,
                category: item.suggestion.category,
                origin: item.origin,
                contentText: content
            )
            let tags = mergedTags(
                persisted: item.tags + (analysis?.tags ?? []),
                inferred: inferredTags,
                selectedCategory: item.suggestion.category
            )
            return SearchDocument(
                url: item.url,
                category: item.suggestion.category,
                origin: item.origin,
                tags: tags,
                location: .inbox,
                fileSize: item.fileSize,
                modificationDate: modificationDate,
                contentText: content,
                isDirectory: isDirectory
            )
        }

        let activeHistory = history.filter { !$0.isRestored }
        var historyByDestination: [String: RoutingRecord] = [:]
        for record in activeHistory {
            historyByDestination[URL(fileURLWithPath: record.destinationPath).standardizedFileURL.path] = record
        }

        for category in FileCategory.allCases {
            if documents.count >= maximumDocuments { break }
            let categoryRoot = libraryRoot.appendingPathComponent(category.displayName, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: categoryRoot,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if documents.count >= maximumDocuments || Task.isCancelled { break }
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey
                ])
                guard values?.isRegularFile == true || values?.isDirectory == true else { continue }
                let standardizedPath = url.standardizedFileURL.path
                let analysis = aiAnalyses[standardizedPath]
                let record = historyByDestination[standardizedPath]
                let origin = record?.effectiveOrigin ?? .unknown
                let fileSize = Int64(values?.fileSize ?? 0)
                let extractedContent = indexedFileContent(
                    for: url,
                    fileSize: fileSize,
                    modificationDate: values?.contentModificationDate,
                    isRegularFile: values?.isRegularFile == true
                )
                let content = [extractedContent, analysis?.summary]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let inferredTags = tagger.tags(
                    for: url,
                    category: category,
                    origin: origin,
                    contentText: content
                )
                let tags = mergedTags(
                    persisted: (record?.tags ?? []) + (analysis?.tags ?? []) + (virtualTags[standardizedPath] ?? []),
                    inferred: inferredTags,
                    selectedCategory: category
                )
                documents.append(SearchDocument(
                    url: url,
                    category: category,
                    origin: origin,
                    tags: tags,
                    location: .library,
                    fileSize: fileSize,
                    modificationDate: values?.contentModificationDate,
                    contentText: content,
                    isDirectory: values?.isDirectory == true
                ))
            }
        }

        var unique: [String: SearchDocument] = [:]
        for document in documents {
            unique[document.id] = document
        }
        return SearchIndexSnapshot(
            documents: Array(unique.values),
            contentCache: usedContentCache
        )
    }

    /// Combines saved and freshly inferred metadata deterministically while
    /// replacing any category tag saved before the user changed the category.
    private func mergedTags(
        persisted: [SmartTag],
        inferred: [SmartTag],
        selectedCategory: FileCategory
    ) -> [SmartTag] {
        let categoryTagIDs = Set(FileCategory.allCases.map { tagger.categoryTag(for: $0).id })
        let selectedCategoryTag = tagger.categoryTag(for: selectedCategory)
        var seen: Set<String> = []
        var merged: [SmartTag] = []

        for tag in persisted + inferred where !categoryTagIDs.contains(tag.id) {
            if seen.insert(tag.id).inserted {
                merged.append(tag)
            }
        }
        if seen.insert(selectedCategoryTag.id).inserted {
            merged.append(selectedCategoryTag)
        }

        return merged.sorted { lhs, rhs in
            let lhsPriority = tagPriority(lhs.kind)
            let rhsPriority = tagPriority(rhs.kind)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            let valueOrder = lhs.value.localizedStandardCompare(rhs.value)
            if valueOrder != .orderedSame { return valueOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private func tagPriority(_ kind: SmartTagKind) -> Int {
        switch kind {
        case .importance: 0
        case .project: 1
        case .organization: 2
        case .documentType: 3
        case .topic: 4
        case .source: 5
        }
    }
}
