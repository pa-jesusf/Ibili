import AVKit
import UIKit

enum PlayerFullscreenContentOrientation: Equatable {
    case portrait
    case landscape
}

struct PlayerFullscreenOrientationResolver {
    static let initialLandscapeMask: UIInterfaceOrientationMask = .landscapeRight

    static func contentOrientation(
        presentationSize: CGSize,
        sourceSizeHint: CGSize?,
        unknownFallback: PlayerFullscreenContentOrientation = .landscape
    ) -> PlayerFullscreenContentOrientation {
        if let size = normalizedSize(presentationSize) {
            return size.width > size.height ? .landscape : .portrait
        }
        if let sourceSizeHint, let size = normalizedSize(sourceSizeHint) {
            return size.width > size.height ? .landscape : .portrait
        }
        return unknownFallback
    }

    static func targetMask(for orientation: PlayerFullscreenContentOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait:
            return .portrait
        case .landscape:
            return initialLandscapeMask
        }
    }

    static func targetInterfaceOrientation(
        for orientation: PlayerFullscreenContentOrientation,
        preferredLandscapeOrientation: UIInterfaceOrientation? = nil
    ) -> UIInterfaceOrientation {
        switch orientation {
        case .portrait:
            return .portrait
        case .landscape:
            if let preferredLandscapeOrientation,
               preferredLandscapeOrientation.isLandscape {
                return preferredLandscapeOrientation
            }
            return .landscapeRight
        }
    }

    static func mask(for interfaceOrientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .unknown: return nil
        @unknown default: return nil
        }
    }

    static func interfaceOrientation(for deviceOrientation: UIDeviceOrientation) -> UIInterfaceOrientation? {
        switch deviceOrientation {
        case .portrait:
            return .portrait
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown, .faceUp, .faceDown, .unknown:
            return nil
        @unknown default:
            return nil
        }
    }

    static func exitOrientation(
        entryOrientation: UIInterfaceOrientation,
        fullscreenOrientation: UIInterfaceOrientation?
    ) -> UIInterfaceOrientation {
        if entryOrientation.isPortrait {
            return .portrait
        }
        if entryOrientation.isLandscape,
           let fullscreenOrientation,
           fullscreenOrientation != .unknown,
           fullscreenOrientation != .portraitUpsideDown {
            return fullscreenOrientation
        }
        return entryOrientation.isLandscape ? entryOrientation : .portrait
    }

    private static func normalizedSize(_ size: CGSize) -> CGSize? {
        let width = abs(size.width)
        let height = abs(size.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

struct PlayerFullscreenOrientationOwner: Hashable {
    let sessionID: PlayerSessionID
    let controllerID: ObjectIdentifier
    let sceneID: ObjectIdentifier
}

struct PlayerFullscreenOrientationLeaseState: Equatable {
    enum Phase: Equatable {
        case entering
        case interactive
        case restoring
    }

    let owner: PlayerFullscreenOrientationOwner
    var target: UIInterfaceOrientation
    var phase: Phase
    let revision: UInt64
    var releasesWhenTargetIsReached = false

    var supportedMask: UIInterfaceOrientationMask {
        switch phase {
        case .interactive:
            return .allButUpsideDown
        case .entering, .restoring:
            return PlayerFullscreenOrientationResolver.mask(for: target) ?? .allButUpsideDown
        }
    }
}

struct PlayerFullscreenOrientationLeaseStore {
    private(set) var leases: [ObjectIdentifier: PlayerFullscreenOrientationLeaseState] = [:]
    private var nextRevision: UInt64 = 0

    @discardableResult
    mutating func acquire(
        owner: PlayerFullscreenOrientationOwner,
        target: UIInterfaceOrientation,
        phase: PlayerFullscreenOrientationLeaseState.Phase = .entering,
        renew: Bool = false
    ) -> Bool {
        if !renew, let existing = leases[owner.sceneID], existing.owner == owner {
            guard existing.target != target || existing.phase != phase else { return false }
            leases[owner.sceneID] = makeLease(owner: owner, target: target, phase: phase)
            return true
        }
        leases[owner.sceneID] = makeLease(owner: owner, target: target, phase: phase)
        return true
    }

    @discardableResult
    mutating func release(owner: PlayerFullscreenOrientationOwner) -> Bool {
        guard leases[owner.sceneID]?.owner == owner else { return false }
        leases.removeValue(forKey: owner.sceneID)
        return true
    }

    func lease(for owner: PlayerFullscreenOrientationOwner) -> PlayerFullscreenOrientationLeaseState? {
        guard let lease = leases[owner.sceneID], lease.owner == owner else { return nil }
        return lease
    }

    func lease(sceneID: ObjectIdentifier) -> PlayerFullscreenOrientationLeaseState? {
        leases[sceneID]
    }

    @discardableResult
    mutating func markForReleaseWhenTargetIsReached(
        owner: PlayerFullscreenOrientationOwner
    ) -> Bool {
        guard var lease = lease(for: owner) else { return false }
        lease.releasesWhenTargetIsReached = true
        leases[owner.sceneID] = lease
        return true
    }

    var soleLease: PlayerFullscreenOrientationLeaseState? {
        leases.count == 1 ? leases.values.first : nil
    }

    private mutating func makeLease(
        owner: PlayerFullscreenOrientationOwner,
        target: UIInterfaceOrientation,
        phase: PlayerFullscreenOrientationLeaseState.Phase
    ) -> PlayerFullscreenOrientationLeaseState {
        nextRevision &+= 1
        return PlayerFullscreenOrientationLeaseState(
            owner: owner,
            target: target,
            phase: phase,
            revision: nextRevision
        )
    }
}

struct PlayerFullscreenTransitionState: Equatable {
    enum Phase: Equatable {
        case inline
        case entering(UInt64)
        case fullscreen(UInt64)
        case exiting(UInt64)
    }

    private(set) var phase: Phase = .inline
    private var nextRevision: UInt64 = 0

    var isFullscreen: Bool {
        if case .fullscreen = phase { return true }
        return false
    }

    mutating func beginEntry() -> UInt64 {
        let revision = makeRevision()
        phase = .entering(revision)
        return revision
    }

    @discardableResult
    mutating func finishEntry(revision: UInt64, cancelled: Bool) -> Bool {
        guard phase == .entering(revision) else { return false }
        phase = cancelled ? .inline : .fullscreen(revision)
        return true
    }

    mutating func beginExit() -> UInt64 {
        let revision = makeRevision()
        phase = .exiting(revision)
        return revision
    }

    @discardableResult
    mutating func finishExit(revision: UInt64, cancelled: Bool) -> Bool {
        guard phase == .exiting(revision) else { return false }
        phase = cancelled ? .fullscreen(revision) : .inline
        return true
    }

    mutating func reset() {
        _ = makeRevision()
        phase = .inline
    }

    private mutating func makeRevision() -> UInt64 {
        nextRevision &+= 1
        return nextRevision
    }
}

@MainActor
final class PlayerFullscreenOrientationPolicy {
    static let shared = PlayerFullscreenOrientationPolicy()

    private final class SceneReference {
        weak var scene: UIWindowScene?
        weak var ownerController: AVPlayerViewController?
        weak var orientationController: UIViewController?
        let entryOrientation: UIInterfaceOrientation
        var effectiveGeometryObservation: NSKeyValueObservation?

        init(
            scene: UIWindowScene,
            ownerController: AVPlayerViewController,
            orientationController: UIViewController,
            entryOrientation: UIInterfaceOrientation
        ) {
            self.scene = scene
            self.ownerController = ownerController
            self.orientationController = orientationController
            self.entryOrientation = entryOrientation
        }
    }

    private struct PendingGeometryRequest {
        let leaseRevision: UInt64
        let requestRevision: UInt64
    }

    private var store = PlayerFullscreenOrientationLeaseStore()
    private var sceneReferences: [ObjectIdentifier: SceneReference] = [:]
    private var pendingGeometryRequests: [ObjectIdentifier: PendingGeometryRequest] = [:]
    private var nextGeometryRequestRevision: UInt64 = 0
    private var deviceOrientationObserver: NSObjectProtocol?
    private var lastObservedDeviceOrientation: UIDeviceOrientation?

    private init() {}

    func supportedInterfaceOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .landscape }
        let lease: PlayerFullscreenOrientationLeaseState?
        if let scene = window?.windowScene {
            lease = store.lease(sceneID: ObjectIdentifier(scene))
        } else {
            lease = store.soleLease
        }
        guard let lease else { return .allButUpsideDown }
        return lease.supportedMask
    }

    func supportedInterfaceOrientations(for scene: UIWindowScene) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .landscape }
        guard let lease = store.lease(sceneID: ObjectIdentifier(scene)) else {
            return .allButUpsideDown
        }
        return lease.supportedMask
    }

    func currentInterfaceOrientation(for controller: UIViewController) -> UIInterfaceOrientation? {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = controller.viewIfLoaded?.window?.windowScene else { return nil }
        return currentInterfaceOrientation(in: scene)
    }

    func acquire(
        sessionID: PlayerSessionID,
        ownerController: AVPlayerViewController,
        orientationController: UIViewController,
        target: PlayerFullscreenContentOrientation,
        entryOrientation: UIInterfaceOrientation,
        preferredLandscapeOrientation: UIInterfaceOrientation? = nil
    ) -> PlayerFullscreenOrientationOwner? {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = orientationController.viewIfLoaded?.window?.windowScene
                ?? ownerController.viewIfLoaded?.window?.windowScene else {
            return nil
        }

        let sceneID = ObjectIdentifier(scene)
        let owner = PlayerFullscreenOrientationOwner(
            sessionID: sessionID,
            controllerID: ObjectIdentifier(ownerController),
            sceneID: sceneID
        )
        sceneReferences[sceneID] = SceneReference(
            scene: scene,
            ownerController: ownerController,
            orientationController: orientationController,
            entryOrientation: entryOrientation
        )
        let targetOrientation = PlayerFullscreenOrientationResolver.targetInterfaceOrientation(
            for: target,
            preferredLandscapeOrientation: preferredLandscapeOrientation ?? entryOrientation
        )
        store.acquire(owner: owner, target: targetOrientation, phase: .entering, renew: true)
        refreshDeviceOrientationObservation()
        observeEffectiveGeometryIfAvailable(reference: sceneReferences[sceneID])
        invalidateSupportedOrientations(controller: orientationController, scene: scene)
        let currentOrientation = currentInterfaceOrientation(in: scene)
        let alreadyMatches = currentOrientation == targetOrientation
        AppLog.debug("player", "原生全屏方向租约已建立", metadata: [
            "sessionID": sessionID.uuidString,
            "entry": interfaceOrientationDescription(entryOrientation),
            "target": interfaceOrientationDescription(targetOrientation),
            "current": interfaceOrientationDescription(currentOrientation),
            "requiresGeometryUpdate": String(!alreadyMatches),
        ])
        if !alreadyMatches {
            requestGeometryUpdate(owner: owner)
        }
        return owner
    }

    func update(
        owner: PlayerFullscreenOrientationOwner,
        ownerController: AVPlayerViewController,
        target: PlayerFullscreenContentOrientation
    ) {
        guard store.lease(for: owner) != nil,
              let reference = sceneReferences[owner.sceneID],
              reference.ownerController === ownerController,
              let scene = reference.scene,
              ObjectIdentifier(ownerController) == owner.controllerID else { return }
        guard let lease = store.lease(for: owner), lease.phase == .entering else { return }
        let preferredLandscapeOrientation = lease.target.isLandscape
            ? lease.target
            : reference.entryOrientation
        let targetOrientation = PlayerFullscreenOrientationResolver.targetInterfaceOrientation(
            for: target,
            preferredLandscapeOrientation: preferredLandscapeOrientation
        )
        let targetChanged = store.acquire(owner: owner, target: targetOrientation, phase: .entering)
        guard targetChanged else { return }
        invalidateSupportedOrientations(controller: reference.orientationController, scene: scene)
        requestGeometryUpdate(owner: owner)
    }

    func beginInteractiveRotation(owner: PlayerFullscreenOrientationOwner) {
        guard let lease = store.lease(for: owner),
              let reference = sceneReferences[owner.sceneID],
              let scene = reference.scene else { return }
        let entryTarget = lease.target
        let current = currentInterfaceOrientation(in: scene)
        store.acquire(owner: owner, target: entryTarget, phase: .interactive, renew: true)
        pendingGeometryRequests.removeValue(forKey: owner.sceneID)
        refreshDeviceOrientationObservation()
        invalidateSupportedOrientations(controller: reference.orientationController, scene: scene)
        if current != entryTarget {
            requestGeometryUpdate(owner: owner)
        }
        AppLog.debug("player", "原生全屏已进入自由旋转阶段", metadata: [
            "sessionID": owner.sessionID.uuidString,
            "entryTarget": interfaceOrientationDescription(entryTarget),
            "current": interfaceOrientationDescription(current),
        ])
    }

    @discardableResult
    func beginRestoringExitOrientation(owner: PlayerFullscreenOrientationOwner) -> Bool {
        guard store.lease(for: owner) != nil,
              let reference = sceneReferences[owner.sceneID],
              let scene = reference.scene else { return false }
        let sceneOrientation = currentInterfaceOrientation(in: scene)
        let fullscreenOrientation: UIInterfaceOrientation?
        if let sceneOrientation, sceneOrientation != .unknown {
            fullscreenOrientation = sceneOrientation
        } else {
            fullscreenOrientation = store.lease(for: owner)?.target
        }
        let target = PlayerFullscreenOrientationResolver.exitOrientation(
            entryOrientation: reference.entryOrientation,
            fullscreenOrientation: fullscreenOrientation
        )
        store.acquire(owner: owner, target: target, phase: .restoring, renew: true)
        refreshDeviceOrientationObservation()
        invalidateSupportedOrientations(controller: reference.orientationController, scene: scene)
        AppLog.debug("player", "开始恢复全屏退出方向", metadata: [
            "sessionID": owner.sessionID.uuidString,
            "entry": interfaceOrientationDescription(reference.entryOrientation),
            "fullscreen": interfaceOrientationDescription(fullscreenOrientation),
            "target": interfaceOrientationDescription(target),
        ])
        requestGeometryUpdate(owner: owner)
        return true
    }

    func finishRestoringExitOrientation(owner: PlayerFullscreenOrientationOwner) {
        guard let lease = store.lease(for: owner),
              lease.phase == .restoring,
              let scene = sceneReferences[owner.sceneID]?.scene else { return }
        if currentInterfaceOrientation(in: scene) == lease.target {
            release(owner: owner)
            return
        }
        store.markForReleaseWhenTargetIsReached(owner: owner)
        // The first request is issued while AVKit is dismissing. Allow one fresh
        // request after that transition has completed.
        pendingGeometryRequests.removeValue(forKey: owner.sceneID)
        requestGeometryUpdate(owner: owner)
    }

    func resumeInteractiveRotation(owner: PlayerFullscreenOrientationOwner) {
        guard let lease = store.lease(for: owner),
              let reference = sceneReferences[owner.sceneID],
              let scene = reference.scene else { return }
        let current = currentInterfaceOrientation(in: scene) ?? lease.target
        store.acquire(
            owner: owner,
            target: current,
            phase: .interactive,
            renew: true
        )
        refreshDeviceOrientationObservation()
        invalidateSupportedOrientations(controller: reference.orientationController, scene: scene)
    }

    func enforceActiveOrientationIfNeeded(in scene: UIWindowScene) {
        let sceneID = ObjectIdentifier(scene)
        guard let lease = store.lease(sceneID: sceneID) else { return }
        guard lease.phase != .interactive else {
            pendingGeometryRequests.removeValue(forKey: sceneID)
            return
        }
        guard currentInterfaceOrientation(in: scene) != lease.target else {
            pendingGeometryRequests.removeValue(forKey: sceneID)
            if lease.releasesWhenTargetIsReached {
                release(owner: lease.owner)
            }
            return
        }
        guard pendingGeometryRequests[sceneID]?.leaseRevision != lease.revision else { return }
        AppLog.debug("player", "纠正全屏期间的方向偏离", metadata: [
            "sessionID": lease.owner.sessionID.uuidString,
            "target": interfaceOrientationDescription(lease.target),
            "current": interfaceOrientationDescription(currentInterfaceOrientation(in: scene)),
        ])
        requestGeometryUpdate(owner: lease.owner)
    }

    func release(owner: PlayerFullscreenOrientationOwner) {
        let releasedLease = store.lease(for: owner)
        guard store.release(owner: owner) else { return }
        refreshDeviceOrientationObservation()
        pendingGeometryRequests.removeValue(forKey: owner.sceneID)
        let reference = sceneReferences.removeValue(forKey: owner.sceneID)
        if let scene = reference?.scene {
            invalidateSupportedOrientations(controller: reference?.orientationController, scene: scene)
        }
        AppLog.debug("player", "原生全屏方向租约已释放", metadata: [
            "sessionID": owner.sessionID.uuidString,
            "target": releasedLease.map { interfaceOrientationDescription($0.target) } ?? "unknown",
            "current": interfaceOrientationDescription(reference?.scene.flatMap(currentInterfaceOrientation)),
        ])
    }

    func controller(for owner: PlayerFullscreenOrientationOwner) -> AVPlayerViewController? {
        guard store.lease(for: owner) != nil else { return nil }
        return sceneReferences[owner.sceneID]?.ownerController
    }

    func orientationController(for owner: PlayerFullscreenOrientationOwner) -> UIViewController? {
        guard store.lease(for: owner) != nil else { return nil }
        return sceneReferences[owner.sceneID]?.orientationController
    }

    private func requestGeometryUpdate(owner: PlayerFullscreenOrientationOwner) {
        guard let lease = store.lease(for: owner),
              let scene = sceneReferences[owner.sceneID]?.scene else {
            return
        }

        guard let mask = PlayerFullscreenOrientationResolver.mask(for: lease.target) else { return }
        guard pendingGeometryRequests[owner.sceneID]?.leaseRevision != lease.revision else { return }
        nextGeometryRequestRevision &+= 1
        let request = PendingGeometryRequest(
            leaseRevision: lease.revision,
            requestRevision: nextGeometryRequestRevision
        )
        pendingGeometryRequests[owner.sceneID] = request
        AppLog.debug("player", "请求原生全屏方向", metadata: [
            "sessionID": owner.sessionID.uuidString,
            "target": interfaceOrientationDescription(lease.target),
        ])
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self,
                      self.store.lease(for: owner)?.revision == lease.revision,
                      self.pendingGeometryRequests[owner.sceneID]?.requestRevision == request.requestRevision else {
                    return
                }
                self.pendingGeometryRequests.removeValue(forKey: owner.sceneID)
                AppLog.warning("player", "原生全屏方向请求失败", metadata: [
                    "sessionID": owner.sessionID.uuidString,
                    "target": self.interfaceOrientationDescription(lease.target),
                    "error": error.localizedDescription,
                ])
                if lease.releasesWhenTargetIsReached {
                    self.release(owner: owner)
                }
            }
        }
    }

    private func invalidateSupportedOrientations(controller: UIViewController?, scene: UIWindowScene) {
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private func refreshDeviceOrientationObservation() {
        let needsObservation = store.leases.values.contains { $0.phase == .interactive }
        if needsObservation, deviceOrientationObserver == nil {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            lastObservedDeviceOrientation = UIDevice.current.orientation
            deviceOrientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.handleDeviceOrientationChange()
                }
            }
        } else if !needsObservation, let deviceOrientationObserver {
            NotificationCenter.default.removeObserver(deviceOrientationObserver)
            self.deviceOrientationObserver = nil
            lastObservedDeviceOrientation = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }

    private func handleDeviceOrientationChange() {
        let deviceOrientation = UIDevice.current.orientation
        guard deviceOrientation != lastObservedDeviceOrientation else { return }
        lastObservedDeviceOrientation = deviceOrientation
        guard let target = PlayerFullscreenOrientationResolver.interfaceOrientation(
            for: deviceOrientation
        ) else { return }

        let interactiveOwners = store.leases.values.compactMap { lease in
            lease.phase == .interactive ? lease.owner : nil
        }
        for owner in interactiveOwners {
            applyInteractiveOrientation(target, owner: owner)
        }
    }

    private func applyInteractiveOrientation(
        _ target: UIInterfaceOrientation,
        owner: PlayerFullscreenOrientationOwner
    ) {
        guard store.lease(for: owner)?.phase == .interactive,
              let reference = sceneReferences[owner.sceneID],
              let scene = reference.scene else { return }
        _ = store.acquire(owner: owner, target: target, phase: .interactive)
        invalidateSupportedOrientations(controller: reference.orientationController, scene: scene)
        guard currentInterfaceOrientation(in: scene) != target else { return }
        requestGeometryUpdate(owner: owner)
    }

    private func observeEffectiveGeometryIfAvailable(reference: SceneReference?) {
        guard #available(iOS 26.0, *),
              let reference,
              reference.effectiveGeometryObservation == nil,
              let scene = reference.scene else { return }
        reference.effectiveGeometryObservation = scene.observe(\.effectiveGeometry, options: [.new]) { [weak self, weak scene] _, _ in
            DispatchQueue.main.async {
                guard let self, let scene else { return }
                self.recordInteractiveOrientationIfNeeded(in: scene)
                self.enforceActiveOrientationIfNeeded(in: scene)
            }
        }
    }

    private func recordInteractiveOrientationIfNeeded(in scene: UIWindowScene) {
        let sceneID = ObjectIdentifier(scene)
        guard let lease = store.lease(sceneID: sceneID),
              lease.phase == .interactive,
              let current = currentInterfaceOrientation(in: scene),
              current != .unknown else { return }
        _ = store.acquire(owner: lease.owner, target: current, phase: .interactive)
    }

    private func currentInterfaceOrientation(in scene: UIWindowScene) -> UIInterfaceOrientation? {
        if #available(iOS 26.0, *) {
            return scene.effectiveGeometry.interfaceOrientation
        }
        return scene.interfaceOrientation
    }

    private func interfaceOrientationDescription(_ orientation: UIInterfaceOrientation?) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .unknown: return "unknown"
        case nil: return "unavailable"
        @unknown default: return "future"
        }
    }

}
