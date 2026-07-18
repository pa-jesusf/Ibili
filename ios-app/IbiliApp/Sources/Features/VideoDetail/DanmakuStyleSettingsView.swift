import SwiftUI

struct DanmakuStyleSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    private let danmakuFontWeightOptions: [(label: String, value: Int)] = [
        ("常规", 4),
        ("中等", 5),
        ("半粗", 6),
        ("加粗", 7),
        ("特粗", 8),
        ("最粗", 9),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("弹幕显示") {
                    Toggle("显示弹幕", isOn: $settings.danmakuEnabled)
                    Toggle("启用弹幕时显示发送提示", isOn: $settings.showDanmakuSendHint)
                }
                Section("样式") {
                    VStack(alignment: .leading, spacing: 8) {
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
                        ForEach(DanmakuFrameRateOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("弹幕字号")
                            Spacer()
                            Text(String(format: "x%.2f", settings.resolvedDanmakuFontScale()))
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
            }
            .navigationTitle("弹幕样式")
            .navigationBarTitleDisplayMode(.inline)
            .tint(IbiliTheme.accent)
        }
    }

    private var strokeWidthLabel: String {
        let value = settings.resolvedDanmakuStrokeWidth()
        return value == 0 ? "关闭" : String(format: "%.1f", value)
    }
}
