import Foundation
import Testing
@testable import GuiliuCore

@Suite("待归类文件删除安全校验")
struct TrashServiceTests {
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
        #expect(decoded.resourceIdentifier == nil)
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
}
