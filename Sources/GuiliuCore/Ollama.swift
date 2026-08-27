import Foundation

public struct OllamaDocumentAnalysis: Codable, Equatable, Sendable {
    public let suggestion: ClassificationSuggestion
    public let tags: [SmartTag]
    public let summary: String?
    public let paperApproach: String?
    public let keyIdea: String?
    public let method: String?
    public let experimentResults: String?
    public let limitations: String?
    public let mainContent: String?
    public let keyPoints: [String]
    public let model: String
    public let analyzedAt: Date

    public init(
        suggestion: ClassificationSuggestion,
        tags: [SmartTag],
        summary: String?,
        paperApproach: String? = nil,
        keyIdea: String? = nil,
        method: String? = nil,
        experimentResults: String? = nil,
        limitations: String? = nil,
        mainContent: String? = nil,
        keyPoints: [String] = [],
        model: String,
        analyzedAt: Date = .now
    ) {
        self.suggestion = suggestion
        self.tags = tags
        self.summary = summary
        self.paperApproach = paperApproach
        self.keyIdea = keyIdea
        self.method = method
        self.experimentResults = experimentResults
        self.limitations = limitations
        self.mainContent = mainContent
        self.keyPoints = keyPoints
        self.model = model
        self.analyzedAt = analyzedAt
    }

    private enum CodingKeys: String, CodingKey {
        case suggestion
        case tags
        case summary
        case paperApproach
        case keyIdea
        case method
        case experimentResults
        case limitations
        case mainContent
        case keyPoints
        case model
        case analyzedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        suggestion = try container.decode(ClassificationSuggestion.self, forKey: .suggestion)
        tags = try container.decode([SmartTag].self, forKey: .tags)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        paperApproach = try container.decodeIfPresent(String.self, forKey: .paperApproach)
        keyIdea = try container.decodeIfPresent(String.self, forKey: .keyIdea)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        experimentResults = try container.decodeIfPresent(String.self, forKey: .experimentResults)
        limitations = try container.decodeIfPresent(String.self, forKey: .limitations)
        mainContent = try container.decodeIfPresent(String.self, forKey: .mainContent)
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        model = try container.decode(String.self, forKey: .model)
        analyzedAt = try container.decode(Date.self, forKey: .analyzedAt)
    }
}

public enum OllamaError: LocalizedError, Equatable {
    case invalidEndpoint
    case unavailable
    case httpStatus(Int, String)
    case invalidResponse
    case modelNotInstalled(String)
    case invalidAnalysis
    case insufficientText

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Ollama 本地 API 地址无效。"
        case .unavailable: "无法连接本机 Ollama；请确认 Ollama 已启动。"
        case .httpStatus(let status, let message): "Ollama 返回错误（\(status)）：\(message)"
        case .invalidResponse: "Ollama 返回了无法识别的响应。"
        case .modelNotInstalled(let model): "本机尚未安装模型 \(model)。"
        case .invalidAnalysis: "模型没有返回有效的分类结果。"
        case .insufficientText: "未能从文件中提取到足够正文，已保留原分析结果。"
        }
    }
}

public struct OllamaClient: Sendable {
    public let baseURL: URL
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 240
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }()

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.baseURL = baseURL
    }

    public func version() async throws -> String {
        struct Response: Decodable { let version: String }
        let data = try await request(path: "/api/version", method: "GET", body: nil, timeout: 8)
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OllamaError.invalidResponse
        }
        return response.version
    }

    /// Asks Ollama to release a resident model immediately. This is used only
    /// after macOS reports critical memory pressure; normal analyses already
    /// send `keep_alive: 0` so the model is not retained after each response.
    public func unload(model: String) async throws {
        let payload: [String: Any] = [
            "model": model,
            "prompt": "",
            "stream": false,
            "keep_alive": 0
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await request(path: "/api/generate", method: "POST", body: body, timeout: 15)
    }

    public func installedModels() async throws -> [String] {
        struct Model: Decodable { let name: String }
        struct Response: Decodable { let models: [Model] }
        let data = try await request(path: "/api/tags", method: "GET", body: nil, timeout: 12)
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OllamaError.invalidResponse
        }
        return response.models.map(\.name)
    }

    public func analyze(
        fileURL: URL,
        origin: FileOrigin,
        fallbackSuggestion: ClassificationSuggestion,
        extractedText: String,
        model: String
    ) async throws -> OllamaDocumentAnalysis {
        let models = try await installedModels()
        guard models.contains(where: { $0 == model || $0.hasPrefix("\(model):") }) else {
            throw OllamaError.modelNotInstalled(model)
        }

        let isResearchPaper = fallbackSuggestion.category == .researchPapers
        let content = isResearchPaper
            ? String(extractedText.prefix(10_000))
            : Self.representativeExcerpt(from: extractedText, maximumCharacters: 3_200)
        let meaningfulCount = content.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.count
        guard meaningfulCount >= 80 else { throw OllamaError.insufficientText }
        if isResearchPaper {
            return try await analyzeResearchPaper(
                fileURL: fileURL,
                origin: origin,
                fallbackSuggestion: fallbackSuggestion,
                content: content,
                model: model
            )
        }

        let allowedCategories = FileCategory.allCases
            .map { "\($0.rawValue)=\($0.displayName)" }
            .joined(separator: ", ")
        let prompt = """
        你是 macOS 本地文件整理助手。请只根据文件名、来源和提供的文档正文判断用途，不要臆造正文中不存在的信息。

        文件名：\(fileURL.lastPathComponent)
        来源：\(origin.displayName)
        规则建议：\(fallbackSuggestion.category.rawValue)（\(fallbackSuggestion.reason)）
        允许的分类（category 必须严格使用等号左侧英文值）：\(allowedCategories)

        要求：
        1. 返回一个最合适的固定分类、0 到 1 的置信度和中文分类依据。
        2. 标签必须保守：project 仅填写正文明确声明的项目正式名称；organization 仅填写明确的作者机构、发布机构或合同主体。禁止把来源 App、浏览器、文件名、分类名、普通主题当成项目或机构。没有可靠证据必须返回空字符串。
        3. document_type 使用简体中文；importance 只能是“重要资料”或空字符串；topics 最多 4 个，使用简体中文，专业英文术语可保留。
        4. main_content 是本次任务的核心，不能为空。请用 5 至 8 句、约 250 至 600 个中文字符，概括这份文档的用途、覆盖的主要主题、各部分之间的关系，以及文档给出的核心结论或主张。不要只复述文件名或分类。
        5. key_points 提取 2 至 6 条真正值得记住的事项。通知、方案、报告优先保留时间、数字、要求、决定和待办；纯叙述文档可提炼关键观点。
        6. 不得补写正文没有提供的数字、机构、项目、结论或待办。细节不足时仍应概括已明确出现的内容，不得把 main_content 留空，也不要解释缺失原因。
        7. reason、document_type、importance、topics、main_content 和 key_points 必须以简体中文为主。专业术语、英文缩写、模块名及正式名称可保留英文。
        8. 输出必须符合 JSON Schema，不要复述这些要求，不要输出额外文字。

        文档代表性正文（从开头、中部和末尾抽取，可能截断）：
        ---
        \(content)
        ---
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "category": ["type": "string", "enum": FileCategory.allCases.map(\.rawValue)],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "reason": ["type": "string"],
                "project": ["type": "string"],
                "organization": ["type": "string"],
                "document_type": ["type": "string"],
                "importance": ["type": "string"],
                "topics": ["type": "array", "items": ["type": "string"], "maxItems": 4],
                "main_content": ["type": "string", "minLength": 80],
                "key_points": [
                    "type": "array",
                    "items": ["type": "string"],
                    "minItems": 2,
                    "maxItems": 6
                ]
            ],
            "required": [
                "category", "confidence", "reason", "project", "organization",
                "document_type", "importance", "topics", "main_content", "key_points"
            ]
        ]
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "你是严谨的中文文档阅读助手。首要任务是让用户快速了解文档讲了什么；分类和标签是次要任务。只输出符合 JSON Schema 的结果。"],
                ["role": "user", "content": prompt]
            ],
            "format": schema,
            "stream": false,
            "think": false,
            // Keep contexts bounded and release model memory after every file.
            "keep_alive": 0,
            "options": ["temperature": 0, "num_ctx": 5_120, "num_predict": 900]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let data = try await request(path: "/api/chat", method: "POST", body: bodyData, timeout: 240)

        struct Message: Decodable { let content: String }
        struct ChatResponse: Decodable { let message: Message }
        guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
              !response.message.content.isEmpty else {
            throw OllamaError.invalidAnalysis
        }
        let analysis = try Self.decodeAnalysisContent(
            response.message.content,
            model: model,
            fileURL: fileURL,
            origin: origin,
            fallbackSuggestion: fallbackSuggestion
        )
        if analysis.suggestion.category == .researchPapers {
            return try await analyzeResearchPaper(
                fileURL: fileURL,
                origin: origin,
                fallbackSuggestion: analysis.suggestion,
                content: String(extractedText.prefix(10_000)),
                model: model
            )
        }
        return Self.ensuringGeneralContent(
            analysis,
            extractedText: extractedText,
            fileURL: fileURL
        )
    }

    private func analyzeResearchPaper(
        fileURL: URL,
        origin: FileOrigin,
        fallbackSuggestion: ClassificationSuggestion,
        content: String,
        model: String
    ) async throws -> OllamaDocumentAnalysis {
        let prompt = """
        你正在阅读一篇已经确认属于科研论文的文档。不要再做通用文档概括，只提炼论文的主要做法。

        论文文件名：\(fileURL.lastPathComponent)

        请完成：
        1. paper_innovation：用 150 至 300 个中文字符说明作者要解决的关键困难、已有方法为什么不够，以及论文真正新增的机制、结构或训练思想。必须点出技术差异，不能只写“提出新框架”。
        2. implementation_steps：按实际数据流或执行顺序写 4 至 7 步，每步 60 至 160 个中文字符，并以简短步骤名开头。尽量覆盖输入与表征、关键模块及职责、模块间的信息传递、监督信号或数据构造、训练目标/损失，以及推理时如何得到结果。
        3. 严禁把实验对比、排行榜、成功率、性能提升、泛泛结论或局限当作实现步骤；只回答方法本身。正文没有提供的细节不得臆造。
        4. project 与 organization 仅在正文明确给出正式名称时填写，否则留空；topics 最多 4 个，用于中文检索，专业术语可保留英文。
        5. 除专业术语、缩写和模块正式名称外，全部使用简体中文。只输出符合 JSON Schema 的结果。

        论文正文（按摘要、引言和方法相关页面抽取，可能截断）：
        ---
        \(content)
        ---
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "project": ["type": "string"],
                "organization": ["type": "string"],
                "topics": ["type": "array", "items": ["type": "string"], "maxItems": 4],
                "paper_innovation": ["type": "string", "minLength": 80],
                "implementation_steps": [
                    "type": "array",
                    "items": ["type": "string"],
                    "minItems": 4,
                    "maxItems": 7
                ]
            ],
            "required": ["project", "organization", "topics", "paper_innovation", "implementation_steps"]
        ]
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "你是严谨的论文方法审阅助手。只解释核心创新与可复述的实现链路，不讨论实验成绩。"],
                ["role": "user", "content": prompt]
            ],
            "format": schema,
            "stream": false,
            "think": false,
            "keep_alive": 0,
            "options": ["temperature": 0, "num_ctx": 5_120, "num_predict": 1_200]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let data = try await request(path: "/api/chat", method: "POST", body: bodyData, timeout: 240)

        struct Message: Decodable { let content: String }
        struct ChatResponse: Decodable { let message: Message }
        struct PaperWireAnalysis: Decodable {
            let project: String
            let organization: String
            let topics: [String]
            let paperInnovation: String
            let implementationSteps: [String]

            enum CodingKeys: String, CodingKey {
                case project, organization, topics
                case paperInnovation = "paper_innovation"
                case implementationSteps = "implementation_steps"
            }
        }

        guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let contentData = response.message.content.data(using: .utf8),
              let wire = try? JSONDecoder().decode(PaperWireAnalysis.self, from: contentData),
              let innovation = Self.cleanedSection(wire.paperInnovation) else {
            throw OllamaError.invalidAnalysis
        }
        let implementationSteps = wire.implementationSteps
            .compactMap(Self.cleanedSection)
            .filter { !Self.isExperimentOnlyStep($0) }
            .prefix(7)
            .map { $0 }
        guard implementationSteps.count >= 3,
              let paperApproach = Self.composedPaperApproach(
                direct: nil,
                innovation: innovation,
                implementationSteps: implementationSteps
              ) else {
            throw OllamaError.invalidAnalysis
        }

        var tags: [SmartTag] = []
        Self.appendValidatedTag(kind: .project, value: wire.project, category: .researchPapers, fileURL: fileURL, origin: origin, to: &tags)
        Self.appendValidatedTag(kind: .organization, value: wire.organization, category: .researchPapers, fileURL: fileURL, origin: origin, to: &tags)
        Self.appendValidatedTag(kind: .documentType, value: "科研论文", category: .researchPapers, fileURL: fileURL, origin: origin, to: &tags)
        for topic in wire.topics.prefix(4) {
            Self.appendValidatedTag(kind: .topic, value: Self.localizedTagValue(topic), category: .researchPapers, fileURL: fileURL, origin: origin, to: &tags)
        }

        return OllamaDocumentAnalysis(
            suggestion: ClassificationSuggestion(
                category: .researchPapers,
                reason: "本地 AI：已根据论文正文提炼核心创新与具体实现",
                confidence: max(fallbackSuggestion.confidence, 0.9)
            ),
            tags: Array(Set(tags)).prefix(8).map { $0 },
            summary: paperApproach,
            paperApproach: paperApproach,
            model: model
        )
    }

    static func decodeAnalysisContent(
        _ content: String,
        model: String,
        fileURL: URL? = nil,
        origin: FileOrigin? = nil,
        fallbackSuggestion: ClassificationSuggestion? = nil
    ) throws -> OllamaDocumentAnalysis {
        struct WireAnalysis: Decodable {
            let category: String
            let confidence: Double
            let reason: String
            let project: String
            let organization: String
            let documentType: String
            let importance: String
            let topics: [String]
            let summary: String?
            let paperApproach: String?
            let paperInnovation: String?
            let implementationSteps: [String]?
            let keyIdea: String?
            let method: String?
            let experimentResults: String?
            let limitations: String?
            let mainContent: String?
            let keyPoints: [String]?

            enum CodingKeys: String, CodingKey {
                case category, confidence, reason, project, organization, importance, topics, summary, method, limitations
                case documentType = "document_type"
                case paperApproach = "paper_approach"
                case paperInnovation = "paper_innovation"
                case implementationSteps = "implementation_steps"
                case keyIdea = "key_idea"
                case experimentResults = "experiments_and_results"
                case mainContent = "main_content"
                case keyPoints = "key_points"
            }
        }

        guard let contentData = content.data(using: .utf8),
              let wire = try? JSONDecoder().decode(WireAnalysis.self, from: contentData),
              let category = FileCategory(rawValue: wire.category) else {
            throw OllamaError.invalidAnalysis
        }

        var tags: [SmartTag] = []
        Self.appendValidatedTag(kind: .project, value: wire.project, category: category, fileURL: fileURL, origin: origin, to: &tags)
        Self.appendValidatedTag(kind: .organization, value: wire.organization, category: category, fileURL: fileURL, origin: origin, to: &tags)
        Self.appendValidatedTag(kind: .documentType, value: Self.localizedTagValue(wire.documentType), category: category, fileURL: fileURL, origin: origin, to: &tags)
        Self.appendValidatedTag(kind: .importance, value: Self.localizedTagValue(wire.importance), category: category, fileURL: fileURL, origin: origin, to: &tags)
        for topic in wire.topics.prefix(4) {
            Self.appendValidatedTag(kind: .topic, value: Self.localizedTagValue(topic), category: category, fileURL: fileURL, origin: origin, to: &tags)
        }

        let paperApproach = Self.composedPaperApproach(
            direct: wire.paperApproach,
            innovation: wire.paperInnovation,
            implementationSteps: wire.implementationSteps ?? []
        )
        let keyIdea = Self.cleanedSection(wire.keyIdea)
        let method = Self.cleanedSection(wire.method)
        let experimentResults = Self.cleanedSection(wire.experimentResults)
        let limitations = Self.cleanedSection(wire.limitations)
        let mainContent = Self.cleanedSection(wire.mainContent)
        let keyPoints = (wire.keyPoints ?? [])
            .compactMap(Self.cleanedSection)
            .prefix(6)
            .map { $0 }
        let fallbackSummary = Self.cleanedSection(wire.summary)
        let synthesizedSummary: String? = if category == .researchPapers {
            paperApproach ?? Self.joinedSummary([keyIdea, method]) ?? fallbackSummary
        } else {
            Self.joinedSummary([mainContent] + keyPoints.map(Optional.some)) ?? fallbackSummary
        }
        let cleanedReason = Self.cleanedSection(wire.reason)
        let shouldUseFallback = wire.confidence < 0.1 || cleanedReason == nil
        return OllamaDocumentAnalysis(
            suggestion: ClassificationSuggestion(
                category: shouldUseFallback ? (fallbackSuggestion?.category ?? category) : category,
                reason: cleanedReason.map { "本地 AI：\(String($0.prefix(120)))" }
                    ?? fallbackSuggestion?.reason
                    ?? "正文信息不足，沿用规则分类",
                confidence: shouldUseFallback
                    ? (fallbackSuggestion?.confidence ?? 0.35)
                    : min(max(wire.confidence, 0), 1)
            ),
            tags: Array(Set(tags)).prefix(8).map { $0 },
            summary: synthesizedSummary.map { String($0.prefix(3_200)) },
            paperApproach: category == .researchPapers ? paperApproach : nil,
            keyIdea: category == .researchPapers ? keyIdea : nil,
            method: category == .researchPapers ? method : nil,
            experimentResults: category == .researchPapers ? experimentResults : nil,
            limitations: category == .researchPapers ? limitations : nil,
            mainContent: category == .researchPapers ? nil : mainContent,
            keyPoints: category == .researchPapers ? [] : keyPoints,
            model: model
        )
    }

    static func ensuringGeneralContent(
        _ analysis: OllamaDocumentAnalysis,
        extractedText: String,
        fileURL: URL
    ) -> OllamaDocumentAnalysis {
        guard analysis.suggestion.category != .researchPapers,
              cleanedSection(analysis.mainContent) == nil,
              cleanedSection(analysis.summary) == nil,
              let fallback = extractiveGeneralSummary(from: extractedText, fileURL: fileURL) else {
            return analysis
        }

        return OllamaDocumentAnalysis(
            suggestion: analysis.suggestion,
            tags: analysis.tags,
            summary: fallback,
            paperApproach: analysis.paperApproach,
            keyIdea: analysis.keyIdea,
            method: analysis.method,
            experimentResults: analysis.experimentResults,
            limitations: analysis.limitations,
            mainContent: fallback,
            keyPoints: analysis.keyPoints,
            model: analysis.model,
            analyzedAt: analysis.analyzedAt
        )
    }

    private static func representativeExcerpt(
        from text: String,
        maximumCharacters: Int
    ) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumCharacters else { return normalized }

        let beginningCount = maximumCharacters / 2
        let middleCount = maximumCharacters / 4
        let endingCount = maximumCharacters - beginningCount - middleCount
        let middleStart = normalized.index(
            normalized.startIndex,
            offsetBy: max(0, normalized.count / 2 - middleCount / 2)
        )
        let middleEnd = normalized.index(middleStart, offsetBy: middleCount, limitedBy: normalized.endIndex) ?? normalized.endIndex
        let endingStart = normalized.index(normalized.endIndex, offsetBy: -endingCount)

        return """
        【文档开头】
        \(normalized.prefix(beginningCount))

        【文档中部】
        \(normalized[middleStart..<middleEnd])

        【文档末尾】
        \(normalized[endingStart...])
        """
    }

    private static func extractiveGeneralSummary(from text: String, fileURL: URL) -> String? {
        let candidates = text
            .components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 10 && !isPlaceholder($0) }
        guard !candidates.isEmpty else { return nil }

        let preferredIndexes = [0, 1, candidates.count / 2, max(0, candidates.count - 2), candidates.count - 1]
        var seen = Set<Int>()
        let selected = preferredIndexes
            .filter { $0 >= 0 && $0 < candidates.count && seen.insert($0).inserted }
            .map { candidates[$0] }
        let body = selected.joined(separator: "；")
        return String("文档《\(fileURL.deletingPathExtension().lastPathComponent)》主要包含以下内容：\(body)。".prefix(800))
    }

    private func request(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw OllamaError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OllamaError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    ?? String(data: data, encoding: .utf8)
                    ?? "未知错误"
                throw OllamaError.httpStatus(http.statusCode, message)
            }
            return data
        } catch let error as OllamaError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OllamaError.unavailable
        }
    }

    private static func appendValidatedTag(
        kind: SmartTagKind,
        value: String,
        category: FileCategory,
        fileURL: URL?,
        origin: FileOrigin?,
        to tags: inout [SmartTag]
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 40 else { return }
        let folded = trimmed.foldingForSearch
        guard !Self.isPlaceholder(trimmed) else { return }
        var forbidden = Set(
            FileOrigin.allCases.flatMap { [$0.rawValue.foldingForSearch, $0.displayName.foldingForSearch] }
                + ["safari", "chrome", "firefox", "edge", "wechat", "微信", "qq", "飞书", "downloads", "下载文件夹"]
                + FileCategory.allCases.map { $0.rawValue.foldingForSearch }
                + (fileURL.map { [$0.lastPathComponent.foldingForSearch, $0.deletingPathExtension().lastPathComponent.foldingForSearch] } ?? [])
        )
        if kind != .organization {
            forbidden.formUnion(FileCategory.allCases.map { $0.displayName.foldingForSearch })
            guard !FileCategory.allCases.contains(where: {
                folded.contains($0.rawValue.foldingForSearch)
                    || folded == $0.displayName.foldingForSearch
            }) else { return }
        }
        if kind != .source, forbidden.contains(folded) { return }
        if let origin, kind == .organization, folded == origin.displayName.foldingForSearch { return }
        if kind == .importance, !["重要资料"].contains(trimmed) { return }
        if kind == .organization, !Self.looksLikeOrganization(trimmed) { return }
        if kind == .project, folded == category.displayName.foldingForSearch { return }
        tags.append(SmartTag(kind: kind, value: trimmed))
    }

    private static func looksLikeOrganization(_ value: String) -> Bool {
        let folded = value.foldingForSearch
        let organizationMarkers = [
            "公司", "集团", "大学", "学院", "研究院", "研究所", "实验室", "委员会", "中心", "协会", "银行", "基金会",
            "university", "institute", "laboratory", " lab", " inc", " ltd", "corp", "corporation", "foundation", "association", "academy"
        ]
        if organizationMarkers.contains(where: { folded.contains($0.foldingForSearch) }) { return true }
        let letters = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return (2...10).contains(letters.count) && letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func cleanedSection(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !isPlaceholder(trimmed) else { return nil }
        return String(trimmed.prefix(1_200))
    }

    private static func cleanedPaperApproach(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !isPlaceholder(trimmed) else { return nil }
        return String(trimmed.prefix(3_200))
    }

    private static func composedPaperApproach(
        direct: String?,
        innovation: String?,
        implementationSteps: [String]
    ) -> String? {
        if let direct = cleanedPaperApproach(direct) { return direct }

        let innovation = cleanedSection(innovation)
        let steps = implementationSteps
            .compactMap(cleanedSection)
            .prefix(7)
            .map { $0 }
        guard innovation != nil || !steps.isEmpty else { return nil }

        var sections: [String] = []
        if let innovation {
            sections.append("核心创新\n\(innovation)")
        }
        if !steps.isEmpty {
            let numbered = steps.enumerated().map { index, step in
                "\(index + 1). \(step)"
            }.joined(separator: "\n")
            sections.append("具体实现\n\(numbered)")
        }
        return String(sections.joined(separator: "\n\n").prefix(3_200))
    }

    private static func isExperimentOnlyStep(_ value: String) -> Bool {
        let folded = value.foldingForSearch
        let leading = String(folded.prefix(24))
        let blockedPrefixes = [
            "实验", "结果", "评估", "性能", "基准测试", "对比实验",
            "experiment", "evaluation", "benchmark", "results"
        ]
        if blockedPrefixes.contains(where: { leading.contains($0.foldingForSearch) }) {
            return true
        }
        let resultMarkers = ["成功率", "准确率", "排行榜", "性能提升", "实验表明", "实验验证"]
        return resultMarkers.contains { folded.contains($0.foldingForSearch) }
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let folded = value.foldingForSearch
        let markers = [
            "当前提取内容未提供", "提取内容未提供", "正文未提供", "内容不足",
            "未能提取", "无法提取", "not provided", "not available", "insufficient content",
            "2 至 4 句说明", "3 至 6 句说明", "4 至 8 句说明", "返回空字符串", "返回空数组"
        ]
        return markers.contains { folded.contains($0.foldingForSearch) }
    }

    private static func joinedSummary(_ sections: [String?]) -> String? {
        let values = sections.compactMap { $0 }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    private static func localizedTagValue(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let translations: [String: String] = [
            "high": "重要资料", "important": "重要资料", "critical": "重要资料",
            "medium": "一般资料", "normal": "一般资料", "low": "低优先级",
            "research paper": "研究论文", "researchpaper": "研究论文", "paper": "研究论文",
            "presentation": "演示文稿", "slides": "演示文稿", "report": "报告",
            "contract": "合同", "manual": "使用手册", "meeting notes": "会议记录",
            "data analysis": "数据分析", "project management": "项目管理"
        ]
        return translations[normalized] ?? value
    }
}
