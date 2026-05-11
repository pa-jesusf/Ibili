import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var cacheVM = ImageCacheViewModel()
    @StateObject private var cdnSpeedVM = CDNSpeedTestViewModel()
    @State private var showsCDNSpeedSheet = false

    private let columnOptions: [(label: String, value: Int)] = [
        ("自动", 0), ("1 列", 1), ("2 列", 2), ("3 列", 3), ("4 列", 4),
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
    /// 1...9 mapping to UIFont.Weight slots, mirrors
    /// `AppSettings.resolvedDanmakuFontWeight()`. Only the
    /// commonly-useful weights are surfaced — the user does not need
    /// access to ultraLight or thin for danmaku.
    private let danmakuFontWeightOptions: [(label: String, value: Int)] = [
        ("常规", 4),
        ("中等", 5),
        ("半粗", 6),
        ("加粗", 7),
        ("特粗", 8),
        ("最粗", 9),
    ]

    private var strokeWidthLabel: String {
        let v = settings.resolvedDanmakuStrokeWidth()
        return v == 0 ? "关闭" : String(format: "%.1f", v)
    }

    private var audioGainLabel: String {
        let v = settings.resolvedAudioGainDb()
        return v == 0 ? "0 dB（不衰减）" : String(format: "%+.0f dB", v)
    }

    var body: some View {
        Form {
            Section {
                Picker("首页列数", selection: Binding(
                    get: { min(max(settings.columnsRaw, 0), 4) },
                    set: { settings.columnsRaw = min(max($0, 0), 4) }
                )) {
                    ForEach(columnOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
            } footer: {
                Text("自动模式：iPhone 竖屏 2 列，iPad 分栏时自动减少列数，完整宽屏最多 4 列。")
            }

            Section {
                Picker("推荐来源", selection: Binding(
                    get: { settings.homeRecommendSource },
                    set: { settings.homeRecommendSource = $0 }
                )) {
                    ForEach(HomeRecommendSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
            } header: {
                Text("首页推荐")
            } footer: {
                Text(settings.homeRecommendSource.detail)
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
                    VStack(alignment: .leading) {
                        HStack {
                            Text("弹幕黑色描边")
                            Spacer()
                            Text(strokeWidthLabel)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { settings.resolvedDanmakuStrokeWidth() },
                                set: { settings.danmakuStrokeWidth = $0 }
                            ),
                            in: 0...6,
                            step: 0.5
                        )
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("弹幕字号")
                            Spacer()
                            Text(String(format: "×%.2f", settings.resolvedDanmakuFontScale()))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { settings.resolvedDanmakuFontScale() },
                                set: { settings.danmakuFontScale = $0 }
                            ),
                            in: 0.6...1.6,
                            step: 0.05
                        )
                    }
                    Picker("弹幕字重", selection: Binding(
                        get: { settings.resolvedDanmakuFontWeight() },
                        set: { settings.danmakuFontWeight = $0 }
                    )) {
                        ForEach(danmakuFontWeightOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                }
                Toggle("快速加载", isOn: $settings.fastLoad)
                Toggle("B站定向流量支持", isOn: .constant(true))
                    .disabled(true)
                Picker("CDN", selection: Binding(
                    get: { settings.cdnService },
                    set: {
                        settings.cdnService = $0
                        PlayUrlPrefetcher.shared.clear()
                    }
                )) {
                    ForEach(MediaCDNService.allCases) { service in
                        Text(service.label).tag(service)
                    }
                }
                Button {
                    showsCDNSpeedSheet = true
                } label: {
                    HStack {
                        Text("CDN 测速")
                            .foregroundStyle(IbiliTheme.textPrimary)
                        Spacer()
                        Text(cdnSpeedVM.summaryText)
                            .font(.footnote)
                            .foregroundStyle(IbiliTheme.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading) {
                    HStack {
                        Text("音量增益")
                        Spacer()
                        Text(audioGainLabel)
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.resolvedAudioGainDb() },
                            set: { settings.audioGainDb = $0 }
                        ),
                        in: -20...0,
                        step: 1
                    )
                }
            } header: {
                Text("播放")
            } footer: {
                Text("CDN 自动模式会保留 B 站返回的候选地址，并由播放器启动时的 Range 竞速选择最快可用源；手动 CDN 会优先改写到指定镜像。音频和直播跟随同一个 CDN 选择。")
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

            cardMetaSection(
                title: "首页卡片显示",
                showPlay: $settings.homeShowPlay,
                showDuration: $settings.homeShowDuration,
                showPubdate: .constant(false), 
                showAuthor: $settings.homeShowAuthor,
                stat: .constant(.none) 
            )

            cardMetaSection(
                title: "搜索结果卡片显示",
                showPlay: $settings.searchShowPlay,
                showDuration: $settings.searchShowDuration,
                showPubdate: $settings.searchShowPubdate,
                showAuthor: $settings.searchShowAuthor,
                stat: Binding(
                    get: { settings.searchCardStat },
                    set: { settings.searchCardStat = $0 }
                )
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
                Text("封面图磁盘缓存。超出上限会按最久未使用淘汰。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheVM.refresh() }
        .sheet(isPresented: $showsCDNSpeedSheet) {
            NavigationStack {
                CDNSpeedTestSheet(
                    vm: cdnSpeedVM,
                    currentService: settings.cdnService
                ) { service in
                    settings.cdnService = service
                    PlayUrlPrefetcher.shared.clear()
                }
            }
        }
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
    footer: String? = nil
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
        if let footer {
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

private struct CDNSpeedTestSheet: View {
    @ObservedObject var vm: CDNSpeedTestViewModel
    let currentService: MediaCDNService
    var onPick: (MediaCDNService) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if let sample = vm.sampleTitle {
                    HStack {
                        Text("样本")
                        Spacer()
                        Text(sample)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let errorText = vm.errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("测速会临时拉取一个热门视频的播放地址，并对每个 CDN 的候选地址做小范围请求；自动模式仍会在播放时竞速。")
            }

            Section("节点") {
                Button {
                    onPick(.auto)
                } label: {
                    resultRow(for: .auto)
                }
                .buttonStyle(.plain)

                ForEach(vm.testServices) { service in
                    Button {
                        onPick(service)
                    } label: {
                        resultRow(for: service)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("CDN 测速")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    vm.start()
                } label: {
                    if vm.isTesting {
                        ProgressView()
                    } else {
                        Label("开始", systemImage: "speedometer")
                    }
                }
                .disabled(vm.isTesting)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func resultRow(for service: MediaCDNService) -> some View {
        HStack(spacing: 10) {
            Image(systemName: service == currentService ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(service == currentService ? IbiliTheme.accent : IbiliTheme.textSecondary)
            Text(service.label)
                .foregroundStyle(IbiliTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(vm.displayText(for: service))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(vm.resultColor(for: service))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

@MainActor
final class CDNSpeedTestViewModel: ObservableObject {
    @Published var isTesting = false
    @Published var sampleTitle: String?
    @Published var errorText: String?
    @Published private(set) var results: [MediaCDNService: CDNSpeedResult] = [:]

    private var task: Task<Void, Never>?
    let testServices = MediaCDNService.allCases.filter { $0 != .auto }

    var summaryText: String {
        guard let best = bestService else { return "未测速" }
        return "\(best.label) \(displayText(for: best))"
    }

    private var bestService: MediaCDNService? {
        results.compactMap { service, result -> (MediaCDNService, Double)? in
            if case .success(let mbps, _) = result { return (service, mbps) }
            return nil
        }
        .max { $0.1 < $1.1 }?
        .0
    }

    func start() {
        guard !isTesting else { return }
        task?.cancel()
        results = Dictionary(uniqueKeysWithValues: testServices.map {
            ($0, CDNSpeedResult.pending)
        })
        sampleTitle = "正在选择样本..."
        errorText = nil
        isTesting = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let sample = try await CDNSpeedTester.resolveSample()
                await MainActor.run {
                    self.sampleTitle = sample.title
                }
                for service in self.testServices {
                    if Task.isCancelled { break }
                    let result = await CDNSpeedTester.measure(service: service, sample: sample)
                    await MainActor.run {
                        self.results[service] = result
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorText = CDNSpeedTester.shortError(error)
                    self.sampleTitle = nil
                    for service in self.testServices {
                        self.results[service] = .failure("样本失败")
                    }
                }
            }
            await MainActor.run {
                self.isTesting = false
            }
        }
    }

    func displayText(for service: MediaCDNService) -> String {
        switch results[service] {
        case nil:
            return service == .auto ? "播放时竞速" : "未测速"
        case .pending:
            return "测速中"
        case .success(let mbps, let ms):
            return String(format: "%.2f MB/s · %d ms", mbps, ms)
        case .failure(let message):
            return message
        }
    }

    func resultColor(for service: MediaCDNService) -> Color {
        switch results[service] {
        case .success:
            return IbiliTheme.accent
        case .failure:
            return .red
        case .pending:
            return IbiliTheme.textSecondary
        case nil:
            return service == .auto ? IbiliTheme.accent : IbiliTheme.textSecondary
        }
    }
}

enum CDNSpeedResult {
    case pending
    case success(mbPerSecond: Double, elapsedMs: Int)
    case failure(String)
}

private enum CDNSpeedTester {
    private static let sampleQn: Int64 = 80
    private static let probeRange: ClosedRange<UInt64> = 0...(262_143)

    struct Sample: Sendable {
        let aid: Int64
        let cid: Int64
        let title: String
    }

    static func resolveSample() async throws -> Sample {
        let page = try await Task.detached(priority: .utility) {
            try CoreClient.shared.feedPopular(pn: 1, ps: 12)
        }.value
        var lastError: Error?
        for item in page.items where item.aid > 0 {
            let aid = item.aid
            let title = item.title
            do {
                let cid = try await resolveCid(for: item)
                _ = try await Task.detached(priority: .utility) {
                    try CoreClient.shared.playUrl(
                        aid: aid,
                        cid: cid,
                        qn: sampleQn,
                        cdn: MediaCDNService.auto.rawValue
                    )
                }.value
                let sampleTitle = title.isEmpty ? "av\(aid)" : title
                return Sample(aid: aid, cid: cid, title: sampleTitle)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? CDNSpeedTestError.noPlayableSample
    }

    static func measure(service: MediaCDNService, sample: Sample) async -> CDNSpeedResult {
        do {
            let play = try await Task.detached(priority: .utility) {
                try CoreClient.shared.playUrl(
                    aid: sample.aid,
                    cid: sample.cid,
                    qn: sampleQn,
                    cdn: service.rawValue
                )
            }.value
            let urls = ([play.url] + play.backupUrls).compactMap(URL.init(string:))
            guard !urls.isEmpty else { return .failure("无地址") }
            let start = CFAbsoluteTimeGetCurrent()
            let race = try await ProxyURLLoader.shared.raceProbe(urls: urls, range: probeRange)
            let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            let mb = Double(race.data.count) / 1_048_576.0
            let seconds = max(0.001, Double(elapsedMs) / 1000.0)
            return .success(mbPerSecond: mb / seconds, elapsedMs: elapsedMs)
        } catch {
            return .failure(Self.shortError(error))
        }
    }

    private static func resolveCid(for item: FeedItemDTO) async throws -> Int64 {
        if item.cid > 0 { return item.cid }
        let bvid = item.bvid
        let aid = item.aid
        if !bvid.isEmpty {
            return try await Task.detached(priority: .utility) {
                try CoreClient.shared.videoViewCid(bvid: bvid)
            }.value
        }
        let view = try await Task.detached(priority: .utility) {
            try CoreClient.shared.videoViewFull(aid: aid)
        }.value
        if view.cid > 0 { return view.cid }
        if let cid = view.pages.first?.cid, cid > 0 { return cid }
        throw CDNSpeedTestError.noPlayableSample
    }

    static func shortError(_ error: Error) -> String {
        if let known = error as? CDNSpeedTestError {
            return known.localizedDescription
        }
        let text = (error as NSError).localizedDescription
        let cleaned = text
            .replacingOccurrences(of: "[internal] ", with: "")
            .replacingOccurrences(of: "web playurl failed: ", with: "")
            .replacingOccurrences(of: "; tv playurl failed:", with: " / TV:")
        if cleaned.count <= 20 { return cleaned }
        return String(cleaned.prefix(20))
    }
}

private enum CDNSpeedTestError: LocalizedError {
    case noPlayableSample

    var errorDescription: String? {
        switch self {
        case .noPlayableSample:
            return "未找到可用测速样本"
        }
    }
}
}
