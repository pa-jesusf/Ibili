import SwiftUI

struct SponsorBlockSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var clearing = false
    @State private var cleared = false
    var body: some View {
        Form {
            Section {
                Toggle("启用空降助手", isOn: $settings.sponsorBlockEnabled)
                Toggle("显示自动跳过提示", isOn: $settings.sponsorBlockNotifications)
                    .disabled(!settings.sponsorBlockEnabled)
            } footer: {
                Text("按需获取社区标记。启用后会向 BilibiliSponsorBlock 服务发送当前视频的 BV 号和分 P 标识，不发送登录凭据。")
            }
            Section("片段类型") {
                ForEach(SponsorCategory.allCases) { category in
                    Picker(category.label, selection: Binding(
                        get: { settings.sponsorConfiguration.policy(for: category) },
                        set: { settings.setSponsorPolicy($0, for: category) }
                    )) {
                        ForEach(SponsorSkipPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                }
            }
            Section {
                Button(cleared ? "片段缓存已清理" : "清理片段缓存") {
                    clearing = true
                    Task {
                        await SponsorBlockRepository.shared.clear()
                        clearing = false
                        cleared = true
                    }
                }
                .disabled(clearing)
            } footer: {
                Text("已随离线视频保存的标记会保留。社区标记可能存在误差，可在播放提示中撤销，或为当前视频停用。")
            }
            Section {
                Link("BilibiliSponsorBlock", destination: URL(string: "https://github.com/hanydd/BilibiliSponsorBlock")!)
            }
        }
        .navigationTitle("空降助手")
        .navigationBarTitleDisplayMode(.inline)
        .tint(IbiliTheme.accent)
    }
}

struct SponsorBlockPlayerSheet: View {
    @ObservedObject var coordinator: SponsorBlockPlaybackCoordinator
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("启用空降助手", isOn: $settings.sponsorBlockEnabled)
                    if let key = coordinator.key, key.isValid {
                        Toggle("本视频停用", isOn: Binding(
                            get: { settings.sponsorConfiguration.disabledVideos.contains(key.bvid) },
                            set: { settings.setSponsorDisabled($0, for: key.bvid) }
                        ))
                        .disabled(!settings.sponsorBlockEnabled)
                    }
                    NavigationLink("片段类型与设置") { SponsorBlockSettingsView() }
                }
                Section {
                    HStack {
                        Text(coordinator.syncState.label)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if coordinator.syncState == .loading { ProgressView() }
                    }
                    if let date = coordinator.fetchedAt {
                        LabeledContent("上次同步") {
                            Text(date, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if coordinator.syncState != .offline && coordinator.syncState != .offlineEmpty {
                        Button("刷新标记", systemImage: "arrow.clockwise") { coordinator.refresh() }
                            .disabled(coordinator.syncState == .loading || coordinator.syncState == .disabled || coordinator.syncState == .unavailable)
                    }
                }
                if !coordinator.segments.isEmpty {
                    Section("社区标记") {
                        ForEach(coordinator.segments) { segment in
                            HStack(spacing: 12) {
                                Button {
                                    coordinator.preview(segment)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(segment.category.label).foregroundStyle(.primary)
                                        Text(segment.timeLabel).monospacedDigit().foregroundStyle(.secondary)
                                        Text(settings.sponsorConfiguration.policy(for: segment.category).label)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button {
                                    coordinator.skip(segment)
                                    dismiss()
                                } label: {
                                    Image(systemName: "forward.end.fill")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("跳过\(segment.category.label)")
                            }
                            .disabled(!settings.sponsorConfiguration.isEnabled(for: coordinator.key?.bvid ?? ""))
                        }
                    }
                }
            }
            .navigationTitle("空降助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .tint(IbiliTheme.accent)
        }
    }
}
