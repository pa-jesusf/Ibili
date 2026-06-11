import CoreGraphics
import Foundation

/// Facade for image-heavy surfaces. It keeps call sites from depending on
/// a specific cache/prefetch implementation, so article images, dynamic
/// images, comments, and covers can converge behind one pipeline.
@MainActor
final class ImagePreviewPipeline {
    static let shared = ImagePreviewPipeline()

    private init() {}

    func prefetch(_ urls: [String], targetPointSize: CGSize, quality: Int? = nil) {
        CoverImagePrefetcher.shared.prefetch(urls, targetPointSize: targetPointSize, quality: quality)
    }
}
