import Foundation

/// Reconciles the logical inbox with the physical files owned by monitored
/// sources. A missing source root is treated as temporarily unavailable rather
/// than empty, so a permission loss or an offline volume cannot silently erase
/// the user's pending queue.
public enum PendingFileReconciler {
    public static func missingFileURLs(
        among pendingURLs: [URL],
        monitoredLocations: [MonitoredLocation],
        affectedBy changedURLs: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard !pendingURLs.isEmpty, !monitoredLocations.isEmpty else { return [] }

        let availableLocations = monitoredLocations.filter { location in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: location.url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && fileManager.isReadableFile(atPath: location.url.path)
        }
        guard !availableLocations.isEmpty else { return [] }

        let changedPaths = changedURLs.map {
            Set($0.map { $0.standardizedFileURL.path })
        }

        return pendingURLs.filter { candidate in
            let candidateURL = candidate.standardizedFileURL
            let candidatePath = candidateURL.path
            guard availableLocations.contains(where: { $0.contains(fileURL: candidateURL) }) else {
                return false
            }
            if let changedPaths {
                guard changedPaths.contains(where: { changedPath in
                    candidatePath == changedPath
                        || candidatePath.hasPrefix(directoryPrefix(for: changedPath))
                }) else { return false }
            }
            return !fileManager.fileExists(atPath: candidatePath)
        }
    }

    private static func directoryPrefix(for path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}
