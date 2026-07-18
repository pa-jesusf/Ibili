import UIKit

/// Serializes diffable data-source commits and keeps only the newest pending
/// state. UIKit can assert when a second snapshot/reconfigure is submitted
/// while the previous commit is still reconciling visible cells.
@MainActor
final class DiffableSnapshotCoordinator<Section: Hashable, Item: Hashable> {
    typealias Snapshot = NSDiffableDataSourceSnapshot<Section, Item>

    enum ApplyMode: Equatable {
        case diff
        case reloadData

        static func merged(_ lhs: Self, _ rhs: Self) -> Self {
            lhs == .reloadData || rhs == .reloadData ? .reloadData : .diff
        }
    }

    private struct PendingApply {
        let snapshot: Snapshot
        let mode: ApplyMode
    }

    private var isApplying = false
    private var pendingApply: PendingApply?

    func apply(
        _ snapshot: Snapshot,
        to dataSource: UICollectionViewDiffableDataSource<Section, Item>,
        mode: ApplyMode = .diff
    ) {
        guard !isApplying else {
            let pendingMode = pendingApply.map { ApplyMode.merged($0.mode, mode) } ?? mode
            pendingApply = PendingApply(snapshot: snapshot, mode: pendingMode)
            return
        }

        isApplying = true
        let completion = { [weak self, weak dataSource] in
            guard let self else { return }
            self.isApplying = false
            guard let pendingApply = self.pendingApply, let dataSource else { return }
            self.pendingApply = nil
            self.apply(pendingApply.snapshot, to: dataSource, mode: pendingApply.mode)
        }

        switch mode {
        case .diff:
            dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
        case .reloadData:
            dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
        }
    }
}
