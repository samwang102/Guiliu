import Foundation

public enum SmartTagKind: String, Codable, CaseIterable, Sendable {
    case importance
    case project
    case organization
    case documentType
    case topic
    case source

    public var displayName: String {
        switch self {
        case .importance: "重要性"
        case .project: "项目"
        case .organization: "机构"
        case .documentType: "类型"
        case .topic: "主题"
        case .source: "来源"
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .importance: 0
        case .project: 1
        case .organization: 2
        case .documentType: 3
        case .topic: 4
        case .source: 5
        }
    }
}

public struct SmartTag: Codable, Hashable, Identifiable, Sendable {
    public let kind: SmartTagKind
    public let value: String

    public init(kind: SmartTagKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public var id: String { "\(kind.rawValue):\(value.foldingForSearch)" }

    public var displayName: String {
        switch kind {
        case .importance, .documentType, .topic:
            value
        case .project:
            "项目：\(value)"
        case .organization:
            "机构：\(value)"
        case .source:
            "来源：\(value)"
        }
    }
}

/// Generates a deliberately bounded set of local, explainable tags. Dynamic
/// project and organization values are extracted only from names, preventing
/// a document body from creating hundreds of one-off tags.
public struct SmartTagger: Sendable {
    public init() {}

    public func tags(
        for url: URL,
        category: FileCategory,
        origin: FileOrigin,
        contentText: String = ""
    ) -> [SmartTag] {
        let stem = url.deletingPathExtension().lastPathComponent
        let searchable = "\(stem) \(String(contentText.prefix(6_000)))".foldingForSearch
        var tags: [SmartTag] = []

        if let project = firstCapture(
            in: stem,
            patterns: [
                #"(?:项目|课题|project)\s*[:：_\-—]+\s*([\p{L}\p{N}]{2,24})"#,
                #"(?:^|[\s_\-—–【】\[\(（])([\p{L}\p{N}]{2,24})\s*(?:项目|课题)(?:$|[\s_\-—–】\]\)）])"#
            ]
        ) {
            tags.append(SmartTag(kind: .project, value: project))
        }

        if let organization = firstCapture(
            in: stem,
            patterns: [
                #"(?:^|[\s_\-—–【】\[\(（])([\p{L}\p{N}]{2,20}(?:有限责任公司|股份有限公司|有限公司|公司|集团|大学|学院|研究院|实验室))(?:$|[\s_\-—–】\]\)）])"#
            ]
        ) {
            tags.append(SmartTag(kind: .organization, value: organization))
        }

        if containsAny(searchable, [
            "合同", "协议", "保密", "nda", "签署", "已签", "最终版", "final"
        ]) {
            tags.append(SmartTag(kind: .importance, value: "重要资料"))
        }

        let semanticRules: [(keywords: [String], value: String)] = [
            (["合同", "contract", "协议", "agreement", "nda"], "合同"),
            (["会议", "纪要", "meeting", "minutes"], "会议资料"),
            (["周报", "月报", "年报", "总结", "报告", "report"], "报告"),
            (["手册", "指南", "说明书", "manual", "guide"], "手册指南"),
            (["签署", "已签", "signed"], "已签署")
        ]
        for rule in semanticRules where containsAny(searchable, rule.keywords) {
            tags.append(SmartTag(kind: .documentType, value: rule.value))
        }

        tags.append(categoryTag(for: category))
        if ![FileOrigin.downloads, .unknown].contains(origin) {
            tags.append(SmartTag(kind: .source, value: origin.displayName))
        }

        var seen: Set<String> = []
        return tags
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.kind.priority != $1.kind.priority {
                    return $0.kind.priority < $1.kind.priority
                }
                return $0.value.localizedStandardCompare($1.value) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    public func categoryTag(for category: FileCategory) -> SmartTag {
        switch category {
        case .researchPapers: SmartTag(kind: .topic, value: "论文")
        case .readingMaterials: SmartTag(kind: .topic, value: "阅读资料")
        case .documentsReports: SmartTag(kind: .topic, value: "文档报告")
        case .presentations: SmartTag(kind: .documentType, value: "演示文稿")
        case .codeProjects: SmartTag(kind: .topic, value: "代码项目")
        case .dataModels: SmartTag(kind: .topic, value: "数据模型")
        case .visualMedia: SmartTag(kind: .topic, value: "图片媒体")
        case .software: SmartTag(kind: .documentType, value: "软件安装包")
        case .recordsForms: SmartTag(kind: .topic, value: "表单记录")
        case .organizationMaterials: SmartTag(kind: .topic, value: "机构资料")
        case .needsReview: SmartTag(kind: .topic, value: "待确认")
        }
    }

    public func replacingCategoryTag(in tags: [SmartTag], with category: FileCategory) -> [SmartTag] {
        let categoryTagIDs = Set(FileCategory.allCases.map { categoryTag(for: $0).id })
        var result = tags.filter { !categoryTagIDs.contains($0.id) }
        result.append(categoryTag(for: category))
        return Array(Set(result)).sorted {
            if $0.kind.priority != $1.kind.priority {
                return $0.kind.priority < $1.kind.priority
            }
            return $0.value.localizedStandardCompare($1.value) == .orderedAscending
        }
    }

    private func containsAny(_ value: String, _ keywords: [String]) -> Bool {
        keywords.contains { value.contains($0.foldingForSearch) }
    }

    private func firstCapture(in value: String, patterns: [String]) -> String? {
        let range = NSRange(value.startIndex..., in: value)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: value, range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: value) else { continue }
            let result = String(value[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.count >= 2 { return result }
        }
        return nil
    }
}

extension String {
    var foldingForSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}
