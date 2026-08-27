import AppKit
import Combine
import Foundation
import GuiliuCore
import Observation

struct AIAnalysisReaderRequest: Identifiable, Equatable {
    let fileURL: URL
    let category: FileCategory
    let pendingItemID: UUID?

    var id: String {
        pendingItemID?.uuidString ?? fileURL.standardizedFileURL.path
    }
}

@MainActor
@Observable
final class AppModel {
    enum Section: Hashable {
        case inbox
        case search
        case history
        case settings
        case category(FileCategory)
    }

    private(set) var selection: Section? = .inbox
    private(set) var pendingItems: [InboxItem] = []
    private(set) var history: [RoutingRecord] = []
    private(set) var trashHistory: [TrashRecord] = []
    private(set) var searchDocuments: [SearchDocument] = []
    private(set) var searchResults: [SearchHit] = []
    private(set) var isIndexingSearch = false
    private(set) var isPreparingFullTextSearch = false
    private(set) var searchFocusGeneration = 0
    var searchQuery = ""
    var searchScope: SearchScope = .all
    var searchMode: SearchMode = .filename
    var searchCategoryFilter: FileCategory?
    private(set) var categoryCounts: [FileCategory: Int] = [:]
    private(set) var libraryContentRevision = 0
    private(set) var isMonitoring = false
    private(set) var weChatFileURLs: [URL] = []
    private(set) var downloadOriginCounts: [FileOrigin: Int] = [:]
    private(set) var processingItemIDs: Set<UUID> = []
    private(set) var processingHistoryIDs: Set<UUID> = []
    private(set) var processingLibraryPaths: Set<String> = []
    private(set) var aiProcessingItemIDs: Set<UUID> = []
    private(set) var aiProcessingPaths: Set<String> = []
    private(set) var isAIAnalysisBusy = false
    private(set) var isResourceConstrained = false
    private(set) var isImportingExistingFiles = false
    private(set) var monitorWeChatReceivedFiles: Bool
    private(set) var ollamaEnabled: Bool
    private(set) var ollamaStatus = "尚未检查"
    private(set) var aiAnalyses: [String: OllamaDocumentAnalysis] = [:]
    var aiAnalysisReader: AIAnalysisReaderRequest?
    var filePreviewURL: URL?
    private(set) var virtualFacetDimensions: [String: [VirtualFacetDimension]] = [:]
    private(set) var virtualFacetAssignments: [String: [String: [String]]] = [:]
    var downloadURL: URL
    var libraryURL: URL
    let desktopURL: URL
    private(set) var qqFolderURL: URL?
    private(set) var feishuFolderURL: URL?
    var errorMessage: String?

    @ObservationIgnored private let classifier = FileClassifier()
    @ObservationIgnored private let router = RoutingService()
    @ObservationIgnored private let originDetector = FileOriginDetector()
    @ObservationIgnored private let tagger = SmartTagger()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: AnyCancellable?
    @ObservationIgnored private var fileSystemMonitor: FileSystemEventMonitor?
    @ObservationIgnored private var knownPaths: Set<String> = []
    @ObservationIgnored private var stability: [String: StabilityObservation] = [:]
    @ObservationIgnored private var customRules: [String: FileCategory] = [:]
    @ObservationIgnored private var handledFingerprints: Set<String> = []
    @ObservationIgnored private var searchIndexTask: Task<Void, Never>?
    @ObservationIgnored private var searchFullTextTask: Task<Void, Never>?
    @ObservationIgnored private var searchIndexGeneration = 0
    @ObservationIgnored private var searchIndexIncludesFullContent = false
    @ObservationIgnored private var searchContentCache: [SearchContentCacheKey: String] = [:]
    @ObservationIgnored private var searchQueryTask: Task<Void, Never>?
    @ObservationIgnored private var searchQueryGeneration = 0
    @ObservationIgnored private var monitorScanTask: Task<Void, Never>?
    @ObservationIgnored private var monitorScanGeneration = 0
    @ObservationIgnored private var monitorRescanRequested = false
    @ObservationIgnored private var monitorPendingPaths: Set<String> = []
    @ObservationIgnored private var monitorRequiresFullScan = false
    @ObservationIgnored private var stabilityRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFileReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var ollamaBatchTask: Task<Void, Never>?
    @ObservationIgnored private var activeAIAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var aiAnalysisGeneration = 0
    @ObservationIgnored private var tagAnalysisQueue: [InboxItem] = []
    @ObservationIgnored private var tagAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var pendingEnqueuePaths: Set<String> = []
    @ObservationIgnored private var pendingEnqueueEntries: [String: ScannedEntry] = [:]
    @ObservationIgnored private var enqueuePreparationTask: Task<Void, Never>?
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private lazy var quickArchivePanel = QuickArchivePanelController(model: self)

    let ollamaModel = "qwen3:4b"
    let ollamaEndpoint = "http://127.0.0.1:11434"

    private struct StabilityObservation {
        var size: Int64
        var modificationDate: Date?
        var resourceIdentifier: String?
        var unchangedPasses: Int
    }

    private struct MonitoredEntry: Sendable {
        let url: URL
        let location: MonitoredLocation
    }

    private struct ScannedEntry: Sendable {
        let entry: MonitoredEntry
        let size: Int64
        let modificationDate: Date?
        let resourceIdentifier: String?
    }

    private struct ImportCandidate: Sendable {
        let item: InboxItem
        let fingerprint: String
    }

    private struct RoutingPolicyResolution {
        let operation: RoutingOperation
        let location: MonitoredLocation?
    }

    private struct ArchivedTrashResult: Sendable {
        let record: TrashRecord?
        let trashedURL: URL
    }

    private enum BackgroundResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure(String)
    }

    private enum DefaultsKey {
        static let monitorPath = "monitorPath"
        static let libraryPath = "libraryPath"
        static let history = "routingHistory"
        static let customRules = "customClassificationRules"
        static let monitorWeChat = "monitorWeChatReceivedFiles"
        static let qqFolderPath = "qqFolderPath"
        static let feishuFolderPath = "feishuFolderPath"
        static let handledFingerprints = "handledFingerprints"
        static let trashHistory = "trashHistory"
        static let pendingItems = "pendingItems"
        static let ollamaEnabled = "ollamaEnabled"
        static let aiAnalyses = "ollamaDocumentAnalyses"
        static let virtualFacetDimensions = "virtualFacetDimensions"
        static let virtualFacetAssignments = "virtualFacetAssignments"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searchCategoryFilter = nil

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let defaultDownload = homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let defaultDesktop = homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
        let defaultLibrary = homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("归流文件库", isDirectory: true)

        let environment = ProcessInfo.processInfo.environment
        let configuredDownloadPath = environment["GUILIU_MONITOR_PATH"]
            ?? defaults.string(forKey: DefaultsKey.monitorPath)
            ?? defaultDownload.path
        let configuredLibraryPath = environment["GUILIU_LIBRARY_PATH"]
            ?? defaults.string(forKey: DefaultsKey.libraryPath)
            ?? defaultLibrary.path

        downloadURL = URL(fileURLWithPath: configuredDownloadPath)
        libraryURL = URL(fileURLWithPath: configuredLibraryPath)
        desktopURL = defaultDesktop
        qqFolderURL = defaults.string(forKey: DefaultsKey.qqFolderPath).map(URL.init(fileURLWithPath:))
        feishuFolderURL = defaults.string(forKey: DefaultsKey.feishuFolderPath).map(URL.init(fileURLWithPath:))
        ollamaEnabled = defaults.object(forKey: DefaultsKey.ollamaEnabled) == nil
            ? true : defaults.bool(forKey: DefaultsKey.ollamaEnabled)

        if environment["GUILIU_DISABLE_APP_DISCOVERY"] == "1" {
            monitorWeChatReceivedFiles = false
        } else if defaults.object(forKey: DefaultsKey.monitorWeChat) == nil {
            monitorWeChatReceivedFiles = true
        } else {
            monitorWeChatReceivedFiles = defaults.bool(forKey: DefaultsKey.monitorWeChat)
        }

        loadPersistedData()
        let missingPersistedPaths = Set(PendingFileReconciler.missingFileURLs(
            among: pendingItems.map(\.url),
            monitoredLocations: pendingFileReconciliationLocations
        ).map { $0.standardizedFileURL.path })
        removeMissingPendingItems(
            at: missingPersistedPaths,
            refreshesSearchIndex: false,
            notifiesQuickArchivePanel: false
        )
        refreshPersistedPendingFileIdentities()
        prepareLibrary()
        prepareVirtualFacets()
        primeMonitors()
        refreshCategoryCounts()
        refreshDownloadOriginCounts()
        rebuildSearchIndex()
        startResourceGovernor()
        startMonitoring()
        startAppLocationDiscovery()
        if ollamaEnabled {
            Task { [weak self] in
                await self?.initializeOllama()
            }
        }
    }

    private func startResourceGovernor() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated {
                self?.handleMemoryPressure(event)
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    private func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            isResourceConstrained = true
            searchFullTextTask?.cancel()
            searchFullTextTask = nil
            isPreparingFullTextSearch = false
            searchIndexIncludesFullContent = false
            searchContentCache.removeAll(keepingCapacity: false)

            aiAnalysisGeneration += 1
            activeAIAnalysisTask?.cancel()
            activeAIAnalysisTask = nil
            ollamaBatchTask?.cancel()
            ollamaBatchTask = nil
            aiProcessingItemIDs.removeAll()
            aiProcessingPaths.removeAll()
            isAIAnalysisBusy = false
            if ollamaEnabled {
                ollamaStatus = "系统内存紧张，已暂停分析并释放本地模型"
                let model = ollamaModel
                Task.detached(priority: .background) {
                    try? await OllamaClient().unload(model: model)
                }
            }
        } else if event.contains(.warning) {
            isResourceConstrained = true
            searchFullTextTask?.cancel()
            searchFullTextTask = nil
            isPreparingFullTextSearch = false
        } else if event.contains(.normal) {
            isResourceConstrained = false
        }
    }

    var monitoredLocations: [MonitoredLocation] {
        var locations: [MonitoredLocation] = [
            MonitoredLocation(
                id: "downloads",
                displayName: "下载文件夹",
                url: downloadURL,
                origin: .downloads
            ),
            MonitoredLocation(
                id: "desktop",
                displayName: "桌面",
                url: desktopURL,
                origin: .desktop
            )
        ]

        if monitorWeChatReceivedFiles {
            locations.append(contentsOf: weChatFileURLs.map { url in
                MonitoredLocation(
                    id: MonitoredLocation.stableSourceID(namespace: "wechat", directoryURL: url),
                    displayName: "微信接收文件",
                    url: url,
                    origin: .wechat,
                    fileOwnership: .appManagedOriginal,
                    recursive: true
                )
            })
        }

        if let qqFolderURL, !sameLocation(qqFolderURL, downloadURL) {
            locations.append(
                MonitoredLocation(
                    id: "qq-custom",
                    displayName: "QQ 专用保存目录",
                    url: qqFolderURL,
                    origin: .qq
                )
            )
        }

        if let feishuFolderURL, !sameLocation(feishuFolderURL, downloadURL) {
            locations.append(
                MonitoredLocation(
                    id: "feishu-custom",
                    displayName: "飞书专用保存目录",
                    url: feishuFolderURL,
                    origin: .feishu
                )
            )
        }

        let eligible = locations.filter {
            FileManager.default.fileExists(atPath: $0.url.path)
                && !locationsOverlap($0.url, libraryURL)
        }
        // Keep nested sources: Downloads/QQ/Feishu are non-recursive while an
        // App-managed attachment tree is recursive, so a parent/child relation
        // is not itself a duplicate. Only collapse monitors with the same root.
        var safe: [MonitoredLocation] = []
        for location in eligible {
            if let conflictIndex = safe.firstIndex(where: { sameLocation($0.url, location.url) }) {
                let probe = location.url.appendingPathComponent(".guiliu-policy-probe")
                safe[conflictIndex] = MonitoredLocation.preferred(
                    for: probe,
                    among: [safe[conflictIndex], location]
                ) ?? safe[conflictIndex]
                continue
            }
            safe.append(location)
        }
        return safe
    }

    /// Pending records remain eligible for existence checks even when the user
    /// temporarily turns off a discovered App source. This is deliberately
    /// broader than the live FSEvents set, but still contains only roots that
    /// currently exist and do not overlap the library.
    private var pendingFileReconciliationLocations: [MonitoredLocation] {
        var locations = monitoredLocations
        for url in weChatFileURLs {
            let location = MonitoredLocation(
                id: MonitoredLocation.stableSourceID(namespace: "wechat", directoryURL: url),
                displayName: "微信接收文件",
                url: url,
                origin: .wechat,
                fileOwnership: .appManagedOriginal,
                recursive: true
            )
            guard FileManager.default.fileExists(atPath: url.path),
                  !locationsOverlap(url, libraryURL),
                  !locations.contains(where: { sameLocation($0.url, url) }) else { continue }
            locations.append(location)
        }
        return locations
    }

    var weChatStatus: String {
        guard !weChatFileURLs.isEmpty else { return "未找到微信文档目录" }
        if monitorWeChatReceivedFiles {
            return "已监控 App 内部原件；创建引用，不复制文件"
        }
        return "已找到文档目录，但监控已关闭"
    }

    var qqStatus: String {
        if let qqFolderURL, !sameLocation(qqFolderURL, downloadURL) {
            return "已监控用户保存目录；移动归档"
        }
        let count = downloadOriginCounts[.qq, default: 0]
        return "从下载文件夹识别来源（已识别 \(count) 项）"
    }

    var feishuStatus: String {
        if let feishuFolderURL, !sameLocation(feishuFolderURL, downloadURL) {
            return "已监控用户保存目录；移动归档"
        }
        let count = downloadOriginCounts[.feishu, default: 0]
        return "从下载文件夹识别来源（已识别 \(count) 项）"
    }

    func startMonitoring() {
        guard timer == nil else { return }
        isMonitoring = true
        restartFileSystemEventMonitor()
        // FSEvents is authoritative. The low-frequency timer only verifies
        // that the stream is still present; it must never turn an idle App into
        // a recurring full walk of large attachment trees.
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.recoverMonitoringIfNeeded()
            }
    }

    /// Re-checks the small logical inbox when the App becomes active or a
    /// window is reopened. FSEvents remains the fast path; this inexpensive
    /// fallback closes gaps caused by coalesced/missed events while the window
    /// was hidden or the Mac was asleep.
    func reconcilePendingFileExistence() {
        pendingFileReconciliationTask?.cancel()
        guard !pendingItems.isEmpty else {
            pendingFileReconciliationTask = nil
            return
        }

        let pendingURLs = pendingItems.map(\.url)
        let locations = pendingFileReconciliationLocations
        pendingFileReconciliationTask = Task { [weak self] in
            let missingPaths = await Task.detached(priority: .utility) {
                Set(PendingFileReconciler.missingFileURLs(
                    among: pendingURLs,
                    monitoredLocations: locations
                ).map { $0.standardizedFileURL.path })
            }.value
            guard !Task.isCancelled, let self else { return }
            pendingFileReconciliationTask = nil
            removeMissingPendingItems(at: missingPaths)
        }
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
        fileSystemMonitor?.stop()
        fileSystemMonitor = nil
        isMonitoring = false
        monitorScanGeneration += 1
        monitorScanTask?.cancel()
        monitorScanTask = nil
        monitorRescanRequested = false
        monitorPendingPaths.removeAll()
        monitorRequiresFullScan = false
        stabilityRecheckTask?.cancel()
        stabilityRecheckTask = nil
        enqueuePreparationTask?.cancel()
        enqueuePreparationTask = nil
        pendingEnqueueEntries.removeAll()
        pendingEnqueuePaths.removeAll()
        stability.removeAll()
    }

    private func recoverMonitoringIfNeeded() {
        guard isMonitoring, fileSystemMonitor?.isRunning != true else { return }
        restartFileSystemEventMonitor()
        if fileSystemMonitor?.isRunning == true {
            requestMonitorScan(requiresFullScan: true)
        }
    }

    func toggleMonitoring() {
        isMonitoring ? stopMonitoring() : startMonitoring()
    }

    func changeMonitorFolder() {
        guard canChangeStorageLocations else { return }
        guard let url = chooseDirectory(title: "选择通用下载文件夹", initialURL: downloadURL) else { return }
        let otherLocations = monitoredLocations.filter { $0.id != "downloads" }
        guard !locationsOverlap(url, libraryURL),
              !otherLocations.contains(where: { locationsOverlap(url, $0.url) }) else {
            errorMessage = "下载目录不能与文件库或其他监控来源相同、包含或被包含，否则可能重复发现或错误移动文件。"
            return
        }
        downloadURL = url
        defaults.set(url.path, forKey: DefaultsKey.monitorPath)
        primeMonitors()
        refreshDownloadOriginCounts()
    }

    func setWeChatMonitoring(_ enabled: Bool) {
        guard canChangeStorageLocations else { return }
        if enabled {
            let nonWeChatLocations = monitoredLocations.filter { $0.origin != .wechat }
            let hasConflict = weChatFileURLs.contains { weChatURL in
                locationsOverlap(weChatURL, libraryURL)
                    || nonWeChatLocations.contains(where: { locationsOverlap(weChatURL, $0.url) })
            }
            guard !hasConflict else {
                errorMessage = "微信接收文件目录与文件库或其他监控来源发生重叠，已保持关闭。请先调整相冲突的目录。"
                monitorWeChatReceivedFiles = false
                defaults.set(false, forKey: DefaultsKey.monitorWeChat)
                return
            }
        }
        monitorWeChatReceivedFiles = enabled
        defaults.set(enabled, forKey: DefaultsKey.monitorWeChat)
        primeMonitors()
    }

    func chooseAppFolder(for origin: FileOrigin) {
        guard canChangeStorageLocations else { return }
        let currentURL: URL
        switch origin {
        case .qq:
            currentURL = qqFolderURL ?? downloadURL
        case .feishu:
            currentURL = feishuFolderURL ?? downloadURL
        default:
            return
        }

        guard let url = chooseDirectory(
            title: "选择\(origin.displayName)的专用保存目录",
            initialURL: currentURL
        ) else { return }
        let sourceID = origin == .qq ? "qq-custom" : "feishu-custom"
        let otherLocations = monitoredLocations.filter { $0.id != sourceID }
        guard !locationsOverlap(url, libraryURL),
              !otherLocations.contains(where: { locationsOverlap(url, $0.url) }) else {
            errorMessage = "专用保存目录不能与文件库或其他监控来源相同、包含或被包含。"
            return
        }

        switch origin {
        case .qq:
            qqFolderURL = url
            defaults.set(url.path, forKey: DefaultsKey.qqFolderPath)
        case .feishu:
            feishuFolderURL = url
            defaults.set(url.path, forKey: DefaultsKey.feishuFolderPath)
        default:
            break
        }
        primeMonitors()
    }

    func useDownloadFolder(for origin: FileOrigin) {
        guard canChangeStorageLocations else { return }
        switch origin {
        case .qq:
            qqFolderURL = nil
            defaults.removeObject(forKey: DefaultsKey.qqFolderPath)
        case .feishu:
            feishuFolderURL = nil
            defaults.removeObject(forKey: DefaultsKey.feishuFolderPath)
        default:
            break
        }
        primeMonitors()
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func changeLibraryFolder() {
        guard canChangeStorageLocations else { return }
        guard let url = chooseDirectory(title: "选择文件库位置", initialURL: libraryURL) else { return }
        guard !monitoredLocations.contains(where: { locationsOverlap(url, $0.url) }) else {
            errorMessage = "文件库不能与任何监控来源相同、包含或被包含，否则会形成循环或误操作。"
            return
        }
        libraryURL = url
        defaults.set(url.path, forKey: DefaultsKey.libraryPath)
        prepareLibrary()
        refreshCategoryCounts()
        rebuildSearchIndex()
    }

    func importExistingFiles() {
        guard !isImportingExistingFiles else { return }
        isImportingExistingFiles = true
        let locations = monitoredLocations
        let customRulesSnapshot = customRules
        let generation = monitorScanGeneration
        let pendingPathsSnapshot = Set(pendingItems.map(\.url.path))
        let handledSnapshot = handledFingerprints

        Task { [weak self] in
            let candidates = await Task.detached(priority: .utility) {
                let classifier = FileClassifier()
                let originDetector = FileOriginDetector()
                let tagger = SmartTagger()
                return Self.scanEntries(in: locations).compactMap { scanned -> ImportCandidate? in
                    let entry = scanned.entry
                    let fingerprint = Self.fingerprintValue(for: scanned)
                    guard !pendingPathsSnapshot.contains(entry.url.path),
                          !Self.shouldIgnore(entry.url, in: entry.location),
                          !handledSnapshot.contains(fingerprint) else { return nil }
                    let origin = originDetector.detect(for: entry.url, fallback: entry.location.origin)
                    let suggestion = classifier.suggest(for: entry.url, customRules: customRulesSnapshot)
                    let capturedIdentity = try? FileIdentitySnapshot.capture(at: entry.url)
                    let persistentIdentity = capturedIdentity?.matches(
                        expectedSize: scanned.size,
                        expectedModificationDate: scanned.modificationDate,
                        expectedResourceIdentifier: scanned.resourceIdentifier,
                        expectedResourceIdentifierSession: FileIdentitySnapshot.currentResourceIdentifierSession
                    ) == true ? capturedIdentity?.persistentIdentity : nil
                    return ImportCandidate(
                        item: InboxItem(
                            url: entry.url,
                            fileSize: scanned.size,
                            suggestion: suggestion,
                            origin: origin,
                            routingOperation: entry.location.routingOperation,
                            sourceID: entry.location.id,
                            sourceDisplayName: entry.location.displayName,
                            tags: tagger.tags(for: entry.url, category: suggestion.category, origin: origin),
                            modificationDate: scanned.modificationDate,
                            resourceIdentifier: scanned.resourceIdentifier,
                            resourceIdentifierSession: scanned.resourceIdentifier == nil
                                ? nil : FileIdentitySnapshot.currentResourceIdentifierSession,
                            persistentIdentity: persistentIdentity
                        ),
                        fingerprint: fingerprint
                    )
                }
            }.value
            guard let self else { return }
            isImportingExistingFiles = false
            guard monitorScanGeneration == generation else { return }

            var newlyQueued: [InboxItem] = []
            var pendingPaths = Set(pendingItems.map(\.url.path))
            for candidate in candidates {
                let item = candidate.item
                guard !pendingPaths.contains(item.url.path),
                      !handledFingerprints.contains(candidate.fingerprint),
                      FileManager.default.fileExists(atPath: item.url.path) else { continue }
                newlyQueued.append(item)
                pendingPaths.insert(item.url.path)
                knownPaths.insert(item.url.path)
            }

            pendingItems.append(contentsOf: newlyQueued.sorted { $0.detectedAt > $1.detectedAt })
            persistPendingItems()
            for item in newlyQueued {
                analyzeTags(for: item)
            }
            rebuildSearchIndex()
            navigate(to: .inbox)
        }
    }

    func route(
        _ item: InboxItem,
        to category: FileCategory,
        rememberExtension: Bool,
        completion: ((String?) -> Void)? = nil
    ) {
        guard processingItemIDs.insert(item.id).inserted else {
            let message = "这个文件正在归档，请稍候。"
            if let completion {
                completion(message)
            } else {
                errorMessage = message
            }
            return
        }
        let handledFingerprint = fingerprint(for: item)
        let routedTags = tagger.replacingCategoryTag(in: item.tags, with: category)
        let libraryRoot = libraryURL
        let effectiveOperation = routingPolicy(for: item).operation

        Task { [weak self] in
            let result: BackgroundResult<RoutingRecord> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try RoutingService().route(
                        item: item,
                        to: category,
                        libraryRoot: libraryRoot,
                        operation: effectiveOperation,
                        tags: routedTags
                    ))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            processingItemIDs.remove(item.id)
            guard case let .success(record) = result else {
                if case let .failure(message) = result {
                    if let completion {
                        completion(message)
                    } else {
                        errorMessage = message
                    }
                }
                return
            }

            history.insert(record, at: 0)
            relocateDocumentMetadata(
                from: item.url,
                to: URL(fileURLWithPath: record.destinationPath)
            )
            pendingItems.removeAll { $0.id == item.id }
            quickArchivePanel.itemDidLeaveQueue(item.id)
            persistPendingItems()
            stability.removeValue(forKey: item.url.path)
            knownPaths.insert(item.url.path)
            if let handledFingerprint {
                handledFingerprints.insert(handledFingerprint)
                persistHandledFingerprints()
            }

            if rememberExtension {
                let ext = item.url.pathExtension.lowercased()
                if !ext.isEmpty {
                    customRules[ext] = category
                    persistCustomRules()
                }
            }

            persistHistory()
            refreshCategoryCounts()
            refreshSearchIndex(for: [
                item.url,
                URL(fileURLWithPath: record.destinationPath)
            ])
            completion?(nil)
        }
    }

    func ignore(_ item: InboxItem) {
        guard !processingItemIDs.contains(item.id) else { return }
        knownPaths.insert(item.url.path)
        stability.removeValue(forKey: item.url.path)
        pendingItems.removeAll { $0.id == item.id }
        quickArchivePanel.itemDidLeaveQueue(item.id)
        persistPendingItems()
        if let handledFingerprint = fingerprint(for: item) {
            handledFingerprints.insert(handledFingerprint)
            persistHandledFingerprints()
        }
        refreshSearchIndex(for: [item.url])
    }

    func canRename(_ item: InboxItem) -> Bool {
        routingPolicy(for: item).operation == .move
    }

    func renamePendingFile(_ item: InboxItem, toBaseName baseName: String) {
        guard canRename(item) else {
            errorMessage = "微信等第三方 App 管理的原件不能直接改名；归档为引用后，可以修改归流中的引用名称。"
            return
        }
        guard processingItemIDs.insert(item.id).inserted else { return }
        let sourcePath = item.url.standardizedFileURL.path
        let allowedDirectory = item.url.deletingLastPathComponent()

        Task { [weak self] in
            let result: BackgroundResult<URL> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try FileRenameService().rename(
                        file: item.url,
                        toBaseName: baseName,
                        in: allowedDirectory,
                        expectedIdentity: item.fileIdentitySnapshot
                    ))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            processingItemIDs.remove(item.id)
            guard case let .success(destination) = result else {
                if case let .failure(message) = result { errorMessage = message }
                return
            }
            guard destination.standardizedFileURL.path != sourcePath else { return }

            if let index = pendingItems.firstIndex(where: { $0.id == item.id }) {
                pendingItems[index] = pendingItems[index].replacingURL(destination)
            }
            knownPaths.remove(sourcePath)
            knownPaths.insert(destination.standardizedFileURL.path)
            if let observation = stability.removeValue(forKey: sourcePath) {
                stability[destination.standardizedFileURL.path] = observation
            }
            relocateDocumentMetadata(from: item.url, to: destination)
            persistPendingItems()
            refreshSearchIndex(for: [item.url, destination])
        }
    }

    func delete(_ item: InboxItem) {
        guard processingItemIDs.insert(item.id).inserted else { return }
        guard let location = monitoredLocations.first(where: { $0.id == item.sourceID }) else {
            processingItemIDs.remove(item.id)
            errorMessage = "找不到这个文件原来的监控来源，归流不会冒险删除它。"
            return
        }

        let handledFingerprint = fingerprint(for: item)
        let allowedRoot = location.url
        Task { [weak self] in
            let result: BackgroundResult<TrashRecord> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try TrashService().trash(item: item, allowedRoot: allowedRoot))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            processingItemIDs.remove(item.id)
            guard case let .success(record) = result else {
                if case let .failure(message) = result { errorMessage = message }
                return
            }

            trashHistory.insert(record, at: 0)
            relocateDocumentMetadata(
                from: item.url,
                to: URL(fileURLWithPath: record.trashedPath)
            )
            pendingItems.removeAll { $0.id == item.id }
            quickArchivePanel.itemDidLeaveQueue(item.id)
            persistPendingItems()
            stability.removeValue(forKey: item.url.path)
            knownPaths.insert(item.url.path)
            if let handledFingerprint {
                handledFingerprints.insert(handledFingerprint)
                persistHandledFingerprints()
            }
            persistTrashHistory()
            refreshSearchIndex(for: [
                item.url,
                URL(fileURLWithPath: record.trashedPath)
            ])
        }
    }

    func deleteArchivedFile(_ source: URL, category: FileCategory) {
        let sourcePath = source.standardizedFileURL.path
        guard processingLibraryPaths.insert(sourcePath).inserted else { return }
        let categoryDirectory = libraryURL
            .appendingPathComponent(category.displayName, isDirectory: true)
            .standardizedFileURL

        Task { [weak self] in
            let result: BackgroundResult<ArchivedTrashResult> = await Task.detached(priority: .userInitiated) {
                do {
                    let freshURL = URL(fileURLWithPath: sourcePath)
                    guard freshURL.deletingLastPathComponent().standardizedFileURL.path == categoryDirectory.path else {
                        throw TrashError.outsideAllowedLocation
                    }

                    let values = try freshURL.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                        .fileResourceIdentifierKey
                    ])

                    // App-managed documents are represented by symbolic links in
                    // the library. Trashing that link removes only the reference;
                    // the WeChat/QQ/Feishu original is deliberately untouched.
                    if values.isSymbolicLink == true {
                        var resultingURL: NSURL?
                        try FileManager.default.trashItem(at: freshURL, resultingItemURL: &resultingURL)
                        guard let resultingURL else { throw TrashError.trashedFileMissing }
                        return .success(ArchivedTrashResult(
                            record: nil,
                            trashedURL: resultingURL as URL
                        ))
                    }

                    guard values.isRegularFile == true, let fileSize = values.fileSize else {
                        throw TrashError.unsupportedItem
                    }
                    let item = InboxItem(
                        url: freshURL,
                        fileSize: Int64(fileSize),
                        suggestion: ClassificationSuggestion(
                            category: category,
                            reason: "已归档文件",
                            confidence: 1
                        ),
                        origin: .unknown,
                        routingOperation: .move,
                        sourceID: "library:\(category.rawValue)",
                        sourceDisplayName: "归流文件库",
                        modificationDate: values.contentModificationDate,
                        resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
                    )
                    let record = try TrashService().trash(item: item, allowedRoot: categoryDirectory)
                    return .success(ArchivedTrashResult(
                        record: record,
                        trashedURL: URL(fileURLWithPath: record.trashedPath)
                    ))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            processingLibraryPaths.remove(sourcePath)
            guard case let .success(trashed) = result else {
                if case let .failure(message) = result { errorMessage = message }
                return
            }

            if let record = trashed.record {
                trashHistory.insert(record, at: 0)
                persistTrashHistory()
            }
            if filePreviewURL?.standardizedFileURL.path == sourcePath {
                filePreviewURL = nil
            }
            relocateDocumentMetadata(from: source, to: trashed.trashedURL)
            refreshCategoryCounts()
            refreshSearchIndex(for: [source, trashed.trashedURL])
        }
    }

    func renameArchivedFile(_ source: URL, category: FileCategory, toBaseName baseName: String) {
        let sourcePath = source.standardizedFileURL.path
        guard processingLibraryPaths.insert(sourcePath).inserted else { return }
        let categoryDirectory = libraryURL
            .appendingPathComponent(category.displayName, isDirectory: true)
            .standardizedFileURL

        Task { [weak self] in
            let result: BackgroundResult<URL> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try FileRenameService().rename(
                        file: source,
                        toBaseName: baseName,
                        in: categoryDirectory,
                        allowSymbolicLink: true
                    ))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            processingLibraryPaths.remove(sourcePath)
            guard case let .success(destination) = result else {
                if case let .failure(message) = result { errorMessage = message }
                return
            }
            guard destination.standardizedFileURL.path != sourcePath else { return }

            relocateDocumentMetadata(from: source, to: destination)
            if let index = history.firstIndex(where: {
                !$0.isRestored
                    && URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path == sourcePath
            }) {
                history[index].destinationPath = destination.path
                persistHistory()
            }
            libraryContentRevision += 1
            refreshSearchIndex(for: [source, destination])
        }
    }

    func restoreDeleted(_ record: TrashRecord) {
        guard processingHistoryIDs.insert(record.id).inserted else { return }
        Task { [weak self] in
            let result: BackgroundResult<TrashRecord> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try TrashService().restore(record))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            processingHistoryIDs.remove(record.id)
            guard case let .success(updated) = result else {
                if case let .failure(message) = result { errorMessage = message }
                return
            }

            if let index = trashHistory.firstIndex(where: { $0.id == record.id }) {
                trashHistory[index] = updated
            }
            relocateDocumentMetadata(
                from: URL(fileURLWithPath: record.trashedPath),
                to: URL(fileURLWithPath: updated.trashedPath)
            )
            requeueRestoredFile(
                at: URL(fileURLWithPath: updated.trashedPath),
                preferredSourceID: record.sourceID,
                previousPath: record.originalPath
            )
            persistTrashHistory()
            refreshCategoryCounts()
            refreshSearchIndex(for: [
                URL(fileURLWithPath: record.trashedPath),
                URL(fileURLWithPath: updated.trashedPath)
            ])
        }
    }

    func undo(_ record: RoutingRecord) {
        guard processingHistoryIDs.insert(record.id).inserted else { return }
        Task { [weak self] in
            let result: BackgroundResult<RoutingRecord> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try RoutingService().restore(record))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            processingHistoryIDs.remove(record.id)
            guard case let .success(updated) = result else {
                if case let .failure(message) = result { errorMessage = message }
                return
            }

            if let index = history.firstIndex(where: { $0.id == record.id }) {
                history[index] = updated
            }
            let restoredURL: URL
            switch updated.effectiveOperation {
            case .move:
                restoredURL = URL(fileURLWithPath: updated.destinationPath)
            case .copy, .reference:
                restoredURL = URL(fileURLWithPath: updated.originalPath)
            }
            relocateDocumentMetadata(
                from: URL(fileURLWithPath: record.destinationPath),
                to: restoredURL
            )
            requeueRestoredFile(
                at: restoredURL,
                previousPath: updated.originalPath
            )
            persistHistory()
            refreshCategoryCounts()
            refreshSearchIndex(for: [
                URL(fileURLWithPath: record.destinationPath),
                restoredURL
            ])
        }
    }

    func reveal(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Navigation owns the lifetime of contextual readers. Clear them before
    /// publishing the new section so SwiftUI never renders a new category with
    /// a Quick Look view that still belongs to the previous one.
    func navigate(to newSelection: Section) {
        guard selection != newSelection else { return }
        closeContextReader()
        selection = newSelection
    }

    func requestSearchFocus() {
        if selection != .search {
            navigate(to: .search)
        }
        searchFocusGeneration &+= 1
    }

    func closeContextReader() {
        aiAnalysisReader = nil
        filePreviewURL = nil
    }

    func previewOrOpen(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            filePreviewURL = nil
            errorMessage = "文件已经不存在，无法预览。"
            return
        }

        if filePreviewURL?.standardizedFileURL.path == normalizedURL.path {
            NSWorkspace.shared.open(normalizedURL)
        } else {
            aiAnalysisReader = nil
            filePreviewURL = normalizedURL
        }
    }

    func closeFilePreview() {
        filePreviewURL = nil
    }

    func openCategory(_ category: FileCategory) {
        let url = libraryURL.appendingPathComponent(category.displayName, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    func openDesktop() {
        NSWorkspace.shared.open(desktopURL)
    }

    func count(for category: FileCategory) -> Int {
        categoryCounts[category, default: 0]
    }

    func facetDimensions(for category: FileCategory) -> [VirtualFacetDimension] {
        virtualFacetDimensions[category.rawValue] ?? VirtualFacetDefaults.dimensions(for: category)
    }

    func facetValues(for file: URL, dimensionID: String) -> [String] {
        virtualFacetAssignments[file.standardizedFileURL.path]?[dimensionID] ?? []
    }

    func addFacetDimension(
        to category: FileCategory,
        name: String,
        selectionMode: VirtualFacetSelectionMode
    ) -> VirtualFacetDimension? {
        let normalized = normalizedFacetText(name)
        guard !normalized.isEmpty else { return nil }
        var dimensions = facetDimensions(for: category)
        guard !dimensions.contains(where: { facetComparisonKey($0.name) == facetComparisonKey(normalized) }) else {
            return dimensions.first { facetComparisonKey($0.name) == facetComparisonKey(normalized) }
        }
        let dimension = VirtualFacetDimension(name: normalized, selectionMode: selectionMode)
        dimensions.append(dimension)
        virtualFacetDimensions[category.rawValue] = dimensions
        persistVirtualFacets()
        return dimension
    }

    @discardableResult
    func addFacetValue(_ value: String, to dimensionID: String, category: FileCategory) -> String? {
        let normalized = normalizedFacetText(value)
        guard !normalized.isEmpty,
              facetComparisonKey(normalized) != facetComparisonKey(VirtualFacetDefaults.uncategorizedTitle) else {
            return nil
        }
        var dimensions = facetDimensions(for: category)
        guard let index = dimensions.firstIndex(where: { $0.id == dimensionID }) else { return nil }
        if let existing = dimensions[index].values.first(where: {
            facetComparisonKey($0) == facetComparisonKey(normalized)
        }) {
            return existing
        }
        dimensions[index].values.append(normalized)
        dimensions[index].values.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        virtualFacetDimensions[category.rawValue] = dimensions
        persistVirtualFacets()
        return normalized
    }

    func toggleFacetValue(
        _ value: String,
        for file: URL,
        dimension: VirtualFacetDimension,
        category: FileCategory
    ) {
        guard let canonicalValue = addFacetValue(value, to: dimension.id, category: category) else { return }
        let path = file.standardizedFileURL.path
        var fileAssignments = virtualFacetAssignments[path] ?? [:]
        var selected = fileAssignments[dimension.id] ?? []
        if selected.contains(canonicalValue) {
            selected.removeAll { $0 == canonicalValue }
        } else if dimension.selectionMode == .single {
            selected = [canonicalValue]
        } else {
            selected.append(canonicalValue)
        }
        if selected.isEmpty {
            fileAssignments.removeValue(forKey: dimension.id)
        } else {
            fileAssignments[dimension.id] = selected
        }
        if fileAssignments.isEmpty {
            virtualFacetAssignments.removeValue(forKey: path)
        } else {
            virtualFacetAssignments[path] = fileAssignments
        }
        persistVirtualFacets()
        refreshSearchIndex(for: [file])
    }

    func facetCount(value: String, dimensionID: String, in files: [URL]) -> Int {
        files.reduce(into: 0) { count, file in
            if facetValues(for: file, dimensionID: dimensionID).contains(value) { count += 1 }
        }
    }

    func setOllamaEnabled(_ enabled: Bool) {
        ollamaEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.ollamaEnabled)
        if enabled {
            Task { [weak self] in await self?.initializeOllama() }
        } else {
            aiAnalysisGeneration += 1
            activeAIAnalysisTask?.cancel()
            activeAIAnalysisTask = nil
            ollamaBatchTask?.cancel()
            ollamaBatchTask = nil
            aiProcessingItemIDs.removeAll()
            aiProcessingPaths.removeAll()
            isAIAnalysisBusy = false
            ollamaStatus = "已关闭"
        }
    }

    func checkOllamaConnection() {
        Task { [weak self] in
            _ = await self?.refreshOllamaStatus()
        }
    }

    func analyzeAllPendingWithOllama() {
        guard ollamaEnabled,
              let generation = beginAIAnalysis() else { return }
        let items = pendingItems
        let task = Task { [weak self] in
            guard let self else { return }
            for item in items where !Task.isCancelled {
                await performAIAnalysis(item)
            }
            finishAIAnalysis(generation: generation)
        }
        ollamaBatchTask = task
        activeAIAnalysisTask = task
    }

    func analyzeWithOllama(_ item: InboxItem) {
        guard ollamaEnabled,
              let generation = beginAIAnalysis() else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await performAIAnalysis(item)
            finishAIAnalysis(generation: generation)
        }
        activeAIAnalysisTask = task
    }

    private func beginAIAnalysis() -> Int? {
        guard !isAIAnalysisBusy else {
            ollamaStatus = "已有本地 AI 任务正在运行；归流会保持单任务以保护内存和界面流畅度"
            return nil
        }
        aiAnalysisGeneration += 1
        isAIAnalysisBusy = true
        return aiAnalysisGeneration
    }

    private func finishAIAnalysis(generation: Int) {
        guard aiAnalysisGeneration == generation else { return }
        isAIAnalysisBusy = false
        activeAIAnalysisTask = nil
        ollamaBatchTask = nil
    }

    func analyzeArchivedFile(_ url: URL, category: FileCategory) {
        guard ollamaEnabled,
              let generation = beginAIAnalysis() else { return }
        let path = url.standardizedFileURL.path
        guard aiProcessingPaths.insert(path).inserted else {
            finishAIAnalysis(generation: generation)
            return
        }
        ollamaStatus = "正在分析“\(url.lastPathComponent)”…"
        let model = ollamaModel
        let origin = history.first(where: {
            !$0.isRestored
                && URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path == path
        })?.effectiveOrigin ?? .unknown

        let task = Task { [weak self] in
            defer {
                self?.aiProcessingPaths.remove(path)
                self?.finishAIAnalysis(generation: generation)
            }
            let maximumCharacters = category == .researchPapers ? 12_000 : 30_000
            let content = await Task.detached(priority: .utility) {
                FileTextExtractor().text(for: url, maximumCharacters: maximumCharacters)
            }.value
            do {
                let analysis = try await OllamaClient().analyze(
                    fileURL: url,
                    origin: origin,
                    fallbackSuggestion: ClassificationSuggestion(
                        category: category,
                        reason: "文件当前位于“\(category.displayName)”",
                        confidence: 1
                    ),
                    extractedText: content,
                    model: model
                )
                guard let self,
                      ollamaEnabled,
                      aiAnalysisGeneration == generation,
                      !Task.isCancelled else { return }
                aiAnalyses[path] = analysis
                if let index = history.firstIndex(where: {
                    !$0.isRestored
                        && URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path == path
                }) {
                    let baseTags = tagger.tags(
                        for: url,
                        category: category,
                        origin: origin,
                        contentText: content
                    )
                    history[index].tags = mergedTags(
                        baseTags,
                        analysis.tags,
                        category: category
                    )
                    persistHistory()
                }
                persistAIAnalyses()
                ollamaStatus = "已连接 · \(model)"
                refreshSearchIndex(for: [url])
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                ollamaStatus = error.localizedDescription
            }
        }
        activeAIAnalysisTask = task
    }

    func aiAnalysis(for url: URL) -> OllamaDocumentAnalysis? {
        aiAnalyses[url.standardizedFileURL.path]
    }

    func openAIAnalysisReader(
        for url: URL,
        category: FileCategory,
        pendingItemID: UUID? = nil
    ) {
        filePreviewURL = nil
        aiAnalysisReader = AIAnalysisReaderRequest(
            fileURL: url,
            category: category,
            pendingItemID: pendingItemID
        )
    }

    func reanalyze(_ request: AIAnalysisReaderRequest) {
        if let pendingItemID = request.pendingItemID,
           let item = pendingItems.first(where: { $0.id == pendingItemID }) {
            analyzeWithOllama(item)
        } else {
            analyzeArchivedFile(request.fileURL, category: request.category)
        }
    }

    func isAIProcessing(_ url: URL) -> Bool {
        aiProcessingPaths.contains(url.standardizedFileURL.path)
    }

    private func initializeOllama() async {
        _ = await refreshOllamaStatus()
    }

    @discardableResult
    private func refreshOllamaStatus() async -> Bool {
        guard ollamaEnabled else {
            ollamaStatus = "已关闭"
            return false
        }
        ollamaStatus = "正在连接本机 Ollama…"
        do {
            let client = OllamaClient()
            let version = try await client.version()
            let models = try await client.installedModels()
            guard models.contains(where: { $0 == ollamaModel || $0.hasPrefix("\(ollamaModel):") }) else {
                ollamaStatus = "已连接 Ollama \(version)，但缺少 \(ollamaModel)"
                return false
            }
            ollamaStatus = "已连接 · \(ollamaModel) · Ollama \(version)"
            return true
        } catch {
            ollamaStatus = error.localizedDescription
            return false
        }
    }

    private func performAIAnalysis(_ item: InboxItem) async {
        guard ollamaEnabled,
              pendingItems.contains(where: { $0.id == item.id }),
              aiProcessingItemIDs.insert(item.id).inserted else { return }
        defer { aiProcessingItemIDs.remove(item.id) }
        ollamaStatus = "正在分析“\(item.url.lastPathComponent)”…"
        let model = ollamaModel
        let maximumCharacters = item.suggestion.category == .researchPapers ? 12_000 : 30_000
        let content = await Task.detached(priority: .utility) {
            FileTextExtractor().text(for: item.url, maximumCharacters: maximumCharacters)
        }.value
        do {
            let analysis = try await OllamaClient().analyze(
                fileURL: item.url,
                origin: item.origin,
                fallbackSuggestion: item.suggestion,
                extractedText: content,
                model: model
            )
            guard ollamaEnabled,
                  !Task.isCancelled,
                  let index = pendingItems.firstIndex(where: { $0.id == item.id }) else { return }
            let baseTags = tagger.tags(
                for: item.url,
                category: analysis.suggestion.category,
                origin: item.origin,
                contentText: content
            )
            let tags = mergedTags(baseTags, analysis.tags, category: analysis.suggestion.category)
            pendingItems[index] = pendingItems[index].applyingAIAnalysis(analysis, mergedTags: tags)
            aiAnalyses[item.url.standardizedFileURL.path] = analysis
            persistPendingItems()
            persistAIAnalyses()
            ollamaStatus = "已连接 · \(model)"
            refreshSearchIndex(for: [item.url])
        } catch is CancellationError {
            return
        } catch {
            ollamaStatus = error.localizedDescription
        }
    }

    private func mergedTags(_ existing: [SmartTag], _ aiTags: [SmartTag], category: FileCategory) -> [SmartTag] {
        let combined = Array(Set(existing + aiTags))
        return tagger.replacingCategoryTag(in: combined, with: category)
    }

    private func relocateDocumentMetadata(from source: URL, to destination: URL) {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        if filePreviewURL?.standardizedFileURL.path == sourcePath {
            filePreviewURL = destination.standardizedFileURL
        }
        if let analysis = aiAnalyses.removeValue(forKey: sourcePath) {
            aiAnalyses[destinationPath] = analysis
            persistAIAnalyses()
        }
        if let assignments = virtualFacetAssignments.removeValue(forKey: sourcePath) {
            virtualFacetAssignments[destinationPath] = assignments
            persistVirtualFacets()
        }
    }

    func reclassify(file source: URL, from currentCategory: FileCategory, to newCategory: FileCategory) {
        guard currentCategory != newCategory else { return }
        let sourcePath = source.standardizedFileURL.path
        guard processingLibraryPaths.insert(sourcePath).inserted else { return }
        let libraryRoot = libraryURL

        Task { [weak self] in
            let result: BackgroundResult<URL> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try RoutingService().reclassify(
                        file: source,
                        from: currentCategory,
                        to: newCategory,
                        libraryRoot: libraryRoot
                    ))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            processingLibraryPaths.remove(sourcePath)
            guard case let .success(destination) = result else {
                if case let .failure(message) = result { errorMessage = message }
                return
            }

            relocateDocumentMetadata(from: source, to: destination)

            if let index = history.firstIndex(where: {
                !$0.isRestored
                    && URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path == sourcePath
            }) {
                history[index].destinationPath = destination.path
                history[index].category = newCategory
                history[index].tags = tagger.replacingCategoryTag(
                    in: history[index].tags ?? [],
                    with: newCategory
                )
            } else {
                let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
                history.insert(RoutingRecord(
                    originalPath: source.path,
                    destinationPath: destination.path,
                    category: newCategory,
                    operation: .move,
                    origin: .unknown,
                    sourceFileSize: size,
                    tags: [tagger.categoryTag(for: newCategory)]
                ), at: 0)
            }

            persistHistory()
            refreshCategoryCounts()
            refreshSearchIndex(for: [source, destination])
        }
    }

    private var canChangeStorageLocations: Bool {
        guard processingItemIDs.isEmpty, processingHistoryIDs.isEmpty, !isImportingExistingFiles else {
            errorMessage = "归流正在处理文件。请等待当前操作完成后再更改来源或文件库位置。"
            return false
        }
        return true
    }

    func rebuildSearchIndex() {
        searchIndexTask?.cancel()
        searchFullTextTask?.cancel()
        searchIndexGeneration += 1
        let generation = searchIndexGeneration
        isIndexingSearch = true
        isPreparingFullTextSearch = false
        searchIndexIncludesFullContent = false
        let libraryRoot = libraryURL
        let pendingSnapshot = pendingItems
        let historySnapshot = history
        let aiAnalysesSnapshot = aiAnalyses
        let virtualTagsSnapshot = virtualSearchTags()
        let cachedContentSnapshot = searchContentCache

        searchIndexTask = Task.detached(priority: .utility) { [weak self] in
            // Merge bursts such as import + tag enrichment + routing into one
            // metadata pass instead of repeatedly walking the whole library.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let snapshot = SearchIndexBuilder().buildSnapshot(
                libraryRoot: libraryRoot,
                pendingItems: pendingSnapshot,
                history: historySnapshot,
                aiAnalyses: aiAnalysesSnapshot,
                virtualTags: virtualTagsSnapshot,
                includeFileContent: false,
                cachedContent: cachedContentSnapshot
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.searchIndexGeneration == generation else { return }
                self.searchDocuments = snapshot.documents
                self.searchContentCache = snapshot.contentCache
                self.isIndexingSearch = false
                self.searchIndexTask = nil
                self.updateSearch()
            }
        }
    }

    /// Applies a small mutation directly to the in-memory index. Routine file
    /// actions should never walk an 11k+ document library just to update one
    /// renamed file or one virtual label. Full reconciliation remains reserved
    /// for launch, library-root changes and explicit bulk import.
    private func refreshSearchIndex(for changedURLs: [URL]) {
        let paths = Set(changedURLs.map { $0.standardizedFileURL.path })
        guard !paths.isEmpty else { return }

        // A launch/bulk reconciliation owns the complete snapshot. Fold this
        // mutation into its debounced rebuild rather than publishing a partial
        // index that could later be overwritten by stale work.
        guard searchIndexTask == nil, !isIndexingSearch else {
            rebuildSearchIndex()
            return
        }

        searchFullTextTask?.cancel()
        searchFullTextTask = nil
        isPreparingFullTextSearch = false
        searchIndexGeneration += 1
        searchIndexIncludesFullContent = false

        var replacements: [SearchDocument] = []
        replacements.reserveCapacity(paths.count)
        for url in changedURLs {
            let standardizedURL = url.standardizedFileURL
            guard paths.contains(standardizedURL.path),
                  let document = makeIncrementalSearchDocument(for: standardizedURL) else { continue }
            replacements.append(document)
        }

        searchDocuments.removeAll { paths.contains($0.id) }
        var replacementPaths = Set<String>()
        for document in replacements where replacementPaths.insert(document.id).inserted {
            searchDocuments.append(document)
        }

        // Discard obsolete cached bodies for deleted/renamed/modified files,
        // while retaining the exact current identity used by a replacement.
        let validKeys = Set(replacements.map {
            SearchContentCacheKey(
                url: $0.url,
                fileSize: $0.fileSize,
                modificationDate: $0.modificationDate
            )
        })
        searchContentCache = searchContentCache.filter { key, _ in
            !paths.contains(key.path) || validKeys.contains(key)
        }
        updateSearch()
    }

    private func makeIncrementalSearchDocument(for url: URL) -> SearchDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        guard values?.isRegularFile == true || values?.isDirectory == true else { return nil }

        let path = url.standardizedFileURL.path
        let fileSize = Int64(values?.fileSize ?? 0)
        let modificationDate = values?.contentModificationDate
        let cacheKey = SearchContentCacheKey(
            url: url,
            fileSize: fileSize,
            modificationDate: modificationDate
        )
        let analysis = aiAnalyses[path]
        let extractedContent = values?.isRegularFile == true ? (searchContentCache[cacheKey] ?? "") : ""
        let content = [extractedContent, analysis?.summary]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if let item = pendingItems.first(where: { $0.url.standardizedFileURL.path == path }) {
            let inferred = tagger.tags(
                for: url,
                category: item.suggestion.category,
                origin: item.origin,
                contentText: content
            )
            let tags = mergedTags(
                item.tags + inferred,
                analysis?.tags ?? [],
                category: item.suggestion.category
            )
            return SearchDocument(
                url: url,
                category: item.suggestion.category,
                origin: item.origin,
                tags: tags,
                location: .inbox,
                fileSize: fileSize,
                modificationDate: modificationDate,
                contentText: content,
                isDirectory: values?.isDirectory == true
            )
        }

        guard let category = libraryCategory(containing: url) else { return nil }
        let record = history.first {
            !$0.isRestored
                && URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path == path
        }
        let origin = record?.effectiveOrigin ?? .unknown
        let inferred = tagger.tags(
            for: url,
            category: category,
            origin: origin,
            contentText: content
        )
        let tags = mergedTags(
            (record?.tags ?? []) + inferred + virtualSearchTags(for: path),
            analysis?.tags ?? [],
            category: category
        )
        return SearchDocument(
            url: url,
            category: category,
            origin: origin,
            tags: tags,
            location: .library,
            fileSize: fileSize,
            modificationDate: modificationDate,
            contentText: content,
            isDirectory: values?.isDirectory == true
        )
    }

    private func libraryCategory(containing url: URL) -> FileCategory? {
        let root = libraryURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        guard let firstComponent = relative.split(separator: "/", maxSplits: 1).first else { return nil }
        return FileCategory.allCases.first { $0.displayName == String(firstComponent) }
    }

    func updateSearch() {
        searchQueryTask?.cancel()
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchMode == .fullText, !trimmedQuery.isEmpty {
            prepareFullTextSearchIndexIfNeeded()
        } else if isPreparingFullTextSearch {
            searchFullTextTask?.cancel()
            searchFullTextTask = nil
            isPreparingFullTextSearch = false
        }
        searchQueryGeneration += 1
        let generation = searchQueryGeneration
        let query = searchQuery
        let documents = searchDocuments
        let scope = searchScope
        let mode = searchMode
        let categoryFilter = searchCategoryFilter

        searchQueryTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = FileSearchEngine().search(
                query,
                in: documents,
                scope: scope,
                category: categoryFilter,
                mode: mode
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.searchQueryGeneration == generation,
                      self.searchQuery == query,
                      self.searchScope == scope,
                      self.searchMode == mode,
                      self.searchCategoryFilter == categoryFilter else { return }
                self.searchResults = results
                self.searchQueryTask = nil
            }
        }
    }

    private func prepareFullTextSearchIndexIfNeeded() {
        guard !searchIndexIncludesFullContent,
              !isIndexingSearch,
              !isResourceConstrained,
              searchFullTextTask == nil else { return }
        isPreparingFullTextSearch = true
        let generation = searchIndexGeneration
        let libraryRoot = libraryURL
        let pendingSnapshot = pendingItems
        let historySnapshot = history
        let aiAnalysesSnapshot = aiAnalyses
        let virtualTagsSnapshot = virtualSearchTags()
        let cachedContentSnapshot = searchContentCache

        searchFullTextTask = Task.detached(priority: .background) { [weak self] in
            let snapshot = SearchIndexBuilder().buildSnapshot(
                libraryRoot: libraryRoot,
                pendingItems: pendingSnapshot,
                history: historySnapshot,
                aiAnalyses: aiAnalysesSnapshot,
                virtualTags: virtualTagsSnapshot,
                includeFileContent: true,
                cachedContent: cachedContentSnapshot
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.searchIndexGeneration == generation,
                      self.searchMode == .fullText else { return }
                self.searchDocuments = snapshot.documents
                self.searchContentCache = snapshot.contentCache
                self.searchIndexIncludesFullContent = true
                self.isPreparingFullTextSearch = false
                self.searchFullTextTask = nil
                self.updateSearch()
            }
        }
    }

    func searchPaths(in category: FileCategory, matching query: String) -> Set<String> {
        Set(
            FileSearchEngine()
                .search(query, in: searchDocuments, scope: .library, category: category, mode: .filename)
                .map { $0.document.url.standardizedFileURL.path }
        )
    }

    func search(for tag: SmartTag) {
        searchQuery = "标签:\(tag.value)"
        searchScope = .all
        updateSearch()
        navigate(to: .search)
    }

    func clearRule(for extensionName: String) {
        customRules.removeValue(forKey: extensionName.lowercased())
        persistCustomRules()
    }

    var rules: [(extensionName: String, category: FileCategory)] {
        customRules
            .map { (extensionName: $0.key, category: $0.value) }
            .sorted { $0.extensionName < $1.extensionName }
    }

    private func startAppLocationDiscovery() {
        let testingPath = ProcessInfo.processInfo.environment["GUILIU_WECHAT_PATH"]
        let discoveryEnabled = ProcessInfo.processInfo.environment["GUILIU_DISABLE_APP_DISCOVERY"] != "1"

        Task { [weak self] in
            let urls = await Task.detached(priority: .utility) {
                guard discoveryEnabled else { return [URL]() }
                if let testingPath {
                    let url = URL(fileURLWithPath: testingPath, isDirectory: true)
                    return FileManager.default.fileExists(atPath: url.path) ? [url] : []
                }

                let accountRoot = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files",
                        isDirectory: true
                    )
                let accounts = (try? FileManager.default.contentsOfDirectory(
                    at: accountRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                return accounts.compactMap { accountURL in
                    let fileURL = accountURL.appendingPathComponent("msg/file", isDirectory: true)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(
                        atPath: fileURL.path,
                        isDirectory: &isDirectory
                    ), isDirectory.boolValue else { return nil }
                    return fileURL
                }
            }.value
            guard let self else { return }
            weChatFileURLs = urls
            refreshPersistedPendingRoutingPolicies()
            reconcilePendingFileExistence()
            primeMonitors()
            scanForNewFiles()
        }
    }

    /// Re-evaluates queued items from their current physical location. Physical
    /// ownership is authoritative: user-managed folders move, while files inside
    /// an App-managed attachment tree use references.
    private func refreshPersistedPendingRoutingPolicies() {
        var didChange = false
        for index in pendingItems.indices {
            let item = pendingItems[index]
            let resolution = routingPolicy(for: item)
            let sourceID = resolution.location?.id ?? item.sourceID
            let sourceDisplayName = resolution.location?.displayName ?? item.sourceDisplayName
            guard item.routingOperation != resolution.operation
                    || item.sourceID != sourceID
                    || item.sourceDisplayName != sourceDisplayName else { continue }

            pendingItems[index] = InboxItem(
                id: item.id,
                url: item.url,
                detectedAt: item.detectedAt,
                fileSize: item.fileSize,
                suggestion: item.suggestion,
                origin: item.origin,
                routingOperation: resolution.operation,
                sourceID: sourceID,
                sourceDisplayName: sourceDisplayName,
                tags: item.tags,
                modificationDate: item.modificationDate,
                resourceIdentifier: item.resourceIdentifier,
                resourceIdentifierSession: item.resourceIdentifierSession,
                persistentIdentity: item.persistentIdentity,
                aiSummary: item.aiSummary,
                aiModel: item.aiModel,
                aiAnalyzedAt: item.aiAnalyzedAt
            )
            didChange = true
        }
        if didChange {
            persistPendingItems()
        }
    }

    private func routingPolicy(for item: InboxItem) -> RoutingPolicyResolution {
        var locations = monitoredLocations

        // Include discovered App-managed roots even if their live monitor has
        // since been disabled. A pending App original must never become a move
        // merely because monitoring was turned off after it entered the inbox.
        for url in weChatFileURLs {
            let id = MonitoredLocation.stableSourceID(namespace: "wechat", directoryURL: url)
            guard !locations.contains(where: { $0.id == id }) else { continue }
            locations.append(MonitoredLocation(
                id: id,
                displayName: "微信接收文件",
                url: url,
                origin: .wechat,
                fileOwnership: .appManagedOriginal,
                recursive: true
            ))
        }

        if let location = MonitoredLocation.preferred(for: item.url, among: locations) {
            return RoutingPolicyResolution(
                operation: location.routingOperation,
                location: location
            )
        }

        // If an App location is temporarily unavailable, retain the reference
        // policy for its already-persisted items. Every other source defaults to
        // moving so unknown or obsolete metadata cannot create silent doubles.
        if item.sourceID.hasPrefix("wechat-") {
            return RoutingPolicyResolution(operation: .reference, location: nil)
        }
        return RoutingPolicyResolution(operation: .move, location: nil)
    }

    private func prepareLibrary() {
        do {
            if !FileManager.default.fileExists(atPath: libraryURL.path) {
                try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            }
            try router.prepareLibrary(at: libraryURL)
        } catch {
            errorMessage = "无法准备文件库：\(error.localizedDescription)"
        }
    }

    private func primeMonitors() {
        monitorScanGeneration += 1
        let generation = monitorScanGeneration
        monitorScanTask?.cancel()
        monitorRescanRequested = false
        monitorPendingPaths.removeAll()
        monitorRequiresFullScan = false
        stabilityRecheckTask?.cancel()
        stabilityRecheckTask = nil
        enqueuePreparationTask?.cancel()
        enqueuePreparationTask = nil
        pendingEnqueueEntries.removeAll()
        pendingEnqueuePaths.removeAll()
        let locations = monitoredLocations
        stability.removeAll()
        if isMonitoring {
            restartFileSystemEventMonitor()
        }

        monitorScanTask = Task.detached(priority: .utility) { [weak self] in
            let scanned = Self.scanEntries(in: locations)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.monitorScanGeneration == generation else { return }
                self.knownPaths = Set(scanned.map { $0.entry.url.path })
                self.knownPaths.formUnion(self.pendingItems.map { $0.url.standardizedFileURL.path })
                self.monitorScanTask = nil
                self.startPendingMonitorScanIfNeeded()
            }
        }
    }

    private func restartFileSystemEventMonitor() {
        fileSystemMonitor?.stop()
        let monitor = FileSystemEventMonitor(urls: monitoredLocations.map(\.url)) { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.requestMonitorScan(
                    paths: batch.paths,
                    requiresFullScan: batch.requiresFullScan
                )
            }
        }
        fileSystemMonitor = monitor.start() ? monitor : nil
    }

    private func scanForNewFiles() {
        requestMonitorScan(requiresFullScan: true)
    }

    private func requestMonitorScan(
        paths: [URL] = [],
        requiresFullScan: Bool
    ) {
        if requiresFullScan {
            monitorRequiresFullScan = true
            monitorPendingPaths.removeAll()
        } else if !monitorRequiresFullScan {
            monitorPendingPaths.formUnion(paths.map { $0.standardizedFileURL.path })
        }
        if monitorScanTask != nil {
            monitorRescanRequested = true
            return
        }
        startPendingMonitorScanIfNeeded()
    }

    private func startPendingMonitorScanIfNeeded() {
        guard monitorScanTask == nil, isMonitoring else { return }
        let performsFullScan = monitorRequiresFullScan
        let changedPaths = monitorPendingPaths
        guard performsFullScan || !changedPaths.isEmpty else {
            monitorRescanRequested = false
            scheduleStabilityRecheckIfNeeded()
            return
        }

        monitorRequiresFullScan = false
        monitorPendingPaths.removeAll()
        monitorRescanRequested = false
        let generation = monitorScanGeneration
        let locations = monitoredLocations
        let pendingURLs = pendingItems.map(\.url)

        monitorScanTask = Task.detached(priority: .utility) { [weak self] in
            let scanned = performsFullScan
                ? Self.scanEntries(in: locations)
                : Self.scanChangedEntries(
                    at: changedPaths.map(URL.init(fileURLWithPath:)),
                    in: locations
                )
            let missingPendingPaths = Set(PendingFileReconciler.missingFileURLs(
                among: pendingURLs,
                monitoredLocations: locations,
                affectedBy: performsFullScan
                    ? nil
                    : changedPaths.map(URL.init(fileURLWithPath:))
            ).map { $0.standardizedFileURL.path })
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.isMonitoring,
                      self.monitorScanGeneration == generation else { return }
                if performsFullScan {
                    self.applyMonitorScan(
                        scanned,
                        locations: locations,
                        missingPendingPaths: missingPendingPaths
                    )
                } else {
                    self.applyIncrementalMonitorScan(
                        scanned,
                        changedPaths: changedPaths,
                        locations: locations,
                        missingPendingPaths: missingPendingPaths
                    )
                }
                self.monitorScanTask = nil
                self.startPendingMonitorScanIfNeeded()
            }
        }
    }

    private func scheduleStabilityRecheckIfNeeded() {
        stabilityRecheckTask?.cancel()
        stabilityRecheckTask = nil
        guard isMonitoring, !stability.isEmpty else { return }

        stabilityRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, isMonitoring else { return }
            stabilityRecheckTask = nil
            requestMonitorScan(
                paths: stability.keys.map(URL.init(fileURLWithPath:)),
                requiresFullScan: false
            )
        }
    }

    private func applyMonitorScan(
        _ scanned: [ScannedEntry],
        locations: [MonitoredLocation],
        missingPendingPaths: Set<String>
    ) {
        let currentPaths = Set(scanned.map { $0.entry.url.path })
        let rootPaths = locations.map { standardizedDirectoryPrefix($0.url) }

        let stalePaths = knownPaths.filter { knownPath in
            rootPaths.contains(where: knownPath.hasPrefix) && !currentPaths.contains(knownPath)
        }
        for stalePath in stalePaths {
            knownPaths.remove(stalePath)
            stability.removeValue(forKey: stalePath)
        }

        removeMissingPendingItems(at: missingPendingPaths)
        processMonitorDiscoveries(scanned)
    }

    private func applyIncrementalMonitorScan(
        _ scanned: [ScannedEntry],
        changedPaths: Set<String>,
        locations: [MonitoredLocation],
        missingPendingPaths: Set<String>
    ) {
        let scannedPaths = Set(scanned.map { $0.entry.url.standardizedFileURL.path })
        let recursiveRoots = locations.filter(\.recursive).map { standardizedDirectoryPrefix($0.url) }
        for changedPath in changedPaths where !scannedPaths.contains(changedPath) {
            knownPaths.remove(changedPath)
            stability.removeValue(forKey: changedPath)
            let directoryPrefix = changedPath.hasSuffix("/") ? changedPath : changedPath + "/"
            if recursiveRoots.contains(where: changedPath.hasPrefix) {
                knownPaths = knownPaths.filter { !$0.hasPrefix(directoryPrefix) }
                stability = stability.filter { !$0.key.hasPrefix(directoryPrefix) }
            }
        }
        removeMissingPendingItems(at: missingPendingPaths)
        processMonitorDiscoveries(scanned)
    }

    private func removeMissingPendingItems(
        at candidatePaths: Set<String>,
        refreshesSearchIndex: Bool = true,
        notifiesQuickArchivePanel: Bool = true
    ) {
        guard !candidatePaths.isEmpty else { return }

        // Recheck on the committing actor: a file may have been recreated at
        // the same path after the background snapshot was taken. App-owned
        // routing operations are also allowed to finish their own transaction.
        let removedItems = pendingItems.filter { item in
            let path = item.url.standardizedFileURL.path
            return candidatePaths.contains(path)
                && !processingItemIDs.contains(item.id)
                && !FileManager.default.fileExists(atPath: path)
        }
        guard !removedItems.isEmpty else { return }

        let removedIDs = Set(removedItems.map(\.id))
        let removedPaths = Set(removedItems.map { $0.url.standardizedFileURL.path })
        pendingItems.removeAll { removedIDs.contains($0.id) }
        tagAnalysisQueue.removeAll { removedIDs.contains($0.id) }
        aiProcessingItemIDs.subtract(removedIDs)
        aiProcessingPaths.subtract(removedPaths)

        var removedAnalysis = false
        var removedFacetAssignments = false
        for item in removedItems {
            let path = item.url.standardizedFileURL.path
            knownPaths.remove(path)
            knownPaths.remove(item.url.path)
            stability.removeValue(forKey: path)
            stability.removeValue(forKey: item.url.path)
            pendingEnqueuePaths.remove(path)
            pendingEnqueueEntries.removeValue(forKey: path)
            if notifiesQuickArchivePanel {
                quickArchivePanel.itemDidLeaveQueue(item.id)
            }
            if aiAnalyses.removeValue(forKey: path) != nil {
                removedAnalysis = true
            }
            if virtualFacetAssignments.removeValue(forKey: path) != nil {
                removedFacetAssignments = true
            }
        }

        if let previewPath = filePreviewURL?.standardizedFileURL.path,
           removedPaths.contains(previewPath) {
            filePreviewURL = nil
        }
        if let readerPath = aiAnalysisReader?.fileURL.standardizedFileURL.path,
           removedPaths.contains(readerPath) {
            aiAnalysisReader = nil
        }

        persistPendingItems()
        if removedAnalysis { persistAIAnalyses() }
        if removedFacetAssignments { persistVirtualFacets() }
        if refreshesSearchIndex {
            refreshSearchIndex(for: removedItems.map(\.url))
        }
    }

    private func processMonitorDiscoveries(_ scanned: [ScannedEntry]) {
        let pendingPaths = Set(pendingItems.map(\.url.path))
        var ready: [ScannedEntry] = []
        for scannedEntry in scanned {
            let entry = scannedEntry.entry
            guard !knownPaths.contains(entry.url.path),
                  !pendingEnqueuePaths.contains(entry.url.path),
                  !pendingPaths.contains(entry.url.path),
                  !shouldIgnore(entry.url, in: entry.location) else { continue }
            let entryFingerprint = fingerprint(for: scannedEntry)
            if handledFingerprints.contains(entryFingerprint) {
                knownPaths.insert(entry.url.path)
                continue
            }

            if var observation = stability[entry.url.path] {
                if observation.size == scannedEntry.size,
                   observation.modificationDate == scannedEntry.modificationDate,
                   observation.resourceIdentifier == scannedEntry.resourceIdentifier {
                    observation.unchangedPasses += 1
                } else {
                    observation.size = scannedEntry.size
                    observation.modificationDate = scannedEntry.modificationDate
                    observation.resourceIdentifier = scannedEntry.resourceIdentifier
                    observation.unchangedPasses = 0
                }
                stability[entry.url.path] = observation

                if observation.unchangedPasses >= 1 {
                    ready.append(scannedEntry)
                }
            } else {
                stability[entry.url.path] = StabilityObservation(
                    size: scannedEntry.size,
                    modificationDate: scannedEntry.modificationDate,
                    resourceIdentifier: scannedEntry.resourceIdentifier,
                    unchangedPasses: 0
                )
            }
        }
        enqueue(ready)
    }

    private func enqueue(_ entries: [ScannedEntry]) {
        for entry in entries {
            let path = entry.entry.url.standardizedFileURL.path
            guard pendingEnqueuePaths.insert(path).inserted else { continue }
            pendingEnqueueEntries[path] = entry
            stability.removeValue(forKey: path)
        }
        startNextInboxPreparationIfNeeded()
    }

    private func startNextInboxPreparationIfNeeded() {
        guard enqueuePreparationTask == nil, !pendingEnqueueEntries.isEmpty else { return }
        let batch = Array(pendingEnqueueEntries.values)
        pendingEnqueueEntries.removeAll()
        let rules = customRules
        let generation = monitorScanGeneration

        enqueuePreparationTask = Task.detached(priority: .utility) { [weak self] in
            let prepared = batch.compactMap { scanned -> InboxItem? in
                guard !Task.isCancelled,
                      FileManager.default.fileExists(atPath: scanned.entry.url.path) else { return nil }
                return Self.makeInboxItem(
                    entry: scanned.entry,
                    size: scanned.size,
                    modificationDate: scanned.modificationDate,
                    resourceIdentifier: scanned.resourceIdentifier,
                    customRules: rules
                )
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                for scanned in batch {
                    self.pendingEnqueuePaths.remove(scanned.entry.url.standardizedFileURL.path)
                }
                self.enqueuePreparationTask = nil
                guard self.isMonitoring,
                      self.monitorScanGeneration == generation else {
                    self.startNextInboxPreparationIfNeeded()
                    return
                }

                let existingPaths = Set(self.pendingItems.map { $0.url.standardizedFileURL.path })
                let newItems = prepared.filter {
                    !existingPaths.contains($0.url.standardizedFileURL.path)
                }
                guard !newItems.isEmpty else {
                    self.startNextInboxPreparationIfNeeded()
                    return
                }
                self.pendingItems.append(contentsOf: newItems)
                for item in newItems {
                    self.knownPaths.insert(item.url.standardizedFileURL.path)
                    self.analyzeTags(for: item)
                    self.quickArchivePanel.enqueue(item)
                }
                self.persistPendingItems()
                self.refreshSearchIndex(for: newItems.map(\.url))
                self.startNextInboxPreparationIfNeeded()
            }
        }
    }

    /// Undo and Trash restore should reconstruct the state that existed before
    /// the operation: the file is visible in the inbox and may be handled again.
    /// Merely moving it back while retaining its handled fingerprint would make
    /// both the monitor and an explicit historical scan suppress it forever.
    private func requeueRestoredFile(
        at url: URL,
        preferredSourceID: String? = nil,
        previousPath: String? = nil
    ) {
        guard FileManager.default.fileExists(atPath: url.path),
              let location = restoredLocation(for: url, preferredSourceID: preferredSourceID),
              let info = fileInfo(at: url) else {
            // If a formerly monitored directory is currently unavailable, do
            // not mark the restored path as known. A later scan can discover it.
            knownPaths.remove(url.path)
            return
        }

        let entry = MonitoredEntry(url: url, location: location)
        clearHandledFingerprints(for: entry, info: info, previousPath: previousPath)
        stability.removeValue(forKey: url.path)
        knownPaths.insert(url.path)

        guard !pendingItems.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) else {
            persistHandledFingerprints()
            return
        }

        let item = Self.makeInboxItem(
            entry: entry,
            size: info.size,
            modificationDate: info.modificationDate,
            resourceIdentifier: nil,
            customRules: customRules
        )
        pendingItems.insert(item, at: 0)
        persistHandledFingerprints()
        persistPendingItems()
        analyzeTags(for: item)
        navigate(to: .inbox)
    }

    private func restoredLocation(for url: URL, preferredSourceID: String?) -> MonitoredLocation? {
        let candidates = monitoredLocations.filter { $0.contains(fileURL: url) }
        if let preferredSourceID,
           let preferred = candidates.first(where: { $0.id == preferredSourceID }),
           MonitoredLocation.preferred(for: url, among: candidates)?.url == preferred.url {
            return preferred
        }
        return MonitoredLocation.preferred(for: url, among: candidates)
    }

    private func clearHandledFingerprints(
        for entry: MonitoredEntry,
        info: (size: Int64, modificationDate: Date?),
        previousPath: String?
    ) {
        let values = try? entry.url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        var identities = Set<String>()
        if let resourceID = values?.fileResourceIdentifier.map({ String(describing: $0) }) {
            identities.insert(resourceID)
        }
        identities.insert(entry.url.standardizedFileURL.resolvingSymlinksInPath().path)
        if let previousPath {
            identities.insert(
                URL(fileURLWithPath: previousPath)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
            )
        }

        let prefixes = identities.map { "\(entry.location.id)|\($0)|\(info.size)|" }
        handledFingerprints = handledFingerprints.filter { fingerprint in
            !prefixes.contains(where: fingerprint.hasPrefix)
        }
    }

    private nonisolated static func makeInboxItem(
        entry: MonitoredEntry,
        size: Int64,
        modificationDate: Date?,
        resourceIdentifier capturedResourceIdentifier: String? = nil,
        customRules rules: [String: FileCategory]
    ) -> InboxItem {
        let origin = FileOriginDetector().detect(for: entry.url, fallback: entry.location.origin)
        let suggestion = FileClassifier().suggest(for: entry.url, customRules: rules)
        let resourceValues = try? entry.url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        let resourceIdentifier = capturedResourceIdentifier
            ?? resourceValues?.fileResourceIdentifier.map { String(describing: $0) }
        let capturedIdentity = try? FileIdentitySnapshot.capture(at: entry.url)
        let persistentIdentity = capturedIdentity?.matches(
            expectedSize: size,
            expectedModificationDate: modificationDate,
            expectedResourceIdentifier: resourceIdentifier,
            expectedResourceIdentifierSession: FileIdentitySnapshot.currentResourceIdentifierSession
        ) == true ? capturedIdentity?.persistentIdentity : nil
        return InboxItem(
            url: entry.url,
            fileSize: size,
            suggestion: suggestion,
            origin: origin,
            routingOperation: entry.location.routingOperation,
            sourceID: entry.location.id,
            sourceDisplayName: entry.location.displayName,
            tags: SmartTagger().tags(for: entry.url, category: suggestion.category, origin: origin),
            modificationDate: modificationDate,
            resourceIdentifier: resourceIdentifier,
            resourceIdentifierSession: resourceIdentifier == nil
                ? nil : FileIdentitySnapshot.currentResourceIdentifierSession,
            persistentIdentity: persistentIdentity
        )
    }

    private func analyzeTags(for item: InboxItem) {
        guard !tagAnalysisQueue.contains(where: { $0.id == item.id }) else { return }
        tagAnalysisQueue.append(item)
        startNextTagAnalysisBatchIfNeeded()
    }

    private func startNextTagAnalysisBatchIfNeeded() {
        guard tagAnalysisTask == nil, !tagAnalysisQueue.isEmpty else { return }
        let batch = tagAnalysisQueue
        tagAnalysisQueue.removeAll(keepingCapacity: true)

        tagAnalysisTask = Task.detached(priority: .background) { [weak self] in
            var results: [(UUID, [SmartTag])] = []
            results.reserveCapacity(batch.count)
            for item in batch {
                if Task.isCancelled { return }
                let content = FileTextExtractor().text(for: item.url)
                if Task.isCancelled { return }
                let tags = SmartTagger().tags(
                    for: item.url,
                    category: item.suggestion.category,
                    origin: item.origin,
                    contentText: content
                )
                results.append((item.id, tags))
            }

            await MainActor.run {
                guard let self else { return }
                self.tagAnalysisTask = nil
                var didChange = false
                var changedURLs: [URL] = []
                for (id, tags) in results {
                    guard let index = self.pendingItems.firstIndex(where: { $0.id == id }) else { continue }
                    self.pendingItems[index].tags = self.mergedTags(
                        self.pendingItems[index].tags,
                        tags,
                        category: self.pendingItems[index].suggestion.category
                    )
                    changedURLs.append(self.pendingItems[index].url)
                    didChange = true
                }
                if didChange {
                    self.persistPendingItems()
                    self.refreshSearchIndex(for: changedURLs)
                }
                self.startNextTagAnalysisBatchIfNeeded()
            }
        }
    }

    /// Directory enumeration and metadata reads can be expensive for recursive
    /// App attachment folders. This routine is nonisolated so callers can run it
    /// on a utility task and commit only its immutable snapshot on MainActor.
    private nonisolated static func scanEntries(in locations: [MonitoredLocation]) -> [ScannedEntry] {
        MonitoredFileScanner.scan(in: locations).map { scanned in
            ScannedEntry(
                entry: MonitoredEntry(
                    url: scanned.entry.url,
                    location: scanned.entry.location
                ),
                size: scanned.size,
                modificationDate: scanned.modificationDate,
                resourceIdentifier: scanned.resourceIdentifier
            )
        }
    }

    private nonisolated static func scanChangedEntries(
        at urls: [URL],
        in locations: [MonitoredLocation]
    ) -> [ScannedEntry] {
        MonitoredFileScanner.scanChanges(at: urls, in: locations).map { scanned in
            ScannedEntry(
                entry: MonitoredEntry(
                    url: scanned.entry.url,
                    location: scanned.entry.location
                ),
                size: scanned.size,
                modificationDate: scanned.modificationDate,
                resourceIdentifier: scanned.resourceIdentifier
            )
        }
    }

    private func contents(of location: MonitoredLocation) -> [URL] {
        if !location.recursive {
            return (try? FileManager.default.contentsOfDirectory(
                at: location.url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: location.url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                results.append(url)
            }
        }
        return results
    }

    private func shouldIgnore(_ url: URL, in location: MonitoredLocation) -> Bool {
        Self.shouldIgnore(url, in: location)
    }

    private nonisolated static func shouldIgnore(_ url: URL, in location: MonitoredLocation) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ignoredSuffixes = [
            ".crdownload", ".download", ".downloading", ".part", ".partial", ".tmp", ".temp", ".dat", ".ds_store"
        ]
        if ignoredSuffixes.contains(where: name.hasSuffix) { return true }

        if location.origin == .wechat {
            let supportedExtensions: Set<String> = [
                "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "csv", "txt", "md", "zip", "rar", "7z",
                "jpg", "jpeg", "png", "heic", "mp3", "m4a", "wav", "mp4", "mov", "py", "ipynb"
            ]
            return !supportedExtensions.contains(url.pathExtension.lowercased())
        }

        return false
    }

    private func fileInfo(at url: URL) -> (size: Int64, modificationDate: Date?)? {
        guard let snapshot = try? FileIdentitySnapshot.capture(at: url) else { return nil }
        return (snapshot.size, snapshot.modificationDate)
    }

    private func fingerprint(for entry: MonitoredEntry, info: (size: Int64, modificationDate: Date?)) -> String {
        fingerprint(for: entry.url, sourceID: entry.location.id, info: info)
    }

    private func fingerprint(for scannedEntry: ScannedEntry) -> String {
        Self.fingerprintValue(for: scannedEntry)
    }

    private nonisolated static func fingerprintValue(for scannedEntry: ScannedEntry) -> String {
        let identity = scannedEntry.resourceIdentifier
            ?? scannedEntry.entry.url.standardizedFileURL.resolvingSymlinksInPath().path
        let modified = scannedEntry.modificationDate?.timeIntervalSince1970 ?? 0
        return "\(scannedEntry.entry.location.id)|\(identity)|\(scannedEntry.size)|\(modified)"
    }

    private func fingerprint(for item: InboxItem) -> String? {
        guard let info = fileInfo(at: item.url) else { return nil }
        return fingerprint(for: item.url, sourceID: item.sourceID, info: info)
    }

    private func fingerprint(
        for url: URL,
        sourceID: String,
        info: (size: Int64, modificationDate: Date?)
    ) -> String {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        let resourceID = values?.fileResourceIdentifier.map { String(describing: $0) }
            ?? url.standardizedFileURL.resolvingSymlinksInPath().path
        let modified = info.modificationDate?.timeIntervalSince1970 ?? 0
        return "\(sourceID)|\(resourceID)|\(info.size)|\(modified)"
    }

    private func refreshCategoryCounts() {
        categoryCounts = Dictionary(uniqueKeysWithValues: FileCategory.allCases.map { category in
            let directory = libraryURL.appendingPathComponent(category.displayName, isDirectory: true)
            let count = (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
            return (category, count)
        })
    }

    private func refreshDownloadOriginCounts() {
        let currentDownloadURL = downloadURL
        let downloadLocation = MonitoredLocation(
            id: "downloads",
            displayName: "下载文件夹",
            url: currentDownloadURL,
            origin: .downloads
        )

        Task { [weak self] in
            let counts = await Task.detached(priority: .utility) {
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: downloadLocation.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                let detector = FileOriginDetector()
                return urls.reduce(into: [FileOrigin: Int]()) { counts, url in
                    let origin = detector.detect(for: url, fallback: .downloads)
                    counts[origin, default: 0] += 1
                }
            }.value
            guard let self, downloadURL == currentDownloadURL else { return }
            downloadOriginCounts = counts
        }
    }

    private func chooseDirectory(title: String, initialURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = initialURL
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func sameLocation(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath() == second.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isInside(url: URL, directory: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = standardizedDirectoryPrefix(directory)
        return target == String(root.dropLast()) || target.hasPrefix(root)
    }

    private func locationsOverlap(_ first: URL, _ second: URL) -> Bool {
        isInside(url: first, directory: second) || isInside(url: second, directory: first)
    }

    private func standardizedDirectoryPrefix(_ url: URL) -> String {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath().path
        return standardized.hasSuffix("/") ? standardized : standardized + "/"
    }

    private func prepareVirtualFacets() {
        for category in FileCategory.allCases {
            let defaults = VirtualFacetDefaults.dimensions(for: category)
            var dimensions = virtualFacetDimensions[category.rawValue] ?? []
            for defaultDimension in defaults.reversed() {
                if let index = dimensions.firstIndex(where: { $0.id == defaultDimension.id }) {
                    let existingKeys = Set(dimensions[index].values.map(facetComparisonKey))
                    dimensions[index].values.append(contentsOf: defaultDimension.values.filter {
                        !existingKeys.contains(facetComparisonKey($0))
                    })
                } else {
                    dimensions.insert(defaultDimension, at: 0)
                }
            }
            virtualFacetDimensions[category.rawValue] = dimensions
        }
        persistVirtualFacets()
    }

    private func normalizedFacetText(_ value: String) -> String {
        let collapsed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(48))
    }

    private func facetComparisonKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func virtualSearchTags() -> [String: [SmartTag]] {
        virtualFacetAssignments.mapValues { assignments in
            Array(Set(assignments.values.flatMap { $0 }.map {
                SmartTag(kind: .topic, value: $0)
            }))
        }
    }

    private func virtualSearchTags(for path: String) -> [SmartTag] {
        guard let assignments = virtualFacetAssignments[path] else { return [] }
        return Array(Set(assignments.values.flatMap { $0 }.map {
            SmartTag(kind: .topic, value: $0)
        }))
    }


    private func loadPersistedData() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: DefaultsKey.history),
           let decoded = try? decoder.decode([RoutingRecord].self, from: data) {
            history = decoded
        }
        if let data = defaults.data(forKey: DefaultsKey.customRules),
           let decoded = try? decoder.decode([String: FileCategory].self, from: data) {
            customRules = decoded
        }
        if let values = defaults.stringArray(forKey: DefaultsKey.handledFingerprints) {
            handledFingerprints = Set(values)
        }
        if let data = defaults.data(forKey: DefaultsKey.trashHistory),
           let decoded = try? decoder.decode([TrashRecord].self, from: data) {
            trashHistory = decoded
        }
        if let data = defaults.data(forKey: DefaultsKey.pendingItems),
           let decoded = try? decoder.decode([InboxItem].self, from: data) {
            // Preserve records until a known source root is confirmed readable.
            // A missing permission or offline volume must not look like a user
            // deletion; PendingFileReconciler applies that safety boundary.
            pendingItems = decoded
        }
        if let data = defaults.data(forKey: DefaultsKey.aiAnalyses),
           let decoded = try? decoder.decode([String: OllamaDocumentAnalysis].self, from: data) {
            aiAnalyses = decoded
        }
        if let data = defaults.data(forKey: DefaultsKey.virtualFacetDimensions),
           let decoded = try? decoder.decode([String: [VirtualFacetDimension]].self, from: data) {
            virtualFacetDimensions = decoded
        }
        if let data = defaults.data(forKey: DefaultsKey.virtualFacetAssignments),
           let decoded = try? decoder.decode([String: [String: [String]]].self, from: data) {
            virtualFacetAssignments = decoded
        }
    }

    /// Refreshes volatile file identifiers after an App or system restart while
    /// validating the persistent evidence saved with every queued item.
    private func refreshPersistedPendingFileIdentities() {
        var didChange = false
        for index in pendingItems.indices {
            let item = pendingItems[index]
            guard item.resourceIdentifierSession != FileIdentitySnapshot.currentResourceIdentifierSession,
                  let current = try? FileIdentitySnapshot.capture(at: item.url) else { continue }

            let matchesSavedEvidence = current.matches(
                expectedSize: item.fileSize,
                expectedModificationDate: item.modificationDate,
                expectedResourceIdentifier: item.resourceIdentifier,
                expectedResourceIdentifierSession: item.resourceIdentifierSession,
                expectedPersistentIdentity: item.persistentIdentity
            )
            guard matchesSavedEvidence else { continue }

            pendingItems[index] = item.replacingFileIdentity(with: current)
            didChange = true
        }
        if didChange {
            persistPendingItems()
        }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(Array(history.prefix(500))) {
            defaults.set(data, forKey: DefaultsKey.history)
        }
    }

    private func persistCustomRules() {
        if let data = try? JSONEncoder().encode(customRules) {
            defaults.set(data, forKey: DefaultsKey.customRules)
        }
    }

    private func persistHandledFingerprints() {
        defaults.set(Array(handledFingerprints.suffix(10_000)), forKey: DefaultsKey.handledFingerprints)
    }

    private func persistTrashHistory() {
        if let data = try? JSONEncoder().encode(Array(trashHistory.prefix(200))) {
            defaults.set(data, forKey: DefaultsKey.trashHistory)
        }
    }

    private func persistPendingItems() {
        if let data = try? JSONEncoder().encode(pendingItems) {
            defaults.set(data, forKey: DefaultsKey.pendingItems)
        }
    }

    private func persistAIAnalyses() {
        if let data = try? JSONEncoder().encode(aiAnalyses) {
            defaults.set(data, forKey: DefaultsKey.aiAnalyses)
        }
    }

    private func persistVirtualFacets() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(virtualFacetDimensions) {
            defaults.set(data, forKey: DefaultsKey.virtualFacetDimensions)
        }
        if let data = try? encoder.encode(virtualFacetAssignments) {
            defaults.set(data, forKey: DefaultsKey.virtualFacetAssignments)
        }
    }
}
