import Foundation

public struct MonitoredFileEntry: Sendable {
    public let url: URL
    public let location: MonitoredLocation

    public init(url: URL, location: MonitoredLocation) {
        self.url = url
        self.location = location
    }
}

public struct MonitoredFileSnapshot: Sendable {
    public let entry: MonitoredFileEntry
    public let size: Int64
    public let modificationDate: Date?
    public let resourceIdentifier: String?

    public init(entry: MonitoredFileEntry, identity: FileIdentitySnapshot) {
        self.entry = entry
        size = identity.size
        modificationDate = identity.modificationDate
        resourceIdentifier = identity.resourceIdentifier
    }
}

/// Enumerates only routable ordinary files. Keeping this policy in the core
/// makes live monitoring and explicit historical import share the same safety
/// boundary, including when parent and child monitor roots overlap.
public enum MonitoredFileScanner {
    /// Pass a finite limit only for bounded callers such as focused tests. The
    /// default is deliberately complete because live monitoring uses the
    /// returned path set to decide which previously known files became stale.
    public static func scan(
        in locations: [MonitoredLocation],
        limitPerLocation: Int? = nil,
        fileManager: FileManager = .default
    ) -> [MonitoredFileSnapshot] {
        if let limitPerLocation, limitPerLocation <= 0 { return [] }
        var entriesByPath: [String: MonitoredFileSnapshot] = [:]

        for location in locations {
            if Task.isCancelled { break }
            var acceptedCount = 0
            if location.recursive {
                guard let enumerator = fileManager.enumerator(
                    at: location.url,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let url as URL in enumerator {
                    if Task.isCancelled { break }
                    guard accept(
                        url,
                        from: location,
                        fileManager: fileManager,
                        into: &entriesByPath
                    ) else { continue }
                    if let limitPerLocation {
                        acceptedCount += 1
                        if acceptedCount >= limitPerLocation { break }
                    }
                }
            } else {
                let urls = (try? fileManager.contentsOfDirectory(
                    at: location.url,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for url in urls {
                    if Task.isCancelled { break }
                    guard accept(
                        url,
                        from: location,
                        fileManager: fileManager,
                        into: &entriesByPath
                    ) else { continue }
                    if let limitPerLocation {
                        acceptedCount += 1
                        if acceptedCount >= limitPerLocation { break }
                    }
                }
            }
        }

        return Array(entriesByPath.values)
    }

    /// Resolves a coalesced FSEvents batch without walking every monitored
    /// source. Ordinary file events cost one identity read; a changed
    /// directory is enumerated only when that source is intentionally
    /// recursive. Stream overflow and root recovery remain the caller's signal
    /// to use the complete `scan(in:)` reconciliation path.
    public static func scanChanges(
        at changedURLs: [URL],
        in locations: [MonitoredLocation],
        fileManager: FileManager = .default
    ) -> [MonitoredFileSnapshot] {
        var entriesByPath: [String: MonitoredFileSnapshot] = [:]
        let uniqueURLs = Dictionary(
            changedURLs.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values

        for changedURL in uniqueURLs {
            if Task.isCancelled { break }
            let changedPath = changedURL.standardizedFileURL.path
            let location = locations.first(where: {
                $0.url.standardizedFileURL.path == changedPath
            }) ?? MonitoredLocation.preferred(for: changedURL, among: locations)
            guard let location,
                  fileManager.fileExists(atPath: changedPath) else { continue }

            let values = try? changedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                _ = accept(
                    changedURL,
                    from: location,
                    fileManager: fileManager,
                    into: &entriesByPath
                )
                continue
            }

            guard values?.isDirectory == true else { continue }
            let isRoot = changedPath == location.url.standardizedFileURL.path
            guard isRoot || location.recursive else { continue }

            if isRoot {
                merge(
                    scan(in: [location], fileManager: fileManager),
                    into: &entriesByPath
                )
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: changedURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { break }
                _ = accept(
                    url,
                    from: location,
                    fileManager: fileManager,
                    into: &entriesByPath
                )
            }
        }

        return Array(entriesByPath.values)
    }

    private static func merge(
        _ snapshots: [MonitoredFileSnapshot],
        into entriesByPath: inout [String: MonitoredFileSnapshot]
    ) {
        for snapshot in snapshots {
            entriesByPath[snapshot.entry.url.standardizedFileURL.path] = snapshot
        }
    }

    /// Returns true only when the candidate is an accepted ordinary file, so
    /// directories, packages and symbolic links never consume a scan quota.
    private static func accept(
        _ url: URL,
        from location: MonitoredLocation,
        fileManager: FileManager,
        into entriesByPath: inout [String: MonitoredFileSnapshot]
    ) -> Bool {
        guard let identity = try? FileIdentitySnapshot.capture(
            at: url,
            fileManager: fileManager
        ) else { return false }

        let scanned = MonitoredFileSnapshot(
            entry: MonitoredFileEntry(url: url, location: location),
            identity: identity
        )
        let path = url.standardizedFileURL.path
        if let existing = entriesByPath[path] {
            let preferred = MonitoredLocation.preferred(
                for: url,
                among: [existing.entry.location, location]
            )
            if preferred?.id == location.id {
                entriesByPath[path] = scanned
            }
        } else {
            entriesByPath[path] = scanned
        }
        return true
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .fileResourceIdentifierKey
    ]
}
