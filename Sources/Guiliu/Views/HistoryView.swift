import GuiliuCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.history.isEmpty && model.trashHistory.isEmpty {
                GuiliuEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: "还没有操作记录",
                    message: "归档、移到废纸篓和恢复操作都会清晰记录在这里。",
                    tint: .purple
                ) { }
            } else {
                GuiliuBackToTopScrollView {
                    LazyVStack(spacing: 0) {
                        historyHeader
                            .padding(.bottom, 16)

                        if !model.history.isEmpty {
                            GuiliuSectionTitle(title: "归档记录", detail: "\(model.history.count) 项")
                                .padding(.horizontal, 3)
                                .padding(.bottom, 8)
                            ForEach(model.history) { record in
                                HistoryRow(
                                    record: record,
                                    isFirst: record.id == model.history.first?.id,
                                    isLast: record.id == model.history.last?.id
                                )
                            }
                        }

                        if !model.trashHistory.isEmpty {
                            GuiliuSectionTitle(title: "废纸篓记录", detail: "\(model.trashHistory.count) 项")
                                .padding(.horizontal, 3)
                                .padding(.top, model.history.isEmpty ? 0 : 20)
                                .padding(.bottom, 8)
                            ForEach(model.trashHistory) { record in
                                TrashHistoryRow(
                                    record: record,
                                    isFirst: record.id == model.trashHistory.first?.id,
                                    isLast: record.id == model.trashHistory.last?.id
                                )
                            }
                        }
                    }
                    .frame(maxWidth: 920)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("操作记录")
    }

    private var historyHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { headerCopy; Spacer(); metrics }
            VStack(alignment: .leading, spacing: 14) { headerCopy; metrics }
        }
        .padding(.horizontal, 3)
    }

    private var headerCopy: some View {
        HStack(spacing: 14) {
            GuiliuIconTile(symbol: "clock.arrow.circlepath", tint: .purple, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text("每一步都有迹可循")
                    .font(.title3.weight(.bold))
                Text("移动操作可以撤销；废纸篓文件会在身份核验后安全恢复。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 18) {
            HistoryMetric(value: model.history.filter { !$0.isRestored }.count, label: "现有归档", tint: GuiliuTheme.brand)
            Divider().frame(height: 34)
            HistoryMetric(value: model.trashHistory.filter { !$0.isRestored }.count, label: "废纸篓", tint: .red)
        }
    }
}

private struct HistoryMetric: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(value)")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TrashHistoryRow: View {
    @Environment(AppModel.self) private var model
    let record: TrashRecord
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        historyShell(
            tint: record.isRestored ? .secondary : .red,
            isFirst: isFirst,
            isLast: isLast
        ) {
            Image(systemName: record.isRestored ? "arrow.uturn.backward.circle.fill" : "trash.fill")
                .font(.system(size: 18, weight: .semibold))
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: record.originalPath).lastPathComponent)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Label(
                    record.isRestored ? "已从废纸篓恢复" : "已移到废纸篓",
                    systemImage: record.isRestored ? "checkmark" : "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(GuiliuRelativeTime.text(for: record.trashedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } trailing: {
            if !record.isRestored {
                if record.contentHash == nil {
                    Label("需手动核实", systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("这条记录没有内容身份摘要，归流不会冒险自动恢复")
                } else if model.processingHistoryIDs.contains(record.id) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在恢复")
                } else {
                    Button("恢复") {
                        model.restoreDeleted(record)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("恢复 \(URL(fileURLWithPath: record.originalPath).lastPathComponent)")
                }
            }
        }
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let record: RoutingRecord
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        historyShell(
            tint: record.isRestored ? .secondary : record.category.tint,
            isFirst: isFirst,
            isLast: isLast
        ) {
            Image(systemName: record.isRestored ? "arrow.uturn.backward.circle.fill" : record.category.symbolName)
                .font(.system(size: 18, weight: .semibold))
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: record.destinationPath).lastPathComponent)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.isRestored ? "已撤销" : "\(record.effectiveOperation.actionName)至 \(record.category.displayName)")
                    if record.effectiveOrigin != .unknown {
                        Text("·")
                        Text(record.effectiveOrigin.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(GuiliuRelativeTime.text(for: record.routedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } trailing: {
            HStack(spacing: 8) {
                Button("显示") {
                    model.reveal(url: URL(fileURLWithPath: record.destinationPath))
                }
                .buttonStyle(.borderless)

                if !record.isRestored {
                    if model.processingHistoryIDs.contains(record.id) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在撤销")
                    } else {
                        Button("撤销") {
                            model.undo(record)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

private func historyShell<Icon: View, Content: View, Trailing: View>(
    tint: Color,
    isFirst: Bool,
    isLast: Bool,
    @ViewBuilder icon: () -> Icon,
    @ViewBuilder content: () -> Content,
    @ViewBuilder trailing: () -> Trailing
) -> some View {
    HStack(spacing: 13) {
        icon()
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
        content()
        Spacer(minLength: 10)
        trailing()
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 10)
    .background(GuiliuTheme.surface)
    .overlay(alignment: .bottom) {
        if !isLast { GuiliuListDivider(leading: 65) }
    }
    .clipShape(
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? 14 : 0,
            bottomLeadingRadius: isLast ? 14 : 0,
            bottomTrailingRadius: isLast ? 14 : 0,
            topTrailingRadius: isFirst ? 14 : 0,
            style: .continuous
        )
    )
}
