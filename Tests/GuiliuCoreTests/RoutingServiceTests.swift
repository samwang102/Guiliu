import Foundation
import Testing
@testable import GuiliuCore

@Suite("文件路由与撤销")
struct RoutingServiceTests {
    private enum InjectedMoveFailure: Error {
        case stop
    }

    @Test("同路径同尺寸文件被替换后拒绝移动")
    func rejectsSameSizeReplacementBeforeMove() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuRouteIdentity")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("report.pdf")
        let original = Data("original".utf8)
        let replacement = Data("replaced".utf8)
        #expect(original.count == replacement.count)
        try original.write(to: source)
        let stableDate = Date(timeIntervalSinceReferenceDate: 123_456_789)
        try FileManager.default.setAttributes([.modificationDate: stableDate], ofItemAtPath: source.path)
        let identity = try FileIdentitySnapshot.capture(at: source)
        let item = makeItem(url: source, identity: identity, operation: .move)

        try FileManager.default.removeItem(at: source)
        try replacement.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: stableDate], ofItemAtPath: source.path)
        let replacementIdentity = try FileIdentitySnapshot.capture(at: source)
        #expect(replacementIdentity.size == identity.size)
        #expect(replacementIdentity.modificationDate == identity.modificationDate)
        #expect(replacementIdentity.resourceIdentifier != identity.resourceIdentifier)

        expectRoutingError(.sourceChanged) {
            _ = try RoutingService().route(
                item: item,
                to: .researchPapers,
                libraryRoot: fixture.library
            )
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: source) == replacement)
    }

    @Test("跨重启后临时资源 ID 变化不会误拒绝未变文件")
    func persistedIdentitySurvivesRestartWithoutFalseRejection() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuPersistentIdentity")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("paper.pdf")
        try Data("unchanged".utf8).write(to: source)
        let identity = try FileIdentitySnapshot.capture(at: source)
        _ = try #require(identity.persistentIdentity)

        let beforeRestart = InboxItem(
            url: source,
            fileSize: identity.size,
            suggestion: ClassificationSuggestion(category: .researchPapers, reason: "测试", confidence: 1),
            routingOperation: .move,
            modificationDate: identity.modificationDate,
            resourceIdentifier: "旧系统会话中的临时 ID",
            resourceIdentifierSession: "previous-system-session",
            persistentIdentity: identity.persistentIdentity
        )
        let persisted = try JSONDecoder().decode(
            InboxItem.self,
            from: JSONEncoder().encode(beforeRestart)
        )

        let record = try RoutingService().route(
            item: persisted,
            to: .researchPapers,
            libraryRoot: fixture.library
        )
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: record.destinationPath))
    }

    @Test("跨重启后同尺寸同时间替换仍由持久身份拒绝")
    func persistentIdentityRejectsDisguisedReplacementAfterRestart() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuPersistentReplacement")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("contract.pdf")
        let original = Data("original".utf8)
        let replacement = Data("replaced".utf8)
        #expect(original.count == replacement.count)
        try original.write(to: source)
        let stableDate = Date(timeIntervalSinceReferenceDate: 456_789)
        try FileManager.default.setAttributes([.modificationDate: stableDate], ofItemAtPath: source.path)
        let identity = try FileIdentitySnapshot.capture(at: source)
        _ = try #require(identity.persistentIdentity)
        let persisted = InboxItem(
            url: source,
            fileSize: identity.size,
            suggestion: ClassificationSuggestion(category: .documentsReports, reason: "测试", confidence: 1),
            routingOperation: .move,
            modificationDate: identity.modificationDate,
            resourceIdentifier: identity.resourceIdentifier,
            resourceIdentifierSession: "previous-system-session",
            persistentIdentity: identity.persistentIdentity
        )

        try FileManager.default.removeItem(at: source)
        try replacement.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: stableDate], ofItemAtPath: source.path)
        let replacementIdentity = try FileIdentitySnapshot.capture(at: source)
        #expect(replacementIdentity.persistentIdentity != identity.persistentIdentity)

        expectRoutingError(.sourceChanged) {
            _ = try RoutingService().route(
                item: persisted,
                to: .documentsReports,
                libraryRoot: fixture.library
            )
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: source) == replacement)
    }

    @Test("只含基础字段的待处理记录仍可解码")
    func decodesMinimalInboxItemWithoutPersistentIdentity() throws {
        struct MinimalInboxItem: Encodable {
            let id = UUID()
            let url = URL(fileURLWithPath: "/tmp/sample.pdf")
            let detectedAt = Date(timeIntervalSinceReferenceDate: 123)
            let fileSize: Int64 = 42
            let suggestion = ClassificationSuggestion(category: .researchPapers, reason: "基础记录", confidence: 0.8)
            let origin = FileOrigin.downloads
            let routingOperation = RoutingOperation.move
            let sourceID = "downloads"
            let sourceDisplayName = "下载文件夹"
            let tags: [SmartTag] = []
            let modificationDate: Date? = Date(timeIntervalSinceReferenceDate: 100)
            let resourceIdentifier: String? = "sample-volatile-id"
        }

        let decoded = try JSONDecoder().decode(
            InboxItem.self,
            from: JSONEncoder().encode(MinimalInboxItem())
        )
        #expect(decoded.resourceIdentifier == "sample-volatile-id")
        #expect(decoded.resourceIdentifierSession == nil)
        #expect(decoded.persistentIdentity == nil)
    }

    @Test("入队后大小变化时复制归档失败且保留原文件")
    func rejectsChangedFileBeforeCopy() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuRouteChangedCopy")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("slides.pptx")
        try Data("old".utf8).write(to: source)
        let item = makeItem(
            url: source,
            identity: try FileIdentitySnapshot.capture(at: source),
            operation: .copy
        )
        try Data("new and still downloading".utf8).write(to: source)

        expectRoutingError(.sourceChanged) {
            _ = try RoutingService().route(
                item: item,
                to: .presentations,
                libraryRoot: fixture.library
            )
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("目录不能作为归档源")
    func rejectsDirectorySource() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuRouteDirectory")
        defer { fixture.remove() }
        let directory = fixture.inbox.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = InboxItem(
            url: directory,
            fileSize: 0,
            suggestion: ClassificationSuggestion(category: .needsReview, reason: "测试", confidence: 0.5)
        )

        expectRoutingError(.unsupportedSource) {
            _ = try RoutingService().route(
                item: item,
                to: .needsReview,
                libraryRoot: fixture.library
            )
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("文件移动到固定分类并可撤销")
    func routeAndRestore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuTests-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = inbox.appendingPathComponent("研究.pdf")
        try Data("hello".utf8).write(to: source)

        let service = RoutingService()
        let record = try service.route(file: source, to: .researchPapers, libraryRoot: library)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: record.destinationPath))
        #expect(record.destinationPath.contains(FileCategory.researchPapers.displayName))

        let restored = try service.restore(record)
        #expect(restored.isRestored)
        #expect(FileManager.default.fileExists(atPath: restored.destinationPath))
        #expect(restored.destinationPath.contains("Inbox"))
    }

    @Test("已归档文件可再次修改分类且不会产生副本")
    func reclassifiesArchivedFileWithoutCopying() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuReclassify")
        defer { fixture.remove() }
        let service = RoutingService()
        try service.prepareLibrary(at: fixture.library)

        let source = fixture.library
            .appendingPathComponent(FileCategory.researchPapers.displayName, isDirectory: true)
            .appendingPathComponent("研究资料.pdf")
        let contents = Data("single archived file".utf8)
        try contents.write(to: source)

        let destination = try service.reclassify(
            file: source,
            from: .researchPapers,
            to: .organizationMaterials,
            libraryRoot: fixture.library
        )

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(destination.deletingLastPathComponent().lastPathComponent == "机构资料")
        #expect(try Data(contentsOf: destination) == contents)
    }

    @Test("模拟跨卷移动经过校验提交并保持撤销语义")
    func verifiedCrossVolumeMoveAndRestore() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuRouteCrossVolume")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("large-video.mp4")
        let contents = Data(repeating: 0x5A, count: 2_200_000)
        try contents.write(to: source)

        let service = RoutingService(forceCrossVolumeMoveForTesting: true)
        let record = try service.route(file: source, to: .visualMedia, libraryRoot: fixture.library)
        let destination = URL(fileURLWithPath: record.destinationPath)

        #expect(record.originalPath == source.path)
        #expect(record.effectiveOperation == .move)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == contents)
        #expect(try hiddenWorkFiles(in: fixture.inbox).isEmpty)
        #expect(try hiddenWorkFiles(in: destination.deletingLastPathComponent()).isEmpty)

        let restored = try service.restore(record)
        #expect(restored.isRestored)
        #expect(try Data(contentsOf: URL(fileURLWithPath: restored.destinationPath)) == contents)
    }

    @Test("跨卷复制期间源文件仍在原路径可见")
    func crossVolumeCopyKeepsSourceVisibleUntilCommit() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuRouteCrashSafeCrossVolume")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("large-data.bin")
        let contents = Data(repeating: 0x3C, count: 1_100_000)
        try contents.write(to: source)

        let service = RoutingService(
            forceCrossVolumeMoveForTesting: true,
            duringCrossVolumeCopyForTesting: { copyingSource, originalURL in
                #expect(copyingSource == originalURL)
                #expect(FileManager.default.fileExists(atPath: originalURL.path))
                guard let current = try? Data(contentsOf: originalURL) else {
                    Issue.record("跨卷复制期间源文件应保持可读")
                    return
                }
                #expect(current == contents)
            }
        )

        let record = try service.route(file: source, to: .dataModels, libraryRoot: fixture.library)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: record.destinationPath)) == contents)
    }

    @Test("目标同名竞争不会覆盖且源文件会回滚")
    func destinationRaceDoesNotOverwriteAndRollsBack() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuRouteDestinationRace")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("report.pdf")
        let original = Data("original report".utf8)
        let intruder = Data("new destination occupant".utf8)
        try original.write(to: source)
        let destination = fixture.library
            .appendingPathComponent(FileCategory.researchPapers.displayName, isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)

        let service = RoutingService(
            forceCrossVolumeMoveForTesting: true,
            duringCrossVolumeCopyForTesting: { _, _ in
                try intruder.write(to: destination)
            }
        )

        #expect(throws: (any Error).self) {
            _ = try service.route(file: source, to: .researchPapers, libraryRoot: fixture.library)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: destination) == intruder)
        #expect(try hiddenWorkFiles(in: fixture.inbox).isEmpty)
    }

    @Test("跨卷提交后原路径被新文件占用时不会删除新文件")
    func sourceReplacementAfterCommitIsPreserved() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuRouteSourceRace")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("archive.zip")
        let original = Data("original archive".utf8)
        let replacement = Data("replacement file".utf8)
        try original.write(to: source)

        let service = RoutingService(
            forceCrossVolumeMoveForTesting: true,
            afterSourceStagedForTesting: { _, originalURL in
                try replacement.write(to: originalURL)
            }
        )

        let record = try service.route(file: source, to: .needsReview, libraryRoot: fixture.library)
        #expect(try Data(contentsOf: source) == replacement)
        #expect(try Data(contentsOf: URL(fileURLWithPath: record.destinationPath)) == original)
        #expect(try hiddenWorkFiles(in: fixture.inbox).isEmpty)
    }

    @Test("跨卷源暂存校验失败时原子回滚到原路径")
    func stagedIdentityFailureRollsBackSourcePath() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuRouteStagedRollback")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("changing.pdf")
        let original = Data("original bytes".utf8)
        try original.write(to: source)

        let service = RoutingService(
            forceCrossVolumeMoveForTesting: true,
            afterSourceStagedForTesting: { staged, _ in
                try Data("changed after staging".utf8).write(to: staged)
            }
        )

        expectRoutingError(.sourceChanged) {
            _ = try service.route(file: source, to: .needsReview, libraryRoot: fixture.library)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try hiddenWorkFiles(in: fixture.inbox).isEmpty)
    }

    @Test("同名文件不会被覆盖")
    func duplicateNameGetsSuffix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuDuplicates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("报告.pdf")
        try Data().write(to: existing)

        let result = RoutingService().uniqueDestination(for: "报告.pdf", in: root)
        #expect(result.lastPathComponent == "报告 2.pdf")
    }

    @Test("复制归档保留 App 原件并记录来源")
    func copyKeepsOriginalAndRecordsMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuCopy-\(UUID().uuidString)", isDirectory: true)
        let appFiles = root.appendingPathComponent("WeChat", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try FileManager.default.createDirectory(at: appFiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let contents = Data("微信收到的论文".utf8)
        let source = appFiles.appendingPathComponent("paper.pdf")
        try contents.write(to: source)

        let record = try RoutingService().route(
            file: source,
            to: .researchPapers,
            libraryRoot: library,
            operation: .copy,
            origin: .wechat
        )

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: record.destinationPath))
        #expect(try Data(contentsOf: source) == contents)
        #expect(try Data(contentsOf: URL(fileURLWithPath: record.destinationPath)) == contents)
        #expect(record.originalPath == source.path)
        #expect(record.operation == .copy)
        #expect(record.effectiveOperation == .copy)
        #expect(record.origin == .wechat)
        #expect(record.effectiveOrigin == .wechat)
        #expect(record.sourceFileSize == Int64(contents.count))
        #expect(record.sourceContentHash?.isEmpty == false)
    }

    @Test("引用归档不复制内容且撤销只删除引用")
    func referenceUsesSymbolicLinkAndKeepsOriginal() throws {
        let fixture = try RoutingFixture(prefix: "GuiliuReference")
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("wechat-paper.pdf")
        let contents = Data(repeating: 0x41, count: 1_200_000)
        try contents.write(to: source)

        let record = try RoutingService().route(
            file: source,
            to: .researchPapers,
            libraryRoot: fixture.library,
            operation: .reference,
            origin: .wechat
        )
        let reference = URL(fileURLWithPath: record.destinationPath)

        #expect(record.effectiveOperation == .reference)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: reference.path) == source.path)
        #expect((try reference.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)

        let restored = try RoutingService().restore(record)
        #expect(restored.isRestored)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: reference.path)) == nil)
    }

    @Test("复制归档的原件丢失时拒绝撤销并保留副本")
    func copyRestoreRejectsMissingOriginal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuCopyRestore-\(UUID().uuidString)", isDirectory: true)
        let appFiles = root.appendingPathComponent("WeChat", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try FileManager.default.createDirectory(at: appFiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = appFiles.appendingPathComponent("slides.pptx")
        try Data("presentation".utf8).write(to: source)
        let service = RoutingService()
        let record = try service.route(
            file: source,
            to: .presentations,
            libraryRoot: library,
            operation: .copy,
            origin: .wechat
        )
        try FileManager.default.removeItem(at: source)

        do {
            _ = try service.restore(record)
            Issue.record("原件已丢失时不应删除归档副本")
        } catch RoutingError.originalCopyMissing {
            // Expected: the archive copy is now the only known copy.
        } catch {
            Issue.record("应抛出 originalCopyMissing，实际为：\(error)")
        }

        #expect(FileManager.default.fileExists(atPath: record.destinationPath))
    }

    @Test("复制归档副本被同长度内容替换时拒绝撤销")
    func copyRestoreRejectsSameSizeContentChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuCopyHash-\(UUID().uuidString)", isDirectory: true)
        let appFiles = root.appendingPathComponent("WeChat", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try FileManager.default.createDirectory(at: appFiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalContents = Data("original".utf8)
        let changedContents = Data("tampered".utf8)
        #expect(originalContents.count == changedContents.count)
        let source = appFiles.appendingPathComponent("contract.pdf")
        try originalContents.write(to: source)
        let service = RoutingService()
        let record = try service.route(
            file: source,
            to: .documentsReports,
            libraryRoot: library,
            operation: .copy,
            origin: .wechat
        )
        let archivedCopy = URL(fileURLWithPath: record.destinationPath)
        try changedContents.write(to: archivedCopy)

        do {
            _ = try service.restore(record)
            Issue.record("归档副本内容变化后不应允许撤销")
        } catch RoutingError.copyChanged {
            // Expected: equal byte length is insufficient when hashes differ.
        } catch {
            Issue.record("应抛出 copyChanged，实际为：\(error)")
        }

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: archivedCopy.path))
        #expect(try Data(contentsOf: archivedCopy) == changedContents)
    }

    @Test("缺少可选来源字段的路由记录仍可解码")
    func decodesMinimalRoutingRecord() throws {
        struct MinimalRoutingRecord: Encodable {
            let id: UUID
            let originalPath: String
            let destinationPath: String
            let category: FileCategory
            let routedAt: Date
            let restoredAt: Date?
        }

        let minimal = MinimalRoutingRecord(
            id: UUID(),
            originalPath: "/tmp/Inbox/sample.pdf",
            destinationPath: "/tmp/Library/科研论文/sample.pdf",
            category: .researchPapers,
            routedAt: Date(timeIntervalSinceReferenceDate: 123),
            restoredAt: nil
        )

        let data = try JSONEncoder().encode(minimal)
        let decoded = try JSONDecoder().decode(RoutingRecord.self, from: data)

        #expect(decoded.id == minimal.id)
        #expect(decoded.operation == nil)
        #expect(decoded.origin == nil)
        #expect(decoded.sourceFileSize == nil)
        #expect(decoded.tags == nil)
        #expect(decoded.sourceContentHash == nil)
        #expect(decoded.effectiveOperation == .move)
        #expect(decoded.effectiveOrigin == .unknown)
    }

    private func makeItem(
        url: URL,
        identity: FileIdentitySnapshot,
        operation: RoutingOperation
    ) -> InboxItem {
        InboxItem(
            url: url,
            fileSize: identity.size,
            suggestion: ClassificationSuggestion(category: .needsReview, reason: "测试", confidence: 0.5),
            routingOperation: operation,
            modificationDate: identity.modificationDate,
            resourceIdentifier: identity.resourceIdentifier,
            resourceIdentifierSession: identity.resourceIdentifierSession,
            persistentIdentity: identity.persistentIdentity
        )
    }

    private func expectRoutingError(_ expected: RoutingError, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("预期抛出 \(expected)，但操作成功")
        } catch let error as RoutingError {
            #expect(error == expected)
        } catch {
            Issue.record("预期抛出 \(expected)，实际为 \(error)")
        }
    }

    private func hiddenWorkFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent.hasPrefix(".guiliu-") }
    }

    private struct RoutingFixture {
        let root: URL
        let inbox: URL
        let library: URL

        init(prefix: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            library = root.appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
