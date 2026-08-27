import CryptoKit
import Foundation

public struct TrashRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let originalPath: String
    public var trashedPath: String
    public let trashedAt: Date
    public var restoredAt: Date?
    public let sourceID: String
    public let origin: FileOrigin
    public let fileSize: Int64
    public let modificationDate: Date?
    public let resourceIdentifier: String?
    public let contentHash: String?

    public init(
        id: UUID = UUID(),
        originalPath: String,
        trashedPath: String,
        trashedAt: Date = .now,
        restoredAt: Date? = nil,
        sourceID: String,
        origin: FileOrigin,
        fileSize: Int64,
        modificationDate: Date?,
        resourceIdentifier: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.trashedAt = trashedAt
        self.restoredAt = restoredAt
        self.sourceID = sourceID
        self.origin = origin
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.resourceIdentifier = resourceIdentifier
        self.contentHash = contentHash
    }

    public var isRestored: Bool { restoredAt != nil }
}

public struct TrashFileSnapshot: Equatable, Sendable {
    public let size: Int64
    public let modificationDate: Date?
    public let resourceIdentifier: String?
    public let contentHash: String
}

public enum TrashError: LocalizedError, Equatable {
    case appManagedFile
    case unsupportedItem
    case outsideAllowedLocation
    case fileChanged
    case fileMissing
    case trashedFileMissing
    case trashedFileChanged

    public var errorDescription: String? {
        switch self {
        case .appManagedFile:
            "这是微信等 App 管理的原件。归流不会删除它，以免聊天附件失效；你可以选择“忽略”。"
        case .unsupportedItem:
            "文件夹、App 或符号链接不能在收件箱中一键删除，请在访达中确认处理。"
        case .outsideAllowedLocation:
            "文件已经不在原来的受监控目录内，为避免误删，操作已取消。"
        case .fileChanged:
            "文件在进入待归类队列后已发生变化，为避免删除错文件，操作已取消。"
        case .fileMissing:
            "文件已经不存在。"
        case .trashedFileMissing:
            "废纸篓中的文件已经不存在，无法恢复。"
        case .trashedFileChanged:
            "废纸篓中的路径已被其他文件占用，或文件内容已经变化。为避免恢复错文件，操作已取消。"
        }
    }
}

public struct TrashService: Sendable {
    public init() {}

    public func validate(
        item: InboxItem,
        allowedRoot: URL,
        fileManager: FileManager = .default
    ) throws -> TrashFileSnapshot {
        guard item.routingOperation == .move else { throw TrashError.appManagedFile }
        guard fileManager.fileExists(atPath: item.url.path) else { throw TrashError.fileMissing }

        let rootPath = allowedRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let itemPath = item.url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else { throw TrashError.outsideAllowedLocation }

        let snapshot = try snapshot(
            at: item.url,
            fileManager: fileManager,
            missingError: .fileMissing,
            changedError: .fileChanged
        )
        guard snapshot.size == item.fileSize else { throw TrashError.fileChanged }
        if let expectedDate = item.modificationDate,
           snapshot.modificationDate != expectedDate {
            throw TrashError.fileChanged
        }
        if let expectedIdentifier = item.resourceIdentifier,
           snapshot.resourceIdentifier != expectedIdentifier {
            throw TrashError.fileChanged
        }
        return snapshot
    }

    public func trash(item: InboxItem, allowedRoot: URL) throws -> TrashRecord {
        let preTrashSnapshot = try validate(item: item, allowedRoot: allowedRoot)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingURL)
        guard let resultingURL else { throw TrashError.trashedFileMissing }

        let trashedURL = resultingURL as URL
        let trashedSnapshot = try snapshot(
            at: trashedURL,
            fileManager: .default,
            missingError: .trashedFileMissing,
            changedError: .trashedFileChanged
        )
        guard snapshotsReferToSameFile(preTrashSnapshot, trashedSnapshot) else {
            throw TrashError.trashedFileChanged
        }

        return TrashRecord(
            originalPath: item.url.path,
            trashedPath: trashedURL.path,
            sourceID: item.sourceID,
            origin: item.origin,
            fileSize: trashedSnapshot.size,
            modificationDate: trashedSnapshot.modificationDate,
            resourceIdentifier: trashedSnapshot.resourceIdentifier,
            contentHash: trashedSnapshot.contentHash
        )
    }

    public func restore(_ record: TrashRecord) throws -> TrashRecord {
        let trashed = URL(fileURLWithPath: record.trashedPath)
        guard FileManager.default.fileExists(atPath: trashed.path) else { throw TrashError.trashedFileMissing }
        let currentSnapshot = try snapshot(
            at: trashed,
            fileManager: .default,
            missingError: .trashedFileMissing,
            changedError: .trashedFileChanged
        )
        guard snapshot(currentSnapshot, matches: record) else {
            throw TrashError.trashedFileChanged
        }
        let original = URL(fileURLWithPath: record.originalPath)
        let destination = uniqueDestination(for: original.lastPathComponent, in: original.deletingLastPathComponent())
        try FileManager.default.moveItem(at: trashed, to: destination)

        var updated = record
        updated.trashedPath = destination.path
        updated.restoredAt = .now
        return updated
    }

    private func snapshot(
        at url: URL,
        fileManager: FileManager,
        missingError: TrashError,
        changedError: TrashError
    ) throws -> TrashFileSnapshot {
        guard fileManager.fileExists(atPath: url.path) else { throw missingError }
        let before = try metadata(at: url)
        guard let hash = Self.sha256(of: url) else { throw changedError }
        let after = try metadata(at: url)

        guard before == after else { throw changedError }
        return TrashFileSnapshot(
            size: after.size,
            modificationDate: after.modificationDate,
            resourceIdentifier: after.resourceIdentifier,
            contentHash: hash
        )
    }

    private struct FileMetadata: Equatable {
        let size: Int64
        let modificationDate: Date?
        let resourceIdentifier: String?
    }

    private func metadata(at url: URL) throws -> FileMetadata {
        // URL resource values may be cached on the URL instance. Recreate it
        // for every snapshot so path reuse cannot inherit the previous file's
        // resource identifier or modification date.
        let freshURL = URL(fileURLWithPath: url.path)
        let values = try freshURL.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .fileResourceIdentifierKey
        ])
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isPackage != true,
              values.isSymbolicLink != true,
              let currentSize = values.fileSize else {
            throw TrashError.unsupportedItem
        }
        return FileMetadata(
            size: Int64(currentSize),
            modificationDate: values.contentModificationDate,
            resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
        )
    }

    private func snapshotsReferToSameFile(_ first: TrashFileSnapshot, _ second: TrashFileSnapshot) -> Bool {
        guard first.size == second.size,
              first.modificationDate == second.modificationDate,
              first.contentHash == second.contentHash else { return false }
        if let expectedIdentifier = first.resourceIdentifier {
            return second.resourceIdentifier == expectedIdentifier
        }
        return true
    }

    private func snapshot(_ snapshot: TrashFileSnapshot, matches record: TrashRecord) -> Bool {
        // Records without identity snapshots may still be displayed, but they
        // cannot be safely restored from only a reusable path, size and
        // timestamp. A content hash is the minimum proof required here.
        guard let expectedHash = record.contentHash,
              snapshot.size == record.fileSize,
              snapshot.contentHash == expectedHash else { return false }
        if let expectedDate = record.modificationDate,
           snapshot.modificationDate != expectedDate { return false }
        if let expectedIdentifier = record.resourceIdentifier,
           snapshot.resourceIdentifier != expectedIdentifier { return false }
        return true
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: candidate.path) else {
            let url = URL(fileURLWithPath: filename)
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            for index in 2...9_999 {
                let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
                let next = directory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: next.path) { return next }
            }
            let fallback = "\(stem) \(UUID().uuidString)"
            return directory.appendingPathComponent(ext.isEmpty ? fallback : "\(fallback).\(ext)")
        }
        return candidate
    }
}
