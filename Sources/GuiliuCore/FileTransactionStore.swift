import Darwin
import Foundation

/// The high-level file-system operation protected by a transaction journal.
public enum FileTransactionOperation: String, Codable, CaseIterable, Sendable {
    case deleteSingle
    case deleteReferencePair
    case restoreSingle
    case restoreReferencePair

    public var includesReference: Bool {
        self == .deleteReferencePair || self == .restoreReferencePair
    }

    public var isRestore: Bool {
        self == .restoreSingle || self == .restoreReferencePair
    }
}

/// Durable checkpoints used by delete and restore recovery code.
///
/// A phase is only advanced after the corresponding file-system operation is
/// durable. `historyApplied` is the final checkpoint and is written by
/// `FileTransactionStore.markHistoryApplied`.
public enum FileTransactionPhase: String, Codable, CaseIterable, Sendable {
    case prepared
    case referenceStaged
    case originalStaged
    case referenceTrashCommitted
    case originalTrashCommitted
    case originalRestoreCommitted
    case referenceRestoreCommitted
    case fileSystemCompleted
    case historyApplied
    case aborted
}

/// A crash-recovery journal for one logical file operation.
///
/// Staging paths are deterministic functions of the transaction identifier,
/// role and original parent directory. This lets recovery code locate a staged
/// object even if a crash occurs immediately before the next journal write.
public struct FileTransaction: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let operation: FileTransactionOperation
    public var phase: FileTransactionPhase
    public let createdAt: Date
    public var updatedAt: Date

    public let originalPath: String
    public let referencePath: String?
    public let originalStagingPath: String
    public let referenceStagingPath: String?

    /// The path actually returned by the Trash API. For restore operations it
    /// is supplied when the transaction is created; for deletes it is filled
    /// after the Trash API succeeds.
    public var actualOriginalTrashPath: String?
    public var actualReferenceTrashPath: String?

    /// The concrete destinations selected for a restore. They may differ from
    /// the historical paths when recovery resolves a same-name conflict.
    public var originalRestoreDestinationPath: String?
    public var referenceRestoreDestinationPath: String?

    public let expectedOriginalIdentity: POSIXFileIdentity
    public let expectedReferenceIdentity: SymbolicLinkIdentitySnapshot?
    /// Identity of a newly-created restored reference when its destination had
    /// to change. It is persisted while the replacement is still staged so a
    /// crash recovery never has to remove an unverified symbolic link.
    public var restoredReferenceIdentity: SymbolicLinkIdentitySnapshot?

    public var trashRecord: TrashRecord?
    public var historyAppliedAt: Date?
    public var needsAttention: Bool
    public var attentionMessage: String?

    public init(
        id: UUID = UUID(),
        operation: FileTransactionOperation,
        phase: FileTransactionPhase = .prepared,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        originalURL: URL,
        referenceURL: URL? = nil,
        actualOriginalTrashURL: URL? = nil,
        actualReferenceTrashURL: URL? = nil,
        originalRestoreDestinationURL: URL? = nil,
        referenceRestoreDestinationURL: URL? = nil,
        expectedOriginalIdentity: POSIXFileIdentity,
        expectedReferenceIdentity: SymbolicLinkIdentitySnapshot? = nil,
        restoredReferenceIdentity: SymbolicLinkIdentitySnapshot? = nil,
        trashRecord: TrashRecord? = nil,
        historyAppliedAt: Date? = nil,
        needsAttention: Bool = false,
        attentionMessage: String? = nil
    ) throws {
        let normalizedOriginalURL = try Self.normalizedAbsoluteURL(originalURL)
        let normalizedReferenceURL = try referenceURL.map(Self.normalizedAbsoluteURL)
        let normalizedOriginalTrashURL = try actualOriginalTrashURL.map(Self.normalizedAbsoluteURL)
        let normalizedReferenceTrashURL = try actualReferenceTrashURL.map(Self.normalizedAbsoluteURL)
        let normalizedOriginalRestoreURL = try originalRestoreDestinationURL.map(
            Self.normalizedAbsoluteURL
        )
        let normalizedReferenceRestoreURL = try referenceRestoreDestinationURL.map(
            Self.normalizedAbsoluteURL
        )

        if operation.includesReference {
            guard let normalizedReferenceURL, let expectedReferenceIdentity else {
                throw FileTransactionStoreError.invalidTransaction(
                    "A reference-pair transaction requires a reference path and identity."
                )
            }
            guard expectedReferenceIdentity.destinationPath == normalizedOriginalURL.path else {
                throw FileTransactionStoreError.invalidTransaction(
                    "The expected reference destination must equal the original path."
                )
            }
            if operation.isRestore,
               (normalizedOriginalTrashURL == nil || normalizedReferenceTrashURL == nil) {
                throw FileTransactionStoreError.invalidTransaction(
                    "A reference-pair restore requires both Trash paths."
                )
            }
            if !operation.isRestore,
               (normalizedOriginalRestoreURL != nil || normalizedReferenceRestoreURL != nil) {
                throw FileTransactionStoreError.invalidTransaction(
                    "Only restore transactions can contain restore destinations."
                )
            }
            self.referencePath = normalizedReferenceURL.path
            self.referenceStagingPath = Self.stagingURL(
                transactionID: id,
                role: "reference",
                adjacentTo: normalizedReferenceURL
            ).path
        } else {
            guard normalizedReferenceURL == nil,
                  normalizedReferenceTrashURL == nil,
                  expectedReferenceIdentity == nil else {
                throw FileTransactionStoreError.invalidTransaction(
                    "A single-file transaction cannot contain reference fields."
                )
            }
            if operation.isRestore, normalizedOriginalTrashURL == nil {
                throw FileTransactionStoreError.invalidTransaction(
                    "A single-file restore requires its Trash path."
                )
            }
            guard normalizedReferenceRestoreURL == nil else {
                throw FileTransactionStoreError.invalidTransaction(
                    "A single-file transaction cannot contain a reference restore destination."
                )
            }
            if !operation.isRestore, normalizedOriginalRestoreURL != nil {
                throw FileTransactionStoreError.invalidTransaction(
                    "A delete transaction cannot contain a restore destination."
                )
            }
            self.referencePath = nil
            self.referenceStagingPath = nil
        }

        if historyAppliedAt != nil, phase != .historyApplied {
            throw FileTransactionStoreError.invalidTransaction(
                "A history timestamp requires the history-applied phase."
            )
        }
        if phase == .historyApplied, historyAppliedAt == nil {
            throw FileTransactionStoreError.invalidTransaction(
                "The history-applied phase requires a timestamp."
            )
        }
        if attentionMessage != nil, !needsAttention {
            throw FileTransactionStoreError.invalidTransaction(
                "An attention message requires needsAttention to be true."
            )
        }

        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.operation = operation
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        originalPath = normalizedOriginalURL.path
        originalStagingPath = Self.stagingURL(
            transactionID: id,
            role: "original",
            adjacentTo: normalizedOriginalURL
        ).path
        actualOriginalTrashPath = normalizedOriginalTrashURL?.path
        actualReferenceTrashPath = normalizedReferenceTrashURL?.path
        originalRestoreDestinationPath = normalizedOriginalRestoreURL?.path
        referenceRestoreDestinationPath = normalizedReferenceRestoreURL?.path
        self.expectedOriginalIdentity = expectedOriginalIdentity
        self.expectedReferenceIdentity = expectedReferenceIdentity
        self.restoredReferenceIdentity = restoredReferenceIdentity
        self.trashRecord = trashRecord
        self.historyAppliedAt = historyAppliedAt
        self.needsAttention = needsAttention
        self.attentionMessage = attentionMessage
    }

    /// Returns the deterministic, same-directory staging URL for a role.
    public static func stagingURL(
        transactionID: UUID,
        role: String,
        adjacentTo url: URL
    ) -> URL {
        let identifier = transactionID.uuidString.lowercased()
        return url.deletingLastPathComponent().appendingPathComponent(
            ".guiliu-transaction-\(identifier)-\(role).staging"
        )
    }

    fileprivate func validated() throws -> FileTransaction {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FileTransactionStoreError.unsupportedSchema(schemaVersion)
        }
        let originalURL = try Self.normalizedAbsoluteURL(URL(fileURLWithPath: originalPath))
        guard originalURL.path == originalPath,
              originalStagingPath == Self.stagingURL(
                transactionID: id,
                role: "original",
                adjacentTo: originalURL
              ).path else {
            throw FileTransactionStoreError.invalidTransaction(
                "The original or staging path is invalid."
            )
        }

        if operation.includesReference {
            guard let referencePath,
                  let referenceStagingPath,
                  let expectedReferenceIdentity else {
                throw FileTransactionStoreError.invalidTransaction(
                    "The reference-pair fields are incomplete."
                )
            }
            let referenceURL = try Self.normalizedAbsoluteURL(URL(fileURLWithPath: referencePath))
            guard referenceURL.path == referencePath,
                  referenceStagingPath == Self.stagingURL(
                    transactionID: id,
                    role: "reference",
                    adjacentTo: referenceURL
                  ).path,
                  expectedReferenceIdentity.destinationPath == originalPath else {
                throw FileTransactionStoreError.invalidTransaction(
                    "The reference or staging path is invalid."
                )
            }
            if operation.isRestore,
               (actualOriginalTrashPath == nil || actualReferenceTrashPath == nil) {
                throw FileTransactionStoreError.invalidTransaction(
                    "The restore Trash paths are incomplete."
                )
            }
            if !operation.isRestore,
               (originalRestoreDestinationPath != nil || referenceRestoreDestinationPath != nil) {
                throw FileTransactionStoreError.invalidTransaction(
                    "A delete transaction contains restore destinations."
                )
            }
        } else {
            guard referencePath == nil,
                  referenceStagingPath == nil,
                  actualReferenceTrashPath == nil,
                  expectedReferenceIdentity == nil,
                  restoredReferenceIdentity == nil else {
                throw FileTransactionStoreError.invalidTransaction(
                    "A single-file transaction contains reference fields."
                )
            }
            if operation.isRestore, actualOriginalTrashPath == nil {
                throw FileTransactionStoreError.invalidTransaction(
                    "The restore Trash path is missing."
                )
            }
            guard referenceRestoreDestinationPath == nil else {
                throw FileTransactionStoreError.invalidTransaction(
                    "A single-file transaction contains a reference restore destination."
                )
            }
            if !operation.isRestore, originalRestoreDestinationPath != nil {
                throw FileTransactionStoreError.invalidTransaction(
                    "A delete transaction contains a restore destination."
                )
            }
        }

        for path in [
            actualOriginalTrashPath,
            actualReferenceTrashPath,
            originalRestoreDestinationPath,
            referenceRestoreDestinationPath
        ].compactMap({ $0 }) {
            let normalized = try Self.normalizedAbsoluteURL(URL(fileURLWithPath: path))
            guard normalized.path == path else {
                throw FileTransactionStoreError.invalidTransaction(
                    "A transaction path is invalid."
                )
            }
        }

        if let restoredReferenceIdentity {
            guard operation == .restoreReferencePair,
                  restoredReferenceIdentity.destinationPath
                    == originalRestoreDestinationPath else {
                throw FileTransactionStoreError.invalidTransaction(
                    "The restored reference identity does not match its destination."
                )
            }
        }

        if let trashRecord {
            guard trashRecord.transactionID == id,
                  trashRecord.originalPath == originalPath else {
                throw FileTransactionStoreError.invalidTransaction(
                    "The completed Trash record does not match its transaction."
                )
            }
            if operation.isRestore {
                guard trashRecord.trashedPath == originalRestoreDestinationPath,
                      trashRecord.restoredAt != nil else {
                    throw FileTransactionStoreError.invalidTransaction(
                        "The restored Trash record does not match its destination."
                    )
                }
            } else {
                guard trashRecord.trashedPath == actualOriginalTrashPath,
                      trashRecord.restoredAt == nil else {
                    throw FileTransactionStoreError.invalidTransaction(
                        "The deleted Trash record does not match its Trash path."
                    )
                }
            }
            if operation.includesReference {
                guard trashRecord.originalReferencePath == referencePath else {
                    throw FileTransactionStoreError.invalidTransaction(
                        "The reference Trash record does not match its transaction."
                    )
                }
                if operation.isRestore {
                    guard trashRecord.trashedReferencePath == actualReferenceTrashPath,
                          trashRecord.restoredReferencePath
                            == referenceRestoreDestinationPath else {
                        throw FileTransactionStoreError.invalidTransaction(
                            "The restored reference record is incomplete."
                        )
                    }
                } else {
                    guard trashRecord.trashedReferencePath == actualReferenceTrashPath,
                          trashRecord.restoredReferencePath == nil else {
                        throw FileTransactionStoreError.invalidTransaction(
                            "The deleted reference record is incomplete."
                        )
                    }
                }
            }
        }
        if phase == .fileSystemCompleted || phase == .historyApplied,
           trashRecord == nil {
            throw FileTransactionStoreError.invalidTransaction(
                "A completed transaction requires its Trash record."
            )
        }

        if historyAppliedAt != nil, phase != .historyApplied {
            throw FileTransactionStoreError.invalidTransaction(
                "The history timestamp and phase disagree."
            )
        }
        if phase == .historyApplied, historyAppliedAt == nil {
            throw FileTransactionStoreError.invalidTransaction(
                "The history timestamp is missing."
            )
        }
        if attentionMessage != nil, !needsAttention {
            throw FileTransactionStoreError.invalidTransaction(
                "The attention fields disagree."
            )
        }
        return self
    }

    private static func normalizedAbsoluteURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw FileTransactionStoreError.invalidTransaction(
                "Transaction paths must be absolute file URLs."
            )
        }
        let normalized = url.standardizedFileURL
        guard normalized.path == url.path else {
            throw FileTransactionStoreError.invalidTransaction(
                "Transaction paths must already be normalized."
            )
        }
        return normalized
    }
}

public enum FileTransactionLoadIssueReason: Equatable, Sendable {
    case invalidFilename
    case unreadable
    case malformed
    case unsupportedSchema(Int)
    case identifierMismatch
    case invalidTransaction
}

public struct FileTransactionLoadIssue: Equatable, Sendable {
    public let filename: String
    public let reason: FileTransactionLoadIssueReason

    public init(filename: String, reason: FileTransactionLoadIssueReason) {
        self.filename = filename
        self.reason = reason
    }
}

/// Valid transactions and isolated journal failures from one directory scan.
public struct FileTransactionLoadResult: Equatable, Sendable {
    public let transactions: [FileTransaction]
    public let issues: [FileTransactionLoadIssue]

    public init(
        transactions: [FileTransaction],
        issues: [FileTransactionLoadIssue]
    ) {
        self.transactions = transactions
        self.issues = issues
    }
}

public enum FileTransactionStoreError: Error, Equatable, Sendable {
    case alreadyExists(UUID)
    case notFound(UUID)
    case unsupportedSchema(Int)
    case corruptJournal(String)
    case invalidTransaction(String)
    case posixFailure(operation: String, code: Int32)
}

/// A durable per-transaction JSON store.
///
/// The store is a value type and owns no shared mutable state. Writers use an
/// advisory store-wide lock, a same-directory temporary file, `fsync`, an
/// atomic rename, and a directory `fsync`, so independent store values are safe
/// to use concurrently across tasks and processes.
public struct FileTransactionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    @discardableResult
    public func create(
        id: UUID = UUID(),
        operation: FileTransactionOperation,
        originalURL: URL,
        referenceURL: URL? = nil,
        actualOriginalTrashURL: URL? = nil,
        actualReferenceTrashURL: URL? = nil,
        originalRestoreDestinationURL: URL? = nil,
        referenceRestoreDestinationURL: URL? = nil,
        expectedOriginalIdentity: POSIXFileIdentity,
        expectedReferenceIdentity: SymbolicLinkIdentitySnapshot? = nil,
        createdAt: Date = .now
    ) throws -> FileTransaction {
        let transaction = try FileTransaction(
            id: id,
            operation: operation,
            createdAt: createdAt,
            originalURL: originalURL,
            referenceURL: referenceURL,
            actualOriginalTrashURL: actualOriginalTrashURL,
            actualReferenceTrashURL: actualReferenceTrashURL,
            originalRestoreDestinationURL: originalRestoreDestinationURL,
            referenceRestoreDestinationURL: referenceRestoreDestinationURL,
            expectedOriginalIdentity: expectedOriginalIdentity,
            expectedReferenceIdentity: expectedReferenceIdentity
        )

        try ensureDirectory()
        return try withTransactionLock(for: id) {
            let destination = journalURL(for: id)
            guard !pathExistsWithoutFollowingSymbolicLink(destination.path) else {
                throw FileTransactionStoreError.alreadyExists(id)
            }
            try writeAtomically(transaction, to: destination)
            return transaction
        }
    }

    /// Atomically replaces the journal for an existing transaction.
    public func save(_ transaction: FileTransaction) throws {
        _ = try transaction.validated()
        try ensureDirectory()
        try withTransactionLock(for: transaction.id) {
            let destination = journalURL(for: transaction.id)
            guard pathExistsWithoutFollowingSymbolicLink(destination.path) else {
                throw FileTransactionStoreError.notFound(transaction.id)
            }
            try writeAtomically(transaction, to: destination)
        }
    }

    /// Loads one journal. Missing journals return `nil`; malformed or obsolete
    /// journals throw so callers explicitly targeting an identifier cannot
    /// accidentally treat corruption as absence.
    public func load(id: UUID) throws -> FileTransaction? {
        try ensureDirectory()
        let url = journalURL(for: id)
        guard pathExistsWithoutFollowingSymbolicLink(url.path) else { return nil }
        let transaction = try decodeJournal(at: url)
        guard transaction.id == id else {
            throw FileTransactionStoreError.corruptJournal(url.lastPathComponent)
        }
        return transaction
    }

    /// Loads every valid journal while isolating old or corrupt files into the
    /// `issues` collection. One bad transaction never hides recoverable work in
    /// another journal.
    public func loadAll() throws -> FileTransactionLoadResult {
        try ensureDirectory()
        let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("transaction-") && $0.hasSuffix(".json") }
            .sorted()

        var transactions: [FileTransaction] = []
        var issues: [FileTransactionLoadIssue] = []
        for filename in filenames {
            guard let filenameID = transactionID(from: filename) else {
                issues.append(FileTransactionLoadIssue(filename: filename, reason: .invalidFilename))
                continue
            }
            let url = directory.appendingPathComponent(filename)
            do {
                let transaction = try decodeJournal(at: url)
                guard transaction.id == filenameID else {
                    issues.append(FileTransactionLoadIssue(
                        filename: filename,
                        reason: .identifierMismatch
                    ))
                    continue
                }
                transactions.append(transaction)
            } catch FileTransactionStoreError.unsupportedSchema(let version) {
                issues.append(FileTransactionLoadIssue(
                    filename: filename,
                    reason: .unsupportedSchema(version)
                ))
            } catch FileTransactionStoreError.invalidTransaction {
                issues.append(FileTransactionLoadIssue(
                    filename: filename,
                    reason: .invalidTransaction
                ))
            } catch FileTransactionStoreError.corruptJournal {
                issues.append(FileTransactionLoadIssue(filename: filename, reason: .malformed))
            } catch {
                issues.append(FileTransactionLoadIssue(filename: filename, reason: .unreadable))
            }
        }

        transactions.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return FileTransactionLoadResult(transactions: transactions, issues: issues)
    }

    /// Bounds startup work without discarding any transaction that could still
    /// affect user-visible state. Only terminal, attention-free journals are
    /// eligible; completed-but-unapplied and partial operations are never
    /// removed.
    @discardableResult
    public func pruneTerminalTransactions(
        historyAppliedLimit: Int = 256,
        abortedLimit: Int = 64
    ) throws -> [UUID] {
        guard historyAppliedLimit >= 0, abortedLimit >= 0 else {
            throw FileTransactionStoreError.invalidTransaction(
                "Transaction retention limits cannot be negative."
            )
        }
        let snapshot = try loadAll().transactions

        func excessIDs(for phase: FileTransactionPhase, limit: Int) -> [UUID] {
            let newestFirst = snapshot
                .filter { $0.phase == phase && !$0.needsAttention }
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                    return $0.id.uuidString > $1.id.uuidString
                }
            return Array(newestFirst.dropFirst(limit).map(\.id))
        }

        let candidates = excessIDs(for: .historyApplied, limit: historyAppliedLimit)
            + excessIDs(for: .aborted, limit: abortedLimit)

        try ensureDirectory()
        return try withMaintenanceLock {
            var removed: [UUID] = []
            do {
                for id in candidates {
                    let didRemove = try withNamedLock(
                        filename: transactionLockFilename(for: id),
                        operation: LOCK_EX
                    ) {
                        let url = journalURL(for: id)
                        guard pathExistsWithoutFollowingSymbolicLink(url.path),
                              let current = try? decodeJournal(at: url),
                              current.id == id,
                              !current.needsAttention,
                              (current.phase == .historyApplied
                                || current.phase == .aborted) else {
                            return false
                        }
                        let result = url.path.withCString { unlink($0) }
                        if result == 0 { return true }
                        if errno == ENOENT { return false }
                        throw posixError("unlink-terminal-journal", errno)
                    }
                    if didRemove { removed.append(id) }
                }
                let removedLocks = try removeOrphanedTransactionLocks()
                if !removed.isEmpty || removedLocks { try syncDirectory() }
                return removed
            } catch {
                if !removed.isEmpty { try? syncDirectory() }
                throw error
            }
        }
    }

    /// Marks the history mutation as durable. Calling this repeatedly is
    /// idempotent: the first timestamp is retained and no later call rewrites
    /// it.
    @discardableResult
    public func markHistoryApplied(
        id: UUID,
        at date: Date = .now
    ) throws -> FileTransaction {
        try ensureDirectory()
        return try withTransactionLock(for: id) {
            let url = journalURL(for: id)
            guard pathExistsWithoutFollowingSymbolicLink(url.path) else {
                throw FileTransactionStoreError.notFound(id)
            }
            var transaction = try decodeJournal(at: url)
            guard transaction.id == id else {
                throw FileTransactionStoreError.corruptJournal(url.lastPathComponent)
            }
            if transaction.historyAppliedAt != nil {
                return transaction
            }
            guard transaction.phase == .fileSystemCompleted,
                  transaction.trashRecord != nil else {
                throw FileTransactionStoreError.invalidTransaction(
                    "History cannot be applied before the file system transaction completes."
                )
            }
            transaction.phase = .historyApplied
            transaction.historyAppliedAt = date
            transaction.updatedAt = date
            try writeAtomically(transaction, to: url)
            return transaction
        }
    }

    /// Persists a recovery condition that needs manual attention while keeping
    /// the last successful file-system phase intact for diagnostics/retry.
    @discardableResult
    public func markNeedsAttention(
        id: UUID,
        message: String,
        at date: Date = .now
    ) throws -> FileTransaction {
        try ensureDirectory()
        return try withTransactionLock(for: id) {
            let url = journalURL(for: id)
            guard pathExistsWithoutFollowingSymbolicLink(url.path) else {
                throw FileTransactionStoreError.notFound(id)
            }
            var transaction = try decodeJournal(at: url)
            guard transaction.id == id else {
                throw FileTransactionStoreError.corruptJournal(url.lastPathComponent)
            }
            if transaction.needsAttention,
               transaction.attentionMessage == message {
                return transaction
            }
            transaction.needsAttention = true
            transaction.attentionMessage = message
            transaction.updatedAt = date
            try writeAtomically(transaction, to: url)
            return transaction
        }
    }

    /// Clears a recovery warning after its underlying condition has been
    /// verified as resolved, without changing the durable operation phase.
    @discardableResult
    public func clearNeedsAttention(
        id: UUID,
        at date: Date = .now
    ) throws -> FileTransaction {
        try ensureDirectory()
        return try withTransactionLock(for: id) {
            let url = journalURL(for: id)
            guard pathExistsWithoutFollowingSymbolicLink(url.path) else {
                throw FileTransactionStoreError.notFound(id)
            }
            var transaction = try decodeJournal(at: url)
            guard transaction.id == id else {
                throw FileTransactionStoreError.corruptJournal(url.lastPathComponent)
            }
            guard transaction.needsAttention || transaction.attentionMessage != nil else {
                return transaction
            }
            transaction.needsAttention = false
            transaction.attentionMessage = nil
            transaction.updatedAt = date
            try writeAtomically(transaction, to: url)
            return transaction
        }
    }

    /// Marks a transaction whose file-system changes were fully rolled back.
    /// Aborted journals remain as small audit records and are ignored by startup
    /// replay.
    @discardableResult
    public func markAborted(
        id: UUID,
        at date: Date = .now
    ) throws -> FileTransaction {
        try ensureDirectory()
        return try withTransactionLock(for: id) {
            let url = journalURL(for: id)
            guard pathExistsWithoutFollowingSymbolicLink(url.path) else {
                throw FileTransactionStoreError.notFound(id)
            }
            var transaction = try decodeJournal(at: url)
            guard transaction.id == id else {
                throw FileTransactionStoreError.corruptJournal(url.lastPathComponent)
            }
            if transaction.phase == .aborted { return transaction }
            transaction.phase = .aborted
            transaction.updatedAt = date
            transaction.needsAttention = false
            transaction.attentionMessage = nil
            try writeAtomically(transaction, to: url)
            return transaction
        }
    }

    public func journalURL(for id: UUID) -> URL {
        directory.appendingPathComponent(
            "transaction-\(id.uuidString.lowercased()).json"
        )
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw FileTransactionStoreError.invalidTransaction(
                "The transaction store must be an ordinary directory."
            )
        }
    }

    private func decodeJournal(at url: URL) throws -> FileTransaction {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FileTransactionStoreError.corruptJournal(url.lastPathComponent)
        }

        struct VersionHeader: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(VersionHeader.self, from: data) else {
            throw FileTransactionStoreError.corruptJournal(url.lastPathComponent)
        }
        guard header.schemaVersion == FileTransaction.currentSchemaVersion else {
            throw FileTransactionStoreError.unsupportedSchema(header.schemaVersion)
        }
        guard let transaction = try? decoder.decode(FileTransaction.self, from: data) else {
            throw FileTransactionStoreError.corruptJournal(url.lastPathComponent)
        }
        return try transaction.validated()
    }

    private func writeAtomically(_ transaction: FileTransaction, to destination: URL) throws {
        _ = try transaction.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transaction)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )

        let descriptor = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw posixError("open", errno)
        }

        var descriptorIsOpen = true
        var shouldRemoveTemporary = true
        defer {
            if descriptorIsOpen { close(descriptor) }
            if shouldRemoveTemporary {
                temporary.path.withCString { _ = unlink($0) }
            }
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write", errno)
                }
                guard written > 0 else { throw posixError("write", EIO) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError("fsync", errno) }
        let closeResult = close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw posixError("close", errno) }

        let renameResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else { throw posixError("rename", errno) }
        shouldRemoveTemporary = false
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError("open-directory", errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            let code = errno
            // APFS can report that directory fsync is unsupported even though
            // the file rename is already atomic and its contents were synced.
            guard code == EINVAL || code == ENOTSUP else {
                throw posixError("fsync-directory", code)
            }
            return
        }
    }

    private func withTransactionLock<T>(
        for id: UUID,
        _ body: () throws -> T
    ) throws -> T {
        // Normal writers share the maintenance gate, then serialize only with
        // writers for the same transaction. Pruning takes the gate exclusively
        // before unlinking journals or their now-orphaned lock files.
        try withNamedLock(filename: ".maintenance.lock", operation: LOCK_SH) {
            try withNamedLock(
                filename: transactionLockFilename(for: id),
                operation: LOCK_EX,
                body
            )
        }
    }

    private func withMaintenanceLock<T>(_ body: () throws -> T) throws -> T {
        try withNamedLock(filename: ".maintenance.lock", operation: LOCK_EX, body)
    }

    private func withNamedLock<T>(
        filename: String,
        operation: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let lockURL = directory.appendingPathComponent(filename)
        let descriptor = lockURL.path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw posixError("open-lock", errno) }
        defer { close(descriptor) }
        while flock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            throw posixError("lock", errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func transactionLockFilename(for id: UUID) -> String {
        ".transaction-\(id.uuidString.lowercased()).lock"
    }

    /// Called only while the maintenance lock is held exclusively, so no
    /// current writer can hold or open a transaction lock as it is unlinked.
    private func removeOrphanedTransactionLocks() throws -> Bool {
        let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var removedAny = false
        for filename in filenames {
            guard let id = transactionID(fromLockFilename: filename),
                  !pathExistsWithoutFollowingSymbolicLink(journalURL(for: id).path) else {
                continue
            }
            let lockURL = directory.appendingPathComponent(filename)
            let result = lockURL.path.withCString { unlink($0) }
            if result == 0 {
                removedAny = true
            } else if errno != ENOENT {
                throw posixError("unlink-orphan-lock", errno)
            }
        }
        return removedAny
    }

    private func transactionID(from filename: String) -> UUID? {
        let prefix = "transaction-"
        let suffix = ".json"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(filename[start..<end]))
    }

    private func transactionID(fromLockFilename filename: String) -> UUID? {
        let prefix = ".transaction-"
        let suffix = ".lock"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(filename[start..<end]))
    }

    private func pathExistsWithoutFollowingSymbolicLink(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }

    private func posixError(_ operation: String, _ code: Int32) -> FileTransactionStoreError {
        .posixFailure(operation: operation, code: code)
    }
}
