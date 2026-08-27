import Foundation
import CryptoKit
import Darwin

public struct RoutingRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var originalPath: String
    public var destinationPath: String
    public var category: FileCategory
    public let routedAt: Date
    public var restoredAt: Date?
    public let operation: RoutingOperation?
    public let origin: FileOrigin?
    public let sourceFileSize: Int64?
    public var tags: [SmartTag]?
    public let sourceContentHash: String?
    public let sourceID: String?
    public var sourceIdentity: FileIdentitySnapshot?
    public var sourcePOSIXIdentity: POSIXFileIdentity?
    public var referenceIdentity: SymbolicLinkIdentitySnapshot?

    public init(
        id: UUID = UUID(),
        originalPath: String,
        destinationPath: String,
        category: FileCategory,
        routedAt: Date = .now,
        restoredAt: Date? = nil,
        operation: RoutingOperation = .move,
        origin: FileOrigin = .unknown,
        sourceFileSize: Int64? = nil,
        tags: [SmartTag] = [],
        sourceContentHash: String? = nil,
        sourceID: String? = nil,
        sourceIdentity: FileIdentitySnapshot? = nil,
        sourcePOSIXIdentity: POSIXFileIdentity? = nil,
        referenceIdentity: SymbolicLinkIdentitySnapshot? = nil
    ) {
        self.id = id
        self.originalPath = originalPath
        self.destinationPath = destinationPath
        self.category = category
        self.routedAt = routedAt
        self.restoredAt = restoredAt
        self.operation = operation
        self.origin = origin
        self.sourceFileSize = sourceFileSize
        self.tags = tags
        self.sourceContentHash = sourceContentHash
        self.sourceID = sourceID
        self.sourceIdentity = sourceIdentity
        self.sourcePOSIXIdentity = sourcePOSIXIdentity
        self.referenceIdentity = referenceIdentity
    }

    public var isRestored: Bool { restoredAt != nil }
    public var effectiveOperation: RoutingOperation { operation ?? .move }
    public var effectiveOrigin: FileOrigin { origin ?? .unknown }
}

public enum RoutingError: LocalizedError, Equatable {
    case sourceMissing
    case unsupportedSource
    case sourceChanged
    case destinationRootMissing
    case routedFileMissing
    case originalCopyMissing
    case copyChanged
    case referenceChanged
    case moveRecoveryRequired(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing: "原文件已经不存在，可能已被其他 App 移动。"
        case .unsupportedSource: "文件夹、App 或符号链接不能归档。"
        case .sourceChanged: "文件在进入待归类队列后已发生变化。为避免归档错文件，操作已取消。"
        case .destinationRootMissing: "文件库位置不可用，请在设置中重新选择。"
        case .routedFileMissing: "归档后的文件已经不存在，无法撤销。"
        case .originalCopyMissing: "微信或其他 App 管理的原件已经不存在；为避免丢失唯一副本，归流不会删除归档副本。"
        case .copyChanged: "原件或归档副本的大小已经改变；为避免删除有差异的文件，归流不会自动撤销。"
        case .referenceChanged: "归档引用已被修改，归流不会自动删除它。"
        case .moveRecoveryRequired(let recoveryPath):
            "移动遇到文件冲突，归流没有覆盖任何现有文件。需要人工核对的文件保留在：\(recoveryPath)"
        }
    }
}

public struct RoutingService: Sendable {
    private let forceCrossVolumeMoveForTesting: Bool
    private let afterSourceStagedForTesting: (@Sendable (_ staged: URL, _ original: URL) throws -> Void)?
    private let duringCrossVolumeCopyForTesting: (@Sendable (_ source: URL, _ original: URL) throws -> Void)?

    public init() {
        forceCrossVolumeMoveForTesting = false
        afterSourceStagedForTesting = nil
        duringCrossVolumeCopyForTesting = nil
    }

    init(
        forceCrossVolumeMoveForTesting: Bool,
        afterSourceStagedForTesting: (@Sendable (_ staged: URL, _ original: URL) throws -> Void)? = nil,
        duringCrossVolumeCopyForTesting: (@Sendable (_ source: URL, _ original: URL) throws -> Void)? = nil
    ) {
        self.forceCrossVolumeMoveForTesting = forceCrossVolumeMoveForTesting
        self.afterSourceStagedForTesting = afterSourceStagedForTesting
        self.duringCrossVolumeCopyForTesting = duringCrossVolumeCopyForTesting
    }

    public func prepareLibrary(at root: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RoutingError.destinationRootMissing
        }

        for category in FileCategory.allCases {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(category.displayName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    public func route(
        file source: URL,
        to category: FileCategory,
        libraryRoot: URL,
        operation: RoutingOperation = .move,
        origin: FileOrigin = .unknown,
        tags: [SmartTag] = [],
        sourceID: String? = nil,
        expectedIdentity: FileIdentitySnapshot? = nil
    ) throws -> RoutingRecord {
        try prepareLibrary(at: libraryRoot)
        let categoryDirectory = libraryRoot.appendingPathComponent(category.displayName, isDirectory: true)
        let destination = uniqueDestination(for: source.lastPathComponent, in: categoryDirectory)

        // Validate only after all destination preparation, immediately before
        // touching the source. This keeps the path-based TOCTOU window narrow.
        let sourceIdentity = try validateSource(source, expectedIdentity: expectedIdentity)
        let sourcePOSIXIdentity = try POSIXFileIdentity.captureRegularFile(at: source)
        let sourceSize: Int64? = sourceIdentity.size
        let sourceContentHash = operation == .copy ? Self.sha256(of: source) : nil
        var referenceIdentity: SymbolicLinkIdentitySnapshot?
        if operation == .copy, sourceContentHash == nil {
            throw RoutingError.copyChanged
        }

        switch operation {
        case .move:
            try moveFileSafely(
                from: source,
                to: destination,
                expectedIdentity: sourceIdentity
            )
        case .copy:
            let temporary = categoryDirectory.appendingPathComponent(".guiliu-\(UUID().uuidString).partial")
            do {
                _ = try validateSource(source, expectedIdentity: sourceIdentity)
                try FileManager.default.copyItem(at: source, to: temporary)
                let copiedSize = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
                guard sourceSize == copiedSize else {
                    throw RoutingError.copyChanged
                }
                guard let expectedHash = sourceContentHash,
                      Self.sha256(of: temporary) == expectedHash,
                      Self.sha256(of: source) == expectedHash else {
                    throw RoutingError.copyChanged
                }
                _ = try validateSource(source, expectedIdentity: sourceIdentity)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        case .reference:
            _ = try validateSource(source, expectedIdentity: sourceIdentity)
            try FileManager.default.createSymbolicLink(
                at: destination,
                withDestinationURL: source.standardizedFileURL
            )
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path))
                    == source.standardizedFileURL.path else {
                try? FileManager.default.removeItem(at: destination)
                throw RoutingError.referenceChanged
            }
            do {
                referenceIdentity = try SymbolicLinkIdentitySnapshot.capture(at: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw RoutingError.referenceChanged
            }
        }

        return RoutingRecord(
            originalPath: source.path,
            destinationPath: destination.path,
            category: category,
            operation: operation,
            origin: origin,
            sourceFileSize: sourceSize,
            tags: tags,
            sourceContentHash: sourceContentHash,
            sourceID: sourceID,
            sourceIdentity: sourceIdentity,
            sourcePOSIXIdentity: sourcePOSIXIdentity,
            referenceIdentity: referenceIdentity
        )
    }

    private func validateSource(
        _ source: URL,
        expectedIdentity: FileIdentitySnapshot?
    ) throws -> FileIdentitySnapshot {
        let current: FileIdentitySnapshot
        do {
            current = try FileIdentitySnapshot.capture(at: source)
        } catch FileIdentityError.missing {
            throw RoutingError.sourceMissing
        } catch FileIdentityError.unsupportedItem {
            throw RoutingError.unsupportedSource
        } catch {
            throw RoutingError.sourceChanged
        }
        if let expectedIdentity,
           !current.matches(
                expectedSize: expectedIdentity.size,
                expectedModificationDate: expectedIdentity.modificationDate,
                expectedResourceIdentifier: expectedIdentity.resourceIdentifier,
                expectedResourceIdentifierSession: expectedIdentity.resourceIdentifierSession,
                expectedPersistentIdentity: expectedIdentity.persistentIdentity
           ) {
            throw RoutingError.sourceChanged
        }
        return current
    }

    /// Routes an inbox item only if the path still refers to the exact ordinary
    /// file snapshot that was queued. The check is performed inside the routing
    /// service immediately before destination preparation and the file operation.
    public func route(
        item: InboxItem,
        to category: FileCategory,
        libraryRoot: URL,
        operation: RoutingOperation? = nil,
        tags: [SmartTag]? = nil
    ) throws -> RoutingRecord {
        try route(
            file: item.url,
            to: category,
            libraryRoot: libraryRoot,
            operation: operation ?? item.routingOperation,
            origin: item.origin,
            tags: tags ?? item.tags,
            sourceID: item.sourceID,
            expectedIdentity: item.fileIdentitySnapshot
        )
    }

    /// Moves an already archived item between two category directories. Both
    /// directories live under the same library root, so this is a rename/move
    /// and never creates a second copy of the file.
    public func reclassify(
        file source: URL,
        from currentCategory: FileCategory,
        to newCategory: FileCategory,
        libraryRoot: URL
    ) throws -> URL {
        guard currentCategory != newCategory else { return source }
        try prepareLibrary(at: libraryRoot)

        let standardizedSource = source.standardizedFileURL
        let expectedParent = libraryRoot
            .appendingPathComponent(currentCategory.displayName, isDirectory: true)
            .standardizedFileURL
        guard standardizedSource.deletingLastPathComponent() == expectedParent else {
            throw RoutingError.sourceChanged
        }

        var status = stat()
        guard lstat(standardizedSource.path, &status) == 0 else {
            throw RoutingError.sourceMissing
        }
        let kind = status.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFLNK else {
            throw RoutingError.unsupportedSource
        }

        let targetDirectory = libraryRoot.appendingPathComponent(newCategory.displayName, isDirectory: true)
        let destination = uniqueDestination(for: standardizedSource.lastPathComponent, in: targetDirectory)
        try FileManager.default.moveItem(at: standardizedSource, to: destination)
        return destination
    }

    public func restore(_ record: RoutingRecord) throws -> RoutingRecord {
        let destination = URL(fileURLWithPath: record.destinationPath)
        let referenceExists = record.effectiveOperation == .reference
            && (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil
        guard referenceExists || FileManager.default.fileExists(atPath: destination.path) else {
            throw RoutingError.routedFileMissing
        }

        var updated = record
        switch record.effectiveOperation {
        case .move:
            let original = URL(fileURLWithPath: record.originalPath)
            let restoredDestination = uniqueDestination(for: original.lastPathComponent, in: original.deletingLastPathComponent())
            let routedIdentity = try validateSource(destination, expectedIdentity: nil)
            try moveFileSafely(
                from: destination,
                to: restoredDestination,
                expectedIdentity: routedIdentity
            )
            updated.destinationPath = restoredDestination.path
        case .copy:
            let original = URL(fileURLWithPath: record.originalPath)
            guard FileManager.default.fileExists(atPath: original.path) else {
                throw RoutingError.originalCopyMissing
            }
            let originalSize = try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
            let destinationSize = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
            if let expected = record.sourceFileSize,
               originalSize != expected || destinationSize != expected {
                throw RoutingError.copyChanged
            }
            guard let originalHash = Self.sha256(of: original),
                  let destinationHash = Self.sha256(of: destination),
                  originalHash == destinationHash else {
                throw RoutingError.copyChanged
            }
            if let expectedHash = record.sourceContentHash,
               originalHash != expectedHash {
                throw RoutingError.copyChanged
            }
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: destination, resultingItemURL: &trashedURL)
            if let trashedURL {
                updated.destinationPath = (trashedURL as URL).path
            }
        case .reference:
            let expectedTarget = URL(fileURLWithPath: record.originalPath).standardizedFileURL.path
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
                  target == expectedTarget else {
                throw RoutingError.referenceChanged
            }
            try FileManager.default.removeItem(at: destination)
        }
        updated.restoredAt = .now
        return updated
    }

    public func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let sourceURL = URL(fileURLWithPath: filename)
        let ext = sourceURL.pathExtension
        let stem = sourceURL.deletingPathExtension().lastPathComponent

        for index in 2...9_999 {
            let newName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let next = directory.appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }

        let fallback = "\(stem) \(UUID().uuidString)"
        return directory.appendingPathComponent(ext.isEmpty ? fallback : "\(fallback).\(ext)")
    }

    /// Moves a file without allowing Foundation to silently implement a
    /// cross-volume move as an unverified copy followed by a delete.
    ///
    /// A same-volume destination uses one exclusive atomic rename. When that
    /// reports `EXDEV`, the original remains visible at its normal path while
    /// a verified temporary copy is built on the destination volume. Only
    /// after that copy is atomically committed is the source briefly renamed
    /// in its own directory and removed.
    private func moveFileSafely(
        from source: URL,
        to destination: URL,
        expectedIdentity: FileIdentitySnapshot
    ) throws {
        // Keep the last identity check immediately adjacent to the atomic
        // same-volume attempt. On EXDEV, rename leaves the source untouched.
        _ = try validateSource(source, expectedIdentity: expectedIdentity)
        if !forceCrossVolumeMoveForTesting {
            switch try exclusiveRename(from: source, to: destination) {
            case .moved:
                do {
                    // Close the final validate/rename race. If the path was
                    // replaced between those calls, move it back without ever
                    // overwriting a new occupant of the original path.
                    _ = try validateSource(destination, expectedIdentity: expectedIdentity)
                    return
                } catch let identityError {
                    let rollbackResult: ExclusiveRenameResult
                    do {
                        rollbackResult = try exclusiveRename(from: destination, to: source)
                    } catch {
                        throw RoutingError.moveRecoveryRequired(destination.path)
                    }
                    guard case .moved = rollbackResult else {
                        throw RoutingError.moveRecoveryRequired(destination.path)
                    }
                    throw identityError
                }
            case .crossVolume:
                break
            }
        }

        try copyFileAcrossVolumes(
            source,
            to: destination,
            expectedIdentity: expectedIdentity
        )
    }

    private func copyFileAcrossVolumes(
        _ source: URL,
        to destination: URL,
        expectedIdentity: FileIdentitySnapshot
    ) throws {
        let destinationDirectory = destination.deletingLastPathComponent()
        let partial = uniqueHiddenURL(
            prefix: ".guiliu-transfer",
            preservingExtensionOf: destination,
            in: destinationDirectory,
            marker: "partial"
        )

        guard let sourceHash = Self.sha256(of: source) else {
            throw RoutingError.copyChanged
        }

        var committed = false
        do {
            _ = try validateSource(source, expectedIdentity: expectedIdentity)
            try duringCrossVolumeCopyForTesting?(source, source)
            try FileManager.default.copyItem(at: source, to: partial)

            let copiedSize = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
            guard copiedSize == expectedIdentity.size,
                  Self.sha256(of: partial) == sourceHash,
                  Self.sha256(of: source) == sourceHash else {
                throw RoutingError.copyChanged
            }
            _ = try validateSource(source, expectedIdentity: expectedIdentity)

            // Make the verified file contents durable before publishing the
            // destination name. F_FULLFSYNC asks macOS to flush through drive
            // caches where supported; fsync remains the portable fallback.
            try makeFileDurable(at: partial)

            // The partial and destination share a parent, so this commit must
            // be atomic. RENAME_EXCL also closes the same-name race without
            // overwriting a file created after uniqueDestination was chosen.
            switch try exclusiveRename(from: partial, to: destination) {
            case .moved:
                committed = true
            case .crossVolume:
                throw posixError(EXDEV, from: partial, to: destination)
            }
            try makeDirectoryDurable(at: destinationDirectory)

            // Commit is durable and visible before the source path is touched.
            // The remaining rename/delete window is short; a crash here can
            // leave a duplicate, but never an invisible sole copy.
            let stagedSource = uniqueHiddenURL(
                prefix: ".guiliu-move",
                preservingExtensionOf: source,
                in: source.deletingLastPathComponent()
            )
            _ = try validateSource(source, expectedIdentity: expectedIdentity)
            switch try exclusiveRename(from: source, to: stagedSource) {
            case .moved:
                break
            case .crossVolume:
                throw posixError(EXDEV, from: source, to: stagedSource)
            }
            do {
                try afterSourceStagedForTesting?(stagedSource, source)
                _ = try validateSource(stagedSource, expectedIdentity: expectedIdentity)
            } catch let stagedError {
                // The path may have been atomically replaced in the tiny
                // validate/rename window. Put the staged object back without
                // overwriting anything that has since occupied the source.
                let rollbackResult: ExclusiveRenameResult
                do {
                    rollbackResult = try exclusiveRename(from: stagedSource, to: source)
                } catch {
                    throw RoutingError.moveRecoveryRequired(stagedSource.path)
                }
                guard case .moved = rollbackResult else {
                    throw RoutingError.moveRecoveryRequired(stagedSource.path)
                }
                throw stagedError
            }
            try FileManager.default.removeItem(at: stagedSource)
        } catch {
            if !committed {
                try? FileManager.default.removeItem(at: partial)
            }
            throw error
        }
    }

    private enum ExclusiveRenameResult {
        case moved
        case crossVolume
    }

    /// Darwin's RENAME_EXCL guarantees that an unexpected same-name file is
    /// never overwritten. Unlike FileManager.moveItem, it also exposes EXDEV
    /// instead of transparently copying across volumes.
    private func exclusiveRename(from source: URL, to destination: URL) throws -> ExclusiveRenameResult {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result != 0 else { return .moved }

        let errorCode = errno
        if errorCode == EXDEV { return .crossVolume }
        throw posixError(errorCode, from: source, to: destination)
    }

    private func makeFileDurable(at url: URL) throws {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw posixError(errno, from: url, to: url)
        }
        defer { close(descriptor) }

        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        let fullSyncError = errno
        guard fullSyncError == ENOTSUP || fullSyncError == EINVAL || fullSyncError == ENOTTY else {
            throw posixError(fullSyncError, from: url, to: url)
        }
        guard fsync(descriptor) == 0 else {
            throw posixError(errno, from: url, to: url)
        }
    }

    private func makeDirectoryDurable(at url: URL) throws {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw posixError(errno, from: url, to: url)
        }
        defer { close(descriptor) }

        // APFS may report EINVAL/ENOTSUP for a directory sync even though the
        // file itself has already been fully flushed. Other errors are real.
        guard fsync(descriptor) == 0 else {
            let errorCode = errno
            guard errorCode == EINVAL || errorCode == ENOTSUP else {
                throw posixError(errorCode, from: url, to: url)
            }
            return
        }
    }

    private func posixError(_ code: Int32, from source: URL, to destination: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(code)),
                NSFilePathErrorKey: source.path,
                "GuiliuDestinationFilePath": destination.path
            ]
        )
    }

    private func uniqueHiddenURL(
        prefix: String,
        preservingExtensionOf source: URL,
        in directory: URL,
        marker: String? = nil
    ) -> URL {
        let ext = source.pathExtension
        let markerSuffix = marker.map { ".\($0)" } ?? ""
        let extensionSuffix = ext.isEmpty ? "" : ".\(ext)"
        return directory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)\(markerSuffix)\(extensionSuffix)"
        )
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
}
