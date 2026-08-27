import Foundation
import Testing
@testable import GuiliuCore

@Suite("文件操作事务日志")
struct FileTransactionStoreTests {
    @Test("四种事务均记录确定性暂存路径和身份")
    func supportsAllOperationsAndDeterministicStagingPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.files.appendingPathComponent("sample.pdf")
        let reference = fixture.library.appendingPathComponent("sample.pdf")
        let trashedOriginal = fixture.trash.appendingPathComponent("sample.pdf")
        let trashedReference = fixture.trash.appendingPathComponent("sample-reference.pdf")
        let restoredOriginal = fixture.files.appendingPathComponent("sample 2.pdf")
        let restoredReference = fixture.library.appendingPathComponent("sample 2.pdf")
        let originalIdentity = POSIXFileIdentity(device: 10, inode: 20)
        let referenceIdentity = SymbolicLinkIdentitySnapshot(
            device: 30,
            inode: 40,
            destinationPath: original.path
        )

        let singleDelete = try fixture.store.create(
            id: Fixture.singleDeleteID,
            operation: .deleteSingle,
            originalURL: original,
            expectedOriginalIdentity: originalIdentity,
            createdAt: Fixture.date
        )
        let pairDelete = try fixture.store.create(
            id: Fixture.pairDeleteID,
            operation: .deleteReferencePair,
            originalURL: original,
            referenceURL: reference,
            expectedOriginalIdentity: originalIdentity,
            expectedReferenceIdentity: referenceIdentity,
            createdAt: Fixture.date.addingTimeInterval(1)
        )
        let singleRestore = try fixture.store.create(
            id: Fixture.singleRestoreID,
            operation: .restoreSingle,
            originalURL: original,
            actualOriginalTrashURL: trashedOriginal,
            originalRestoreDestinationURL: restoredOriginal,
            expectedOriginalIdentity: originalIdentity,
            createdAt: Fixture.date.addingTimeInterval(2)
        )
        let pairRestore = try fixture.store.create(
            id: Fixture.pairRestoreID,
            operation: .restoreReferencePair,
            originalURL: original,
            referenceURL: reference,
            actualOriginalTrashURL: trashedOriginal,
            actualReferenceTrashURL: trashedReference,
            originalRestoreDestinationURL: restoredOriginal,
            referenceRestoreDestinationURL: restoredReference,
            expectedOriginalIdentity: originalIdentity,
            expectedReferenceIdentity: referenceIdentity,
            createdAt: Fixture.date.addingTimeInterval(3)
        )

        #expect(singleDelete.operation == .deleteSingle)
        #expect(pairDelete.operation == .deleteReferencePair)
        #expect(singleRestore.operation == .restoreSingle)
        #expect(pairRestore.operation == .restoreReferencePair)
        #expect(singleDelete.originalStagingPath == fixture.files.appendingPathComponent(
            ".guiliu-transaction-11111111-1111-1111-1111-111111111111-original.staging"
        ).path)
        #expect(pairDelete.referenceStagingPath == fixture.library.appendingPathComponent(
            ".guiliu-transaction-22222222-2222-2222-2222-222222222222-reference.staging"
        ).path)
        #expect(pairRestore.actualOriginalTrashPath == trashedOriginal.path)
        #expect(pairRestore.actualReferenceTrashPath == trashedReference.path)
        #expect(singleRestore.originalRestoreDestinationPath == restoredOriginal.path)
        #expect(pairRestore.referenceRestoreDestinationPath == restoredReference.path)
        #expect(pairDelete.expectedOriginalIdentity == originalIdentity)
        #expect(pairDelete.expectedReferenceIdentity == referenceIdentity)

        let loaded = try fixture.store.loadAll()
        #expect(loaded.transactions.map(\.operation) == [
            .deleteSingle,
            .deleteReferencePair,
            .restoreSingle,
            .restoreReferencePair
        ])
        #expect(loaded.issues.isEmpty)
    }

    @Test("旧版本和损坏日志彼此隔离且不遮蔽有效事务")
    func isolatesOldAndCorruptJournals() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let valid = try fixture.makeSingleDelete(id: Fixture.singleDeleteID)
        let obsolete = try fixture.makeSingleDelete(id: Fixture.pairDeleteID)

        let obsoleteURL = fixture.store.journalURL(for: obsolete.id)
        var obsoleteJSON = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: obsoleteURL)) as? [String: Any]
        )
        obsoleteJSON["schemaVersion"] = 0
        try JSONSerialization.data(withJSONObject: obsoleteJSON).write(to: obsoleteURL)

        let corruptID = Fixture.singleRestoreID
        let corruptURL = fixture.store.journalURL(for: corruptID)
        try Data("{not-json".utf8).write(to: corruptURL)

        let result = try fixture.store.loadAll()

        #expect(result.transactions == [valid])
        #expect(result.issues == [
            FileTransactionLoadIssue(
                filename: obsoleteURL.lastPathComponent,
                reason: .unsupportedSchema(0)
            ),
            FileTransactionLoadIssue(
                filename: corruptURL.lastPathComponent,
                reason: .malformed
            )
        ])
        #expect(throws: FileTransactionStoreError.unsupportedSchema(0)) {
            _ = try fixture.store.load(id: obsolete.id)
        }
        #expect(throws: FileTransactionStoreError.corruptJournal(corruptURL.lastPathComponent)) {
            _ = try fixture.store.load(id: corruptID)
        }
    }

    @Test("并发保存只发布完整 JSON 且不遗留临时文件")
    func atomicallyUpdatesJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let initial = try fixture.makeSingleDelete(id: Fixture.singleDeleteID)
        let phases: [FileTransactionPhase] = [
            .prepared,
            .originalStaged,
            .originalTrashCommitted
        ]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    var candidate = initial
                    candidate.phase = phases[index % phases.count]
                    candidate.updatedAt = Fixture.date.addingTimeInterval(Double(index + 1))
                    candidate.actualOriginalTrashPath = fixture.trash
                        .appendingPathComponent("sample-\(index).pdf").path
                    try fixture.store.save(candidate)
                }
            }
            try await group.waitForAll()
        }

        let journalData = try Data(contentsOf: fixture.store.journalURL(for: initial.id))
        let decoded = try JSONDecoder().decode(FileTransaction.self, from: journalData)
        #expect(phases.contains(decoded.phase))
        #expect(decoded.actualOriginalTrashPath?.hasPrefix(fixture.trash.path) == true)

        let filenames = try FileManager.default.contentsOfDirectory(atPath: fixture.journals.path)
        #expect(filenames.filter { $0.hasSuffix(".json") } == [
            fixture.store.journalURL(for: initial.id).lastPathComponent
        ])
        #expect(filenames.allSatisfy { !$0.hasSuffix(".tmp") })
        #expect(try fixture.store.load(id: initial.id) == decoded)
    }

    @Test("读取和历史落盘标记均可幂等重试")
    func readsAndMarksHistoryIdempotently() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transaction = try fixture.makeSingleDelete(id: Fixture.singleDeleteID)
        transaction.phase = .fileSystemCompleted
        transaction.actualOriginalTrashPath = fixture.trash
            .appendingPathComponent("sample.pdf").path
        transaction.trashRecord = TrashRecord(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            transactionID: transaction.id,
            originalPath: transaction.originalPath,
            trashedPath: try #require(transaction.actualOriginalTrashPath),
            trashedAt: Fixture.date,
            sourceID: "generic-source",
            origin: .downloads,
            fileSize: 64,
            modificationDate: Fixture.date,
            contentHash: "generic-content-hash"
        )
        try fixture.store.save(transaction)

        let beforeRead = try Data(contentsOf: fixture.store.journalURL(for: transaction.id))
        let firstRead = try fixture.store.loadAll()
        let secondRead = try fixture.store.loadAll()
        let afterRead = try Data(contentsOf: fixture.store.journalURL(for: transaction.id))

        #expect(firstRead == secondRead)
        #expect(beforeRead == afterRead)

        let firstDate = Fixture.date.addingTimeInterval(10)
        let firstMark = try fixture.store.markHistoryApplied(id: transaction.id, at: firstDate)
        let afterFirstMark = try Data(contentsOf: fixture.store.journalURL(for: transaction.id))
        let secondMark = try fixture.store.markHistoryApplied(
            id: transaction.id,
            at: firstDate.addingTimeInterval(100)
        )
        let afterSecondMark = try Data(contentsOf: fixture.store.journalURL(for: transaction.id))

        #expect(firstMark.phase == .historyApplied)
        #expect(firstMark.historyAppliedAt == firstDate)
        #expect(secondMark == firstMark)
        #expect(afterSecondMark == afterFirstMark)

        let attentionDate = firstDate.addingTimeInterval(200)
        let attention = try fixture.store.markNeedsAttention(
            id: transaction.id,
            message: "Recovery requires review.",
            at: attentionDate
        )
        #expect(attention.phase == .historyApplied)
        #expect(attention.needsAttention)
        #expect(attention.attentionMessage == "Recovery requires review.")
        #expect(attention.updatedAt == attentionDate)

        let clearedDate = attentionDate.addingTimeInterval(1)
        let cleared = try fixture.store.clearNeedsAttention(
            id: transaction.id,
            at: clearedDate
        )
        let clearedAgain = try fixture.store.clearNeedsAttention(
            id: transaction.id,
            at: clearedDate.addingTimeInterval(10)
        )
        #expect(cleared.phase == .historyApplied)
        #expect(!cleared.needsAttention)
        #expect(cleared.attentionMessage == nil)
        #expect(cleared.updatedAt == clearedDate)
        #expect(clearedAgain == cleared)
    }

    @Test("终态日志裁剪有界且绝不删除待应用或需关注事务")
    func prunesOnlyExcessSafeTerminalTransactions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        func completedDelete(index: Int, createdAt: Date) throws -> FileTransaction {
            let original = fixture.files.appendingPathComponent("item-\(index).pdf")
            let trashed = fixture.trash.appendingPathComponent("item-\(index).pdf")
            var transaction = try fixture.store.create(
                operation: .deleteSingle,
                originalURL: original,
                expectedOriginalIdentity: POSIXFileIdentity(
                    device: 10,
                    inode: UInt64(1_000 + index)
                ),
                createdAt: createdAt
            )
            transaction.phase = .fileSystemCompleted
            transaction.actualOriginalTrashPath = trashed.path
            transaction.trashRecord = TrashRecord(
                transactionID: transaction.id,
                originalPath: original.path,
                trashedPath: trashed.path,
                trashedAt: createdAt,
                sourceID: "generic-source",
                origin: .downloads,
                fileSize: 1,
                modificationDate: nil,
                contentHash: "hash-\(index)"
            )
            try fixture.store.save(transaction)
            return transaction
        }

        var history: [FileTransaction] = []
        for index in 0..<3 {
            let completed = try completedDelete(
                index: index,
                createdAt: Fixture.date.addingTimeInterval(Double(index))
            )
            history.append(try fixture.store.markHistoryApplied(
                id: completed.id,
                at: Fixture.date.addingTimeInterval(Double(100 + index))
            ))
        }

        var aborted: [FileTransaction] = []
        for index in 10..<13 {
            let transaction = try fixture.store.create(
                operation: .deleteSingle,
                originalURL: fixture.files.appendingPathComponent("item-\(index).pdf"),
                expectedOriginalIdentity: POSIXFileIdentity(
                    device: 10,
                    inode: UInt64(1_000 + index)
                ),
                createdAt: Fixture.date.addingTimeInterval(Double(index))
            )
            aborted.append(try fixture.store.markAborted(
                id: transaction.id,
                at: Fixture.date.addingTimeInterval(Double(200 + index))
            ))
        }

        let unapplied = try completedDelete(index: 20, createdAt: Fixture.date)
        let partial = try fixture.store.create(
            operation: .deleteSingle,
            originalURL: fixture.files.appendingPathComponent("partial.pdf"),
            expectedOriginalIdentity: POSIXFileIdentity(device: 10, inode: 9_999),
            createdAt: Fixture.date
        )
        let attentionCompleted = try completedDelete(index: 21, createdAt: Fixture.date)
        let attentionHistory = try fixture.store.markHistoryApplied(
            id: attentionCompleted.id,
            at: Fixture.date.addingTimeInterval(300)
        )
        _ = try fixture.store.markNeedsAttention(
            id: attentionHistory.id,
            message: "Keep for review.",
            at: Fixture.date.addingTimeInterval(301)
        )
        let orphanLockID = UUID()
        let orphanLock = fixture.journals.appendingPathComponent(
            ".transaction-\(orphanLockID.uuidString.lowercased()).lock"
        )
        try Data().write(to: orphanLock)

        let removed = try fixture.store.pruneTerminalTransactions(
            historyAppliedLimit: 1,
            abortedLimit: 1
        )
        let remaining = try fixture.store.loadAll().transactions
        let remainingIDs = Set(remaining.map(\.id))

        #expect(Set(removed) == Set(history.prefix(2).map(\.id) + aborted.prefix(2).map(\.id)))
        #expect(remainingIDs.contains(history[2].id))
        #expect(remainingIDs.contains(aborted[2].id))
        #expect(remainingIDs.contains(unapplied.id))
        #expect(remainingIDs.contains(partial.id))
        #expect(remainingIDs.contains(attentionHistory.id))
        #expect(remaining.first(where: { $0.id == attentionHistory.id })?.needsAttention == true)
        for id in removed {
            let lock = fixture.journals.appendingPathComponent(
                ".transaction-\(id.uuidString.lowercased()).lock"
            )
            #expect(!FileManager.default.fileExists(atPath: lock.path))
        }
        #expect(!FileManager.default.fileExists(atPath: orphanLock.path))
        let filenames = try FileManager.default.contentsOfDirectory(atPath: fixture.journals.path)
        #expect(filenames.contains(".maintenance.lock"))
        #expect(!filenames.contains(".transactions.lock"))
    }

    private struct Fixture: Sendable {
        static let singleDeleteID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        static let pairDeleteID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        static let singleRestoreID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        static let pairRestoreID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        static let date = Date(timeIntervalSinceReferenceDate: 700_000)

        let root: URL
        let journals: URL
        let files: URL
        let library: URL
        let trash: URL
        let store: FileTransactionStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "GuiliuFileTransactionStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
            journals = root.appendingPathComponent("Journals", isDirectory: true)
            files = root.appendingPathComponent("Files", isDirectory: true)
            library = root.appendingPathComponent("Library", isDirectory: true)
            trash = root.appendingPathComponent("Trash", isDirectory: true)
            store = FileTransactionStore(directory: journals)
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        }

        func makeSingleDelete(id: UUID) throws -> FileTransaction {
            try store.create(
                id: id,
                operation: .deleteSingle,
                originalURL: files.appendingPathComponent("sample.pdf"),
                expectedOriginalIdentity: POSIXFileIdentity(device: 10, inode: 20),
                createdAt: Self.date
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
