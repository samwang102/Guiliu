import Darwin
import Foundation

public enum FileRenameError: LocalizedError, Equatable {
    case invalidName
    case sourceMissing
    case outsideAllowedLocation
    case unsupportedItem
    case sourceChanged

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "请输入有效的文件名；名称不能包含斜杠、冒号或换行。"
        case .sourceMissing:
            "文件已经不存在，可能已被其他 App 移动。"
        case .outsideAllowedLocation:
            "文件不在允许重命名的位置，操作已取消。"
        case .unsupportedItem:
            "这个项目不能由归流重命名。"
        case .sourceChanged:
            "文件进入待归类队列后已发生变化。为避免改错文件，重命名已取消。"
        }
    }
}

public struct FileRenameService: Sendable {
    public init() {}

    /// Renames one direct child of an explicitly allowed directory. The UI
    /// supplies only the stem, so the original extension can never be changed
    /// accidentally. Existing files are preserved by choosing a numbered name.
    public func rename(
        file source: URL,
        toBaseName requestedBaseName: String,
        in allowedDirectory: URL,
        expectedIdentity: FileIdentitySnapshot? = nil,
        allowSymbolicLink: Bool = false
    ) throws -> URL {
        let source = source.standardizedFileURL
        let allowedDirectory = allowedDirectory.standardizedFileURL
        guard source.deletingLastPathComponent().path == allowedDirectory.path else {
            throw FileRenameError.outsideAllowedLocation
        }

        var status = stat()
        guard lstat(source.path, &status) == 0 else {
            throw FileRenameError.sourceMissing
        }
        let kind = status.st_mode & S_IFMT
        guard kind == S_IFREG || (allowSymbolicLink && kind == S_IFLNK) else {
            throw FileRenameError.unsupportedItem
        }

        if let expectedIdentity {
            guard kind == S_IFREG,
                  let current = try? FileIdentitySnapshot.capture(at: source),
                  current.matches(
                    expectedSize: expectedIdentity.size,
                    expectedModificationDate: expectedIdentity.modificationDate,
                    expectedResourceIdentifier: expectedIdentity.resourceIdentifier,
                    expectedResourceIdentifierSession: expectedIdentity.resourceIdentifierSession,
                    expectedPersistentIdentity: expectedIdentity.persistentIdentity
                  ) else {
                throw FileRenameError.sourceChanged
            }
        }

        let baseName = requestedBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(baseName) else { throw FileRenameError.invalidName }

        let ext = source.pathExtension
        let filename = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        if filename == source.lastPathComponent { return source }

        let destination = uniqueDestination(for: filename, in: allowedDirectory)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            if lstat(source.path, &status) != 0 { throw FileRenameError.sourceMissing }
            throw error
        }
    }

    private func isValid(_ baseName: String) -> Bool {
        guard !baseName.isEmpty, baseName != ".", baseName != ".." else { return false }
        return !baseName.unicodeScalars.contains { scalar in
            scalar.value < 32 || scalar == "/" || scalar == ":"
        }
    }

    private func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard !exists(candidate) else {
            let filenameURL = URL(fileURLWithPath: filename)
            let ext = filenameURL.pathExtension
            let stem = filenameURL.deletingPathExtension().lastPathComponent
            for index in 2...9_999 {
                let nextName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
                let next = directory.appendingPathComponent(nextName)
                if !exists(next) { return next }
            }
            let fallback = "\(stem) \(UUID().uuidString)"
            return directory.appendingPathComponent(ext.isEmpty ? fallback : "\(fallback).\(ext)")
        }
        return candidate
    }

    private func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }
}
