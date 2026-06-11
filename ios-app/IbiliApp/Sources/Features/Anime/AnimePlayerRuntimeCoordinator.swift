import Foundation

@MainActor
final class AnimePlayerRuntimeCoordinator {
    static let shared = AnimePlayerRuntimeCoordinator()
    private static let prepareGrace: TimeInterval = 0.28
    private static let teardownGrace: TimeInterval = 2.0

    private var viewModels: [PlayerSessionID: AnimePlayerViewModel] = [:]
    private var pendingPreparationWork: [PlayerSessionID: DispatchWorkItem] = [:]
    private var pendingTeardownWork: [PlayerSessionID: DispatchWorkItem] = [:]
    private var pendingTeardownTokens: [PlayerSessionID: UUID] = [:]

    func viewModel(for routeID: PlayerSessionID) -> AnimePlayerViewModel {
        cancelPendingTeardown(for: routeID)
        if let existing = viewModels[routeID] {
            return existing
        }
        let viewModel = AnimePlayerViewModel()
        viewModels[routeID] = viewModel
        return viewModel
    }

    func prepareForDismissal(routeID: PlayerSessionID) {
        guard let viewModel = viewModels[routeID] else { return }
        viewModel.prepareForDismissal()
    }

    func retainSessions(root: DeepLinkRouter.AnimePlayerRoute?, stack: [DeepLinkRouter.AnimePlayerRoute]) {
        let retainedIDs = Set(([root].compactMap { $0?.id }) + stack.map(\.id))
        for routeID in retainedIDs {
            cancelPendingTeardown(for: routeID)
        }
        let staleSessions = viewModels.filter { !retainedIDs.contains($0.key) }
        for (routeID, viewModel) in staleSessions {
            scheduleTeardown(for: routeID, viewModel: viewModel)
        }
    }

    private func cancelPendingTeardown(for routeID: PlayerSessionID) {
        pendingPreparationWork.removeValue(forKey: routeID)?.cancel()
        pendingTeardownWork.removeValue(forKey: routeID)?.cancel()
        pendingTeardownTokens.removeValue(forKey: routeID)
    }

    private func scheduleTeardown(for routeID: PlayerSessionID, viewModel: AnimePlayerViewModel) {
        guard pendingTeardownWork[routeID] == nil else { return }
        let token = UUID()
        pendingTeardownTokens[routeID] = token
        let prepareWork = DispatchWorkItem { [weak self, weak viewModel] in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self,
                      self.pendingTeardownTokens[routeID] == token else { return }
                self.pendingPreparationWork.removeValue(forKey: routeID)
                viewModel?.prepareForDismissal()
            }
        }
        pendingPreparationWork[routeID] = prepareWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.prepareGrace, execute: prepareWork)
        AppLog.debug("anime", "延迟销毁追番播放器会话", metadata: [
            "routeID": routeID.uuidString,
            "prepareDelayMs": String(Int(Self.prepareGrace * 1000)),
            "delayMs": String(Int(Self.teardownGrace * 1000)),
        ])
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.pendingTeardownTokens[routeID] == token else { return }
                self.pendingPreparationWork.removeValue(forKey: routeID)?.cancel()
                self.pendingTeardownWork.removeValue(forKey: routeID)
                self.pendingTeardownTokens.removeValue(forKey: routeID)
                guard let viewModel = self.viewModels[routeID] else { return }
                viewModel.teardown()
                self.viewModels.removeValue(forKey: routeID)
            }
        }
        pendingTeardownWork[routeID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.teardownGrace, execute: work)
    }
}
