import SwiftUI
import UIKit
import Photos

/// Full-screen image preview with pinch-to-zoom and save-to-album.
/// Used by `ReplyPictureGrid` when a thumbnail is tapped.
struct ImagePreviewSheet: View {
    let urls: [String]
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var saveStatus: String?
    @State private var saveStatusWork: DispatchWorkItem?

    init(urls: [String], initialIndex: Int) {
        self.urls = urls
        self.initialIndex = initialIndex
        _index = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                    ZoomablePreviewPage(url: u)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                    Spacer()
                    Text("\(index + 1) / \(urls.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.45)))
                    Spacer()
                    Button {
                        save()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                if let m = saveStatus {
                    Text(m)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.bottom, 28)
                        .transition(.opacity)
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Save

    private func save() {
        guard urls.indices.contains(index) else { return }
        let urlString = urls[index]
        Task.detached(priority: .userInitiated) {
            await downloadAndSave(urlString)
        }
    }

    private func downloadAndSave(_ urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else {
                await flash("保存失败：图片解码失败")
                return
            }
            let status = await requestPhotoAddOnly()
            guard status == .authorized || status == .limited else {
                await flash("无相册权限")
                return
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }
            await flash("已保存到相册")
        } catch {
            await flash("保存失败")
        }
    }

    @MainActor
    private func flash(_ message: String) {
        saveStatus = message
        saveStatusWork?.cancel()
        let w = DispatchWorkItem { saveStatus = nil }
        saveStatusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }

    private func requestPhotoAddOnly() async -> PHAuthorizationStatus {
        await withCheckedContinuation { (cc: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cc.resume(returning: status)
            }
        }
    }
}

/// Single page that supports pinch-to-zoom on top of `RemoteImage`.
private struct ZoomablePreviewPage: View {
    let url: String

    @State private var scale: CGFloat = 1.0
    @GestureState private var pinch: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        let total = scale * pinch
        RemoteImage(url: url, contentMode: .fit)
            .scaleEffect(total)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .gesture(
                MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        let next = max(1.0, min(scale * value, 4.0))
                        scale = next
                        if next == 1.0 { offset = .zero }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .updating($drag) { v, s, _ in if scale > 1.01 { s = v.translation } }
                    .onEnded { v in
                        if scale > 1.01 {
                            offset.width += v.translation.width
                            offset.height += v.translation.height
                        }
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    if scale > 1.01 {
                        scale = 1
                        offset = .zero
                    } else {
                        scale = 2.4
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
