import Foundation

@MainActor
final class PlayerRuntimeCoordinator {
    static let shared = PlayerRuntimeCoordinator()
    private static let teardownGrace: TimeInterval = 2.0

    private var viewModels: [PlayerSessionID: PlayerViewModel] = [:]
    private var pendingTeardownWork: [PlayerSessionID: DispatchWorkItem] = [:]
    private var pendingTeardownTokens: [PlayerSessionID: UUID] = [:]
    private var pictureInPictureRouteID: PlayerSessionID?
    private var pictureInPictureSnapshot: DeepLinkRouter.SessionSnapshot?

    func viewModel(for routeID: PlayerSessionID) -> PlayerViewModel {
        cancelPendingTeardown(for: routeID)
        if let existing = viewModels[routeID] {
            return existing
        }
        let viewModel = PlayerViewModel(sessionID: routeID)
        viewModels[routeID] = viewModel
        return viewModel
    }

    func setPictureInPictureActive(_ isActive: Bool,
                                   for routeID: PlayerSessionID,
                                   snapshot: DeepLinkRouter.SessionSnapshot? = nil) {
        if isActive {
            cancelPendingTeardown(for: routeID)
            pictureInPictureRouteID = routeID
            pictureInPictureSnapshot = snapshot
        } else if pictureInPictureRouteID == routeID {
            pictureInPictureRouteID = nil
            pictureInPictureSnapshot = nil
        }
    }

    func pictureInPictureSnapshot(for routeID: PlayerSessionID) -> DeepLinkRouter.SessionSnapshot? {
        guard pictureInPictureRouteID == routeID else { return nil }
        return pictureInPictureSnapshot
    }

    func handle(_ event: PlayerSessionEvent, for routeID: PlayerSessionID) {
        guard let viewModel = viewModels[routeID] else { return }
        viewModel.handle(event)
    }

    func prepareForDismissal(routeID: PlayerSessionID) {
        guard let viewModel = viewModels[routeID] else { return }
        viewModel.prepareForDismissal()
    }

    func retainSessions(root: DeepLinkRouter.PlayerRoute?, stack: [DeepLinkRouter.PlayerRoute]) {
        var retainedIDs = Set(([root].compactMap { $0?.id }) + stack.map(\.id))
        if let pictureInPictureRouteID {
            retainedIDs.insert(pictureInPictureRouteID)
        }
        for routeID in retainedIDs {
            cancelPendingTeardown(for: routeID)
        }
        let staleSessions = viewModels.filter { !retainedIDs.contains($0.key) }
        for (routeID, viewModel) in staleSessions {
            scheduleTeardown(for: routeID, viewModel: viewModel)
        }
    }

    private func cancelPendingTeardown(for routeID: PlayerSessionID) {
        pendingTeardownWork.removeValue(forKey: routeID)?.cancel()
        pendingTeardownTokens.removeValue(forKey: routeID)
    }

    private func scheduleTeardown(for routeID: PlayerSessionID, viewModel: PlayerViewModel) {
        guard pendingTeardownWork[routeID] == nil else { return }
        viewModel.prepareForDismissal()
        let token = UUID()
        pendingTeardownTokens[routeID] = token
        AppLog.debug("player", "延迟销毁播放器会话", metadata: [
            "routeID": routeID.uuidString,
            "delayMs": String(Int(Self.teardownGrace * 1000)),
        ])
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.pendingTeardownTokens[routeID] == token else { return }
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
