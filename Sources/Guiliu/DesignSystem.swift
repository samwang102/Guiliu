import AppKit
import GuiliuCore
import SwiftUI
import UniformTypeIdentifiers

enum GuiliuTheme {
    static let brand = Color(red: 0.10, green: 0.42, blue: 0.92)
    static let brandWarm = Color(red: 0.10, green: 0.72, blue: 0.78)
    static let success = Color(red: 0.12, green: 0.60, blue: 0.43)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor).opacity(0.94)
    static let sidebarField = Color.primary.opacity(0.045)
    static let subduedSurface = Color.primary.opacity(0.032)
    static let hoverSurface = Color.primary.opacity(0.028)
    static let hairline = Color.primary.opacity(0.075)
    static let strongHairline = Color.primary.opacity(0.12)

    static let brandGradient = LinearGradient(
        colors: [brandWarm, brand],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Dense file lists use one cached icon per file type. Looking up the icon for
/// every individual path can synchronously invoke Finder metadata providers and
/// makes fast scrolling visibly uneven, especially for Office documents.
@MainActor
enum GuiliuFileIcon {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func image(for url: URL, isDirectory: Bool = false) -> NSImage {
        let extensionName = url.pathExtension.lowercased()
        let key = isDirectory ? "__folder" : (extensionName.isEmpty ? "__file" : extensionName)
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let contentType: UTType
        if isDirectory {
            contentType = .folder
        } else {
            contentType = UTType(filenameExtension: extensionName) ?? .data
        }
        let image = NSWorkspace.shared.icon(for: contentType)
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    static func removeAllCachedImages() {
        cache.removeAllObjects()
    }
}

extension FileCategory {
    var tint: Color {
        switch self {
        case .researchPapers: Color(red: 0.38, green: 0.34, blue: 0.78)
        case .readingMaterials: Color(red: 0.16, green: 0.55, blue: 0.70)
        case .documentsReports: Color(red: 0.20, green: 0.46, blue: 0.78)
        case .presentations: Color(red: 0.90, green: 0.45, blue: 0.20)
        case .codeProjects: Color(red: 0.10, green: 0.54, blue: 0.50)
        case .dataModels: Color(red: 0.27, green: 0.59, blue: 0.34)
        case .visualMedia: Color(red: 0.78, green: 0.31, blue: 0.52)
        case .software: Color(red: 0.55, green: 0.35, blue: 0.72)
        case .recordsForms: Color(red: 0.60, green: 0.43, blue: 0.28)
        case .organizationMaterials: Color(red: 0.12, green: 0.40, blue: 0.72)
        case .needsReview: .secondary
        }
    }
}

struct GuiliuPageBackground: View {
    var body: some View {
        // A solid canvas avoids re-compositing two window-sized translucent
        // gradients whenever a long file list scrolls.
        GuiliuTheme.canvas
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

struct GuiliuCard<Content: View>: View {
    private let padding: CGFloat
    @ViewBuilder private let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(GuiliuTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(GuiliuTheme.hairline, lineWidth: 1)
            }
    }
}

/// A quiet, continuous surface for dense management rows. Unlike a stack of
/// independent cards this establishes one visual group and keeps scrolling
/// light-weight.
struct GuiliuListSurface<Content: View>: View {
    @ViewBuilder private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(GuiliuTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(GuiliuTheme.hairline, lineWidth: 1)
            }
    }
}

struct GuiliuListDivider: View {
    var leading: CGFloat = 62

    var body: some View {
        Rectangle()
            .fill(GuiliuTheme.hairline)
            .frame(height: 1)
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }
}

/// SwiftUI's `Text(date, style: .relative)` installs a timeline that refreshes
/// every visible row. File modification times only need a stable, readable
/// label, so dense lists use this inexpensive snapshot instead.
enum GuiliuRelativeTime {
    static func text(for date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }

        let days = seconds / 86_400
        if days < 30 { return "\(days) 天前" }
        if days < 365 { return "\(max(1, days / 30)) 个月前" }
        return "\(max(1, days / 365)) 年前"
    }
}

struct GuiliuIconTile: View {
    let symbol: String
    var tint: Color = GuiliuTheme.brand
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct GuiliuStatusPill: View {
    let title: String
    let symbol: String
    var tint: Color = GuiliuTheme.success

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.11), in: Capsule())
    }
}

struct GuiliuSectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct GuiliuEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = GuiliuTheme.brand
    @ViewBuilder let actions: Actions

    init(
        symbol: String,
        title: String,
        message: String,
        tint: Color = GuiliuTheme.brand,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 17) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 76, height: 76)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 10) {
                actions
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GuiliuPathLabel: View {
    let path: String

    var body: some View {
        Label {
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "folder")
        }
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .help(path)
        .accessibilityLabel("位置：\(path)")
    }
}

/// A vertical scroll container that reveals a compact, floating return-to-top
/// control without taking space away from the page content.
struct GuiliuBackToTopScrollView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsBackToTop = false
    private let showsIndicators: Bool
    private let content: () -> Content
    private let topAnchor = "guiliu-scroll-top"
    init(
        showsIndicators: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.showsIndicators = showsIndicators
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: showsIndicators) {
                GuiliuScrollOffsetObserver(
                    isPastThreshold: $showsBackToTop,
                    threshold: 480
                )
                .frame(width: 0, height: 0)

                Color.clear
                    .frame(height: 1)
                    .id(topAnchor)

                content()
            }
            .overlay(alignment: .bottomTrailing) {
                if showsBackToTop {
                    Button {
                        if reduceMotion {
                            proxy.scrollTo(topAnchor, anchor: .top)
                        } else {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                proxy.scrollTo(topAnchor, anchor: .top)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(GuiliuTheme.brandGradient, in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.18), lineWidth: 1) }
                    .shadow(color: Color.black.opacity(0.16), radius: 6, y: 2)
                    .help("回到顶部")
                    .accessibilityLabel("回到顶部")
                    .padding(15)
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsBackToTop)
        }
    }
}

/// SwiftUI geometry preferences can stop updating once their sentinel leaves a
/// lazy scroll viewport. Observing the enclosing NSScrollView gives this small
/// progressive control a stable signal without recomputing list rows.
private struct GuiliuScrollOffsetObserver: NSViewRepresentable {
    @Binding var isPastThreshold: Bool
    let threshold: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(isPastThreshold: $isPastThreshold, threshold: threshold)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPastThreshold = $isPastThreshold
        context.coordinator.threshold = threshold
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject {
        var isPastThreshold: Binding<Bool>
        var threshold: CGFloat
        private weak var clipView: NSClipView?

        init(isPastThreshold: Binding<Bool>, threshold: CGFloat) {
            self.isPastThreshold = isPastThreshold
            self.threshold = threshold
        }

        func attach(to view: NSView) {
            guard let scrollView = view.enclosingScrollView else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.attach(to: view)
                }
                return
            }
            let candidate = scrollView.contentView
            guard clipView !== candidate else {
                publish(candidate.bounds.minY)
                return
            }

            stopObserving()
            clipView = candidate
            candidate.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: candidate
            )
            publish(candidate.bounds.minY)
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            clipView = nil
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            publish(clipView.bounds.minY)
        }

        private func publish(_ offset: CGFloat) {
            let value = offset > threshold
            guard value != isPastThreshold.wrappedValue else { return }
            isPastThreshold.wrappedValue = value
        }
    }
}
