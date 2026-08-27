import SwiftUI

struct RenameFileButton: View {
    let fileURL: URL
    var isEnabled = true
    var unavailableHelp: String?
    let rename: (String) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "pencil")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help(isEnabled ? "重命名" : (unavailableHelp ?? "当前文件不能重命名"))
        .accessibilityLabel("重命名 \(fileURL.lastPathComponent)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            RenameFilePopover(fileURL: fileURL) { baseName in
                rename(baseName)
                isPresented = false
            }
        }
    }
}

private struct RenameFilePopover: View {
    let fileURL: URL
    let submit: (String) -> Void

    @State private var baseName: String
    @FocusState private var isFocused: Bool

    init(fileURL: URL, submit: @escaping (String) -> Void) {
        self.fileURL = fileURL
        self.submit = submit
        _baseName = State(initialValue: fileURL.deletingPathExtension().lastPathComponent)
    }

    private var normalizedName: String {
        baseName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !normalizedName.isEmpty
            && normalizedName != "."
            && normalizedName != ".."
            && !normalizedName.contains("/")
            && !normalizedName.contains(":")
            && !normalizedName.contains(where: { $0.isNewline })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("重命名文档")
                    .font(.headline.weight(.bold))
                Text("扩展名保持不变；同名时会自动添加数字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                TextField("文件名", text: $baseName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(commit)
                if !fileURL.pathExtension.isEmpty {
                    Text(".\(fileURL.pathExtension)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("当前位置：\(fileURL.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("完成", action: commit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 350)
        .onAppear { isFocused = true }
    }

    private func commit() {
        guard isValid else { return }
        submit(normalizedName)
    }
}
