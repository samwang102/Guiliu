import GuiliuCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedPane: SettingsPane = .sources

    var body: some View {
        GuiliuBackToTopScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader

                if selectedPane == .sources {
                    SettingsSection(title: "监控来源", subtitle: "归流只留意你指定的位置") {
                    PathSettingRow(
                        title: "下载文件夹",
                        subtitle: "Safari、微信、QQ、飞书等显式保存的文件",
                        path: model.downloadURL.path,
                        symbol: "arrow.down.circle.fill",
                        tint: .blue,
                        buttonTitle: "更改…",
                        action: model.changeMonitorFolder
                    )

                    SettingsDivider()

                    PathSettingRow(
                        title: "桌面",
                        subtitle: "自动发现新截图和其他新文件；启动时只建立现有文件基线",
                        path: model.desktopURL.path,
                        symbol: "desktopcomputer",
                        tint: .indigo,
                        buttonTitle: "打开",
                        action: model.openDesktop
                    )

                    SettingsDivider()

                    AppSourceRow(
                        name: "微信接收文件",
                        symbol: "message.fill",
                        tint: .green,
                        status: model.weChatStatus,
                        path: model.weChatFileURLs.first?.path,
                        isEnabled: Binding(
                            get: { model.monitorWeChatReceivedFiles },
                            set: { enabled in model.setWeChatMonitoring(enabled) }
                        ),
                        canShow: model.weChatFileURLs.first != nil,
                        showAction: {
                            if let url = model.weChatFileURLs.first { model.reveal(url: url) }
                        }
                    )

                    SettingsDivider()

                    DedicatedFolderRow(
                        name: "QQ",
                        symbol: "bubble.left.and.bubble.right.fill",
                        tint: .cyan,
                        status: model.qqStatus,
                        path: model.qqFolderURL?.path,
                        chooseAction: { model.chooseAppFolder(for: .qq) },
                        canReset: model.qqFolderURL != nil,
                        resetAction: { model.useDownloadFolder(for: .qq) }
                    )

                    SettingsDivider()

                    DedicatedFolderRow(
                        name: "飞书",
                        symbol: "paperplane.fill",
                        tint: .blue,
                        status: model.feishuStatus,
                        path: model.feishuFolderURL?.path,
                        chooseAction: { model.chooseAppFolder(for: .feishu) },
                        canReset: model.feishuFolderURL != nil,
                        resetAction: { model.useDownloadFolder(for: .feishu) }
                    )

                    SettingsDivider()

                    SettingsRowShell(
                        symbol: "lock.shield.fill",
                        tint: .orange,
                        title: "持续监控权限",
                        subtitle: "微信内部目录需要完全磁盘访问权限，才能在每次启动后持续监控且不重复询问"
                    ) {
                        Button("打开系统设置") {
                            model.openFullDiskAccessSettings()
                        }
                    }
                }

                    SettingsSection(title: "文件库", subtitle: "实体文件的最终存放位置") {
                        PathSettingRow(
                            title: "归流文件库",
                            subtitle: "十一个固定分类都保存在这个目录中；这里更改的是文件库根目录",
                            path: model.libraryURL.path,
                            symbol: "externaldrive.fill",
                            tint: GuiliuTheme.brand,
                            buttonTitle: "更改…",
                            action: model.changeLibraryFolder
                        )
                    }
                }

                if selectedPane == .intelligence {
                    SettingsSection(title: "本地 AI（Ollama）", subtitle: "智能分类、自动标签与论文概括均在这台 Mac 上完成") {
                    SettingsRowShell(
                        symbol: "brain.head.profile.fill",
                        tint: .purple,
                        title: "Ollama 智能分析",
                        subtitle: model.ollamaStatus
                    ) {
                        Toggle(
                            "启用本地 AI",
                            isOn: Binding(
                                get: { model.ollamaEnabled },
                                set: { model.setOllamaEnabled($0) }
                            )
                        )
                        .labelsHidden()
                    }

                    SettingsDivider()

                    SettingsRowShell(
                        symbol: "cpu.fill",
                        tint: .indigo,
                        title: model.ollamaModel,
                        subtitle: "API：\(model.ollamaEndpoint) · 不使用云端回退"
                    ) {
                        HStack(spacing: 8) {
                            Button("测试连接") {
                                model.checkOllamaConnection()
                            }
                            Button("分析待归类文件") {
                                model.analyzeAllPendingWithOllama()
                                model.navigate(to: .inbox)
                            }
                            .disabled(!model.ollamaEnabled || model.pendingItems.isEmpty || model.isAIAnalysisBusy)
                        }
                    }
                }

                    SettingsSection(title: "运行与索引", subtitle: "自动化始终由你掌控") {
                        SettingsRowShell(
                            symbol: model.isMonitoring ? "dot.radiowaves.left.and.right" : "pause.fill",
                            tint: model.isMonitoring ? GuiliuTheme.success : .secondary,
                            title: "文件监控",
                            subtitle: model.isMonitoring ? "运行中，新文件稳定写入后会进入待归类" : "已暂停，不会发现新文件"
                        ) {
                            Button(model.isMonitoring ? "暂停" : "启动") {
                                model.toggleMonitoring()
                            }
                        }

                        SettingsDivider()

                        SettingsRowShell(
                            symbol: "arrow.clockwise",
                            tint: .blue,
                            title: "扫描既有文件",
                            subtitle: "从所有已启用来源补充尚未处理的文件"
                        ) {
                            Button(model.isImportingExistingFiles ? "正在扫描…" : "立即扫描") {
                                model.importExistingFiles()
                                model.navigate(to: .inbox)
                            }
                            .disabled(model.isImportingExistingFiles)
                        }

                        SettingsDivider()

                        SettingsRowShell(
                            symbol: model.isResourceConstrained ? "memorychip.fill" : "sparkles",
                            tint: model.isResourceConstrained ? .orange : .purple,
                            title: "分层检索与资源保护",
                            subtitle: model.isResourceConstrained
                                ? "系统资源紧张：已暂停全文准备与 AI，文件浏览和归档保持优先"
                                : "文件名即时可搜；正文按需在后台补齐，内存紧张时自动降载"
                        ) {
                            GuiliuStatusPill(
                                title: model.isResourceConstrained ? "保护中" : "本地处理",
                                symbol: model.isResourceConstrained ? "shield.lefthalf.filled" : "lock.fill",
                                tint: model.isResourceConstrained ? .orange : GuiliuTheme.success
                            )
                        }
                    }
                }

                if selectedPane == .rules {
                    SettingsSection(title: "记住的分类习惯", subtitle: "按扩展名自动选中常用分类") {
                    if model.rules.isEmpty {
                        HStack(spacing: 12) {
                            GuiliuIconTile(symbol: "wand.and.stars", tint: .purple, size: 38)
                            Text("还没有规则。归类时勾选“以后默认归入这里”即可添加。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(Array(model.rules.enumerated()), id: \.element.extensionName) { index, rule in
                            HStack(spacing: 12) {
                                Text(".\(rule.extensionName)")
                                    .font(.body.monospaced().weight(.medium))
                                    .frame(minWidth: 54, alignment: .leading)
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Label(rule.category.displayName, systemImage: rule.category.symbolName)
                                    .foregroundStyle(rule.category.tint)
                                Spacer()
                                Button("移除") {
                                    model.clearRule(for: rule.extensionName)
                                }
                                .buttonStyle(.borderless)
                            }
                            if index < model.rules.count - 1 { SettingsDivider() }
                        }
                    }
                }

                    Label {
                        Text("微信内部来源会持续监控接收文件目录，归档时创建小型引用，不复制原件；微信清理原文件后引用也会失效。在归流中将已归档引用移到废纸篓时，经过身份验证的 App 原件会一并移入并可一起恢复。macOS 的普通 App 数据授权只在本次运行有效；若要避免每次启动询问，需要在系统设置中给归流一次完全磁盘访问权限。不会读取聊天数据库、头像、缩略图或缓存。")
                    } icon: {
                        Image(systemName: "hand.raised.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                }
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("设置")
    }

    private var settingsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                headerIdentity
                Spacer(minLength: 18)
                panePicker
            }
            VStack(alignment: .leading, spacing: 14) {
                headerIdentity
                panePicker
            }
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 2)
    }

    private var headerIdentity: some View {
        HStack(spacing: 12) {
                GuiliuIconTile(symbol: "slider.horizontal.3", tint: GuiliuTheme.brand, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("按你的方式整理")
                        .font(.title3.weight(.bold))
                    Text("来源、文件库和索引都在本机运行，随时可以暂停或更改。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var panePicker: some View {
        Picker("设置分区", selection: $selectedPane) {
            ForEach(SettingsPane.allCases) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 360)
        .accessibilityLabel("设置分区")
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case sources
    case intelligence
    case rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: "来源与文件库"
        case .intelligence: "AI 与自动化"
        case .rules: "规则与隐私"
        }
    }

    var symbol: String {
        switch self {
        case .sources: "folder.badge.gearshape"
        case .intelligence: "sparkles"
        case .rules: "checkmark.shield"
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 3)

            GuiliuListSurface {
                VStack(spacing: 14) {
                    content
                }
                .padding(15)
            }
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 50)
    }
}

private struct SettingsRowShell<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var path: String?
    @ViewBuilder let actions: Actions

    init(
        symbol: String,
        tint: Color,
        title: String,
        subtitle: String,
        path: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            GuiliuIconTile(symbol: symbol, tint: tint, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let path {
                    GuiliuPathLabel(path: path)
                }
            }
            Spacer(minLength: 12)
            actions
        }
    }
}

private struct AppSourceRow: View {
    let name: String
    let symbol: String
    let tint: Color
    let status: String
    let path: String?
    @Binding var isEnabled: Bool
    let canShow: Bool
    let showAction: () -> Void

    var body: some View {
        SettingsRowShell(symbol: symbol, tint: tint, title: name, subtitle: status, path: path) {
            HStack(spacing: 9) {
                if canShow {
                    Button("显示", action: showAction)
                        .buttonStyle(.borderless)
                }
                Toggle("监控 \(name)", isOn: $isEnabled)
                    .labelsHidden()
            }
        }
    }
}

private struct DedicatedFolderRow: View {
    let name: String
    let symbol: String
    let tint: Color
    let status: String
    let path: String?
    let chooseAction: () -> Void
    let canReset: Bool
    let resetAction: () -> Void

    var body: some View {
        SettingsRowShell(symbol: symbol, tint: tint, title: name, subtitle: status, path: path) {
            HStack(spacing: 8) {
                if canReset {
                    Button("使用下载", action: resetAction)
                        .buttonStyle(.borderless)
                }
                Button(path == nil ? "选择目录…" : "更改…", action: chooseAction)
            }
        }
    }
}

private struct PathSettingRow: View {
    let title: String
    let subtitle: String
    let path: String
    let symbol: String
    let tint: Color
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        SettingsRowShell(symbol: symbol, tint: tint, title: title, subtitle: subtitle, path: path) {
            Button(buttonTitle, action: action)
        }
    }
}
