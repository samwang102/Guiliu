import AppKit
import QuickLookUI
import SwiftUI

struct FilePreviewReaderView: View {
    @Environment(AppModel.self) private var model
    let fileURL: URL
    @State private var preparedPreviewURL: URL?

    private var details: String {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let type = values?.isDirectory == true
            ? "文件夹"
            : (fileURL.pathExtension.isEmpty ? "文件" : fileURL.pathExtension.uppercased())
        guard let size = values?.fileSize, values?.isDirectory != true else { return type }
        return "\(type) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    private var isDirectory: Bool {
        (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: GuiliuFileIcon.image(for: fileURL, isDirectory: isDirectory))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .padding(6)
                    .background(GuiliuTheme.brand.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("打开") {
                    NSWorkspace.shared.open(fileURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    model.closeFilePreview()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("关闭预览")
                .accessibilityLabel("关闭文件预览")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider().opacity(0.7)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                Group {
                    if let preparedPreviewURL {
                        SystemQuickLookPreview(fileURL: preparedPreviewURL)
                            .id(preparedPreviewURL.standardizedFileURL.path)
                    } else {
                        ProgressView("正在准备预览…")
                            .controlSize(.small)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "文件已不存在",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("它可能已经被移动、重命名或删除。")
                )
            }

            Divider().opacity(0.6)

            HStack(spacing: 7) {
                Image(systemName: "cursorarrow.click.2")
                Text("再次点击已高亮的文件即可打开")
                Spacer()
                Button("在访达中显示") {
                    model.reveal(url: fileURL)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .background(GuiliuTheme.canvas)
        .task(id: fileURL.standardizedFileURL.path) {
            preparedPreviewURL = nil
            do {
                // Avoid constructing every intermediate Quick Look view when
                // the user moves rapidly through a file list.
                try await Task.sleep(for: .milliseconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  FileManager.default.fileExists(atPath: fileURL.path) else { return }
            preparedPreviewURL = fileURL
        }
    }
}

private struct SystemQuickLookPreview: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            preconditionFailure("macOS 无法创建 Quick Look 预览视图")
        }
        // Media must never keep playing merely because it was selected in the
        // file browser. Explicitly opening the file remains the user's action.
        view.autostarts = false
        view.previewItem = fileURL as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        // Intentionally immutable. SwiftUI may call update after Quick Look has
        // internally deactivated the view during an identity change. Assigning
        // any non-nil item in that state triggers Quick Look's fatal assertion.
        // The surrounding `.id(fileURL.path)` creates a fresh NSView per file.
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        // QLPreviewView can otherwise retain a large PDF, Office render or
        // media decoder after the SwiftUI inspector has disappeared.
        nsView.autostarts = false
        nsView.previewItem = nil
    }
}
