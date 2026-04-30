import SwiftUI
import PhotosUI

/// Thin SwiftUI wrapper over `PHPickerViewController` for picking
/// images. PHPicker doesn't require Photos permission since iOS 14
/// — the system runs the picker in a private extension and only
/// hands back the chosen items, so the host app never gains
/// general access to the user's library. That matches the
/// "私密访问机制" requirement: we never call
/// `PHPhotoLibrary.requestAuthorization`.
struct PrivatePhotoPicker: UIViewControllerRepresentable {
    /// Maximum number of images the user may choose in one shot.
    let selectionLimit: Int
    /// Invoked once the user finishes picking. Empty array if the
    /// user dismissed without selecting anything.
    let onPicked: ([UIImage]) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .compatible
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PrivatePhotoPicker

        init(parent: PrivatePhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.dismiss()
                parent.onPicked([])
                return
            }
            let group = DispatchGroup()
            // Preserve the user's selection order even though
            // `loadObject` resolves out-of-order.
            var images: [UIImage?] = Array(repeating: nil, count: results.count)
            for (idx, result) in results.enumerated() {
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { reading, _ in
                    if let img = reading as? UIImage {
                        images[idx] = img
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                self.parent.dismiss()
                self.parent.onPicked(images.compactMap { $0 })
            }
        }
    }
}
