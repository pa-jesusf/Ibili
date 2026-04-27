import SwiftUI
import AVKit

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var isLoading = true
    @Published var errorText: String?
    @Published var player: AVPlayer?

    func load(item: FeedItemDTO) async {
        isLoading = true; errorText = nil
        do {
            let info = try await Task.detached { try CoreClient.shared.playUrl(aid: item.aid, cid: item.cid, qn: 64) }.value
            guard let url = URL(string: info.url) else {
                errorText = "无效的播放地址"; isLoading = false; return
            }
            // Bilibili durl URLs require Referer + User-Agent.
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "Bilibili Freedoooooom/MarkII",
                    "Referer": "https://www.bilibili.com/"
                ]
            ])
            let pi = AVPlayerItem(asset: asset)
            self.player = AVPlayer(playerItem: pi)
            self.player?.play()
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    func teardown() {
        player?.pause()
        player = nil
    }
}

struct PlayerView: View {
    let item: FeedItemDTO
    @StateObject private var vm = PlayerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let p = vm.player {
                    VideoPlayer(player: p)
                } else if vm.isLoading {
                    ProgressView().tint(.white)
                } else if let err = vm.errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                            .foregroundStyle(.yellow)
                        Text(err).foregroundStyle(.white).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.headline)
                    Text(item.author).font(.subheadline).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("AV", value: String(item.aid))
                    LabeledContent("BV", value: item.bvid)
                    LabeledContent("CID", value: String(item.cid))
                }
                .padding()
            }
        }
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(item: item) }
        .onDisappear { vm.teardown() }
    }
}
