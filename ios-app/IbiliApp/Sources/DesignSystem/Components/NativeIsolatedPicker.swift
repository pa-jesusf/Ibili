import SwiftUI
import UIKit

/// A small UIViewRepresentable wrapper that hosts a single
/// UISegmentedControl instance with per-instance coloring so we do
/// not touch the global `UISegmentedControl.appearance()`.
///
/// Usage: `NativeIsolatedPicker(items: Array(Tab.allCases),
/// title: { $0.title }, selection: $tab)`
struct NativeIsolatedPicker<T: Hashable>: UIViewRepresentable {
    var items: [T]
    var title: (T) -> String
    @Binding var selection: T
    let accentColor: UIColor

    init(items: [T], title: @escaping (T) -> String, selection: Binding<T>, accentColor: UIColor = IbiliTheme.accentUIColor) {
        self.items = items
        self.title = title
        self._selection = selection
        self.accentColor = accentColor
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let seg = UISegmentedControl(items: items.map(title))
        seg.selectedSegmentTintColor = accentColor
        seg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.secondaryLabel], for: .normal)
        seg.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        if let idx = items.firstIndex(where: { $0 == selection }) {
            seg.selectedSegmentIndex = idx
        } else {
            seg.selectedSegmentIndex = UISegmentedControl.noSegment
        }
        return seg
    }

    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        // Sync titles / segment count
        for i in 0..<items.count {
            let t = title(items[i])
            if i < uiView.numberOfSegments {
                uiView.setTitle(t, forSegmentAt: i)
            } else {
                uiView.insertSegment(withTitle: t, at: i, animated: false)
            }
        }
        while uiView.numberOfSegments > items.count {
            uiView.removeSegment(at: uiView.numberOfSegments - 1, animated: false)
        }
        context.coordinator.items = items
        if let idx = items.firstIndex(where: { $0 == selection }) {
            uiView.selectedSegmentIndex = idx
        } else {
            uiView.selectedSegmentIndex = UISegmentedControl.noSegment
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, items: items)
    }

    final class Coordinator: NSObject {
        var selection: Binding<T>
        var items: [T]
        init(selection: Binding<T>, items: [T]) {
            self.selection = selection
            self.items = items
        }
        @objc func valueChanged(_ sender: UISegmentedControl) {
            let idx = sender.selectedSegmentIndex
            guard idx >= 0 && idx < items.count else { return }
            selection.wrappedValue = items[idx]
        }
    }
}
