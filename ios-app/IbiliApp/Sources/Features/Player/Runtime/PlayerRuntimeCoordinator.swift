import Foundation

@MainActor
final class PlayerRuntimeCoordinator {
    static let shared = PlayerRuntimeCoordinator()

    private var viewModels: [PlayerSessionID: PlayerViewModel] = [:]
    private var pictureInPictureRouteID: PlayerSessionID?
    private var pictureInPictureSnapshot: DeepLinkRouter.SessionSnapshot?

    func viewModel(for routeID: PlayerSessionID) -> PlayerViewModel {
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

    func retainSessions(root: DeepLinkRouter.PlayerRoute?, stack: [DeepLinkRouter.PlayerRoute]) {
        var retainedIDs = Set(([root].compactMap { $0?.id }) + stack.map(\.id))
        if let pictureInPictureRouteID {
            retainedIDs.insert(pictureInPictureRouteID)
        }
        for (routeID, viewModel) in viewModels where !retainedIDs.contains(routeID) {
            viewModel.teardown()
            viewModels.removeValue(forKey: routeID)
        }
    }
}