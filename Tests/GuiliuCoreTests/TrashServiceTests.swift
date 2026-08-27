import Foundation
import Testing
@testable import GuiliuCore

@Suite("待归类文件删除安全校验")
struct TrashServiceTests {
    private enum InjectedTrashFailure: Error {
        case stop
    }

    private let service = TrashService()

    @Test("受监控目录内未变化的普通文件通过校验")
    func validatesRegularFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = Data("temporary download".utf8)
        let file = fixture.allowedRoot.appendingPathComponent("unused.txt")
        try contents.write(to: file)
        let item = makeItem(url: file, fileSize: Int64(contents.count))

        let snapshot = try service.validate(item: item, allowedRoot: fixture.allowedRoot)

        #expect(snapshot.size == Int64(contents.count))
        #expect(snapshot.modificationDate != nil)
        #expect(snapshot.resourceIdentifier != nil)
        #expect(!snapshot.contentHash.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("微信引用来源拒绝删除")
    func rejectsReferencedWeChatOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.allowedRoot.appendingPathComponent("received.pdf")
        try Data("wechat".utf8).write(to: file)
        let item = makeItem(
            url: file,
            fileSize: 6,
            origin: .wechat,
            operation: .reference
        )

        expectError(.appManagedFile) {
            _ = try service.validate(item: item, allowedRoot: fixture.allowedRoot)
        }
    }

    @Test("明确授权时 App 原件可通过删除校验")
    func validatesExplicitlyAuthorizedAppOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.allowedRoot.appendingPathComponent("received.pdf")
        try Data("app attachment".utf8).write(to: file)
        let identity = try FileIdentitySnapshot.capture(at: file)
        let item = makeReferenceItem(url: file, identity: identity)

        let snapshot = try service.validate(
            item: item,
            allowedRoot: fixture.allowedRoot,
            allowAppManagedOriginal: true
        )

        #expect(snapshot.size == identity.size)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("归档引用与 App 原件成对进入废纸篓并可一起恢复")
    func trashesAndRestoresReferencePair() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let original = fixture.appFiles.appendingPathComponent("attachment.pdf")
        let reference = fixture.category.appendingPathComponent("attachment.pdf")
        let contents = Data("recoverable app attachment".utf8)
        try contents.write(to: original)
        try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: original)

        let sourceIdentity = try FileIdentitySnapshot.capture(at: original)
        let sourcePOSIXIdentity = try POSIXFileIdentity.captureRegularFile(at: original)
        let referenceIdentity = try SymbolicLinkIdentitySnapshot.capture(at: reference)
        let store = FileTransactionStore(
            directory: fixture.root.appendingPathComponent("Journals", isDirectory: true)
        )
        let pairService = fakeTrashService(in: fixture.fakeTrash, transactionStore: store)

        let trashed = try pairService.trashReferenceAndOriginal(
            referenceURL: reference,
            referenceRoot: fixture.category,
            expectedReferenceIdentity: referenceIdentity,
            originalItem: makeReferenceItem(url: original, identity: sourceIdentity),
            originalRoot: fixture.appFiles,
            expectedOriginalPOSIXIdentity: sourcePOSIXIdentity
        )

        #expect(trashed.record.includesArchivedReference)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: reference.path)) == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: trashed.record.trashedPath)) == contents)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: trashed.trashedReferenceURL.path
        ) == original.path)
        let deleteTransactionID = try #require(trashed.record.transactionID)
        let deleteTransaction = try #require(try store.load(id: deleteTransactionID))
        #expect(deleteTransaction.operation == .deleteReferencePair)
        #expect(deleteTransaction.phase == .fileSystemCompleted)
        #expect(deleteTransaction.trashRecord == trashed.record)

        let restored = try pairService.restore(trashed.record)

        #expect(restored.isRestored)
        #expect(restored.trashedPath == original.path)
        #expect(restored.restoredReferencePath == reference.path)
        #expect(try Data(contentsOf: original) == contents)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: reference.path) == original.path)
        #expect(restored.transactionID != trashed.record.transactionID)
        let restoreTransactionID = try #require(restored.transactionID)
        let restoreTransaction = try #require(try store.load(id: restoreTransactionID))
        #expect(restoreTransaction.operation == .restoreReferencePair)
        #expect(restoreTransaction.phase == .fileSystemCompleted)
        #expect(restoreTransaction.trashRecord == restored)
    }

    @Test("归档引用被替换后拒绝删除原件")
    func rejectsReplacedArchivedReference() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let original = fixture.appFiles.appendingPathComponent("attachment.pdf")
        let other = fixture.appFiles.appendingPathComponent("other.pdf")
        let reference = fixture.category.appendingPathComponent("attachment.pdf")
        try Data("original".utf8).write(to: original)
        try Data("unrelated".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: original)
        let sourceIdentity = try FileIdentitySnapshot.capture(at: original)
        let sourcePOSIXIdentity = try POSIXFileIdentity.captureRegularFile(at: original)
        let referenceIdentity = try SymbolicLinkIdentitySnapshot.capture(at: reference)

        try FileManager.default.removeItem(at: reference)
        try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: other)

        expectError(.fileChanged) {
            _ = try fakeTrashService(in: fixture.fakeTrash).trashReferenceAndOriginal(
                referenceURL: reference,
                referenceRoot: fixture.category,
                expectedReferenceIdentity: referenceIdentity,
                originalItem: makeReferenceItem(url: original, identity: sourceIdentity),
                originalRoot: fixture.appFiles,
                expectedOriginalPOSIXIdentity: sourcePOSIXIdentity
            )
        }
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: reference.path) == other.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.fakeTrash.path).isEmpty)
    }

    @Test("App 原路径被同尺寸文件复用后拒绝成对删除")
    func rejectsReplacedAppOriginal() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let original = fixture.appFiles.appendingPathComponent("attachment.pdf")
        let reference = fixture.category.appendingPathComponent("attachment.pdf")
        let originalContents = Data("original".utf8)
        let replacementContents = Data("replaced".utf8)
        #expect(originalContents.count == replacementContents.count)
        try originalContents.write(to: original)
        let stableDate = Date(timeIntervalSinceReferenceDate: 654_321)
        try FileManager.default.setAttributes([.modificationDate: stableDate], ofItemAtPath: original.path)
        try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: original)
        let sourceIdentity = try FileIdentitySnapshot.capture(at: original)
        let sourcePOSIXIdentity = try POSIXFileIdentity.captureRegularFile(at: original)
        let referenceIdentity = try SymbolicLinkIdentitySnapshot.capture(at: reference)

        try FileManager.default.removeItem(at: original)
        try replacementContents.write(to: original)
        try FileManager.default.setAttributes([.modificationDate: stableDate], ofItemAtPath: original.path)

        expectError(.fileChanged) {
            _ = try fakeTrashService(in: fixture.fakeTrash).trashReferenceAndOriginal(
                referenceURL: reference,
                referenceRoot: fixture.category,
                expectedReferenceIdentity: referenceIdentity,
                originalItem: makeReferenceItem(url: original, identity: sourceIdentity),
                originalRoot: fixture.appFiles,
                expectedOriginalPOSIXIdentity: sourcePOSIXIdentity
            )
        }
        #expect(try Data(contentsOf: original) == replacementContents)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: reference.path) == original.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.fakeTrash.path).isEmpty)
    }

    @Test("原件进入废纸篓失败时归档引用自动回滚")
    func rollsBackReferenceWhenOriginalTrashFails() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let original = fixture.appFiles.appendingPathComponent("attachment.pdf")
        let reference = fixture.category.appendingPathComponent("attachment.pdf")
        try Data("keep both".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: original)
        let sourceIdentity = try FileIdentitySnapshot.capture(at: original)
        let sourcePOSIXIdentity = try POSIXFileIdentity.captureRegularFile(at: original)
        let referenceIdentity = try SymbolicLinkIdentitySnapshot.capture(at: reference)
        let store = FileTransactionStore(
            directory: fixture.root.appendingPathComponent("Journals", isDirectory: true)
        )
        let pairService = fakeTrashService(
            in: fixture.fakeTrash,
            rejectingDirectory: original.deletingLastPathComponent().standardizedFileURL.path,
            transactionStore: store
        )

        do {
            _ = try pairService.trashReferenceAndOriginal(
                referenceURL: reference,
                referenceRoot: fixture.category,
                expectedReferenceIdentity: referenceIdentity,
                originalItem: makeReferenceItem(url: original, identity: sourceIdentity),
                originalRoot: fixture.appFiles,
                expectedOriginalPOSIXIdentity: sourcePOSIXIdentity
            )
            Issue.record("原件删除失败时不应返回成功")
        } catch InjectedTrashFailure.stop {
            // Expected: the first Trash move is rolled back.
        } catch {
            Issue.record("预期注入失败，实际为 \(error)")
        }

        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: reference.path) == original.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.fakeTrash.path).isEmpty)
        let transactions = try store.loadAll().transactions
        #expect(transactions.count == 1)
        #expect(transactions.first?.operation == .deleteReferencePair)
        #expect(transactions.first?.phase == .aborted)
        #expect(transactions.first?.needsAttention == false)
    }

    @Test("文件夹拒绝一键删除")
    func rejectsDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.allowedRoot.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = makeItem(url: directory, fileSize: 0)

        expectError(.unsupportedItem) {
            _ = try service.validate(item: item, allowedRoot: fixture.allowedRoot)
        }
    }

    @Test("受监控目录之外的文件拒绝删除")
    func rejectsFileOutsideAllowedRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.outsideRoot.appendingPathComponent("unrelated.txt")
        try Data("outside".utf8).write(to: file)
        let item = makeItem(url: file, fileSize: 7)

        expectError(.outsideAllowedLocation) {
            _ = try service.validate(item: item, allowedRoot: fixture.allowedRoot)
        }
    }

    @Test("入队后大小变化的文件拒绝删除")
    func rejectsChangedFileSize() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.allowedRoot.appendingPathComponent("changing.txt")
        try Data("old".utf8).write(to: file)
        let item = makeItem(url: file, fileSize: 3)
        try Data("new and longer".utf8).write(to: file)

        expectError(.fileChanged) {
            _ = try service.validate(item: item, allowedRoot: fixture.allowedRoot)
        }
    }

    @Test("同路径同尺寸文件被替换后拒绝删除")
    func rejectsSameSizeReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.allowedRoot.appendingPathComponent("replaceable.txt")
        let original = Data("original".utf8)
        let replacement = Data("replaced".utf8)
        #expect(original.count == replacement.count)
        try original.write(to: file)
        let stableDate = Date(timeIntervalSinceReferenceDate: 123_456)
        try FileManager.default.setAttributes([.modificationDate: stableDate], ofItemAtPath: file.path)
        let identity = try FileIdentitySnapshot.capture(at: file)
        let item = InboxItem(
            url: file,
            fileSize: identity.size,
            suggestion: ClassificationSuggestion(category: .needsReview, reason: "测试", confidence: 1),
            origin: .downloads,
            routingOperation: .move,
            sourceID: "test-source",
            sourceDisplayName: "测试来源",
            modificationDate: identity.modificationDate,
            resourceIdentifier: identity.resourceIdentifier,
            resourceIdentifierSession: identity.resourceIdentifierSession,
            persistentIdentity: identity.persistentIdentity
        )

        try FileManager.default.removeItem(at: file)
        try replacement.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: stableDate], ofItemAtPath: file.path)

        expectError(.fileChanged) {
            _ = try service.validate(item: item, allowedRoot: fixture.allowedRoot)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: file) == replacement)
    }

    @Test("校验后路径被原子替换时不会把替换文件送入废纸篓")
    func rollsBackReplacementRacingWithTrash() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let file = fixture.appFiles.appendingPathComponent("replaceable.txt")
        let original = Data("original".utf8)
        let replacement = Data("replaced".utf8)
        #expect(original.count == replacement.count)
        try original.write(to: file)
        let stableDate = Date(timeIntervalSinceReferenceDate: 234_567)
        try FileManager.default.setAttributes([.modificationDate: stableDate], ofItemAtPath: file.path)
        let identity = try FileIdentitySnapshot.capture(at: file)
        let posixIdentity = try POSIXFileIdentity.captureRegularFile(at: file)
        let item = InboxItem(
            url: file,
            fileSize: identity.size,
            suggestion: ClassificationSuggestion(category: .needsReview, reason: "测试", confidence: 1),
            routingOperation: .move,
            sourceID: "downloads",
            sourceDisplayName: "下载文件夹",
            modificationDate: identity.modificationDate,
            resourceIdentifier: identity.resourceIdentifier,
            resourceIdentifierSession: identity.resourceIdentifierSession,
            persistentIdentity: identity.persistentIdentity,
            posixIdentity: posixIdentity
        )
        let raceService = TrashService(
            trashItemHandler: { source in
                let destination = fixture.fakeTrash.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            },
            afterValidationBeforeStaging: { source in
                try FileManager.default.removeItem(at: source)
                try replacement.write(to: source)
                try FileManager.default.setAttributes(
                    [.modificationDate: stableDate],
                    ofItemAtPath: source.path
                )
            }
        )

        expectError(.fileChanged) {
            _ = try raceService.trash(
                item: item,
                allowedRoot: fixture.appFiles,
                expectedPOSIXIdentity: posixIdentity
            )
        }
        #expect(try Data(contentsOf: file) == replacement)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.fakeTrash.path).isEmpty)
    }

    @Test("从模拟废纸篓恢复到原路径")
    func restoresFromFakeTrashToOriginalPath() throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let contents = Data("restore me".utf8)
        let trashed = fixture.fakeTrash.appendingPathComponent("file.txt")
        let original = fixture.inbox.appendingPathComponent("file.txt")
        try contents.write(to: trashed)
        let record = try makeTrashRecord(original: original, trashed: trashed, fileSize: Int64(contents.count))

        let restored = try service.restore(record)

        #expect(restored.isRestored)
        #expect(restored.trashedPath == original.path)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
        #expect(try Data(contentsOf: original) == contents)
    }

    @Test("恢复时同名文件生成唯一后缀且不覆盖原文件")
    func restoresWithUniqueSuffixWithoutOverwriting() throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let existingContents = Data("keep existing".utf8)
        let restoredContents = Data("restore separate copy".utf8)
        let original = fixture.inbox.appendingPathComponent("file.txt")
        let trashed = fixture.fakeTrash.appendingPathComponent("file.txt")
        try existingContents.write(to: original)
        try restoredContents.write(to: trashed)
        let record = try makeTrashRecord(
            original: original,
            trashed: trashed,
            fileSize: Int64(restoredContents.count)
        )

        let restored = try service.restore(record)
        let uniqueDestination = URL(fileURLWithPath: restored.trashedPath)

        #expect(restored.isRestored)
        #expect(uniqueDestination.lastPathComponent == "file 2.txt")
        #expect(FileManager.default.fileExists(atPath: uniqueDestination.path))
        #expect(try Data(contentsOf: original) == existingContents)
        #expect(try Data(contentsOf: uniqueDestination) == restoredContents)
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
    }

    @Test("废纸篓路径被同名新文件复用时拒绝恢复")
    func rejectsReusedTrashPath() throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let original = fixture.inbox.appendingPathComponent("file.txt")
        let trashed = fixture.fakeTrash.appendingPathComponent("file.txt")
        let originalContents = Data("first-file".utf8)
        let replacementContents = originalContents
        try originalContents.write(to: trashed)
        let stableModificationDate = Date(timeIntervalSinceReferenceDate: 123_456_789)
        try FileManager.default.setAttributes(
            [.modificationDate: stableModificationDate],
            ofItemAtPath: trashed.path
        )
        let record = try makeTrashRecord(
            original: original,
            trashed: trashed,
            fileSize: Int64(originalContents.count)
        )
        #expect(record.resourceIdentifierSession
            == FileIdentitySnapshot.currentResourceIdentifierSession)

        let replacement = fixture.fakeTrash.appendingPathComponent("replacement.txt")
        try replacementContents.write(to: replacement)
        if let modificationDate = record.modificationDate {
            try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: replacement.path)
        }
        try FileManager.default.removeItem(at: trashed)
        try FileManager.default.moveItem(at: replacement, to: trashed)
        let replacementSnapshot = try service.validate(
            item: makeItem(url: trashed, fileSize: Int64(replacementContents.count)),
            allowedRoot: fixture.fakeTrash
        )
        #expect(replacementSnapshot.size == record.fileSize)
        #expect(replacementSnapshot.modificationDate == record.modificationDate)
        #expect(replacementSnapshot.contentHash == record.contentHash)
        #expect(replacementSnapshot.resourceIdentifier != record.resourceIdentifier)

        expectError(.trashedFileChanged) {
            _ = try service.restore(record)
        }
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: trashed) == replacementContents)
    }

    @Test("单文件删除与恢复分别持久化完整事务")
    func journalsSingleDeleteAndRestore() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let original = fixture.appFiles.appendingPathComponent("journaled.txt")
        let contents = Data("durable transaction".utf8)
        try contents.write(to: original)
        let identity = try FileIdentitySnapshot.capture(at: original)
        let posixIdentity = try POSIXFileIdentity.captureRegularFile(at: original)
        let item = InboxItem(
            url: original,
            fileSize: identity.size,
            suggestion: ClassificationSuggestion(
                category: .needsReview,
                reason: "测试",
                confidence: 1
            ),
            origin: .downloads,
            routingOperation: .move,
            sourceID: "downloads",
            sourceDisplayName: "下载文件夹",
            modificationDate: identity.modificationDate,
            resourceIdentifier: identity.resourceIdentifier,
            resourceIdentifierSession: identity.resourceIdentifierSession,
            persistentIdentity: identity.persistentIdentity,
            posixIdentity: posixIdentity
        )
        let store = FileTransactionStore(
            directory: fixture.root.appendingPathComponent("Journals", isDirectory: true)
        )
        let journaledService = fakeTrashService(
            in: fixture.fakeTrash,
            transactionStore: store
        )

        let deleted = try journaledService.trash(
            item: item,
            allowedRoot: fixture.appFiles,
            expectedPOSIXIdentity: posixIdentity
        )
        let deleteID = try #require(deleted.transactionID)
        let deleteTransaction = try #require(try store.load(id: deleteID))
        #expect(deleteTransaction.operation == .deleteSingle)
        #expect(deleteTransaction.phase == .fileSystemCompleted)
        #expect(deleteTransaction.trashRecord == deleted)

        let restored = try journaledService.restore(deleted)
        let restoreID = try #require(restored.transactionID)
        let restoreTransaction = try #require(try store.load(id: restoreID))
        #expect(restoreID != deleteID)
        #expect(restoreTransaction.operation == .restoreSingle)
        #expect(restoreTransaction.phase == .fileSystemCompleted)
        #expect(restoreTransaction.trashRecord == restored)
        #expect(try Data(contentsOf: URL(fileURLWithPath: restored.trashedPath)) == contents)
    }

    @Test("启动恢复把成对删除的确定性暂存安全回滚")
    func recoversInterruptedReferencePairDelete() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let original = fixture.appFiles.appendingPathComponent("interrupted.pdf")
        let reference = fixture.category.appendingPathComponent("interrupted.pdf")
        try Data("recover on launch".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: original)
        let originalIdentity = try POSIXFileIdentity.captureRegularFile(at: original)
        let referenceIdentity = try SymbolicLinkIdentitySnapshot.capture(at: reference)
        let store = FileTransactionStore(
            directory: fixture.root.appendingPathComponent("Journals", isDirectory: true)
        )
        var transaction = try store.create(
            operation: .deleteReferencePair,
            originalURL: original,
            referenceURL: reference,
            expectedOriginalIdentity: originalIdentity,
            expectedReferenceIdentity: referenceIdentity
        )
        try FileManager.default.moveItem(
            at: reference,
            to: URL(fileURLWithPath: try #require(transaction.referenceStagingPath))
        )
        try FileManager.default.moveItem(
            at: original,
            to: URL(fileURLWithPath: transaction.originalStagingPath)
        )
        transaction.phase = .originalStaged
        try store.save(transaction)

        let recovery = try TrashService(
            transactionStore: store
        ).recoverInterruptedTransactions()

        #expect(recovery.rolledBackTransactionIDs == [transaction.id])
        #expect(recovery.attentionMessages.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: reference.path)
            == original.path)
        #expect(try store.load(id: transaction.id)?.phase == .aborted)
    }

    @Test("启动恢复遇到路径冲突不覆盖并标记人工处理")
    func recoveryRefusesConflictingDestination() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let original = fixture.appFiles.appendingPathComponent("conflict.txt")
        let originalContents = Data("original object".utf8)
        let replacementContents = Data("replacement object".utf8)
        try originalContents.write(to: original)
        let identity = try POSIXFileIdentity.captureRegularFile(at: original)
        let store = FileTransactionStore(
            directory: fixture.root.appendingPathComponent("Journals", isDirectory: true)
        )
        var transaction = try store.create(
            operation: .deleteSingle,
            originalURL: original,
            expectedOriginalIdentity: identity
        )
        let staging = URL(fileURLWithPath: transaction.originalStagingPath)
        try FileManager.default.moveItem(at: original, to: staging)
        transaction.phase = .originalStaged
        try store.save(transaction)
        try replacementContents.write(to: original)

        let recovery = try TrashService(
            transactionStore: store
        ).recoverInterruptedTransactions()

        #expect(recovery.rolledBackTransactionIDs.isEmpty)
        #expect(recovery.attentionMessages.count == 1)
        #expect(try Data(contentsOf: original) == replacementContents)
        #expect(try Data(contentsOf: staging) == originalContents)
        #expect(try store.load(id: transaction.id)?.needsAttention == true)
    }

    @Test("废纸篓处理器移动后报错时事务保留为待恢复而非误标中止")
    func retainsJournalWhenTrashHandlerLosesResultPath() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let original = fixture.appFiles.appendingPathComponent("uncertain.txt")
        try Data("uncertain trash result".utf8).write(to: original)
        let identity = try FileIdentitySnapshot.capture(at: original)
        let posixIdentity = try POSIXFileIdentity.captureRegularFile(at: original)
        let item = InboxItem(
            url: original,
            fileSize: identity.size,
            suggestion: ClassificationSuggestion(
                category: .needsReview,
                reason: "测试",
                confidence: 1
            ),
            origin: .downloads,
            routingOperation: .move,
            sourceID: "downloads",
            sourceDisplayName: "下载文件夹",
            modificationDate: identity.modificationDate,
            resourceIdentifier: identity.resourceIdentifier,
            resourceIdentifierSession: identity.resourceIdentifierSession,
            persistentIdentity: identity.persistentIdentity,
            posixIdentity: posixIdentity
        )
        let store = FileTransactionStore(
            directory: fixture.root.appendingPathComponent("Journals", isDirectory: true)
        )
        let uncertainService = TrashService(
            trashItemHandler: { source in
                let destination = fixture.fakeTrash.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                throw InjectedTrashFailure.stop
            },
            transactionStore: store
        )

        do {
            _ = try uncertainService.trash(
                item: item,
                allowedRoot: fixture.appFiles,
                expectedPOSIXIdentity: posixIdentity
            )
            Issue.record("位置不明的删除不应返回成功")
        } catch TrashError.trashRollbackFailed {
            // The journal, not an unsafe guessed path, is the recovery source.
        } catch {
            Issue.record("预期位置不明错误，实际为 \(error)")
        }

        let transaction = try #require(try store.loadAll().transactions.first)
        #expect(transaction.phase == .originalStaged)
        #expect(transaction.needsAttention)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: transaction.originalStagingPath))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.fakeTrash.path).count == 1)
    }

    @Test("只重放尚未应用历史的已完成事务")
    func replaysOnlyFileSystemCompletedTransactions() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let store = FileTransactionStore(
            directory: fixture.root.appendingPathComponent("Journals", isDirectory: true)
        )
        let original = fixture.appFiles.appendingPathComponent("history.txt")
        let trashed = fixture.fakeTrash.appendingPathComponent("history.txt")
        try Data("history".utf8).write(to: trashed)
        let identity = try POSIXFileIdentity.captureRegularFile(at: trashed)
        var first = try store.create(
            operation: .deleteSingle,
            originalURL: original,
            expectedOriginalIdentity: identity
        )
        first.phase = .fileSystemCompleted
        first.actualOriginalTrashPath = trashed.path
        first.trashRecord = TrashRecord(
            transactionID: first.id,
            originalPath: original.path,
            trashedPath: trashed.path,
            sourceID: "downloads",
            origin: .downloads,
            fileSize: 7,
            modificationDate: nil,
            contentHash: "hash"
        )
        try store.save(first)

        let secondID = UUID()
        var second = try store.create(
            id: secondID,
            operation: .deleteSingle,
            originalURL: fixture.appFiles.appendingPathComponent("history-2.txt"),
            expectedOriginalIdentity: identity
        )
        second.phase = .fileSystemCompleted
        second.actualOriginalTrashPath = trashed.path
        second.trashRecord = TrashRecord(
            transactionID: second.id,
            originalPath: second.originalPath,
            trashedPath: trashed.path,
            sourceID: "downloads",
            origin: .downloads,
            fileSize: 7,
            modificationDate: nil,
            contentHash: "hash"
        )
        try store.save(second)
        _ = try store.markHistoryApplied(id: secondID)

        let recovery = try TrashService(
            transactionStore: store
        ).recoverInterruptedTransactions()

        #expect(recovery.completedTransactions.map(\.id) == [first.id])
        #expect(recovery.rolledBackTransactionIDs.isEmpty)
        #expect(recovery.attentionMessages.isEmpty)
    }

    @Test("历史已应用的恢复事务清理成功后解除旧引用告警")
    func clearsResolvedRestoreBackupAttention() throws {
        let fixture = try ReferenceFixture()
        defer { fixture.remove() }
        let store = FileTransactionStore(
            directory: fixture.root.appendingPathComponent("Journals", isDirectory: true)
        )
        let id = UUID()
        let original = fixture.appFiles.appendingPathComponent("restored.pdf")
        let reference = fixture.category.appendingPathComponent("restored.pdf")
        let restoredReference = fixture.category.appendingPathComponent("restored 2.pdf")
        let originalTrash = fixture.fakeTrash.appendingPathComponent("restored.pdf")
        let referenceTrash = fixture.fakeTrash.appendingPathComponent("restored-reference.pdf")
        try Data("restored".utf8).write(to: original)
        let originalIdentity = try POSIXFileIdentity.captureRegularFile(at: original)
        let referenceStaging = FileTransaction.stagingURL(
            transactionID: id,
            role: "reference",
            adjacentTo: reference
        )
        try FileManager.default.createSymbolicLink(
            at: referenceStaging,
            withDestinationURL: original
        )
        let referenceIdentity = try SymbolicLinkIdentitySnapshot.capture(at: referenceStaging)
        var transaction = try store.create(
            id: id,
            operation: .restoreReferencePair,
            originalURL: original,
            referenceURL: reference,
            actualOriginalTrashURL: originalTrash,
            actualReferenceTrashURL: referenceTrash,
            originalRestoreDestinationURL: original,
            referenceRestoreDestinationURL: restoredReference,
            expectedOriginalIdentity: originalIdentity,
            expectedReferenceIdentity: referenceIdentity
        )
        transaction.phase = .fileSystemCompleted
        transaction.trashRecord = TrashRecord(
            transactionID: id,
            originalPath: original.path,
            trashedPath: original.path,
            restoredAt: .now,
            sourceID: "app-source",
            origin: .wechat,
            fileSize: 8,
            modificationDate: nil,
            contentHash: "hash",
            originalReferencePath: reference.path,
            trashedReferencePath: referenceTrash.path,
            restoredReferencePath: restoredReference.path,
            referenceIdentity: referenceIdentity
        )
        try store.save(transaction)
        _ = try store.markHistoryApplied(id: id)
        _ = try store.markNeedsAttention(
            id: id,
            message: "恢复已完成，但旧引用暂存副本需要清理：\(referenceStaging.path)"
        )

        let recovery = try TrashService(
            transactionStore: store
        ).recoverInterruptedTransactions()
        let cleared = try #require(try store.load(id: id))

        #expect(recovery.completedTransactions.isEmpty)
        #expect(recovery.attentionMessages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: referenceStaging.path))
        #expect(!cleared.needsAttention)
        #expect(cleared.attentionMessage == nil)
        #expect(cleared.phase == .historyApplied)
    }

    @Test("缺少可选身份字段的删除记录仍可解码")
    func decodesMinimalTrashRecord() throws {
        struct MinimalTrashRecord: Encodable {
            let id: UUID
            let originalPath: String
            let trashedPath: String
            let trashedAt: Date
            let restoredAt: Date?
            let sourceID: String
            let origin: FileOrigin
            let fileSize: Int64
            let modificationDate: Date?
        }

        let minimal = MinimalTrashRecord(
            id: UUID(),
            originalPath: "/tmp/Inbox/sample.txt",
            trashedPath: "/tmp/.Trash/sample.txt",
            trashedAt: Date(timeIntervalSinceReferenceDate: 123),
            restoredAt: nil,
            sourceID: "downloads",
            origin: .downloads,
            fileSize: 42,
            modificationDate: Date(timeIntervalSinceReferenceDate: 100)
        )

        let decoded = try JSONDecoder().decode(TrashRecord.self, from: JSONEncoder().encode(minimal))

        #expect(decoded.id == minimal.id)
        #expect(decoded.transactionID == nil)
        #expect(decoded.resourceIdentifier == nil)
        #expect(decoded.resourceIdentifierSession == nil)
        #expect(decoded.contentHash == nil)
        #expect(decoded.fileSize == minimal.fileSize)
    }

    @Test("缺少内容身份的删除记录拒绝恢复")
    func rejectsRestoreForRecordWithoutIdentity() throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let contents = Data("sample trash".utf8)
        let original = fixture.inbox.appendingPathComponent("incomplete.txt")
        let trashed = fixture.fakeTrash.appendingPathComponent("incomplete.txt")
        try contents.write(to: trashed)
        let values = try trashed.resourceValues(forKeys: [.contentModificationDateKey])
        let record = TrashRecord(
            originalPath: original.path,
            trashedPath: trashed.path,
            sourceID: "downloads",
            origin: .downloads,
            fileSize: Int64(contents.count),
            modificationDate: values.contentModificationDate
        )

        expectError(.trashedFileChanged) {
            _ = try service.restore(record)
        }
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test("跨进程恢复不比较易失的资源标识")
    func restoreSkipsResourceIdentifierFromPreviousSession() throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let original = fixture.inbox.appendingPathComponent("cross-session.txt")
        let trashed = fixture.fakeTrash.appendingPathComponent("cross-session.txt")
        let replacement = fixture.fakeTrash.appendingPathComponent("replacement.txt")
        let contents = Data("same verified contents".utf8)
        let stableModificationDate = Date(timeIntervalSinceReferenceDate: 345_678)
        try contents.write(to: trashed)
        try FileManager.default.setAttributes(
            [.modificationDate: stableModificationDate],
            ofItemAtPath: trashed.path
        )
        let captured = try makeTrashRecord(
            original: original,
            trashed: trashed,
            fileSize: Int64(contents.count)
        )
        try contents.write(to: replacement)
        try FileManager.default.setAttributes(
            [.modificationDate: stableModificationDate],
            ofItemAtPath: replacement.path
        )
        try FileManager.default.removeItem(at: trashed)
        try FileManager.default.moveItem(at: replacement, to: trashed)
        let previousSessionRecord = TrashRecord(
            id: captured.id,
            originalPath: captured.originalPath,
            trashedPath: captured.trashedPath,
            trashedAt: captured.trashedAt,
            sourceID: captured.sourceID,
            origin: captured.origin,
            fileSize: captured.fileSize,
            modificationDate: captured.modificationDate,
            resourceIdentifier: captured.resourceIdentifier,
            resourceIdentifierSession: "previous-process-session",
            contentHash: captured.contentHash
        )
        let replacementSnapshot = try service.validate(
            item: makeItem(url: trashed, fileSize: Int64(contents.count)),
            allowedRoot: fixture.fakeTrash
        )
        #expect(replacementSnapshot.modificationDate == captured.modificationDate)
        #expect(replacementSnapshot.contentHash == captured.contentHash)
        #expect(replacementSnapshot.resourceIdentifier != captured.resourceIdentifier)

        let restored = try service.restore(previousSessionRecord)

        #expect(restored.isRestored)
        #expect(try Data(contentsOf: original) == contents)
    }

    @Test("缺失文件通过最近存在祖先解析所属卷")
    func resolvesVolumeFromNearestExistingAncestor() throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let missing = fixture.inbox
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("file.txt")
        let expectedVolume = try #require(
            fixture.inbox.resourceValues(forKeys: [.volumeURLKey]).volume
        )

        let resolved = service.nearestExistingAncestorVolumeURL(for: missing)

        #expect(resolved == expectedVolume.standardizedFileURL)
    }

    private func makeItem(
        url: URL,
        fileSize: Int64,
        origin: FileOrigin = .downloads,
        operation: RoutingOperation = .move
    ) -> InboxItem {
        InboxItem(
            url: url,
            fileSize: fileSize,
            suggestion: ClassificationSuggestion(
                category: .needsReview,
                reason: "测试",
                confidence: 0.5
            ),
            origin: origin,
            routingOperation: operation,
            sourceID: "test-source",
            sourceDisplayName: "测试来源"
        )
    }

    private func makeReferenceItem(
        url: URL,
        identity: FileIdentitySnapshot
    ) -> InboxItem {
        InboxItem(
            url: url,
            fileSize: identity.size,
            suggestion: ClassificationSuggestion(
                category: .needsReview,
                reason: "测试",
                confidence: 1
            ),
            origin: .wechat,
            routingOperation: .reference,
            sourceID: "app-attachment-root",
            sourceDisplayName: "App 接收文件",
            modificationDate: identity.modificationDate,
            resourceIdentifier: nil,
            resourceIdentifierSession: nil,
            persistentIdentity: identity.persistentIdentity
        )
    }

    private func fakeTrashService(
        in directory: URL,
        rejectingDirectory: String? = nil,
        transactionStore: FileTransactionStore? = nil
    ) -> TrashService {
        TrashService(trashItemHandler: { source in
            if source.deletingLastPathComponent().standardizedFileURL.path == rejectingDirectory {
                throw InjectedTrashFailure.stop
            }
            let destination = directory.appendingPathComponent(
                "\(UUID().uuidString)-\(source.lastPathComponent)"
            )
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }, transactionStore: transactionStore)
    }

    private func expectError(_ expected: TrashError, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("预期抛出 \(expected)，但操作成功")
        } catch let error as TrashError {
            #expect(error == expected)
        } catch {
            Issue.record("预期抛出 \(expected)，实际为 \(error)")
        }
    }

    private func makeTrashRecord(
        original: URL,
        trashed: URL,
        fileSize: Int64
    ) throws -> TrashRecord {
        let item = makeItem(url: trashed, fileSize: fileSize)
        let snapshot = try service.validate(item: item, allowedRoot: trashed.deletingLastPathComponent())
        return TrashRecord(
            originalPath: original.path,
            trashedPath: trashed.path,
            sourceID: "test-source",
            origin: .downloads,
            fileSize: snapshot.size,
            modificationDate: snapshot.modificationDate,
            resourceIdentifier: snapshot.resourceIdentifier,
            resourceIdentifierSession: snapshot.resourceIdentifier == nil
                ? nil
                : FileIdentitySnapshot.currentResourceIdentifierSession,
            contentHash: snapshot.contentHash
        )
    }

    private struct Fixture {
        let root: URL
        let allowedRoot: URL
        let outsideRoot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GuiliuTrashTests-\(UUID().uuidString)", isDirectory: true)
            allowedRoot = root.appendingPathComponent("Allowed", isDirectory: true)
            outsideRoot = root.appendingPathComponent("Allowed-Sibling", isDirectory: true)
            try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct RestoreFixture {
        let root: URL
        let inbox: URL
        let fakeTrash: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GuiliuRestoreTests-\(UUID().uuidString)", isDirectory: true)
            inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            fakeTrash = root.appendingPathComponent("FakeTrash", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct ReferenceFixture {
        let root: URL
        let appFiles: URL
        let category: URL
        let fakeTrash: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GuiliuReferenceTrashTests-\(UUID().uuidString)", isDirectory: true)
            appFiles = root.appendingPathComponent("AppFiles", isDirectory: true)
            category = root.appendingPathComponent("LibraryCategory", isDirectory: true)
            fakeTrash = root.appendingPathComponent("FakeTrash", isDirectory: true)
            try FileManager.default.createDirectory(at: appFiles, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
