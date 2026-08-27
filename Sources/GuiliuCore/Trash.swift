import CryptoKit
import Darwin
import Foundation

public struct TrashRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The durable file-system transaction that produced the current state.
    /// Older history records decode this as `nil`.
    public var transactionID: UUID?
    public let originalPath: String
    public var trashedPath: String
    public let trashedAt: Date
    public var restoredAt: Date?
    public let sourceID: String
    public let origin: FileOrigin
    public let routingRecordID: UUID?
    public let fileSize: Int64
    public let modificationDate: Date?
    public let resourceIdentifier: String?
    /// `fileResourceIdentifier` is process-session scoped on macOS. Persisting
    /// the capture session prevents a volatile identifier from rejecting a
    /// valid restore after relaunch.
    public let resourceIdentifierSession: String?
    public let contentHash: String?
    public let originalReferencePath: String?
    public var trashedReferencePath: String?
    public var restoredReferencePath: String?
    public let referenceIdentity: SymbolicLinkIdentitySnapshot?

    public init(
        id: UUID = UUID(),
        transactionID: UUID? = nil,
        originalPath: String,
        trashedPath: String,
        trashedAt: Date = .now,
        restoredAt: Date? = nil,
        sourceID: String,
        origin: FileOrigin,
        routingRecordID: UUID? = nil,
        fileSize: Int64,
        modificationDate: Date?,
        resourceIdentifier: String? = nil,
        resourceIdentifierSession: String? = nil,
        contentHash: String? = nil,
        originalReferencePath: String? = nil,
        trashedReferencePath: String? = nil,
        restoredReferencePath: String? = nil,
        referenceIdentity: SymbolicLinkIdentitySnapshot? = nil
    ) {
        self.id = id
        self.transactionID = transactionID
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.trashedAt = trashedAt
        self.restoredAt = restoredAt
        self.sourceID = sourceID
        self.origin = origin
        self.routingRecordID = routingRecordID
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.resourceIdentifier = resourceIdentifier
        self.resourceIdentifierSession = resourceIdentifierSession
        self.contentHash = contentHash
        self.originalReferencePath = originalReferencePath
        self.trashedReferencePath = trashedReferencePath
        self.restoredReferencePath = restoredReferencePath
        self.referenceIdentity = referenceIdentity
    }

    public var isRestored: Bool { restoredAt != nil }
    public var includesArchivedReference: Bool {
        originalReferencePath != nil && trashedReferencePath != nil && referenceIdentity != nil
    }
}

public struct TrashFileSnapshot: Equatable, Sendable {
    public let size: Int64
    public let modificationDate: Date?
    public let resourceIdentifier: String?
    public let contentHash: String
}

public struct ReferenceTrashResult: Sendable {
    public let record: TrashRecord
    public let trashedReferenceURL: URL

    public init(record: TrashRecord, trashedReferenceURL: URL) {
        self.record = record
        self.trashedReferenceURL = trashedReferenceURL
    }
}

public enum TrashError: LocalizedError, Equatable {
    case appManagedFile
    case unsupportedItem
    case outsideAllowedLocation
    case fileChanged
    case fileMissing
    case trashedFileMissing
    case trashedFileChanged
    case referenceRollbackFailed(String)
    case trashRollbackFailed(String)
    case restoreRollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appManagedFile:
            "这是 App 管理的原件。请从它的待归类条目，或经过验证的归档引用执行删除。"
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
        case .referenceRollbackFailed(let path):
            "原件未被删除，但引用无法自动放回。引用仍保留在废纸篓：\(path)"
        case .trashRollbackFailed(let path):
            "删除未完成，文件也无法自动放回原位。可恢复文件保留在：\(path)"
        case .restoreRollbackFailed(let paths):
            "恢复未完整完成，自动回滚也遇到冲突。请在这些位置核对文件：\(paths)"
        }
    }
}

/// Startup replay output. Completed transactions are deliberately returned as
/// full journals rather than only records so the caller can apply delete and
/// restore history mutations differently and idempotently.
public struct TrashTransactionRecoveryResult: Sendable {
    public let completedTransactions: [FileTransaction]
    public let rolledBackTransactionIDs: [UUID]
    public let attentionMessages: [String]
    public let loadIssues: [FileTransactionLoadIssue]

    public init(
        completedTransactions: [FileTransaction],
        rolledBackTransactionIDs: [UUID],
        attentionMessages: [String],
        loadIssues: [FileTransactionLoadIssue]
    ) {
        self.completedTransactions = completedTransactions
        self.rolledBackTransactionIDs = rolledBackTransactionIDs
        self.attentionMessages = attentionMessages
        self.loadIssues = loadIssues
    }
}

public struct TrashService: Sendable {
    private let trashItemHandler: @Sendable (URL) throws -> URL
    private let afterValidationBeforeStaging: (@Sendable (URL) throws -> Void)?
    private let transactionStore: FileTransactionStore?

    public init(transactionStore: FileTransactionStore? = nil) {
        self.transactionStore = transactionStore
        afterValidationBeforeStaging = nil
        trashItemHandler = { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            guard let resultingURL else { throw TrashError.trashedFileMissing }
            return resultingURL as URL
        }
    }

    init(
        trashItemHandler: @escaping @Sendable (URL) throws -> URL,
        afterValidationBeforeStaging: (@Sendable (URL) throws -> Void)? = nil,
        transactionStore: FileTransactionStore? = nil
    ) {
        self.transactionStore = transactionStore
        self.trashItemHandler = trashItemHandler
        self.afterValidationBeforeStaging = afterValidationBeforeStaging
    }

    public func validate(
        item: InboxItem,
        allowedRoot: URL,
        allowAppManagedOriginal: Bool = false,
        fileManager: FileManager = .default
    ) throws -> TrashFileSnapshot {
        guard item.routingOperation == .move
                || (allowAppManagedOriginal && item.routingOperation == .reference) else {
            throw TrashError.appManagedFile
        }
        guard fileManager.fileExists(atPath: item.url.path) else { throw TrashError.fileMissing }

        let rootPath = allowedRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let itemPath = item.url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else { throw TrashError.outsideAllowedLocation }

        let currentIdentity: FileIdentitySnapshot
        do {
            currentIdentity = try FileIdentitySnapshot.capture(at: item.url, fileManager: fileManager)
        } catch FileIdentityError.missing {
            throw TrashError.fileMissing
        } catch {
            throw TrashError.unsupportedItem
        }
        guard currentIdentity.matches(
            expectedSize: item.fileSize,
            expectedModificationDate: item.modificationDate,
            expectedResourceIdentifier: item.resourceIdentifier,
            expectedResourceIdentifierSession: item.resourceIdentifierSession,
            expectedPersistentIdentity: item.persistentIdentity
        ) else {
            throw TrashError.fileChanged
        }

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
           item.resourceIdentifierSession == FileIdentitySnapshot.currentResourceIdentifierSession,
           snapshot.resourceIdentifier != expectedIdentifier {
            throw TrashError.fileChanged
        }
        return snapshot
    }

    public func trash(
        item: InboxItem,
        allowedRoot: URL,
        allowAppManagedOriginal: Bool = false,
        expectedPOSIXIdentity: POSIXFileIdentity? = nil
    ) throws -> TrashRecord {
        let beforePOSIXIdentity = try POSIXFileIdentity.captureRegularFile(at: item.url)
        if expectedPOSIXIdentity == nil,
           item.persistentIdentity == nil,
           !(item.resourceIdentifier != nil
                && item.resourceIdentifierSession == FileIdentitySnapshot.currentResourceIdentifierSession) {
            throw TrashError.fileChanged
        }
        if let expectedPOSIXIdentity, beforePOSIXIdentity != expectedPOSIXIdentity {
            throw TrashError.fileChanged
        }
        let preTrashSnapshot = try validate(
            item: item,
            allowedRoot: allowedRoot,
            allowAppManagedOriginal: allowAppManagedOriginal
        )
        let authorizedPOSIXIdentity = expectedPOSIXIdentity ?? beforePOSIXIdentity
        guard try POSIXFileIdentity.captureRegularFile(at: item.url)
                == authorizedPOSIXIdentity else {
            throw TrashError.fileChanged
        }
        let originalURL = item.url.standardizedFileURL
        var transaction = try transactionStore?.create(
            operation: .deleteSingle,
            originalURL: originalURL,
            expectedOriginalIdentity: authorizedPOSIXIdentity
        )
        let stagingURL = transaction.map { URL(fileURLWithPath: $0.originalStagingPath) }
            ?? deletionStagingURL(for: originalURL)
        var recoveryURL: URL?
        var reachedTrashHandler = false
        do {
            guard !pathExistsWithoutFollowingSymbolicLink(stagingURL) else {
                throw TrashError.fileChanged
            }
            try afterValidationBeforeStaging?(originalURL)
            try FileManager.default.moveItem(at: originalURL, to: stagingURL)
            recoveryURL = stagingURL
            try advance(&transaction, to: .originalStaged)

            guard try POSIXFileIdentity.captureRegularFile(at: stagingURL)
                    == authorizedPOSIXIdentity else {
                throw TrashError.fileChanged
            }
            let stagedSnapshot = try snapshot(
                at: stagingURL,
                fileManager: .default,
                missingError: .fileMissing,
                changedError: .fileChanged
            )
            guard snapshotsReferToSameFile(preTrashSnapshot, stagedSnapshot) else {
                throw TrashError.fileChanged
            }

            let trashedURL = try trashItemHandler(stagingURL)
            reachedTrashHandler = true
            recoveryURL = trashedURL
            try advance(&transaction, to: .originalTrashCommitted) {
                $0.actualOriginalTrashPath = trashedURL.standardizedFileURL.path
            }
            let trashedSnapshot = try snapshot(
                at: trashedURL,
                fileManager: .default,
                missingError: .trashedFileMissing,
                changedError: .trashedFileChanged
            )
            guard snapshotsReferToSameFile(preTrashSnapshot, trashedSnapshot),
                  try POSIXFileIdentity.captureRegularFile(at: trashedURL)
                    == authorizedPOSIXIdentity else {
                throw TrashError.trashedFileChanged
            }

            let record = TrashRecord(
                transactionID: transaction?.id,
                originalPath: originalURL.path,
                trashedPath: trashedURL.path,
                sourceID: item.sourceID,
                origin: item.origin,
                fileSize: trashedSnapshot.size,
                modificationDate: trashedSnapshot.modificationDate,
                resourceIdentifier: trashedSnapshot.resourceIdentifier,
                resourceIdentifierSession: trashedSnapshot.resourceIdentifier == nil
                    ? nil
                    : FileIdentitySnapshot.currentResourceIdentifierSession,
                contentHash: trashedSnapshot.contentHash
            )
            try advance(&transaction, to: .fileSystemCompleted) {
                $0.trashRecord = record
            }
            return record
        } catch {
            if let recoveryURL,
               pathExistsWithoutFollowingSymbolicLink(recoveryURL) {
                let identityMatches = (try? POSIXFileIdentity.captureRegularFile(at: recoveryURL))
                    == authorizedPOSIXIdentity
                // Before the Trash handler, this is the exact path entry that
                // this call just staged. Moving it back preserves even a
                // replacement injected in the validation/staging race window.
                guard (!reachedTrashHandler || identityMatches),
                      !pathExistsWithoutFollowingSymbolicLink(originalURL) else {
                    markNeedsAttention(
                        transaction,
                        message: "删除回滚未完成：\(recoveryURL.path)"
                    )
                    throw TrashError.trashRollbackFailed(recoveryURL.path)
                }
                do {
                    try FileManager.default.moveItem(at: recoveryURL, to: originalURL)
                } catch {
                    markNeedsAttention(
                        transaction,
                        message: "删除回滚未完成：\(recoveryURL.path)"
                    )
                    throw TrashError.trashRollbackFailed(recoveryURL.path)
                }
            } else if !pathExistsWithoutFollowingSymbolicLink(originalURL) {
                let unresolvedPath = recoveryURL?.path ?? originalURL.path
                markNeedsAttention(
                    transaction,
                    message: "删除结果位置未知，需要人工核对：\(unresolvedPath)"
                )
                throw TrashError.trashRollbackFailed(unresolvedPath)
            }
            markAborted(transaction)
            throw error
        }
    }

    /// Moves a verified library reference and its App-managed original to the
    /// system Trash as one recoverable record. The reference is moved first;
    /// if the original fails validation or cannot be trashed, the reference is
    /// moved back without overwriting anything.
    public func trashReferenceAndOriginal(
        referenceURL: URL,
        referenceRoot: URL,
        expectedReferenceIdentity: SymbolicLinkIdentitySnapshot,
        originalItem: InboxItem,
        originalRoot: URL,
        expectedOriginalPOSIXIdentity: POSIXFileIdentity,
        routingRecordID: UUID? = nil
    ) throws -> ReferenceTrashResult {
        try validateOrdinaryDirectory(referenceRoot)
        try validateOrdinaryDirectory(originalRoot)

        let normalizedReference = referenceURL.standardizedFileURL
        guard normalizedReference.deletingLastPathComponent().path
                == referenceRoot.standardizedFileURL.path else {
            throw TrashError.outsideAllowedLocation
        }
        guard expectedReferenceIdentity.destinationPath
                == originalItem.url.standardizedFileURL.path else {
            throw TrashError.fileChanged
        }
        guard try SymbolicLinkIdentitySnapshot.capture(at: normalizedReference)
                == expectedReferenceIdentity else {
            throw TrashError.fileChanged
        }
        guard try POSIXFileIdentity.captureRegularFile(at: originalItem.url)
                == expectedOriginalPOSIXIdentity else {
            throw TrashError.fileChanged
        }
        let preTrashSnapshot = try validate(
            item: originalItem,
            allowedRoot: originalRoot,
            allowAppManagedOriginal: true
        )

        // Recheck both objects immediately before the first mutation.
        guard try SymbolicLinkIdentitySnapshot.capture(at: normalizedReference)
                == expectedReferenceIdentity,
              try POSIXFileIdentity.captureRegularFile(at: originalItem.url)
                == expectedOriginalPOSIXIdentity else {
            throw TrashError.fileChanged
        }
        let normalizedOriginal = originalItem.url.standardizedFileURL
        var transaction = try transactionStore?.create(
            operation: .deleteReferencePair,
            originalURL: normalizedOriginal,
            referenceURL: normalizedReference,
            expectedOriginalIdentity: expectedOriginalPOSIXIdentity,
            expectedReferenceIdentity: expectedReferenceIdentity
        )
        let referenceStagingURL = transaction?.referenceStagingPath.map(URL.init(fileURLWithPath:))
            ?? deletionStagingURL(for: normalizedReference)
        let originalStagingURL = transaction.map { URL(fileURLWithPath: $0.originalStagingPath) }
            ?? deletionStagingURL(for: normalizedOriginal)
        var referenceRecoveryURL: URL?
        var originalRecoveryURL: URL?
        var originalReachedTrashHandler = false
        do {
            guard !pathExistsWithoutFollowingSymbolicLink(referenceStagingURL),
                  !pathExistsWithoutFollowingSymbolicLink(originalStagingURL) else {
                throw TrashError.fileChanged
            }

            try FileManager.default.moveItem(at: normalizedReference, to: referenceStagingURL)
            referenceRecoveryURL = referenceStagingURL
            try advance(&transaction, to: .referenceStaged)
            guard try SymbolicLinkIdentitySnapshot.capture(at: referenceStagingURL)
                    == expectedReferenceIdentity else {
                throw TrashError.fileChanged
            }

            let trashedReferenceURL = try trashItemHandler(referenceStagingURL)
            referenceRecoveryURL = trashedReferenceURL
            try advance(&transaction, to: .referenceTrashCommitted) {
                $0.actualReferenceTrashPath = trashedReferenceURL.standardizedFileURL.path
            }
            guard try SymbolicLinkIdentitySnapshot.capture(at: trashedReferenceURL)
                    == expectedReferenceIdentity else {
                throw TrashError.trashedFileChanged
            }
            guard try POSIXFileIdentity.captureRegularFile(at: normalizedOriginal)
                    == expectedOriginalPOSIXIdentity else {
                throw TrashError.fileChanged
            }

            try afterValidationBeforeStaging?(normalizedOriginal)
            try FileManager.default.moveItem(at: normalizedOriginal, to: originalStagingURL)
            originalRecoveryURL = originalStagingURL
            try advance(&transaction, to: .originalStaged)
            guard try POSIXFileIdentity.captureRegularFile(at: originalStagingURL)
                    == expectedOriginalPOSIXIdentity else {
                throw TrashError.fileChanged
            }
            let stagedSnapshot = try snapshot(
                at: originalStagingURL,
                fileManager: .default,
                missingError: .fileMissing,
                changedError: .fileChanged
            )
            guard snapshotsReferToSameFile(preTrashSnapshot, stagedSnapshot) else {
                throw TrashError.fileChanged
            }

            let trashedOriginalURL = try trashItemHandler(originalStagingURL)
            originalReachedTrashHandler = true
            originalRecoveryURL = trashedOriginalURL
            try advance(&transaction, to: .originalTrashCommitted) {
                $0.actualOriginalTrashPath = trashedOriginalURL.standardizedFileURL.path
            }
            let trashedSnapshot = try snapshot(
                at: trashedOriginalURL,
                fileManager: .default,
                missingError: .trashedFileMissing,
                changedError: .trashedFileChanged
            )
            guard snapshotsReferToSameFile(preTrashSnapshot, trashedSnapshot),
                  try POSIXFileIdentity.captureRegularFile(at: trashedOriginalURL)
                    == expectedOriginalPOSIXIdentity else {
                throw TrashError.trashedFileChanged
            }

            let combinedRecord = TrashRecord(
                transactionID: transaction?.id,
                originalPath: normalizedOriginal.path,
                trashedPath: trashedOriginalURL.path,
                sourceID: originalItem.sourceID,
                origin: originalItem.origin,
                routingRecordID: routingRecordID,
                fileSize: trashedSnapshot.size,
                modificationDate: trashedSnapshot.modificationDate,
                resourceIdentifier: trashedSnapshot.resourceIdentifier,
                resourceIdentifierSession: trashedSnapshot.resourceIdentifier == nil
                    ? nil
                    : FileIdentitySnapshot.currentResourceIdentifierSession,
                contentHash: trashedSnapshot.contentHash,
                originalReferencePath: normalizedReference.path,
                trashedReferencePath: trashedReferenceURL.path,
                referenceIdentity: expectedReferenceIdentity
            )
            try advance(&transaction, to: .fileSystemCompleted) {
                $0.trashRecord = combinedRecord
            }
            return ReferenceTrashResult(
                record: combinedRecord,
                trashedReferenceURL: trashedReferenceURL
            )
        } catch {
            var rollbackFailures: [String] = []
            if let originalRecoveryURL,
               pathExistsWithoutFollowingSymbolicLink(originalRecoveryURL) {
                let identityMatches = (try? POSIXFileIdentity.captureRegularFile(
                    at: originalRecoveryURL
                )) == expectedOriginalPOSIXIdentity
                if (!originalReachedTrashHandler || identityMatches),
                   !pathExistsWithoutFollowingSymbolicLink(normalizedOriginal) {
                    do {
                        try FileManager.default.moveItem(
                            at: originalRecoveryURL,
                            to: normalizedOriginal
                        )
                    } catch {
                        rollbackFailures.append(originalRecoveryURL.path)
                    }
                } else {
                    rollbackFailures.append(originalRecoveryURL.path)
                }
            } else if !pathExistsWithoutFollowingSymbolicLink(normalizedOriginal) {
                rollbackFailures.append(normalizedOriginal.path)
            }

            if let referenceRecoveryURL,
               pathExistsWithoutFollowingSymbolicLink(referenceRecoveryURL) {
                do {
                    guard !pathExistsWithoutFollowingSymbolicLink(normalizedReference),
                          try SymbolicLinkIdentitySnapshot.capture(
                            at: referenceRecoveryURL,
                            requireRegularFileTarget: false
                          ) == expectedReferenceIdentity else {
                        throw TrashError.referenceRollbackFailed(referenceRecoveryURL.path)
                    }
                    try FileManager.default.moveItem(
                        at: referenceRecoveryURL,
                        to: normalizedReference
                    )
                } catch {
                    rollbackFailures.append(referenceRecoveryURL.path)
                }
            } else if !pathExistsWithoutFollowingSymbolicLink(normalizedReference) {
                rollbackFailures.append(normalizedReference.path)
            }

            if !rollbackFailures.isEmpty {
                let paths = rollbackFailures.joined(separator: "、")
                markNeedsAttention(transaction, message: "成对删除回滚未完成：\(paths)")
                if rollbackFailures.count == 1,
                   rollbackFailures[0] == referenceRecoveryURL?.path {
                    throw TrashError.referenceRollbackFailed(rollbackFailures[0])
                }
                throw TrashError.trashRollbackFailed(paths)
            }
            markAborted(transaction)
            throw error
        }
    }

    public func restore(_ record: TrashRecord) throws -> TrashRecord {
        let trashed = URL(fileURLWithPath: record.trashedPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: trashed.path) else { throw TrashError.trashedFileMissing }
        let trashedPOSIXIdentity = try POSIXFileIdentity.captureRegularFile(at: trashed)
        let currentSnapshot = try snapshot(
            at: trashed,
            fileManager: .default,
            missingError: .trashedFileMissing,
            changedError: .trashedFileChanged
        )
        guard snapshot(currentSnapshot, matches: record) else {
            throw TrashError.trashedFileChanged
        }

        let pairedReference: (
            original: URL,
            trashed: URL,
            identity: SymbolicLinkIdentitySnapshot
        )?
        if record.originalReferencePath == nil,
           record.trashedReferencePath == nil,
           record.referenceIdentity == nil {
            pairedReference = nil
        } else {
            guard let originalReferencePath = record.originalReferencePath,
                  let trashedReferencePath = record.trashedReferencePath,
                  let referenceIdentity = record.referenceIdentity else {
                throw TrashError.trashedFileChanged
            }
            let originalReference = URL(fileURLWithPath: originalReferencePath).standardizedFileURL
            let trashedReference = URL(fileURLWithPath: trashedReferencePath).standardizedFileURL
            try validateOrdinaryDirectory(originalReference.deletingLastPathComponent())
            guard try SymbolicLinkIdentitySnapshot.capture(
                at: trashedReference,
                requireRegularFileTarget: false
            ) == referenceIdentity else {
                throw TrashError.trashedFileChanged
            }
            pairedReference = (originalReference, trashedReference, referenceIdentity)
        }

        let original = URL(fileURLWithPath: record.originalPath).standardizedFileURL
        let destination = uniqueDestination(
            for: original.lastPathComponent,
            in: original.deletingLastPathComponent()
        )
        let referenceDestination = pairedReference.map {
            uniqueDestination(
                for: $0.original.lastPathComponent,
                in: $0.original.deletingLastPathComponent()
            )
        }
        var transaction = try transactionStore?.create(
            operation: pairedReference == nil ? .restoreSingle : .restoreReferencePair,
            originalURL: original,
            referenceURL: pairedReference?.original,
            actualOriginalTrashURL: trashed,
            actualReferenceTrashURL: pairedReference?.trashed,
            originalRestoreDestinationURL: destination,
            referenceRestoreDestinationURL: referenceDestination,
            expectedOriginalIdentity: trashedPOSIXIdentity,
            expectedReferenceIdentity: pairedReference?.identity
        )
        let originalStagingURL = transaction.map { URL(fileURLWithPath: $0.originalStagingPath) }
            ?? deletionStagingURL(for: original)
        let referenceStagingURL = transaction?.referenceStagingPath.map(URL.init(fileURLWithPath:))
            ?? pairedReference.map { deletionStagingURL(for: $0.original) }
        let replacementReferenceStagingURL = pairedReference.map { pair in
            transaction.map { transaction in
                FileTransaction.stagingURL(
                    transactionID: transaction.id,
                    role: "restored-reference",
                    adjacentTo: pair.original
                )
            } ?? deletionStagingURL(for: pair.original)
        }
        var restoredReferenceIdentity: SymbolicLinkIdentitySnapshot?
        var preservesOldReferenceInStaging = false
        var createdReplacementReference = false

        do {
            guard !pathExistsWithoutFollowingSymbolicLink(originalStagingURL),
                  referenceStagingURL.map({ !pathExistsWithoutFollowingSymbolicLink($0) }) ?? true,
                  replacementReferenceStagingURL.map({
                    !pathExistsWithoutFollowingSymbolicLink($0)
                  }) ?? true else {
                throw TrashError.trashedFileChanged
            }

            try FileManager.default.moveItem(at: trashed, to: originalStagingURL)
            try advance(&transaction, to: .originalStaged)
            guard try POSIXFileIdentity.captureRegularFile(at: originalStagingURL)
                    == trashedPOSIXIdentity else {
                throw TrashError.trashedFileChanged
            }
            let stagedSnapshot = try snapshot(
                at: originalStagingURL,
                fileManager: .default,
                missingError: .trashedFileMissing,
                changedError: .trashedFileChanged
            )
            guard snapshot(stagedSnapshot, matches: record) else {
                throw TrashError.trashedFileChanged
            }
            try FileManager.default.moveItem(at: originalStagingURL, to: destination)
            guard try POSIXFileIdentity.captureRegularFile(at: destination)
                    == trashedPOSIXIdentity else {
                throw TrashError.trashedFileChanged
            }
            try advance(&transaction, to: .originalRestoreCommitted)

            var updated = record
            updated.transactionID = transaction?.id
            updated.trashedPath = destination.path

            if let pairedReference,
               let referenceDestination,
               let referenceStagingURL {
                if pairedReference.identity.destinationPath == destination.path {
                    try FileManager.default.moveItem(
                        at: pairedReference.trashed,
                        to: referenceStagingURL
                    )
                    try advance(&transaction, to: .referenceStaged)
                    guard try SymbolicLinkIdentitySnapshot.capture(at: referenceStagingURL)
                            == pairedReference.identity else {
                        throw TrashError.trashedFileChanged
                    }
                    try FileManager.default.moveItem(
                        at: referenceStagingURL,
                        to: referenceDestination
                    )
                    guard try SymbolicLinkIdentitySnapshot.capture(at: referenceDestination)
                            == pairedReference.identity else {
                        throw TrashError.trashedFileChanged
                    }
                } else {
                    guard let replacementReferenceStagingURL else {
                        throw TrashError.trashedFileChanged
                    }
                    try FileManager.default.createSymbolicLink(
                        at: replacementReferenceStagingURL,
                        withDestinationURL: destination
                    )
                    createdReplacementReference = true
                    restoredReferenceIdentity = try SymbolicLinkIdentitySnapshot.capture(
                        at: replacementReferenceStagingURL
                    )
                    try advance(&transaction, to: .referenceStaged) {
                        $0.restoredReferenceIdentity = restoredReferenceIdentity
                    }
                    try FileManager.default.moveItem(
                        at: replacementReferenceStagingURL,
                        to: referenceDestination
                    )
                    guard try SymbolicLinkIdentitySnapshot.capture(at: referenceDestination)
                            == restoredReferenceIdentity else {
                        throw TrashError.trashedFileChanged
                    }
                    try FileManager.default.moveItem(
                        at: pairedReference.trashed,
                        to: referenceStagingURL
                    )
                    preservesOldReferenceInStaging = true
                    guard try SymbolicLinkIdentitySnapshot.capture(
                        at: referenceStagingURL,
                        requireRegularFileTarget: false
                    ) == pairedReference.identity else {
                        throw TrashError.trashedFileChanged
                    }
                }
                try advance(&transaction, to: .referenceRestoreCommitted)
                updated.restoredReferencePath = referenceDestination.path
            }

            updated.restoredAt = .now
            try advance(&transaction, to: .fileSystemCompleted) {
                $0.trashRecord = updated
            }

            // For a renamed original, the old link is retained as a verified
            // rollback backup until the completed journal is durable.
            if preservesOldReferenceInStaging,
               let referenceStagingURL {
                do {
                    try FileManager.default.removeItem(at: referenceStagingURL)
                } catch {
                    markNeedsAttention(
                        transaction,
                        message: "恢复已完成，但旧引用暂存副本需要清理：\(referenceStagingURL.path)"
                    )
                }
            }
            return updated
        } catch {
            var rollbackFailurePaths: [String] = []

            if let pairedReference,
               let referenceDestination,
               let referenceStagingURL {
                if let restoredReferenceIdentity {
                    for candidate in [referenceDestination, replacementReferenceStagingURL].compactMap({ $0 }) {
                        guard pathExistsWithoutFollowingSymbolicLink(candidate) else { continue }
                        if (try? SymbolicLinkIdentitySnapshot.capture(
                            at: candidate,
                            requireRegularFileTarget: false
                        )) == restoredReferenceIdentity {
                            do { try FileManager.default.removeItem(at: candidate) }
                            catch { rollbackFailurePaths.append(candidate.path) }
                        } else {
                            rollbackFailurePaths.append(candidate.path)
                        }
                    }
                } else if createdReplacementReference,
                          let replacementReferenceStagingURL,
                          pathExistsWithoutFollowingSymbolicLink(
                            replacementReferenceStagingURL
                          ) {
                    do {
                        try FileManager.default.removeItem(
                            at: replacementReferenceStagingURL
                        )
                    } catch {
                        rollbackFailurePaths.append(replacementReferenceStagingURL.path)
                    }
                }

                if pathExistsWithoutFollowingSymbolicLink(referenceStagingURL) {
                    do {
                        guard !pathExistsWithoutFollowingSymbolicLink(pairedReference.trashed),
                              try SymbolicLinkIdentitySnapshot.capture(
                                at: referenceStagingURL,
                                requireRegularFileTarget: false
                              ) == pairedReference.identity else {
                            throw TrashError.trashedFileChanged
                        }
                        try FileManager.default.moveItem(
                            at: referenceStagingURL,
                            to: pairedReference.trashed
                        )
                    } catch {
                        rollbackFailurePaths.append(referenceStagingURL.path)
                    }
                } else if pathExistsWithoutFollowingSymbolicLink(referenceDestination),
                          (try? SymbolicLinkIdentitySnapshot.capture(
                            at: referenceDestination,
                            requireRegularFileTarget: false
                          )) == pairedReference.identity {
                    do {
                        guard !pathExistsWithoutFollowingSymbolicLink(pairedReference.trashed) else {
                            throw TrashError.trashedFileChanged
                        }
                        try FileManager.default.moveItem(
                            at: referenceDestination,
                            to: pairedReference.trashed
                        )
                    } catch {
                        rollbackFailurePaths.append(referenceDestination.path)
                    }
                } else if !pathExistsWithoutFollowingSymbolicLink(pairedReference.trashed) {
                    rollbackFailurePaths.append(pairedReference.trashed.path)
                }
            }

            let originalCandidates = [destination, originalStagingURL]
            if !pathExistsWithoutFollowingSymbolicLink(trashed) {
                if let candidate = originalCandidates.first(where: {
                    pathExistsWithoutFollowingSymbolicLink($0)
                        && (try? POSIXFileIdentity.captureRegularFile(at: $0))
                            == trashedPOSIXIdentity
                }) {
                    do { try FileManager.default.moveItem(at: candidate, to: trashed) }
                    catch { rollbackFailurePaths.append(candidate.path) }
                } else {
                    rollbackFailurePaths.append(trashed.path)
                }
            }

            if !rollbackFailurePaths.isEmpty {
                let paths = rollbackFailurePaths.joined(separator: "、")
                markNeedsAttention(transaction, message: "恢复回滚未完成：\(paths)")
                throw TrashError.restoreRollbackFailed(paths)
            }
            markAborted(transaction)
            throw error
        }
    }

    /// Reconciles durable file-operation journals before monitors begin. A
    /// completed journal is returned for idempotent history replay. Every
    /// partial journal is rolled back to its pre-operation layout only when all
    /// path entries still match the identities captured before the operation.
    public func recoverInterruptedTransactions() throws -> TrashTransactionRecoveryResult {
        guard let transactionStore else {
            return TrashTransactionRecoveryResult(
                completedTransactions: [],
                rolledBackTransactionIDs: [],
                attentionMessages: [],
                loadIssues: []
            )
        }

        let loaded = try transactionStore.loadAll()
        var completed: [FileTransaction] = []
        var rolledBack: [UUID] = []
        var attention: [String] = loaded.issues.map {
            "文件操作日志无法读取：\($0.filename)"
        }

        for transaction in loaded.transactions {
            if transaction.phase == .aborted { continue }

            if transaction.phase == .fileSystemCompleted
                || transaction.phase == .historyApplied {
                guard transaction.trashRecord != nil else {
                    let message = "事务 \(transaction.id.uuidString) 已完成，但缺少历史记录。"
                    _ = try? transactionStore.markNeedsAttention(
                        id: transaction.id,
                        message: message
                    )
                    attention.append(message)
                    continue
                }
                if let cleanupMessage = cleanupCompletedRestoreBackup(transaction) {
                    _ = try? transactionStore.markNeedsAttention(
                        id: transaction.id,
                        message: cleanupMessage
                    )
                    attention.append(cleanupMessage)
                } else if transaction.needsAttention,
                          let message = transaction.attentionMessage {
                    if isResolvedRestoreBackupAttention(transaction) {
                        do {
                            _ = try transactionStore.clearNeedsAttention(id: transaction.id)
                        } catch {
                            attention.append("旧引用暂存已清理，但无法清除事务告警：\(message)")
                        }
                    } else {
                        attention.append(message)
                    }
                }
                if transaction.phase == .fileSystemCompleted {
                    completed.append(transaction)
                }
                continue
            }

            do {
                try rollbackInterrupted(transaction)
                _ = try transactionStore.markAborted(id: transaction.id)
                rolledBack.append(transaction.id)
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                let message = "事务 \(transaction.id.uuidString) 无法安全自动回滚：\(detail)"
                _ = try? transactionStore.markNeedsAttention(
                    id: transaction.id,
                    message: message
                )
                attention.append(message)
            }
        }

        do {
            _ = try transactionStore.pruneTerminalTransactions()
        } catch {
            attention.append("无法清理旧的终态文件操作日志：\(error.localizedDescription)")
        }

        return TrashTransactionRecoveryResult(
            completedTransactions: completed,
            rolledBackTransactionIDs: rolledBack,
            attentionMessages: attention,
            loadIssues: loaded.issues
        )
    }

    private func rollbackInterrupted(_ transaction: FileTransaction) throws {
        switch transaction.operation {
        case .deleteSingle:
            try restoreRegularObject(
                expectedIdentity: transaction.expectedOriginalIdentity,
                destination: URL(fileURLWithPath: transaction.originalPath),
                knownCandidates: regularDeleteCandidates(transaction),
                transaction: transaction
            )

        case .deleteReferencePair:
            // Restore the target first so the reference never becomes a
            // dangling visible entry during recovery.
            try restoreRegularObject(
                expectedIdentity: transaction.expectedOriginalIdentity,
                destination: URL(fileURLWithPath: transaction.originalPath),
                knownCandidates: regularDeleteCandidates(transaction),
                transaction: transaction
            )
            guard let referencePath = transaction.referencePath,
                  let expectedReferenceIdentity = transaction.expectedReferenceIdentity else {
                throw TransactionRecoveryFailure("引用事务字段不完整。")
            }
            try restoreReferenceObject(
                expectedIdentity: expectedReferenceIdentity,
                destination: URL(fileURLWithPath: referencePath),
                knownCandidates: referenceDeleteCandidates(transaction),
                transaction: transaction
            )

        case .restoreSingle:
            guard let trashPath = transaction.actualOriginalTrashPath else {
                throw TransactionRecoveryFailure("恢复事务缺少废纸篓路径。")
            }
            try restoreRegularObject(
                expectedIdentity: transaction.expectedOriginalIdentity,
                destination: URL(fileURLWithPath: trashPath),
                knownCandidates: regularRestoreCandidates(transaction),
                transaction: nil
            )

        case .restoreReferencePair:
            guard let trashPath = transaction.actualOriginalTrashPath,
                  let referenceTrashPath = transaction.actualReferenceTrashPath,
                  let expectedReferenceIdentity = transaction.expectedReferenceIdentity else {
                throw TransactionRecoveryFailure("成对恢复事务字段不完整。")
            }

            try removeInterruptedRestoredReference(transaction)
            try restoreReferenceObject(
                expectedIdentity: expectedReferenceIdentity,
                destination: URL(fileURLWithPath: referenceTrashPath),
                knownCandidates: referenceRestoreCandidates(transaction),
                transaction: nil
            )
            try restoreRegularObject(
                expectedIdentity: transaction.expectedOriginalIdentity,
                destination: URL(fileURLWithPath: trashPath),
                knownCandidates: regularRestoreCandidates(transaction),
                transaction: nil
            )
        }
    }

    private func restoreRegularObject(
        expectedIdentity: POSIXFileIdentity,
        destination: URL,
        knownCandidates: [URL],
        transaction: FileTransaction?
    ) throws {
        let normalizedDestination = destination.standardizedFileURL
        var candidates = deduplicatedURLs([normalizedDestination] + knownCandidates)
        if let transaction {
            candidates += discoverTrashCandidates(
                stagingPath: transaction.originalStagingPath,
                adjacentTo: URL(fileURLWithPath: transaction.originalPath)
            )
            candidates = deduplicatedURLs(candidates)
        }

        if pathExistsWithoutFollowingSymbolicLink(normalizedDestination),
           (try? POSIXFileIdentity.captureRegularFile(at: normalizedDestination))
                != expectedIdentity {
            throw TransactionRecoveryFailure(
                "目标路径已被其他文件占用：\(normalizedDestination.path)"
            )
        }
        for candidate in knownCandidates where
            pathExistsWithoutFollowingSymbolicLink(candidate)
                && (try? POSIXFileIdentity.captureRegularFile(at: candidate)) != expectedIdentity {
            throw TransactionRecoveryFailure("事务暂存路径已被复用：\(candidate.path)")
        }

        let matches = candidates.filter {
            pathExistsWithoutFollowingSymbolicLink($0)
                && (try? POSIXFileIdentity.captureRegularFile(at: $0)) == expectedIdentity
        }
        guard matches.count == 1, let source = matches.first else {
            throw TransactionRecoveryFailure(
                matches.isEmpty ? "找不到经过身份验证的原件。" : "同一身份出现在多个路径。"
            )
        }
        if source.path != normalizedDestination.path {
            guard !pathExistsWithoutFollowingSymbolicLink(normalizedDestination) else {
                throw TransactionRecoveryFailure(
                    "目标路径已被占用：\(normalizedDestination.path)"
                )
            }
            try FileManager.default.moveItem(at: source, to: normalizedDestination)
            guard try POSIXFileIdentity.captureRegularFile(at: normalizedDestination)
                    == expectedIdentity else {
                throw TransactionRecoveryFailure("原件回滚后的身份不一致。")
            }
        }
    }

    private func restoreReferenceObject(
        expectedIdentity: SymbolicLinkIdentitySnapshot,
        destination: URL,
        knownCandidates: [URL],
        transaction: FileTransaction?
    ) throws {
        let normalizedDestination = destination.standardizedFileURL
        var candidates = deduplicatedURLs([normalizedDestination] + knownCandidates)
        if let transaction,
           let referenceStagingPath = transaction.referenceStagingPath,
           let referencePath = transaction.referencePath {
            candidates += discoverTrashCandidates(
                stagingPath: referenceStagingPath,
                adjacentTo: URL(fileURLWithPath: referencePath)
            )
            candidates = deduplicatedURLs(candidates)
        }

        if pathExistsWithoutFollowingSymbolicLink(normalizedDestination),
           (try? SymbolicLinkIdentitySnapshot.capture(
            at: normalizedDestination,
            requireRegularFileTarget: false
           )) != expectedIdentity {
            throw TransactionRecoveryFailure(
                "引用目标路径已被其他项目占用：\(normalizedDestination.path)"
            )
        }
        for candidate in knownCandidates where pathExistsWithoutFollowingSymbolicLink(candidate) {
            guard (try? SymbolicLinkIdentitySnapshot.capture(
                at: candidate,
                requireRegularFileTarget: false
            )) == expectedIdentity else {
                throw TransactionRecoveryFailure("引用暂存路径已被复用：\(candidate.path)")
            }
        }

        let matches = candidates.filter {
            pathExistsWithoutFollowingSymbolicLink($0)
                && (try? SymbolicLinkIdentitySnapshot.capture(
                    at: $0,
                    requireRegularFileTarget: false
                )) == expectedIdentity
        }
        guard matches.count == 1, let source = matches.first else {
            throw TransactionRecoveryFailure(
                matches.isEmpty ? "找不到经过身份验证的引用。" : "引用身份出现在多个路径。"
            )
        }
        if source.path != normalizedDestination.path {
            guard !pathExistsWithoutFollowingSymbolicLink(normalizedDestination) else {
                throw TransactionRecoveryFailure(
                    "引用目标路径已被占用：\(normalizedDestination.path)"
                )
            }
            try FileManager.default.moveItem(at: source, to: normalizedDestination)
            guard try SymbolicLinkIdentitySnapshot.capture(
                at: normalizedDestination,
                requireRegularFileTarget: false
            ) == expectedIdentity else {
                throw TransactionRecoveryFailure("引用回滚后的身份不一致。")
            }
        }
    }

    private func removeInterruptedRestoredReference(_ transaction: FileTransaction) throws {
        guard let restoredIdentity = transaction.restoredReferenceIdentity else {
            let unjournaledCandidate = replacementReferenceStagingURL(for: transaction)
            if let unjournaledCandidate,
               pathExistsWithoutFollowingSymbolicLink(unjournaledCandidate) {
                throw TransactionRecoveryFailure(
                    "存在尚未记录身份的新引用：\(unjournaledCandidate.path)"
                )
            }
            return
        }
        let candidates = [
            transaction.referenceRestoreDestinationPath.map(URL.init(fileURLWithPath:)),
            replacementReferenceStagingURL(for: transaction)
        ].compactMap { $0 }
        for candidate in candidates where pathExistsWithoutFollowingSymbolicLink(candidate) {
            guard (try? SymbolicLinkIdentitySnapshot.capture(
                at: candidate,
                requireRegularFileTarget: false
            )) == restoredIdentity else {
                throw TransactionRecoveryFailure(
                    "新引用路径已发生变化：\(candidate.path)"
                )
            }
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private func cleanupCompletedRestoreBackup(_ transaction: FileTransaction) -> String? {
        guard transaction.operation == .restoreReferencePair,
              let stagingPath = transaction.referenceStagingPath,
              let identity = transaction.expectedReferenceIdentity else { return nil }
        let stagingURL = URL(fileURLWithPath: stagingPath)
        guard pathExistsWithoutFollowingSymbolicLink(stagingURL) else { return nil }
        guard (try? SymbolicLinkIdentitySnapshot.capture(
            at: stagingURL,
            requireRegularFileTarget: false
        )) == identity else {
            return "恢复完成后的旧引用暂存路径已变化：\(stagingURL.path)"
        }
        do {
            try FileManager.default.removeItem(at: stagingURL)
            return nil
        } catch {
            return "无法清理恢复完成后的旧引用暂存副本：\(stagingURL.path)"
        }
    }

    private func isResolvedRestoreBackupAttention(_ transaction: FileTransaction) -> Bool {
        guard transaction.operation == .restoreReferencePair,
              let message = transaction.attentionMessage else { return false }
        return message.contains("旧引用暂存")
    }

    private func regularDeleteCandidates(_ transaction: FileTransaction) -> [URL] {
        [
            URL(fileURLWithPath: transaction.originalStagingPath),
            transaction.actualOriginalTrashPath.map(URL.init(fileURLWithPath:))
        ].compactMap { $0 }
    }

    private func referenceDeleteCandidates(_ transaction: FileTransaction) -> [URL] {
        [
            transaction.referenceStagingPath.map(URL.init(fileURLWithPath:)),
            transaction.actualReferenceTrashPath.map(URL.init(fileURLWithPath:))
        ].compactMap { $0 }
    }

    private func regularRestoreCandidates(_ transaction: FileTransaction) -> [URL] {
        [
            URL(fileURLWithPath: transaction.originalStagingPath),
            transaction.originalRestoreDestinationPath.map(URL.init(fileURLWithPath:))
        ].compactMap { $0 }
    }

    private func referenceRestoreCandidates(_ transaction: FileTransaction) -> [URL] {
        [
            transaction.referenceStagingPath.map(URL.init(fileURLWithPath:)),
            transaction.referenceRestoreDestinationPath.map(URL.init(fileURLWithPath:))
        ].compactMap { $0 }
    }

    private func replacementReferenceStagingURL(for transaction: FileTransaction) -> URL? {
        guard let referencePath = transaction.referencePath else { return nil }
        return FileTransaction.stagingURL(
            transactionID: transaction.id,
            role: "restored-reference",
            adjacentTo: URL(fileURLWithPath: referencePath)
        )
    }

    private func discoverTrashCandidates(stagingPath: String, adjacentTo original: URL) -> [URL] {
        let stagingName = URL(fileURLWithPath: stagingPath).lastPathComponent
        let stagingStem = URL(fileURLWithPath: stagingName).deletingPathExtension().lastPathComponent
        let stagingExtension = URL(fileURLWithPath: stagingName).pathExtension
        var directories = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        ]
        if let volumeURL = nearestExistingAncestorVolumeURL(for: original) {
            directories.append(
                volumeURL.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
            )
        }
        var candidates: [URL] = []
        for directory in deduplicatedURLs(directories) {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            ) else { continue }
            candidates += children.filter {
                let child = $0.lastPathComponent
                if child == stagingName { return true }
                let childURL = URL(fileURLWithPath: child)
                return childURL.pathExtension == stagingExtension
                    && childURL.deletingPathExtension().lastPathComponent
                        .hasPrefix(stagingStem + " ")
            }
        }
        return candidates
    }

    /// Resolves the volume from the nearest path entry that still exists. The
    /// transaction's original/reference itself is normally absent after a
    /// crash, especially on external volumes, so querying it directly is not
    /// reliable.
    func nearestExistingAncestorVolumeURL(for url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while true {
            if pathExistsWithoutFollowingSymbolicLink(candidate),
               let values = try? candidate.resourceValues(forKeys: [.volumeURLKey]),
               let volume = values.volume {
                return volume.standardizedFileURL
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap {
            let url = $0.standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    private func advance(
        _ transaction: inout FileTransaction?,
        to phase: FileTransactionPhase,
        update: (inout FileTransaction) -> Void = { _ in }
    ) throws {
        guard var value = transaction, let transactionStore else { return }
        update(&value)
        value.phase = phase
        value.updatedAt = .now
        try transactionStore.save(value)
        transaction = value
    }

    private func markAborted(_ transaction: FileTransaction?) {
        guard let transaction, let transactionStore else { return }
        _ = try? transactionStore.markAborted(id: transaction.id)
    }

    private func markNeedsAttention(_ transaction: FileTransaction?, message: String) {
        guard let transaction, let transactionStore else { return }
        _ = try? transactionStore.markNeedsAttention(id: transaction.id, message: message)
    }

    private struct TransactionRecoveryFailure: LocalizedError {
        let detail: String

        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
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
           record.resourceIdentifierSession
                == FileIdentitySnapshot.currentResourceIdentifierSession,
           snapshot.resourceIdentifier != expectedIdentifier { return false }
        return true
    }

    private func deletionStagingURL(for originalURL: URL) -> URL {
        let ext = originalURL.pathExtension
        let baseName = "归流待恢复-\(UUID().uuidString)"
        let filename = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        return originalURL.deletingLastPathComponent().appendingPathComponent(filename)
    }

    private func validateOrdinaryDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.standardizedFileURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw TrashError.outsideAllowedLocation
        }
    }

    private func pathExistsWithoutFollowingSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
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
        guard !pathExistsWithoutFollowingSymbolicLink(candidate) else {
            let url = URL(fileURLWithPath: filename)
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            for index in 2...9_999 {
                let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
                let next = directory.appendingPathComponent(name)
                if !pathExistsWithoutFollowingSymbolicLink(next) { return next }
            }
            let fallback = "\(stem) \(UUID().uuidString)"
            return directory.appendingPathComponent(ext.isEmpty ? fallback : "\(fallback).\(ext)")
        }
        return candidate
    }
}
