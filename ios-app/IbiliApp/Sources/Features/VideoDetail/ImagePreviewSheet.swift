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
    /// Live vertical drag offset for swipe-to-dismiss. Only kicks in
    /// when the underlying page isn't pinch-zoomed (we read this back
    /// from `ZoomablePreviewPage` via a preference).
    @State private var dismissDrag: CGFloat = 0
    @State private var pageZoomed = false

    init(urls: [String], initialIndex: Int) {
        self.urls = urls
        self.initialIndex = initialIndex
        _index = State(initialValue: initialIndex)
    }

    var body: some View {
        // Background dims as the user drags the image down. At 240pt
        // of travel the alpha falls to ~30 %, signalling "release to
        // close". Mirrors Photos.app behaviour.
        let dragMag = abs(dismissDrag)
        let dimAlpha = max(0.0, 1.0 - Double(dragMag / 480))
        ZStack {
            Color.black.opacity(dimAlpha)
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                    ZoomablePreviewPage(url: u, isZoomed: $pageZoomed)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dismissDrag)
            .scaleEffect(max(0.85, 1.0 - dragMag / 1600))
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0), value: dismissDrag)

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                    .buttonStyle(GlassCircleButtonStyle())
                    Spacer()
                    Text("\(index + 1) / \(urls.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(GlassCapsuleBackground())
                    Spacer()
                    Button {
                        save()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                    .buttonStyle(GlassCircleButtonStyle())
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { v in
                    // Only dismiss-drag when the page isn't zoomed in
                    // (the inner `ZoomablePreviewPage` claims the
                    // gesture during pan-zoom). We also clamp to
                    // downward direction; upward drag is ignored.
                    guard !pageZoomed else { return }
                    if v.translation.height >= 0 {
                        dismissDrag = v.translation.height
                    }
                }
                .onEnded { v in
                    guard !pageZoomed else { return }
                    if v.translation.height > 120 || v.predictedEndTranslation.height > 240 {
                        // Animate back to neutral while dismissing so
                        // the close transition feels continuous with
                        // the drag.
                        dismiss()
                        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0)) {
                            dismissDrag = 0
                        }
                    } else {
                        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86, blendDuration: 0)) {
                            dismissDrag = 0
                        }
                    }
                }
        )
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
    /// Lifted so the parent sheet can suspend its swipe-to-dismiss
    /// gesture while the user is panning a zoomed-in image.
    @Binding var isZoomed: Bool

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
                        isZoomed = next > 1.01
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
                        isZoomed = false
                    } else {
                        scale = 2.4
                        isZoomed = true
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Circular liquid-glass background for overlay buttons. iOS 26 picks
/// up the system glass material; older targets fall back to a
/// translucent black disc that still reads cleanly on bright photos.
private struct GlassCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let scale = configuration.isPressed ? 0.94 : 1.0
        configuration.label
            .background {
                if #available(iOS 26.0, *) {
                    Circle().fill(.ultraThinMaterial)
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                } else {
                    Circle().fill(.black.opacity(0.45))
                }
            }
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Capsule companion to `GlassCircleButtonStyle` for the page indicator.
private struct GlassCapsuleBackground: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
        } else {
            Capsule().fill(.black.opacity(0.45))
        }
    }
}
