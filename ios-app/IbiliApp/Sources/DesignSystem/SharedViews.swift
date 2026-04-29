import SwiftUI
import UIKit

/// Process-wide image cache. Sized to keep ~150 covers in memory at typical
/// resolutions; UIKit will evict on memory pressure automatically.
final class ImageCache {
    static let shared = ImageCache()
    let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 256
        c.totalCostLimit = 64 * 1024 * 1024 // 64 MB
        return c
    }()
}

/// Shared cover prefetcher for feed-like grids. It warms the same
/// `ImageCache` used by `RemoteImage`, so prefetched covers are reused
/// by cells instead of being downloaded twice.
@MainActor
final class CoverImagePrefetcher {
    static let shared = CoverImagePrefetcher()

    private let maxConcurrent = 6
    private var tasks: [URL: Task<Void, Never>] = [:]

    func prefetch(_ urlStrings: [String], targetPointSize: CGSize, quality: Int?) {
        let urls = urlStrings.compactMap { raw -> URL? in
            let resolved = BiliImageURL.resized(raw, pointSize: targetPointSize, quality: quality)
            return URL(string: resolved)
        }
        for url in urls where tasks[url] == nil && ImageCache.shared.cache.object(forKey: url as NSURL) == nil {
            if tasks.count >= maxConcurrent, let first = tasks.keys.first {
                tasks[first]?.cancel()
                tasks[first] = nil
            }
            tasks[url] = Task { [url] in
                defer { Task { @MainActor in self.tasks[url] = nil } }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if Task.isCancelled { return }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
                    guard let img = UIImage(data: data) else { return }
                    ImageCache.shared.cache.setObject(img, forKey: url as NSURL, cost: data.count)
                } catch {
                    return
                }
            }
        }
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

    func load(_ url: URL?) {
        guard let url else { image = nil; return }
        if loadedURL == url, image != nil { return }
        loadedURL = url
        if let cached = ImageCache.shared.cache.object(forKey: url as NSURL) {
            image = cached
            failed = false
            return
        }
        task?.cancel()
        failed = false
        task = Task { [url] in
            // Three retry attempts with backoff — Bilibili's CDN occasionally
            // 502s on the first hit for fresh URLs.
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if Task.isCancelled { return }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    if let img = UIImage(data: data) {
                        let display = downsample(img, to: url)
                        ImageCache.shared.cache.setObject(display, forKey: url as NSURL,
                                                         cost: data.count)
                        await MainActor.run {
                            if self.loadedURL == url { self.image = display; self.failed = false }
                        }
                        return
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(nanoseconds: UInt64(150_000_000 * (attempt + 1)))
            }
            await MainActor.run {
                if self.loadedURL == url, self.image == nil { self.failed = true }
            }
        }
    }

    deinit { task?.cancel() }

    private nonisolated func downsample(_ image: UIImage, to url: URL) -> UIImage {
        let maxDim: CGFloat = UIScreen.main.bounds.width * UIScreen.main.scale
        let size = image.size
        let scale = min(maxDim / max(size.width, 1), maxDim / max(size.height, 1))
        guard scale < 0.9 else { return image }
        let targetSize = CGSize(width: (size.width * scale).rounded(),
                                height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
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
        .onAppear { loader.load(resolvedURL) }
        .onChange(of: resolvedURL) { loader.load($0) }
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
