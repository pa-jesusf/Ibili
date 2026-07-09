import SwiftUI
import UIKit

/// Process-wide image cache. Sized to keep ~150 covers in memory at typical
/// resolutions; UIKit will evict on memory pressure automatically.
final class ImageCache {
    static let shared = ImageCache()
    private static let storedURLUserInfoKey = "url"
    static let didStoreImageNotification = Notification.Name("IbiliImageCacheDidStoreImage")

    let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 256
        c.totalCostLimit = 64 * 1024 * 1024 // 64 MB
        return c
    }()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL, cost: Int) {
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.didStoreImageNotification,
                object: self,
                userInfo: [Self.storedURLUserInfoKey: url]
            )
        }
    }

    static func storedURL(from notification: Notification) -> URL? {
        notification.userInfo?[storedURLUserInfoKey] as? URL
    }
}

/// Shared cover prefetcher for feed-like grids. It warms the same
/// `ImageCache` used by `RemoteImage`, so prefetched covers are reused
/// by cells instead of being downloaded twice.
@MainActor
final class CoverImagePrefetcher {
    static let shared = CoverImagePrefetcher()

    private let maxConcurrent = 4
    private var tasks: [URL: Task<Void, Never>] = [:]

    func prefetch(_ urlStrings: [String], targetPointSize: CGSize, quality: Int?) {
        let urls = urlStrings.compactMap { raw -> URL? in
            let resolved = BiliImageURL.resized(raw, pointSize: targetPointSize, quality: quality)
            return URL(string: resolved)
        }
        let maxPixelDimension = Self.maxPixelDimension(for: targetPointSize)
        for url in urls where tasks[url] == nil && ImageCache.shared.image(for: url) == nil {
            if tasks.count >= maxConcurrent, let first = tasks.keys.first {
                tasks[first]?.cancel()
                tasks[first] = nil
            }
            tasks[url] = Task { [url, maxPixelDimension] in
                defer { Task { @MainActor in self.tasks[url] = nil } }
                _ = await ImagePipeline.shared.image(for: url, maxPixelDimension: maxPixelDimension)
            }
        }
    }

    private static func maxPixelDimension(for targetPointSize: CGSize) -> CGFloat {
        let scale = UIScreen.main.scale
        let maxScreenDimension = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * scale
        let targetDimension = max(targetPointSize.width, targetPointSize.height) * scale
        return min(max(targetDimension, 160), maxScreenDimension)
    }
}

/// Loads + caches a single image. Survives view-cell recycling because the
/// `URLSession.dataTask` is owned by the loader, not by the SwiftUI view, and
/// because successful results are cached by URL.
@MainActor
private final class RemoteImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed: Bool = false
    private var task: Task<Void, Never>?
    private var loadedURL: URL?

    func load(_ url: URL?, targetPointSize: CGSize?) {
        guard let url else {
            task?.cancel()
            loadedURL = nil
            image = nil
            failed = false
            return
        }
        if loadedURL == url, image != nil { return }
        loadedURL = url
        if loadFromMemoryCache(url) { return }
        let maxDisplayPixelDimension = Self.maxDisplayPixelDimension(for: targetPointSize)
        task?.cancel()
        failed = false
        task = Task { [url] in
            let display = await ImagePipeline.shared.image(for: url, maxPixelDimension: maxDisplayPixelDimension)
            await MainActor.run {
                guard self.loadedURL == url else { return }
                if let display {
                    self.image = display
                    self.failed = false
                } else if self.image == nil {
                    self.failed = true
                }
            }
        }
    }

    func useCachedImageIfAvailable(for url: URL?) {
        guard let url, loadedURL == url, image == nil else { return }
        if loadFromMemoryCache(url) {
            task?.cancel()
        }
    }

    deinit { task?.cancel() }

    @discardableResult
    private func loadFromMemoryCache(_ url: URL) -> Bool {
        guard let cached = ImageCache.shared.image(for: url) else { return false }
        image = cached
        failed = false
        return true
    }

    @MainActor
    private static func maxDisplayPixelDimension(for targetPointSize: CGSize?) -> CGFloat {
        let scale = UIScreen.main.scale
        let maxScreenDimension = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * scale
        guard let targetPointSize else {
            return maxScreenDimension
        }
        let targetDimension = max(targetPointSize.width, targetPointSize.height) * scale
        return min(max(targetDimension, 160), maxScreenDimension)
    }

}

/// Cover image with caching + retry. Replaces the previous `AsyncImage` based
/// implementation, which would silently drop loads when a cell scrolled off
/// before the request completed.
struct RemoteImage: View {
    let url: String
    var contentMode: ContentMode = .fill
    var targetPointSize: CGSize? = nil
    var quality: Int? = nil

    @StateObject private var loader = RemoteImageLoader()

    private var resolvedURL: URL? {
        let s = targetPointSize.map { BiliImageURL.resized(url, pointSize: $0, quality: quality) } ?? url
        return URL(string: s)
    }

    var body: some View {
        ZStack {
            if let img = loader.image {
                Image(uiImage: img).resizable().aspectRatio(contentMode: contentMode)
            } else if loader.failed {
                Rectangle().fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            } else {
                Rectangle().fill(Color.gray.opacity(0.15))
            }
        }
        .onAppear { loader.load(resolvedURL, targetPointSize: targetPointSize) }
        .onChange(of: resolvedURL) { loader.load($0, targetPointSize: targetPointSize) }
        .onReceive(NotificationCenter.default.publisher(for: ImageCache.didStoreImageNotification)) { notification in
            let storedURL = ImageCache.storedURL(from: notification)
            guard storedURL == resolvedURL else { return }
            loader.useCachedImageIfAvailable(for: storedURL)
        }
    }
}

/// QR code rendered via CoreImage.
struct QRCodeImage: View {
    let payload: String

    var body: some View {
        if let img = makeQR(payload) {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.gray
        }
    }

    private func makeQR(_ s: String) -> UIImage? {
        guard let data = s.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
