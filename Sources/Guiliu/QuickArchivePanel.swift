import AppKit
import GuiliuCore
import SwiftUI

@MainActor
final class QuickArchivePanelController {
    private weak var model: AppModel?
    private var queuedItemIDs: [UUID] = []
    private var currentItemID: UUID?
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    func enqueue(_ item: InboxItem) {
        guard currentItemID != item.id, !queuedItemIDs.contains(item.id) else { return }
        queuedItemIDs.append(item.id)
        presentNextIfNeeded()
    }

    func itemDidLeaveQueue(_ itemID: UUID) {
        if currentItemID == itemID {
            finish(itemID: itemID)
        } else {
            queuedItemIDs.removeAll { $0 == itemID }
        }
    }

    private func presentNextIfNeeded() {
        guard currentItemID == nil, let model else { return }
        while let itemID = queuedItemIDs.first,
              !model.pendingItems.contains(where: { $0.id == itemID }) {
            queuedItemIDs.removeFirst()
        }
        guard let itemID = queuedItemIDs.first,
              let item = model.pendingItems.first(where: { $0.id == itemID }) else { return }

        currentItemID = itemID
        let content = QuickArchivePanelView(
            item: item,
            archive: { [weak self] category, completion in
                self?.archive(itemID: itemID, to: category, completion: completion)
            },
            delete: { [weak self] in self?.delete(itemID: itemID) },
            later: { [weak self] in self?.finish(itemID: itemID) },
            openInbox: { [weak self] in self?.openInbox(itemID: itemID) }
        )

        let size = NSSize(width: 430, height: 246)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: content)

        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - size.width - 18,
            y: visibleFrame.maxY - size.height - 18
        ))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func archive(
        itemID: UUID,
        to category: FileCategory,
        completion: @escaping (String?) -> Void
    ) {
        guard let model,
              let item = model.pendingItems.first(where: { $0.id == itemID }) else {
            finish(itemID: itemID)
            return
        }
        model.route(item, to: category, rememberExtension: false) { [weak self] message in
            completion(message)
            if message == nil {
                self?.finish(itemID: itemID)
            }
        }
    }

    private func delete(itemID: UUID) {
        guard let model,
              let item = model.pendingItems.first(where: { $0.id == itemID }) else {
            finish(itemID: itemID)
            return
        }
        model.delete(item)
    }

    private func openInbox(itemID: UUID) {
        guard let model else { return }
        model.navigate(to: .inbox)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .first(where: { !($0 is NSPanel) })?
            .makeKeyAndOrderFront(nil)
        finish(itemID: itemID)
    }

    private func finish(itemID: UUID) {
        queuedItemIDs.removeAll { $0 == itemID }
        if currentItemID == itemID { currentItemID = nil }
        panel?.orderOut(nil)
        panel = nil
        DispatchQueue.main.async { [weak self] in self?.presentNextIfNeeded() }
    }
}

private struct QuickArchivePanelView: View {
    let item: InboxItem
    let archive: (FileCategory, @escaping (String?) -> Void) -> Void
    let delete: () -> Void
    let later: () -> Void
    let openInbox: () -> Void

    @State private var selectedCategory: FileCategory
    @State private var isSubmitting = false
    @State private var submissionError: String?

    init(
        item: InboxItem,
        archive: @escaping (FileCategory, @escaping (String?) -> Void) -> Void,
        delete: @escaping () -> Void,
        later: @escaping () -> Void,
        openInbox: @escaping () -> Void
    ) {
        self.item = item
        self.archive = archive
        self.delete = delete
        self.later = later
        self.openInbox = openInbox
        _selectedCategory = State(initialValue: item.suggestion.category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: GuiliuFileIcon.image(for: item.url))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .padding(7)
                    .background(selectedCategory.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text("新文件，放到哪里？")
                        .font(.headline.weight(.bold))
                    Text(item.url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(item.sourceDisplayName) · \(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)
                Button(action: later) {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("稍后处理")
            }

            HStack(spacing: 10) {
                Text("归档到")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Menu {
                    ForEach(FileCategory.allCases) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            if category == selectedCategory {
                                Label(category.displayName, systemImage: "checkmark")
                            } else {
                                Label(category.displayName, systemImage: category.symbolName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: selectedCategory.symbolName)
                        Text(selectedCategory.displayName)
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(selectedCategory.tint)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(selectedCategory.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                .menuStyle(.borderlessButton)
            }

            HStack(spacing: 9) {
                if item.routingOperation != .copy {
                    Button(action: delete) {
                        Label(
                            item.routingOperation == .reference ? "原件移到废纸篓" : "移到废纸篓",
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help(item.routingOperation == .reference
                        ? "将 App 原件移到废纸篓，可从操作记录恢复"
                        : "移到废纸篓，可从操作记录恢复")
                    .accessibilityLabel(item.routingOperation == .reference
                        ? "将 App 原件移到废纸篓"
                        : "将文件移到废纸篓")
                }
                Button("在归流中查看", action: openInbox)
                    .buttonStyle(.borderless)
                Spacer()
                Button("稍后", action: later)
                    .buttonStyle(.bordered)
                Button {
                    isSubmitting = true
                    submissionError = nil
                    archive(selectedCategory) { message in
                        isSubmitting = false
                        submissionError = message
                    }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("立即归档", systemImage: item.routingOperation == .reference ? "link" : "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }

            if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityLabel("归档失败：\(submissionError)")
            } else {
                Text("归档完成后此提示会自动关闭")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(17)
        .frame(width: 430, height: 246)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}
