import Foundation

/// A deliberately finite set of generic physical destinations. Recommendations
/// may choose one of these values, but they can never invent a new directory.
public enum FileCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case researchPapers
    case readingMaterials
    case documentsReports
    case presentations
    case codeProjects
    case dataModels
    case visualMedia
    case software
    case recordsForms
    case organizationMaterials
    case needsReview

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .researchPapers: "科研论文"
        case .readingMaterials: "阅读资料"
        case .documentsReports: "文档与报告"
        case .presentations: "演示与汇报"
        case .codeProjects: "代码与项目"
        case .dataModels: "数据与模型"
        case .visualMedia: "图片与媒体"
        case .software: "软件与安装包"
        case .recordsForms: "表单与记录"
        case .organizationMaterials: "机构资料"
        case .needsReview: "待整理"
        }
    }

    public var symbolName: String {
        switch self {
        case .researchPapers: "doc.text.magnifyingglass"
        case .readingMaterials: "books.vertical.fill"
        case .documentsReports: "doc.badge.ellipsis"
        case .presentations: "rectangle.on.rectangle.angled"
        case .codeProjects: "chevron.left.forwardslash.chevron.right"
        case .dataModels: "externaldrive.fill.badge.timemachine"
        case .visualMedia: "photo.on.rectangle.angled"
        case .software: "shippingbox.fill"
        case .recordsForms: "list.clipboard.fill"
        case .organizationMaterials: "building.2.crop.circle.fill"
        case .needsReview: "tray.full.fill"
        }
    }
}
