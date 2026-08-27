import Foundation

/// File-system identity that Foundation documents as persistent across system
/// restarts. Individual fields are optional because not every volume supports
/// document or generation identifiers.
public struct PersistentFileIdentity: Codable, Equatable, Hashable, Sendable {
    public let volumeUUID: String?
    public let documentIdentifier: Int?
    public let generationIdentifier: String?

    public init(
        volumeUUID: String?,
        documentIdentifier: Int?,
        generationIdentifier: String?
    ) {
        self.volumeUUID = volumeUUID
        self.documentIdentifier = documentIdentifier
        self.generationIdentifier = generationIdentifier
    }

    fileprivate var hasIdentityEvidence: Bool {
        generationIdentifier != nil || (volumeUUID != nil && documentIdentifier != nil)
    }

    fileprivate func matches(_ current: PersistentFileIdentity?) -> Bool {
        guard let current else { return false }
        if let volumeUUID, current.volumeUUID != volumeUUID { return false }
        if let documentIdentifier, current.documentIdentifier != documentIdentifier { return false }
        if let generationIdentifier, current.generationIdentifier != generationIdentifier { return false }
        return true
    }
}

/// A lightweight identity snapshot captured when a regular file enters the
/// inbox. It deliberately excludes directories, packages and symbolic links so
/// callers cannot accidentally turn a monitored folder into a routing target.
public struct FileIdentitySnapshot: Equatable, Sendable {
    public let size: Int64
    public let modificationDate: Date?
    public let resourceIdentifier: String?
    public let resourceIdentifierSession: String?
    public let persistentIdentity: PersistentFileIdentity?

    /// `fileResourceIdentifier` is explicitly documented as volatile across a
    /// system restart. This token scopes comparisons to this process only.
    public static let currentResourceIdentifierSession = UUID().uuidString

    public init(
        size: Int64,
        modificationDate: Date?,
        resourceIdentifier: String?,
        resourceIdentifierSession: String? = FileIdentitySnapshot.currentResourceIdentifierSession,
        persistentIdentity: PersistentFileIdentity? = nil
    ) {
        self.size = size
        self.modificationDate = modificationDate
        self.resourceIdentifier = resourceIdentifier
        self.resourceIdentifierSession = resourceIdentifierSession
        self.persistentIdentity = persistentIdentity
    }

    public static func capture(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> FileIdentitySnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FileIdentityError.missing
        }

        // URL resource values may be cached on a URL instance. Recreate it for
        // every check so reuse of the same path cannot reuse stale identity.
        let freshURL = URL(fileURLWithPath: url.path)
        let values = try freshURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .volumeUUIDStringKey,
            .documentIdentifierKey,
            .generationIdentifierKey
        ])
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isPackage != true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize else {
            throw FileIdentityError.unsupportedItem
        }

        let persistentIdentity = PersistentFileIdentity(
            volumeUUID: values.volumeUUIDString,
            documentIdentifier: values.documentIdentifier,
            generationIdentifier: encodedGenerationIdentifier(values.generationIdentifier)
        )
        return FileIdentitySnapshot(
            size: Int64(fileSize),
            modificationDate: values.contentModificationDate,
            resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
            persistentIdentity: persistentIdentity.hasIdentityEvidence ? persistentIdentity : nil
        )
    }

    /// Matches an inbox snapshot. Date and resource identity may be absent;
    /// size remains authoritative.
    public func matches(
        expectedSize: Int64,
        expectedModificationDate: Date?,
        expectedResourceIdentifier: String?,
        expectedResourceIdentifierSession: String? = nil,
        expectedPersistentIdentity: PersistentFileIdentity? = nil
    ) -> Bool {
        guard size == expectedSize else { return false }
        if let expectedModificationDate,
           modificationDate != expectedModificationDate {
            return false
        }
        if let expectedPersistentIdentity,
           !expectedPersistentIdentity.matches(persistentIdentity) {
            return false
        }
        if let expectedResourceIdentifier,
           let expectedResourceIdentifierSession,
           expectedResourceIdentifierSession == resourceIdentifierSession,
           resourceIdentifier != expectedResourceIdentifier {
            return false
        }
        return true
    }

    private static func encodedGenerationIdentifier(
        _ value: (any NSCopying & NSSecureCoding & NSObjectProtocol)?
    ) -> String? {
        guard let value else { return nil }
        if let data = value as? Data {
            return "data:\(data.base64EncodedString())"
        }
        guard let archived = try? NSKeyedArchiver.archivedData(
            withRootObject: value,
            requiringSecureCoding: true
        ) else { return nil }
        return "archive:\(archived.base64EncodedString())"
    }
}

public enum FileIdentityError: Error, Equatable, Sendable {
    case missing
    case unsupportedItem
}
