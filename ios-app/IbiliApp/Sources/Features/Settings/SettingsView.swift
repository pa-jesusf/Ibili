import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    private let columnOptions: [(label: String, value: Int)] = [
        ("自动", 0), ("1 列", 1), ("2 列", 2), ("3 列", 3), ("4 列", 4), ("5 列", 5),
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
        ("360P", 16),
        ("480P", 32),
        ("720P", 64),
        ("1080P", 80),
        ("1080P+", 112),
        ("4K", 120),
    ]

    var body: some View {
        Form {
            Section {
                Picker("首页列数", selection: $settings.columnsRaw) {
                    ForEach(columnOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
            } footer: {
                Text("自动模式：手机 2 列，iPad 横屏可达 4 列。")
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

            Section("播放") {
                Picker("默认清晰度", selection: Binding(
                    get: { settings.resolvedPreferredVideoQn() },
                    set: { settings.preferredQn = $0 }
                )) {
                    ForEach(preferredVideoQualityOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                Toggle("显示弹幕", isOn: $settings.danmakuEnabled)
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
                }
                Toggle("自动旋转进入/退出全屏", isOn: $settings.autoRotateFullscreen)
            }
        }
        .navigationTitle("显示设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
