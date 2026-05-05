import SwiftUI
import UIKit

private enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all
    case infoAndAbove
    case warningAndAbove
    case errorsOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .infoAndAbove: return "信息+"
        case .warningAndAbove: return "警告+"
        case .errorsOnly: return "错误"
        }
    }

    func includes(_ level: AppLogLevel) -> Bool {
        switch self {
        case .all: return true
        case .infoAndAbove: return level != .debug
        case .warningAndAbove: return level == .warning || level == .error
        case .errorsOnly: return level == .error
        }
    }
}

private enum LogGroupFilter: String, CaseIterable, Identifiable {
    case all
    case apiRequests
    case playerBehavior
    case authSession
    case content
    case interaction
    case other

    var id: String { rawValue }

    var title: String {
        group?.title ?? "全部分类"
    }

    var group: AppLogCategoryGroup? {
        switch self {
        case .all: return nil
        case .apiRequests: return .apiRequests
        case .playerBehavior: return .playerBehavior
        case .authSession: return .authSession
        case .content: return .content
        case .interaction: return .interaction
        case .other: return .other
        }
    }
}

private enum LogCategoryFilterKey {
    static let all = "__all__"
}

struct LogsView: View {
    @EnvironmentObject private var logStore: AppLogStore
    @State private var levelFilter: LogLevelFilter = .all
    @State private var groupFilter: LogGroupFilter = .all
    @State private var categoryFilterKey = LogCategoryFilterKey.all
    @State private var showCopiedAlert = false
    @State private var showClearConfirmation = false

    private var entriesMatchingLevelAndGroup: [AppLogEntry] {
        logStore.entries.filter { entry in
            levelFilter.includes(entry.level)
                && (groupFilter.group == nil || entry.categoryDescriptor.group == groupFilter.group)
        }
    }

    private var availableCategories: [AppLogCategoryDescriptor] {
        AppLogCategoryCatalog.descriptors(from: entriesMatchingLevelAndGroup,
                                          in: groupFilter.group)
    }

    private var filteredEntries: [AppLogEntry] {
        Array(entriesMatchingLevelAndGroup.filter { entry in
            categoryFilterKey == LogCategoryFilterKey.all
                || entry.categoryDescriptor.key == categoryFilterKey
        }.reversed())
    }

    private var activeFilterSummary: String {
        let groupTitle = groupFilter.title
        let categoryTitle = availableCategories.first(where: { $0.key == categoryFilterKey })?.title ?? "全部子类"
        return "级别：\(levelFilter.title)  分类：\(groupTitle)  子类：\(categoryTitle)"
    }

    var body: some View {
        List {
            Section {
                Text("遇到问题后，复制并发送日志给开发者可以帮助快速定位问题。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(activeFilterSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if filteredEntries.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("暂无日志")
                            .font(.headline)
                        Text("先进行一次登录、刷首页或播放视频，再回来复制日志。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(filteredEntries) { entry in
                        LogRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle("应用日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Section("级别") {
                        Picker("级别", selection: $levelFilter) {
                            ForEach(LogLevelFilter.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }

                    Section("分类") {
                        Picker("分类", selection: $groupFilter) {
                            ForEach(LogGroupFilter.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }

                    if !availableCategories.isEmpty {
                        Section("子类") {
                            Picker("子类", selection: $categoryFilterKey) {
                                Text("全部子类").tag(LogCategoryFilterKey.all)
                                ForEach(availableCategories) { option in
                                    Text(option.title).tag(option.key)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }

                Button {
                    UIPasteboard.general.string = filteredEntries
                        .reversed()
                        .map(\.formattedLine)
                        .joined(separator: "\n")
                    showCopiedAlert = true
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(filteredEntries.isEmpty)

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(logStore.entries.isEmpty)
            }
        }
        .onChange(of: levelFilter) { _ in
            resetCategoryFilterIfNeeded()
        }
        .onChange(of: groupFilter) { _ in
            categoryFilterKey = LogCategoryFilterKey.all
        }
        .onChange(of: logStore.entries) { _ in
            resetCategoryFilterIfNeeded()
        }
        .alert("日志已复制", isPresented: $showCopiedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("当前筛选结果已复制到剪贴板。")
        }
        .confirmationDialog("清空日志？",
                            isPresented: $showClearConfirmation,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                logStore.clear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除应用内已保存的所有日志。")
        }
    }

    private func resetCategoryFilterIfNeeded() {
        guard categoryFilterKey != LogCategoryFilterKey.all else { return }
        guard availableCategories.contains(where: { $0.key == categoryFilterKey }) else {
            categoryFilterKey = LogCategoryFilterKey.all
            return
        }
    }
}

private struct LogRow: View {
    let entry: AppLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LogLevelBadge(level: entry.level)
                LogCategoryGroupBadge(group: entry.categoryDescriptor.group)
                Text(entry.categoryDescriptor.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(entry.formattedLineTimestamp)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(entry.message)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            if !entry.sortedMetadata.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.sortedMetadata, id: \.0) { pair in
                        HStack(alignment: .top, spacing: 6) {
                            Text(pair.0)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(pair.1)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LogLevelBadge: View {
    let level: AppLogLevel

    var body: some View {
        Text(level.title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct LogCategoryGroupBadge: View {
    let group: AppLogCategoryGroup

    var body: some View {
        Text(group.title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch group {
        case .apiRequests: return .teal
        case .playerBehavior: return .purple
        case .authSession: return .green
        case .content: return .indigo
        case .interaction: return .pink
        case .other: return .gray
        }
    }
}

private extension AppLogEntry {
    var formattedLineTimestamp: String {
        Self.listFormatter.string(from: timestamp)
    }

    static let listFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}