import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var cacheVM = ImageCacheViewModel()

    private let columnOptions: [(label: String, value: Int)] = [
        ("自动", 0), ("1 列", 1), ("2 列", 2), ("3 列", 3),
    ]
    private let qualityOptions: [(label: String, value: Int)] = [
        ("自动（按显示像素）", 0),
        ("流畅 60", 60),
        ("标准 75", 75),
        ("高清 90", 90),
        ("原图 100", 100),
    ]
    private let preferredVideoQualityOptions: [(label: String, value: Int)] = [
        ("默认最高", 0),
        ("8K", 127),
        ("杜比", 126),
        ("HDR", 125),
        ("4K", 120),
        ("1080P60", 116),
        ("1080P+", 112),
        ("1080P", 80),
        ("720P60", 74),
        ("720P", 64),
        ("480P", 32),
        ("360P", 16),
    ]

    private let preferredAudioQualityOptions: [(label: String, value: Int)] = [
        ("Hi-Res无损", 30251),
        ("杜比全景声", 30250),
        ("192K", 30280),
        ("132K", 30232),
        ("64K", 30216),
    ]
    private let danmakuFrameRateOptions: [(label: String, value: Int)] = [
        ("30 帧", 30),
        ("60 帧", 60),
    ]

    var body: some View {
        Form {
            Section {
                Picker("首页列数", selection: Binding(
                    get: { min(max(settings.columnsRaw, 0), 3) },
                    set: { settings.columnsRaw = min(max($0, 0), 3) }
                )) {
                    ForEach(columnOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
            } footer: {
                Text("自动模式：iPhone 竖屏 2 列，较宽布局最多 3 列。")
            }

            Section {
                Picker("封面清晰度", selection: $settings.imageQualityRaw) {
                    ForEach(qualityOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
            } footer: {
                Text("自动模式按列数与屏幕像素密度选择最优分辨率，仅下载所需像素，节省流量。")
            }

            Section {
                Picker("默认清晰度", selection: Binding(
                    get: { settings.resolvedPreferredVideoQn() },
                    set: { settings.preferredQn = $0 }
                )) {
                    ForEach(preferredVideoQualityOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                Picker("默认音质", selection: $settings.preferredAudioQn) {
                    ForEach(preferredAudioQualityOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                Toggle("显示弹幕", isOn: $settings.danmakuEnabled)
                Toggle("启用弹幕时显示发送提示", isOn: $settings.showDanmakuSendHint)
                if settings.danmakuEnabled {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("弹幕透明度")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.danmakuOpacity * 100))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.danmakuOpacity, in: 0.1...1.0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("弹幕屏蔽等级")
                            Spacer()
                            Text("\(settings.resolvedDanmakuBlockLevel()) 级")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.resolvedDanmakuBlockLevel()) },
                                set: { settings.danmakuBlockLevel = Int($0.rounded()) }
                            ),
                            in: 0...11,
                            step: 1
                        )
                    }
                    Picker("弹幕帧率", selection: Binding(
                        get: { settings.resolvedDanmakuFrameRate() },
                        set: { settings.danmakuFrameRate = $0 }
                    )) {
                        ForEach(danmakuFrameRateOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                }
                Toggle("手机横屏自动进入/退出全屏", isOn: $settings.autoRotateFullscreen)
                Toggle("快速加载", isOn: $settings.fastLoad)
            } header: {
                Text("播放")
            } footer: {
                Text("快速加载会同时加载最低画质与首选画质，高画质加载好后自动切换。失败诊断会自动导出 startup window 样本并生成 packaging-workspace。")
            }

            Section {
                NavigationLink {
                    DiagnosticsBrowserView()
                } label: {
                    Label("播放失败诊断", systemImage: "waveform.and.magnifyingglass")
                }
            } footer: {
                Text("浏览自动导出的 diagnostics 目录，并直接用本地文件 URL 播放 packaging-workspace/master.m3u8 做真机 smoke test。")
            }

            Section {
                Picker("视频编号显示", selection: Binding(
                    get: { settings.videoIdDisplay },
                    set: { settings.videoIdDisplay = $0 }
                )) {
                    ForEach(VideoIdDisplay.allCases) { v in
                        Text(v.label).tag(v)
                    }
                }
            } header: {
                Text("视频详情页")
            } footer: {
                Text("控制视频详情页右下角显示 BV 号或旧版 av 号。")
            }

            Section {
                Toggle("播放数", isOn: $settings.homeShowPlay)
                Toggle("时长", isOn: $settings.homeShowDuration)
                Toggle("UP 主", isOn: $settings.homeShowAuthor)
            } header: {
                Text("首页卡片显示")
            } footer: {
                Text("首页推荐流仅下发有限信息，为保持视觉一致不提供投稿时间与数据角标选项。")
            }

            cardMetaSection(
                title: "搜索结果卡片显示",
                showPlay: $settings.searchShowPlay,
                showDuration: $settings.searchShowDuration,
                showPubdate: $settings.searchShowPubdate,
                showAuthor: $settings.searchShowAuthor,
                stat: Binding(
                    get: { settings.searchCardStat },
                    set: { settings.searchCardStat = $0 }
                ),
                footer: "调整搜索结果卡片显示的各项信息。"
            )

            Section {
                HStack {
                    Text("当前占用")
                    Spacer()
                    Text(cacheVM.usageText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Picker("缓存上限", selection: Binding(
                    get: { settings.imageCacheMaxMB },
                    set: { settings.imageCacheMaxMB = $0 }
                )) {
                    ForEach(cacheLimitOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                Button(role: .destructive) {
                    cacheVM.clear()
                } label: {
                    HStack {
                        Text("清除图片缓存")
                        Spacer()
                        if cacheVM.isClearing {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(cacheVM.isClearing)
            } header: {
                Text("缓存")
            } footer: {
                Text("封面图磁盘缓存。命中后无需再次请求 CDN，适配上游 cached_network_image 的体验；超出上限会按最久未使用淘汰。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheVM.refresh() }
    }

    private let cacheLimitOptions: [(label: String, value: Int)] = [
        ("64 MB", 64),
        ("128 MB", 128),
        ("256 MB", 256),
        ("512 MB", 512),
        ("1 GB", 1024),
        ("2 GB", 2048),
    ]

    /// One reusable settings section per card screen — keeps Home and
    /// Search visually identical in 设置 while still letting users tune
    /// each independently.
    @ViewBuilder
    private func cardMetaSection(
        title: String,
        showPlay: Binding<Bool>,
        showDuration: Binding<Bool>,
        showPubdate: Binding<Bool>,
        showAuthor: Binding<Bool>,
        stat: Binding<FeedCardStat>,
        footer: String
    ) -> some View {
        Section {
            Toggle("播放数", isOn: showPlay)
            Toggle("时长", isOn: showDuration)
            Toggle("投稿时间", isOn: showPubdate)
            Toggle("UP 主", isOn: showAuthor)
            Picker("数据角标", selection: stat) {
                ForEach(FeedCardStat.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}

/// Backs the 设置 → 缓存 section. Lives next to the view because
/// it's intentionally tiny — the cache itself does the heavy
/// lifting; we just pull the current footprint and surface a
/// "clear" affordance.
@MainActor
final class ImageCacheViewModel: ObservableObject {
    @Published var usageText: String = "—"
    @Published var isClearing: Bool = false

    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    func refresh() {
        Task {
            let bytes = await Task.detached(priority: .utility) {
                ImageDiskCache.shared.currentBytes()
            }.value
            usageText = formatter.string(fromByteCount: bytes)
        }
    }

    func clear() {
        isClearing = true
        ImageDiskCache.shared.clearAll { [weak self] in
            self?.isClearing = false
            self?.refresh()
        }
    }
}
