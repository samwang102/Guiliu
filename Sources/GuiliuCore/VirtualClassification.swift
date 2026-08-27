import Foundation

public enum VirtualFacetSelectionMode: String, Codable, Sendable {
    case single
    case multiple
}

/// A user-facing classification axis that never creates or moves folders.
/// One document can therefore be viewed through several independent axes.
public struct VirtualFacetDimension: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var selectionMode: VirtualFacetSelectionMode
    public var values: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        selectionMode: VirtualFacetSelectionMode = .multiple,
        values: [String] = []
    ) {
        self.id = id
        self.name = name
        self.selectionMode = selectionMode
        self.values = values
    }
}

public enum VirtualFacetDefaults {
    public static let uncategorizedTitle = "尚未分类"
    public static let paperMainQuestionID = "paper-main-question"
    public static let paperDirectionID = "paper-direction"
    public static let paperStageID = "paper-stage"

    public static func isUncategorized(_ assignedValues: [String]) -> Bool {
        assignedValues.isEmpty
    }

    public static func resolvedDimensionID(
        preferred: String?,
        in dimensions: [VirtualFacetDimension]
    ) -> String? {
        if let preferred, dimensions.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return dimensions.first?.id
    }

    public static func dimensions(for category: FileCategory) -> [VirtualFacetDimension] {
        if category == .researchPapers {
            return [
                VirtualFacetDimension(
                    id: paperMainQuestionID,
                    name: "研究主题",
                    selectionMode: .single,
                    values: []
                ),
                VirtualFacetDimension(
                    id: paperDirectionID,
                    name: "研究方法",
                    selectionMode: .multiple,
                    values: []
                ),
                VirtualFacetDimension(
                    id: paperStageID,
                    name: "阅读状态",
                    selectionMode: .single,
                    values: ["待读", "阅读中", "已读"]
                )
            ]
        }

        let name: String
        switch category {
        case .readingMaterials: name = "主题 / 来源"
        case .documentsReports: name = "项目 / 文档类型"
        case .presentations: name = "项目 / 场合"
        case .codeProjects: name = "项目 / 技术栈"
        case .dataModels: name = "项目 / 数据用途"
        case .visualMedia: name = "项目 / 素材用途"
        case .software: name = "用途 / 平台"
        case .recordsForms: name = "用途 / 来源"
        case .organizationMaterials: name = "项目 / 资料类型"
        case .needsReview: name = "临时分组"
        case .researchPapers: name = "研究方向"
        }
        return [VirtualFacetDimension(
            id: "default-\(category.rawValue)",
            name: name,
            selectionMode: .multiple
        )]
    }
}
