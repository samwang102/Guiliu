import CoreServices
import Foundation

struct FileSystemEventBatch: Sendable {
    let paths: [URL]
    let requiresFullScan: Bool
}

/// Watches all configured source trees through macOS FSEvents. The stream is
/// recursive, coalesces bursts, and lets the app avoid repeatedly walking large
/// WeChat attachment trees while the filesystem is unchanged.
final class FileSystemEventMonitor: @unchecked Sendable {
    private let paths: [String]
    private let handler: @Sendable (FileSystemEventBatch) -> Void
    private let queue = DispatchQueue(label: "cn.guiliu.filesystem-events", qos: .utility)
    private var stream: FSEventStreamRef?
    private(set) var isRunning = false

    init(urls: [URL], handler: @escaping @Sendable (FileSystemEventBatch) -> Void) {
        paths = Array(Set(urls.map { $0.standardizedFileURL.path })).sorted()
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        guard stream == nil, !paths.isEmpty else { return isRunning }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileSystemEventMonitor>
                .fromOpaque(info)
                .takeUnretainedValue()

            let count = Int(eventCount)
            let pathPointers = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var changedPaths: [URL] = []
            changedPaths.reserveCapacity(count)
            var requiresFullScan = false

            let recoveryFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged
            )
            for index in 0..<count {
                if let pointer = pathPointers[index] {
                    changedPaths.append(URL(fileURLWithPath: String(cString: pointer)))
                }
                if eventFlags[index] & recoveryFlags != 0 {
                    requiresFullScan = true
                }
            }

            let uniquePaths = Dictionary(
                changedPaths.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
                uniquingKeysWith: { first, _ in first }
            ).values.sorted { $0.path < $1.path }
            monitor.handler(FileSystemEventBatch(
                paths: uniquePaths,
                requiresFullScan: requiresFullScan
            ))
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagIgnoreSelf
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.65,
            flags
        ) else { return false }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return false
        }
        isRunning = true
        return true
    }

    func stop() {
        guard let stream else {
            isRunning = false
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        isRunning = false
    }

    deinit {
        stop()
    }
}
