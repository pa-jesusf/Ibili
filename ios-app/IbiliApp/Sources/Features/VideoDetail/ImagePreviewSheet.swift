import SwiftUI
import UIKit
import Photos

struct CommentImagePreviewItem: Hashable {
    let originalURL: String
    let cachedThumbnailSide: CGFloat

    init(originalURL: String, cachedThumbnailSide: CGFloat = 96) {
        self.originalURL = originalURL
        self.cachedThumbnailSide = cachedThumbnailSide
    }

    func withCachedThumbnailSide(_ side: CGFloat) -> CommentImagePreviewItem {
        CommentImagePreviewItem(originalURL: originalURL, cachedThumbnailSide: side)
    }

    var normalizedOriginalURL: String {
        BiliImageURL.original(originalURL)
    }

    func thumbnailURL() -> String {
        BiliImageURL.resized(
            originalURL,
            pointSize: CGSize(width: cachedThumbnailSide, height: cachedThumbnailSide),
            quality: 75
        )
    }

    func displayURL(screenSize: CGSize) -> String {
        BiliImageURL.resized(originalURL, pointSize: screenSize, quality: nil)
    }
}

/// Full-screen image preview with pinch-to-zoom and save-to-album.
/// Used by `ReplyPictureGrid` when a thumbnail is tapped.
struct ImagePreviewSheet: View {
    let images: [CommentImagePreviewItem]
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var originalIndexes: Set<Int> = []
    @State private var saveStatus: String?
    @State private var saveStatusWork: DispatchWorkItem?
    /// Live vertical drag offset for swipe-to-dismiss. Only kicks in
    /// when the underlying page isn't pinch-zoomed (we read this back
    /// from `ZoomablePreviewPage` via a preference).
    @State private var dismissDrag: CGFloat = 0
    @State private var pageZoomed = false
    @State private var didEnterGestureShield = false

    private var safeIndex: Int {
        guard !images.isEmpty else { return 0 }
        return min(max(index, 0), images.count - 1)
    }

    init(images: [CommentImagePreviewItem], initialIndex: Int) {
        self.images = images
        self.initialIndex = initialIndex
        _index = State(initialValue: min(max(0, initialIndex), max(0, images.count - 1)))
    }

    init(urls: [String], initialIndex: Int) {
        self.init(images: urls.map { CommentImagePreviewItem(originalURL: $0) }, initialIndex: initialIndex)
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

            GeometryReader { proxy in
                ImagePreviewPager(
                    images: images,
                    index: $index,
                    screenSize: proxy.size,
                    originalIndexes: originalIndexes,
                    pageZoomed: $pageZoomed
                ) { image, i in
                    ZoomablePreviewPage(
                        image: image,
                        screenSize: proxy.size,
                        showsOriginal: originalIndexes.contains(i),
                        isZoomed: $pageZoomed
                    )
                    .onDisappear {
                        if index != i {
                            pageZoomed = false
                        }
                    }
                }
            }
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
                    Text("\(safeIndex + 1) / \(images.count)")
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
                HStack(spacing: 10) {
                    Button {
                        originalIndexes.insert(safeIndex)
                    } label: {
                        Label(originalIndexes.contains(safeIndex) ? "已是原图" : "原图",
                              systemImage: originalIndexes.contains(safeIndex) ? "checkmark.circle" : "photo.badge.magnifyingglass")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .background(GlassCapsuleBackground())
                    .disabled(originalIndexes.contains(safeIndex))
                }
                .padding(.bottom, saveStatus == nil ? 28 : 10)

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
        .onAppear {
            guard !didEnterGestureShield else { return }
            didEnterGestureShield = true
            ModalGestureShield.enter()
        }
        .onDisappear {
            guard didEnterGestureShield else { return }
            didEnterGestureShield = false
            ModalGestureShield.leave()
        }
        // High-priority gesture so we win over `TabView`'s page swipe
        // ONLY when the user is clearly dragging downward. We require
        // the vertical translation to dominate horizontally before
        // claiming the gesture, otherwise left/right page swipes are
        // forwarded to the underlying `TabView`.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard !pageZoomed else { return }
                    let dx = abs(v.translation.width)
                    let dy = v.translation.height
                    // Vertical-dominant downward drag only; ignore
                    // anything that looks remotely like a page flip.
                    guard dy > 0, dy > dx * 1.4 else {
                        dismissDrag = 0
                        return
                    }
                    dismissDrag = dy
                }
                .onEnded { v in
                    guard !pageZoomed else { return }
                    let dx = abs(v.translation.width)
                    let dy = v.translation.height
                    let isVertical = dy > dx * 1.4
                    if isVertical, dy > 120 || v.predictedEndTranslation.height > 240 {
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
        guard images.indices.contains(safeIndex) else { return }
        let urlString = images[safeIndex].normalizedOriginalURL
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
private struct ImagePreviewPager<Page: View>: UIViewControllerRepresentable {
    let images: [CommentImagePreviewItem]
    @Binding var index: Int
    let screenSize: CGSize
    let originalIndexes: Set<Int>
    @Binding var pageZoomed: Bool
    let page: (CommentImagePreviewItem, Int) -> Page

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let vc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        vc.dataSource = context.coordinator
        vc.delegate = context.coordinator
        context.coordinator.configureScrollViews(in: vc.view)
        if let initial = context.coordinator.controller(at: index) {
            vc.setViewControllers([initial], direction: .forward, animated: false)
        }
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configureScrollViews(in: vc.view)
        context.coordinator.reloadVisiblePageIfNeeded(in: vc)
        guard context.coordinator.visibleIndex != index,
              let target = context.coordinator.controller(at: index) else { return }
        let direction: UIPageViewController.NavigationDirection = index > context.coordinator.visibleIndex ? .forward : .reverse
        let coordinator = context.coordinator
        coordinator.isProgrammaticUpdate = true
        vc.setViewControllers([target], direction: direction, animated: false) { _ in
            coordinator.isProgrammaticUpdate = false
            coordinator.visibleIndex = index
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ImagePreviewPager
        var visibleIndex: Int
        var isProgrammaticUpdate = false
        private var controllers: [Int: UIViewController] = [:]

        init(parent: ImagePreviewPager) {
            self.parent = parent
            self.visibleIndex = parent.index
        }

        func configureScrollViews(in root: UIView) {
            let discovered = root.subviewsRecursive().compactMap { $0 as? UIScrollView }
            for scrollView in discovered {
                scrollView.isPagingEnabled = true
                scrollView.alwaysBounceHorizontal = parent.images.count > 1
                scrollView.alwaysBounceVertical = false
                scrollView.delaysContentTouches = false
                scrollView.canCancelContentTouches = true
            }
        }

        func controller(at index: Int) -> UIViewController? {
            guard parent.images.indices.contains(index) else { return nil }
            if let existing = controllers[index] {
                update(existing, at: index)
                return existing
            }
            let controller = UIHostingController(
                rootView: parent.page(parent.images[index], index)
            )
            controller.view.backgroundColor = .clear
            controllers[index] = controller
            return controller
        }

        func reloadVisiblePageIfNeeded(in vc: UIPageViewController) {
            for (index, controller) in controllers {
                update(controller, at: index)
            }
            guard let visible = vc.viewControllers?.first,
                  let visibleIndex = controllers.first(where: { $0.value === visible })?.key else { return }
            self.visibleIndex = visibleIndex
        }

        private func update(_ controller: UIViewController, at index: Int) {
            guard let controller = controller as? UIHostingController<Page>,
                  parent.images.indices.contains(index) else { return }
            controller.rootView = parent.page(parent.images[index], index)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let index = index(of: viewController) else { return nil }
            return controller(at: index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let index = index(of: viewController) else { return nil }
            return controller(at: index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let current = pageViewController.viewControllers?.first,
                  let currentIndex = index(of: current) else { return }
            visibleIndex = currentIndex
            parent.index = currentIndex
        }

        private func index(of controller: UIViewController) -> Int? {
            controllers.first(where: { $0.value === controller })?.key
        }
    }
}

private extension UIView {
    func subviewsRecursive() -> [UIView] {
        subviews + subviews.flatMap { $0.subviewsRecursive() }
    }
}

/// Single page that supports pinch-to-zoom on top of `RemoteImage`.
private struct ZoomablePreviewPage: View {
    let image: CommentImagePreviewItem
    let screenSize: CGSize
    let showsOriginal: Bool
    /// Lifted so the parent sheet can suspend its swipe-to-dismiss
    /// gesture while the user is panning a zoomed-in image.
    @Binding var isZoomed: Bool

    @State private var scale: CGFloat = 1.0
    @GestureState private var pinch: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        let total = scale * pinch
        ProgressivePreviewImage(
            image: image,
            screenSize: screenSize,
            showsOriginal: showsOriginal
        )
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
            .onChange(of: showsOriginal) { _ in
                resetZoom()
            }
            .onDisappear {
                resetZoom()
            }
    }

    private func resetZoom() {
        scale = 1
        offset = .zero
        isZoomed = false
    }
}

private struct ProgressivePreviewImage: View {
    let image: CommentImagePreviewItem
    let screenSize: CGSize
    let showsOriginal: Bool

    private var fallbackURL: URL? {
        URL(string: image.thumbnailURL())
    }

    private var requestedURL: URL? {
        let raw = showsOriginal
            ? image.normalizedOriginalURL
            : image.displayURL(screenSize: screenSize)
        return URL(string: raw)
    }

    var body: some View {
        CachedRemoteImage(
            url: requestedURL,
            fallbackURL: fallbackURL,
            contentMode: .fit
        )
    }
}

@MainActor
private final class CachedRemoteImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var task: Task<Void, Never>?
    private var loadedURL: URL?

    func load(url: URL?, fallbackURL: URL?) {
        task?.cancel()
        failed = false
        loadedURL = url
        image = cachedImage(for: url) ?? cachedImage(for: fallbackURL)

        guard let url else { return }
        if ImageCache.shared.image(for: url) != nil {
            return
        }

        task = Task { [url] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if Task.isCancelled { return }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard let raw = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                let display = self.downsample(raw)
                ImageCache.shared.store(display, for: url, cost: data.count)
                ImageDiskCache.shared.write(url, data: data)
                await MainActor.run {
                    guard self.loadedURL == url else { return }
                    self.image = display
                    self.failed = false
                }
            } catch {
                await MainActor.run {
                    guard self.loadedURL == url, self.image == nil else { return }
                    self.failed = true
                }
            }
        }
    }

    func useCachedImageIfAvailable(for url: URL?) {
        guard let url, loadedURL == url, image == nil else { return }
        image = cachedImage(for: url)
    }

    deinit { task?.cancel() }

    private func cachedImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        if let memory = ImageCache.shared.image(for: url) {
            return memory
        }
        guard let data = ImageDiskCache.shared.read(url),
              let raw = UIImage(data: data) else {
            return nil
        }
        let display = downsample(raw)
        ImageCache.shared.store(display, for: url, cost: data.count)
        return display
    }

    private nonisolated func downsample(_ image: UIImage) -> UIImage {
        let maxDim = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale * 1.5
        let size = image.size
        let scale = min(maxDim / max(size.width, 1), maxDim / max(size.height, 1))
        guard scale < 0.9 else { return image }
        let targetSize = CGSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private struct CachedRemoteImage: View {
    let url: URL?
    let fallbackURL: URL?
    var contentMode: ContentMode = .fit

    @StateObject private var loader = CachedRemoteImageLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity.animation(.easeOut(duration: 0.16)))
            } else if loader.failed {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loader.load(url: url, fallbackURL: fallbackURL) }
        .onChange(of: url) { loader.load(url: $0, fallbackURL: fallbackURL) }
        .onChange(of: fallbackURL) { loader.load(url: url, fallbackURL: $0) }
        .onReceive(NotificationCenter.default.publisher(for: ImageCache.didStoreImageNotification)) { notification in
            let storedURL = ImageCache.storedURL(from: notification)
            guard storedURL == url else { return }
            loader.useCachedImageIfAvailable(for: storedURL)
        }
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
