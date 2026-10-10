import AVFoundation
import MediaPlayer
import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import Ibili

@MainActor
final class PlayerNowPlayingTests: XCTestCase {
    private func drain() async { for _ in 0..<100 { await Task.yield() } }

    private func image() -> PlayerNowPlayingImage {
        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        #else
        return NSImage(size: CGSize(width: 8, height: 8))
        #endif
    }

    func testActivationBeforeLoadingPublishesTitleAndArtworkWithoutPictureInPictureReactivation() async {
        let store = NowPlayingTestStore(), owner = NowPlayingTestOwner()
        let coordinator = PlayerNowPlayingCoordinator(infoStore: store, registersRemoteCommands: false) { _ in self.image() }
        coordinator.activate(owner)
        XCTAssertNil(store.nowPlayingInfo)
        owner.prepare(title: "前台视频", artwork: "https://example.test/cover.png")
        coordinator.refresh(for: owner)
        await drain()
        XCTAssertEqual(store.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "前台视频")
        XCTAssertEqual(store.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String, "UP 主")
        XCTAssertNotNil(store.nowPlayingInfo?[MPMediaItemPropertyArtwork])
        XCTAssertEqual(store.playbackState, .playing)
        coordinator.unregister(owner)
    }

    func testLoadingCandidateRemainsPreferredAcrossTemporaryPlayerRemoval() async {
        let store = NowPlayingTestStore(), owner = NowPlayingTestOwner()
        let coordinator = PlayerNowPlayingCoordinator(infoStore: store, registersRemoteCommands: false) { _ in self.image() }
        owner.prepare(title: "旧分 P", artwork: nil)
        coordinator.activate(owner)
        owner.player = nil
        coordinator.refresh(for: owner)
        XCTAssertNil(store.nowPlayingInfo)
        owner.prepare(title: "新分 P", artwork: nil)
        coordinator.refresh(for: owner)
        XCTAssertEqual(store.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "新分 P")
        coordinator.unregister(owner)
        coordinator.refresh(for: owner)
        XCTAssertNil(store.nowPlayingInfo)
    }

    func testPlaybackRefreshesSharePendingArtworkAndRetryAfterFailure() async {
        let store = NowPlayingTestStore(), owner = NowPlayingTestOwner()
        var requests = 0
        var finish: CheckedContinuation<PlayerNowPlayingImage?, Never>?
        let coordinator = PlayerNowPlayingCoordinator(infoStore: store, registersRemoteCommands: false) { _ in
            requests += 1
            return await withCheckedContinuation { finish = $0 }
        }
        owner.prepare(title: "视频", artwork: "https://example.test/one.png")
        coordinator.activate(owner); await drain()
        for _ in 0..<20 { coordinator.refresh(for: owner) }
        await drain()
        XCTAssertEqual(requests, 1)
        finish?.resume(returning: nil); await drain()
        coordinator.refresh(for: owner); await drain()
        XCTAssertEqual(requests, 2)
        finish?.resume(returning: image()); await drain()
        for _ in 0..<20 { coordinator.refresh(for: owner) }
        await drain()
        XCTAssertEqual(requests, 2)
        XCTAssertNotNil(store.nowPlayingInfo?[MPMediaItemPropertyArtwork])
        coordinator.unregister(owner)
    }

    func testOldArtworkCannotOverwriteNewOwnerOrReappearAfterArtworkIsRemoved() async {
        let store = NowPlayingTestStore(), a = NowPlayingTestOwner(), b = NowPlayingTestOwner()
        var pending: [String: CheckedContinuation<PlayerNowPlayingImage?, Never>] = [:]
        let coordinator = PlayerNowPlayingCoordinator(infoStore: store, registersRemoteCommands: false) { url in
            await withCheckedContinuation { pending[url] = $0 }
        }
        a.prepare(title: "A", artwork: "a")
        coordinator.activate(a); await drain()
        coordinator.activate(b) // B is not ready yet; A's late title cannot become preferred again.
        b.prepare(title: "B", artwork: "b")
        coordinator.refresh(for: b); await drain()
        pending["a"]?.resume(returning: image()); await drain()
        coordinator.refresh(for: a)
        XCTAssertEqual(store.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "B")
        XCTAssertNil(store.nowPlayingInfo?[MPMediaItemPropertyArtwork])
        b.prepare(title: "B 无封面", artwork: nil)
        coordinator.refresh(for: b)
        pending["b"]?.resume(returning: image()); await drain()
        XCTAssertNil(store.nowPlayingInfo?[MPMediaItemPropertyArtwork])
        XCTAssertEqual(store.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "B 无封面")
        coordinator.unregister(b)
        XCTAssertNil(store.nowPlayingInfo)
    }
}

@MainActor
private final class NowPlayingTestStore: PlayerNowPlayingInfoStore {
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .stopped
}

@MainActor
private final class NowPlayingTestOwner: PlayerSystemMediaSessionOwner {
    var player: AVPlayer?
    let currentAid: Int64 = 1
    let currentCid: Int64 = 2
    var nowPlayingMetadata: PlayerNowPlayingMetadata?
    var shouldExposeSystemMediaSession: Bool { player != nil && nowPlayingMetadata != nil }
    let systemMediaSessionDebugMetadata: [String: String] = [:]
    let currentElapsedPlaybackTime: TimeInterval? = 10
    let systemMediaPlaybackRate: Float = 1
    let systemMediaDefaultRate: Float = 1
    func handleRemotePlaybackIntent(_ intent: PlayerIntent) {}
    func prepare(title: String, artwork: String?) {
        player = AVPlayer()
        nowPlayingMetadata = .init(title: title, artist: "UP 主", artworkURL: artwork, duration: 100)
    }
}
