import UIKit

/// Shared image loader used by SwiftUI views and UIKit collection cells.
/// It centralizes memory cache, disk cache, network retry and downsampling so
/// scrolling surfaces do not each reinvent their own image lifecycle.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()

    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    func image(for url: URL, maxPixelDimension: CGFloat) async -> UIImage? {
        if let cached = ImageCache.shared.image(for: url) {
            return cached
        }
        if let diskData = ImageDiskCache.shared.read(url),
           let raw = UIImage(data: diskData) {
            let display = downsample(raw, maxPixelDimension: maxPixelDimension)
            ImageCache.shared.store(display, for: url, cost: diskData.count)
            return display
        }
        if let task = inFlight[url] {
            return await task.value
        }
        let task = Task<UIImage?, Never> { [url, maxPixelDimension] in
            for attempt in 0..<3 {
                if Task.isCancelled { return nil }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if Task.isCancelled { return nil }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    guard let raw = UIImage(data: data) else { return nil }
                    let display = await MainActor.run {
                        self.downsample(raw, maxPixelDimension: maxPixelDimension)
                    }
                    ImageCache.shared.store(display, for: url, cost: data.count)
                    ImageDiskCache.shared.write(url, data: data)
                    return display
                } catch {
                    if Task.isCancelled { return nil }
                }
                try? await Task.sleep(nanoseconds: UInt64(150_000_000 * (attempt + 1)))
            }
            return nil
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        return image
    }

    func cancel(_ url: URL) {
        inFlight[url]?.cancel()
        inFlight[url] = nil
    }

    private nonisolated func downsample(_ image: UIImage, maxPixelDimension maxDim: CGFloat) -> UIImage {
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

