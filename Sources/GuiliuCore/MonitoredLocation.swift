import Darwin
import Foundation

/// Describes who owns the file at a monitored location. The operation is
/// intentionally derived from ownership rather than from the App that created
/// the file: a WeChat download in ~/Downloads is user-managed and should move,
/// while a file inside WeChat's private `msg/file` tree remains App-managed and
/// is represented in the library by a lightweight reference.
public enum MonitoredFileOwnership: String, Codable, Hashable, Sendable {
    case userManaged
    case appManagedOriginal

    public var routingOperation: RoutingOperation {
        switch self {
        case .userManaged: .move
        case .appManagedOriginal: .reference
        }
    }

    public var operationDescription: String {
        switch self {
        case .userManaged: "移动归档，不在来源目录保留副本"
        case .appManagedOriginal: "创建引用，不复制 App 管理的原件"
        }
    }
}

public struct MonitoredLocation: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let url: URL
    public let origin: FileOrigin
    public let fileOwnership: MonitoredFileOwnership
    public let recursive: Bool

    public var routingOperation: RoutingOperation { fileOwnership.routingOperation }
    public var operationDescription: String { fileOwnership.operationDescription }

    public init(
        id: String,
        displayName: String,
        url: URL,
        origin: FileOrigin,
        fileOwnership: MonitoredFileOwnership = .userManaged,
        recursive: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.origin = origin
        self.fileOwnership = fileOwnership
        self.recursive = recursive
    }

    /// Whether this source would enumerate a particular file. Non-recursive
    /// user folders (Downloads, QQ and Feishu save folders) only own their
    /// immediate children; App attachment trees may own descendants.
    public func contains(fileURL: URL) -> Bool {
        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = url.standardizedFileURL.resolvingSymlinksInPath()
        if !recursive {
            return file.deletingLastPathComponent().path == directory.path
        }
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return file.path.hasPrefix(prefix)
    }

    /// Resolves a file that is visible through more than one monitor. The most
    /// specific source wins; if two monitors point at the same root, explicit
    /// App ownership wins so an App-managed original can never be moved by an
    /// overlapping configuration.
    public static func preferred(
        for fileURL: URL,
        among locations: [MonitoredLocation]
    ) -> MonitoredLocation? {
        locations
            .filter { $0.contains(fileURL: fileURL) }
            .sorted(by: isPreferred)
            .first
    }

    private static func isPreferred(_ lhs: MonitoredLocation, _ rhs: MonitoredLocation) -> Bool {
        let lhsPath = lhs.url.standardizedFileURL.resolvingSymlinksInPath().path
        let rhsPath = rhs.url.standardizedFileURL.resolvingSymlinksInPath().path
        if lhsPath.count != rhsPath.count {
            return lhsPath.count > rhsPath.count
        }
        if lhs.fileOwnership != rhs.fileOwnership {
            return lhs.fileOwnership == .appManagedOriginal
        }
        return lhs.id < rhs.id
    }

    /// Builds an identifier that remains stable when the discovery order changes
    /// or the app restarts. Swift's `Hasher` is intentionally randomized between
    /// processes, so source identities use a small deterministic FNV-1a digest of
    /// the canonical directory path instead.
    public static func stableSourceID(namespace: String, directoryURL: URL) -> String {
        let canonicalPath = directoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping

        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in canonicalPath.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return "\(namespace)-\(String(format: "%016llx", digest))"
    }
}

public struct FileOriginDetector: Sendable {
    public init() {}

    public func detect(for url: URL, fallback: FileOrigin) -> FileOrigin {
        if [.wechat, .qq, .feishu].contains(fallback) {
            return fallback
        }

        guard let quarantine = quarantineAttribute(for: url) else {
            return fallback
        }
        return Self.parseQuarantineAgent(quarantine) ?? fallback
    }

    public static func parseQuarantineAgent(_ value: String) -> FileOrigin? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        let agent = fields[2].lowercased()

        if agent.contains("wechat") || agent.contains("xinwechat") || agent.contains("微信") {
            return .wechat
        }
        if agent == "qq" || agent.contains("com.tencent.qq") {
            return .qq
        }
        if agent.contains("feishu") || agent.contains("lark") || agent.contains("飞书") {
            return .feishu
        }
        if agent.contains("safari") {
            return .safari
        }
        return nil
    }

    private func quarantineAttribute(for url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { filePath in
            guard let filePath else { return nil }
            let attributeName = "com.apple.quarantine"
            let length = getxattr(filePath, attributeName, nil, 0, 0, 0)
            guard length > 0 else { return nil }

            var bytes = [UInt8](repeating: 0, count: length)
            let result = bytes.withUnsafeMutableBytes { buffer in
                getxattr(filePath, attributeName, buffer.baseAddress, length, 0, 0)
            }
            guard result > 0 else { return nil }
            return String(decoding: bytes.prefix(result), as: UTF8.self)
        }
    }
}
