import SwiftUI

private struct ArtworkScopeKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

private extension EnvironmentValues {
    var artworkScope: UUID? {
        get { self[ArtworkScopeKey.self] }
        set { self[ArtworkScopeKey.self] = newValue }
    }
}

private struct ArtworkAnchor {
    let scope: UUID
    let url: String
    let size: CGSize
    let quality: Int
    let bounds: Anchor<CGRect>
}

private struct ArtworkBoundsKey: PreferenceKey {
    static var defaultValue: [ArtworkAnchor] = []
    static func reduce(value: inout [ArtworkAnchor], nextValue: () -> [ArtworkAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func cardArtwork(url: String, size: CGSize, quality: Int) -> some View {
        modifier(CardArtwork(url: url, size: size, quality: quality))
    }

    func artworkCardSurface(style: ExtendedCoverBackdrop.SurfaceStyle = .ambient, cornerRadius: CGFloat = 16) -> some View {
        modifier(ArtworkCardSurface(style: style, cornerRadius: cornerRadius))
    }
}

private struct CardArtwork: ViewModifier {
    let url: String
    let size: CGSize
    let quality: Int
    @Environment(\.artworkScope) private var scope

    func body(content: Content) -> some View {
        content.anchorPreference(key: ArtworkBoundsKey.self, value: .bounds) { anchor in
            guard let scope, !url.isEmpty else { return [] }
            return [ArtworkAnchor(scope: scope, url: url, size: size, quality: quality, bounds: anchor)]
        }
    }
}

private struct ArtworkCardSurface: ViewModifier {
    let style: ExtendedCoverBackdrop.SurfaceStyle
    let cornerRadius: CGFloat
    @State private var scope = UUID()
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let backed = content
            .environment(\.artworkScope, scope)
            .backgroundPreferenceValue(ArtworkBoundsKey.self) { anchors in
                GeometryReader { geometry in
                    ArtworkBackdropView(anchors: anchors.filter { $0.scope == scope }, geometry: geometry, style: style)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .background(style == .ambient ? IbiliTheme.surface : IbiliTheme.background)
        if style == .ambient {
            backed.clipShape(shape)
                .overlay(shape.strokeBorder(colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.06),
                                            lineWidth: 1 / UIScreen.main.scale))
        } else {
            backed.clipped()
        }
    }
}

private struct ArtworkBackdropView: View {
    let anchors: [ArtworkAnchor]
    let geometry: GeometryProxy
    let style: ExtendedCoverBackdrop.SurfaceStyle
    @Environment(\.colorScheme) private var colorScheme
    @State private var prepared: PreparedArtwork?

    private struct Source: Hashable {
        let request: ImageRequestKey
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        var cacheKey: String { "\(request.cacheKey)#\(x)-\(y)-\(width)-\(height)" }
    }

    private struct Request: Hashable {
        let sources: [Source]
        let configuration: ExtendedCoverBackdrop.SurfaceConfiguration
    }

    private struct PreparedArtwork {
        let request: Request
        let image: UIImage
        let isComplete: Bool
    }

    private var request: Request? {
        let size = geometry.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = UIScreen.main.scale
        func aligned(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let sources = anchors.compactMap { anchor -> Source? in
            let frame = geometry[anchor.bounds]
            guard frame.width > 0, frame.height > 0 else { return nil }
            let resolved = BiliImageURL.resized(anchor.url, pointSize: anchor.size, quality: anchor.quality)
            guard let url = URL(string: resolved) else { return nil }
            return Source(request: ImageRequestKey(url: url, maxPixelDimension: ImagePipeline.displayPixelDimension(for: anchor.size)),
                          x: aligned(frame.minX), y: aligned(frame.minY), width: aligned(frame.width), height: aligned(frame.height))
        }
        guard !sources.isEmpty else { return nil }
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let background = style == .ambient ? UIColor.secondarySystemBackground : UIColor.systemBackground
        background.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Request(sources: sources, configuration: .init(width: aligned(size.width), height: aligned(size.height),
                                                             style: style, red: red, green: green, blue: blue))
    }

    var body: some View {
        let request = request
        Group {
            if let prepared, prepared.request == request {
                Image(uiImage: prepared.image).resizable()
            } else {
                Color.clear
            }
        }
        .task(id: request) {
            guard let request else { prepared = nil; return }
            guard prepared?.request != request || prepared?.isComplete != true else { return }
            var artwork: [ExtendedCoverBackdrop.Artwork] = []
            var cacheKeys: [String] = []
            for source in request.sources {
                let image = await ImagePipeline.shared.image(for: source.request.url, maxPixelDimension: CGFloat(source.request.pixels))
                guard !Task.isCancelled else { return }
                if let bitmap = image?.cgImage {
                    artwork.append(.init(image: bitmap, frame: source.frame))
                    cacheKeys.append(source.cacheKey)
                }
            }
            guard !artwork.isEmpty else { return }
            let sources = artwork
            let cacheKey = cacheKeys.joined(separator: "|")
            let bitmap = try? await BlockingWorkQueue.images.run(priority: .utility) {
                ExtendedCoverBackdrop.surface(for: sources, cacheKey: cacheKey, configuration: request.configuration)
            }
            guard !Task.isCancelled, let bitmap else { return }
            // A failed tile can recover on the next appearance, just like
            // RemoteImage. Only complete backgrounds skip that new attempt.
            prepared = PreparedArtwork(request: request, image: UIImage(cgImage: bitmap),
                                       isComplete: artwork.count == request.sources.count)
        }
    }
}
