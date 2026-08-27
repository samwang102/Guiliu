import Foundation
import Testing
@testable import GuiliuCore

@Suite("监控扫描安全边界")
struct MonitoredFileScannerTests {
    @Test("外部删除文件后待归档协调器返回该文件")
    func deletedPendingFileIsReconciled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuPendingDeletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pendingFile = root.appendingPathComponent("later.pdf")
        try Data("pending".utf8).write(to: pendingFile)
        let location = MonitoredLocation(
            id: "downloads",
            displayName: "下载",
            url: root,
            origin: .downloads
        )

        try FileManager.default.removeItem(at: pendingFile)
        let missing = PendingFileReconciler.missingFileURLs(
            among: [pendingFile],
            monitoredLocations: [location],
            affectedBy: [pendingFile]
        )

        #expect(missing.map(\.standardizedFileURL.path) == [pendingFile.standardizedFileURL.path])
    }

    @Test("无关文件事件不会清除待归档项目")
    func unrelatedEventDoesNotRemovePendingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuPendingUnrelated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingFile = root.appendingPathComponent("missing.pdf")
        let unrelatedFile = root.appendingPathComponent("other.pdf")
        let location = MonitoredLocation(
            id: "downloads",
            displayName: "下载",
            url: root,
            origin: .downloads
        )

        let missing = PendingFileReconciler.missingFileURLs(
            among: [missingFile],
            monitoredLocations: [location],
            affectedBy: [unrelatedFile]
        )

        #expect(missing.isEmpty)
    }

    @Test("递归目录删除事件会清除其下方待归档项目")
    func deletedDirectoryReconcilesNestedPendingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuPendingDirectory-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("account", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pendingFile = nested.appendingPathComponent("paper.pdf")
        try Data("paper".utf8).write(to: pendingFile)
        let location = MonitoredLocation(
            id: "wechat",
            displayName: "微信接收文件",
            url: root,
            origin: .wechat,
            fileOwnership: .appManagedOriginal,
            recursive: true
        )

        try FileManager.default.removeItem(at: nested)
        let missing = PendingFileReconciler.missingFileURLs(
            among: [pendingFile],
            monitoredLocations: [location],
            affectedBy: [nested]
        )

        #expect(missing.map(\.standardizedFileURL.path) == [pendingFile.standardizedFileURL.path])
    }

    @Test("监控根目录不可用时保留待归档项目")
    func unavailableRootDoesNotErasePendingQueue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuPendingOffline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pendingFile = root.appendingPathComponent("paper.pdf")
        try Data("paper".utf8).write(to: pendingFile)
        let location = MonitoredLocation(
            id: "external",
            displayName: "暂时不可用目录",
            url: root,
            origin: .customFolder,
            recursive: true
        )

        try FileManager.default.removeItem(at: root)
        let missing = PendingFileReconciler.missingFileURLs(
            among: [pendingFile],
            monitoredLocations: [location]
        )

        #expect(missing.isEmpty)
    }

    @Test("增量事件只读取变化路径而不重扫同级文件")
    func incrementalScanTouchesOnlyChangedPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuScannerIncremental-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let changed = root.appendingPathComponent("changed.pdf")
        let untouched = root.appendingPathComponent("untouched.pdf")
        try Data("changed".utf8).write(to: changed)
        try Data("untouched".utf8).write(to: untouched)
        let location = MonitoredLocation(
            id: "downloads",
            displayName: "下载",
            url: root,
            origin: .downloads,
            recursive: false
        )

        let scanned = MonitoredFileScanner.scanChanges(at: [changed], in: [location])

        #expect(scanned.map(\.entry.url.standardizedFileURL.path) == [changed.standardizedFileURL.path])
        #expect(!scanned.contains { $0.entry.url.standardizedFileURL == untouched.standardizedFileURL })
    }

    @Test("默认扫描没有隐式数量上限")
    func defaultScanIncludesEveryOrdinaryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuScannerComplete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectedCount = 12
        for index in 0..<expectedCount {
            let file = root.appendingPathComponent("file-\(index).pdf")
            try Data("file \(index)".utf8).write(to: file)
        }
        let location = MonitoredLocation(
            id: "complete",
            displayName: "完整扫描目录",
            url: root,
            origin: .downloads,
            recursive: true
        )

        let scanned = MonitoredFileScanner.scan(in: [location])
        let effectivelyUnlimited = MonitoredFileScanner.scan(in: [location], limitPerLocation: Int.max)
        let explicitlyLimited = MonitoredFileScanner.scan(in: [location], limitPerLocation: 5)

        #expect(scanned.count == expectedCount)
        #expect(effectivelyUnlimited.count == expectedCount)
        #expect(explicitlyLimited.count == 5)
    }

    @Test("递归扫描时目录不消耗普通文件配额")
    func directoriesBeforeFileDoNotExhaustSmallLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuScannerLimit-\(UUID().uuidString)", isDirectory: true)
        let firstDirectory = root.appendingPathComponent("DirectoryFirst", isDirectory: true)
        let nestedDirectory = firstDirectory.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A recursive enumerator must visit both ancestor directories before it
        // can reach this file. With a raw-entry limit of one, the file starves.
        let file = nestedDirectory.appendingPathComponent("eventually.pdf")
        try Data("ordinary file".utf8).write(to: file)
        let location = MonitoredLocation(
            id: "recursive",
            displayName: "递归目录",
            url: root,
            origin: .wechat,
            fileOwnership: .appManagedOriginal,
            recursive: true
        )

        let scanned = MonitoredFileScanner.scan(in: [location], limitPerLocation: 1)

        #expect(scanned.count == 1)
        #expect(scanned.first?.entry.url.standardizedFileURL == file.standardizedFileURL)
    }

    @Test("父子监控重叠时只收普通文件且采用最具体来源")
    func overlappingRootsNeverProduceDirectoryItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuScanner-\(UUID().uuidString)", isDirectory: true)
        let appRoot = root.appendingPathComponent("AppManaged", isDirectory: true)
        let nested = appRoot.appendingPathComponent("account", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = nested.appendingPathComponent("paper.pdf")
        try Data("paper".utf8).write(to: file)
        let parent = MonitoredLocation(
            id: "example-parent",
            displayName: "旧父目录",
            url: root,
            origin: .customFolder
        )
        let appManaged = MonitoredLocation(
            id: "app-managed",
            displayName: "App 原件",
            url: appRoot,
            origin: .wechat,
            fileOwnership: .appManagedOriginal,
            recursive: true
        )

        let scanned = MonitoredFileScanner.scan(in: [parent, appManaged])

        #expect(scanned.count == 1)
        #expect(scanned.first?.entry.url.standardizedFileURL == file.standardizedFileURL)
        #expect(scanned.first?.entry.location.id == appManaged.id)
        #expect(!scanned.contains { $0.entry.url.standardizedFileURL == appRoot.standardizedFileURL })
    }
}
