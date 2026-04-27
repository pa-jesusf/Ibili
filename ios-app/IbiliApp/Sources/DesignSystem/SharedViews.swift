import SwiftUI

/// Minimal async image with placeholder. SwiftUI's `AsyncImage` is fine for MVP;
/// wrap so we can swap to a caching loader without touching call sites.
struct RemoteImage: View {
    let url: String
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                Rectangle().fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            default:
                Rectangle().fill(Color.gray.opacity(0.15))
            }
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
