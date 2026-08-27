import Foundation

public enum FileOrigin: String, Codable, CaseIterable, Identifiable, Sendable {
    case downloads
    case desktop
    case safari
    case wechat
    case qq
    case feishu
    case customFolder
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .downloads: "下载文件夹"
        case .desktop: "桌面"
        case .safari: "Safari"
        case .wechat: "微信"
        case .qq: "QQ"
        case .feishu: "飞书"
        case .customFolder: "自定义来源"
        case .unknown: "未知来源"
        }
    }

    public var symbolName: String {
        switch self {
        case .downloads: "arrow.down.circle.fill"
        case .desktop: "desktopcomputer"
        case .safari: "safari.fill"
        case .wechat: "message.fill"
        case .qq: "bubble.left.and.bubble.right.fill"
        case .feishu: "paperplane.fill"
        case .customFolder: "folder.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

public enum RoutingOperation: String, Codable, Sendable {
    case move
    case copy
    case reference

    public var actionName: String {
        switch self {
        case .move: "移动"
        case .copy: "复制"
        case .reference: "引用"
        }
    }
}

public struct InboxItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let detectedAt: Date
    public let fileSize: Int64
    public let suggestion: ClassificationSuggestion
    public let origin: FileOrigin
    public let routingOperation: RoutingOperation
    public let sourceID: String
    public let sourceDisplayName: String
    public var tags: [SmartTag]
    public let modificationDate: Date?
    public let resourceIdentifier: String?
    public let resourceIdentifierSession: String?
    public let persistentIdentity: PersistentFileIdentity?
    public let posixIdentity: POSIXFileIdentity?
    public let aiSummary: String?
    public let aiModel: String?
    public let aiAnalyzedAt: Date?

    public init(
        id: UUID = UUID(),
        url: URL,
        detectedAt: Date = .now,
        fileSize: Int64,
        suggestion: ClassificationSuggestion,
        origin: FileOrigin = .unknown,
        routingOperation: RoutingOperation = .move,
        sourceID: String = "unknown-source",
        sourceDisplayName: String = "文件来源",
        tags: [SmartTag] = [],
        modificationDate: Date? = nil,
        resourceIdentifier: String? = nil,
        resourceIdentifierSession: String? = nil,
        persistentIdentity: PersistentFileIdentity? = nil,
        posixIdentity: POSIXFileIdentity? = nil,
        aiSummary: String? = nil,
        aiModel: String? = nil,
        aiAnalyzedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.detectedAt = detectedAt
        self.fileSize = fileSize
        self.suggestion = suggestion
        self.origin = origin
        self.routingOperation = routingOperation
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.tags = tags
        self.modificationDate = modificationDate
        self.resourceIdentifier = resourceIdentifier
        self.resourceIdentifierSession = resourceIdentifierSession
        self.persistentIdentity = persistentIdentity
        self.posixIdentity = posixIdentity
        self.aiSummary = aiSummary
        self.aiModel = aiModel
        self.aiAnalyzedAt = aiAnalyzedAt
    }

    public var fileIdentitySnapshot: FileIdentitySnapshot {
        FileIdentitySnapshot(
            size: fileSize,
            modificationDate: modificationDate,
            resourceIdentifier: resourceIdentifier,
            resourceIdentifierSession: resourceIdentifierSession,
            persistentIdentity: persistentIdentity
        )
    }

    public func replacingFileIdentity(
        with snapshot: FileIdentitySnapshot,
        posixIdentity: POSIXFileIdentity?
    ) -> InboxItem {
        InboxItem(
            id: id,
            url: url,
            detectedAt: detectedAt,
            fileSize: snapshot.size,
            suggestion: suggestion,
            origin: origin,
            routingOperation: routingOperation,
            sourceID: sourceID,
            sourceDisplayName: sourceDisplayName,
            tags: tags,
            modificationDate: snapshot.modificationDate,
            resourceIdentifier: snapshot.resourceIdentifier,
            resourceIdentifierSession: snapshot.resourceIdentifierSession,
            persistentIdentity: snapshot.persistentIdentity,
            posixIdentity: posixIdentity,
            aiSummary: aiSummary,
            aiModel: aiModel,
            aiAnalyzedAt: aiAnalyzedAt
        )
    }

    public func replacingURL(_ newURL: URL) -> InboxItem {
        InboxItem(
            id: id,
            url: newURL,
            detectedAt: detectedAt,
            fileSize: fileSize,
            suggestion: suggestion,
            origin: origin,
            routingOperation: routingOperation,
            sourceID: sourceID,
            sourceDisplayName: sourceDisplayName,
            tags: tags,
            modificationDate: modificationDate,
            resourceIdentifier: resourceIdentifier,
            resourceIdentifierSession: resourceIdentifierSession,
            persistentIdentity: persistentIdentity,
            posixIdentity: posixIdentity,
            aiSummary: aiSummary,
            aiModel: aiModel,
            aiAnalyzedAt: aiAnalyzedAt
        )
    }

    public func applyingAIAnalysis(_ analysis: OllamaDocumentAnalysis, mergedTags: [SmartTag]) -> InboxItem {
        InboxItem(
            id: id,
            url: url,
            detectedAt: detectedAt,
            fileSize: fileSize,
            suggestion: analysis.suggestion,
            origin: origin,
            routingOperation: routingOperation,
            sourceID: sourceID,
            sourceDisplayName: sourceDisplayName,
            tags: mergedTags,
            modificationDate: modificationDate,
            resourceIdentifier: resourceIdentifier,
            resourceIdentifierSession: resourceIdentifierSession,
            persistentIdentity: persistentIdentity,
            posixIdentity: posixIdentity,
            aiSummary: analysis.summary,
            aiModel: analysis.model,
            aiAnalyzedAt: analysis.analyzedAt
        )
    }
}
