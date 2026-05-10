import SwiftUI

struct OfflineDownloadSheet: View {
    let item: FeedItemDTO
    let qualities: [(qn: Int64, label: String)]
    let currentQn: Int64
    let audioQualities: [(qn: Int64, label: String)]
    let currentAudioQn: Int64
    let cdn: String
    let onStart: (OfflineDownloadRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedQn: Int64
    @State private var selectedAudioQn: Int64

    init(
        item: FeedItemDTO,
        qualities: [(qn: Int64, label: String)],
        currentQn: Int64,
        audioQualities: [(qn: Int64, label: String)],
        currentAudioQn: Int64,
        cdn: String,
        onStart: @escaping (OfflineDownloadRequest) -> Void
    ) {
        self.item = item
        self.qualities = qualities
        self.currentQn = currentQn
        self.audioQualities = audioQualities
        self.currentAudioQn = currentAudioQn
        self.cdn = cdn
        self.onStart = onStart
        _selectedQn = State(initialValue: currentQn > 0 ? currentQn : (qualities.first?.qn ?? 80))
        _selectedAudioQn = State(initialValue: currentAudioQn > 0 ? currentAudioQn : (audioQualities.first?.qn ?? 0))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        RemoteImage(url: item.cover,
                                    contentMode: .fill,
                                    targetPointSize: CGSize(width: 240, height: 150),
                                    quality: 78)
                            .frame(width: 112, height: 70)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(2)
                            Text(item.author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Section("画质") {
                    Picker("视频画质", selection: $selectedQn) {
                        ForEach(normalizedQualities, id: \.qn) { q in
                            Text(q.label).tag(q.qn)
                        }
                    }
                    if !normalizedAudioQualities.isEmpty {
                        Picker("音频质量", selection: $selectedAudioQn) {
                            ForEach(normalizedAudioQualities, id: \.qn) { q in
                                Text(q.label).tag(q.qn)
                            }
                        }
                    }
                }
                Section {
                    Text("离线缓存会优先无损封装为单个可播放文件；如果当前流无法无损封装，将明确失败，不会静默转码降级。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("离线缓存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") {
                        let q = normalizedQualities.first { $0.qn == selectedQn }
                        let a = normalizedAudioQualities.first { $0.qn == selectedAudioQn }
                        onStart(OfflineDownloadRequest(
                            item: item,
                            qn: selectedQn,
                            qnLabel: q?.label ?? "自动",
                            audioQn: selectedAudioQn,
                            audioQnLabel: a?.label ?? "",
                            cdn: cdn
                        ))
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var normalizedQualities: [(qn: Int64, label: String)] {
        if !qualities.isEmpty { return qualities }
        return [(currentQn > 0 ? currentQn : 80, currentQn > 0 ? "\(currentQn)P" : "自动")]
    }

    private var normalizedAudioQualities: [(qn: Int64, label: String)] {
        audioQualities
    }
}
