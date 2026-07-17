import UIKit

/// Serializes diffable data-source commits and keeps only the newest pending
/// state. UIKit can assert when a second snapshot/reconfigure is submitted
/// while the previous commit is still reconciling visible cells.
@MainActor
final class DiffableSnapshotCoordinator<Section: Hashable, Item: Hashable> {
    typealias Snapshot = NSDiffableDataSourceSnapshot<Section, Item>

    private var isApplying = false
    private var pendingSnapshot: Snapshot?

    func apply(
        _ snapshot: Snapshot,
        to dataSource: UICollectionViewDiffableDataSource<Section, Item>
    ) {
        guard !isApplying else {
            pendingSnapshot = snapshot
            return
        }

        isApplying = true
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self, weak dataSource] in
            guard let self else { return }
            self.isApplying = false
            guard let pendingSnapshot = self.pendingSnapshot, let dataSource else { return }
            self.pendingSnapshot = nil
            self.apply(pendingSnapshot, to: dataSource)
        }
    }
}
