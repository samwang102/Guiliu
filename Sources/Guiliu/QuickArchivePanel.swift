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
            delete: { [weak self] completion in
                self?.delete(itemID: itemID, completion: completion)
            },
            later: { [weak self] in self?.finish(itemID: itemID) },
            openInbox: { [weak self] in self?.openInbox(itemID: itemID) }
        )

        let size = NSSize(width: 360, height: 178)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
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

    private func delete(itemID: UUID, completion: @escaping (String?) -> Void) {
        guard let model,
              let item = model.pendingItems.first(where: { $0.id == itemID }) else {
            finish(itemID: itemID)
            return
        }
        model.delete(item, completion: completion)
    }

    private func openInbox(itemID: UUID) {
        guard let model else { return }
        model.navigate(to: .inbox)
        if let item = model.pendingItems.first(where: { $0.id == itemID }) {
            model.previewFile(item.url)
        }
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
    let delete: (@escaping (String?) -> Void) -> Void
    let later: () -> Void
    let openInbox: () -> Void

    @State private var selectedCategory: FileCategory
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        item: InboxItem,
        archive: @escaping (FileCategory, @escaping (String?) -> Void) -> Void,
        delete: @escaping (@escaping (String?) -> Void) -> Void,
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(nsImage: GuiliuFileIcon.image(for: item.url))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .padding(5)
                    .background(selectedCategory.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.url.lastPathComponent)
                    Text("\(item.sourceDisplayName) · \(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

            HStack(spacing: 8) {
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

            HStack(spacing: 12) {
                Button {
                    isSubmitting = true
                    submissionError = nil
                    delete { message in
                        isSubmitting = false
                        submissionError = message
                    }
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help(item.routingOperation == .reference
                    ? "将 App 原件移到废纸篓，可从操作记录恢复"
                    : "移到废纸篓，可从操作记录恢复")
                .accessibilityLabel(item.routingOperation == .reference
                    ? "将 App 原件移到废纸篓"
                    : "将文件移到废纸篓")

                Button("预览", action: openInbox)
                    .buttonStyle(.borderless)
                Spacer()
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
                        Label("归档", systemImage: item.routingOperation == .reference ? "link" : "arrow.right")
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
                    .help(submissionError)
                    .accessibilityLabel("操作失败：\(submissionError)")
            } else {
                Text(item.routingOperation == .reference ? "引用归档 · 删除会将 App 原件移到废纸篓" : "关闭可稍后处理 · 删除的文件可从废纸篓恢复")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(isSubmitting)
        .padding(13)
        .frame(width: 360, height: 178)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}
