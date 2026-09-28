import XCTest
import Combine
@testable import Ibili

final class AppSessionTests: XCTestCase {
    @MainActor
    private func waitForCheck(_ session: AppSession) async {
        let done = expectation(description: "connection result")
        let subscription = session.$isCheckingConnection.drop(while: { $0 }).prefix(1)
            .sink { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    private var credentials: PersistedSessionDTO {
        PersistedSessionDTO(accessToken: "test-token", refreshToken: "", mid: 42,
                            expiresAtSecs: 0, webCookies: [["SESSDATA", "test-cookie"]])
    }

    @MainActor
    func testOfflineStartupPreservesCredentialsAndReconnects() async {
        var cleared = 0
        var checks = 0
        let services = AppSessionServices(load: { self.credentials }, save: { _ in }, restore: { _ in },
            clear: { cleared += 1 }, logout: {}, check: {
                checks += 1
                if checks == 1 { throw URLError(.notConnectedToInternet) }
                return SessionSnapshotDTO(loggedIn: true, mid: 42, expiresAtSecs: 0)
            })
        let session = AppSession(services: services)
        XCTAssertEqual(checks, 0) // Initializer must not access the network.
        session.start()
        await waitForCheck(session)
        guard case .offline = session.connectionState else { return XCTFail("expected offline") }
        XCTAssertTrue(session.isLoggedIn)
        XCTAssertEqual(cleared, 0)
        session.reconnect()
        await waitForCheck(session)
        XCTAssertEqual(session.connectionState, .online)
        XCTAssertEqual(cleared, 0)
    }

    @MainActor
    func testExpiredSessionEntersOfflineThenOffersLoginOnReconnect() async {
        var cleared = 0
        let session = AppSession(services: AppSessionServices(
            load: { self.credentials }, save: { _ in }, restore: { _ in },
            clear: { cleared += 1 }, logout: {},
            check: { SessionSnapshotDTO(loggedIn: false, mid: 0, expiresAtSecs: 0) }))
        session.start()
        await waitForCheck(session)
        guard case .offline = session.connectionState else { return XCTFail("expected offline") }
        XCTAssertFalse(session.isLoggedIn)
        XCTAssertEqual(cleared, 1)
        session.reconnect()
        await waitForCheck(session)
        XCTAssertEqual(session.connectionState, .login)
    }

    @MainActor
    func testFirstLaunchOnlineOpensLogin() async {
        let session = AppSession(services: AppSessionServices(
            load: { nil }, save: { _ in }, restore: { _ in }, clear: {}, logout: {},
            check: { SessionSnapshotDTO(loggedIn: false, mid: 0, expiresAtSecs: 0) }))
        session.start()
        await waitForCheck(session)
        XCTAssertEqual(session.connectionState, .login)
    }

    @MainActor
    func testLateReconnectCannotUndoNewLogin() async {
        let entered = expectation(description: "check started")
        let finished = expectation(description: "check returned")
        var continuation: CheckedContinuation<SessionSnapshotDTO, Never>?
        let session = AppSession(services: AppSessionServices(
            load: { nil }, save: { _ in }, restore: { _ in }, clear: {}, logout: {},
            check: {
                let snapshot = await withCheckedContinuation {
                    continuation = $0
                    entered.fulfill()
                }
                finished.fulfill()
                return snapshot
            }))
        session.start()
        await fulfillment(of: [entered], timeout: 2)
        session.didLogin(credentials)
        continuation?.resume(returning: SessionSnapshotDTO(loggedIn: false, mid: 0, expiresAtSecs: 0))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(session.connectionState, .online)
        XCTAssertEqual(session.mid, 42)
    }

    @MainActor
    func testRequestLoginPreservesCredentialsAndRejectsLateReconnect() async {
        let entered = expectation(description: "reconnect started")
        let finished = expectation(description: "reconnect returned")
        var continuation: CheckedContinuation<SessionSnapshotDTO, Never>?
        var cleared = 0
        let session = AppSession(services: AppSessionServices(
            load: { self.credentials }, save: { _ in }, restore: { _ in },
            clear: { cleared += 1 }, logout: {}, check: {
                let snapshot = await withCheckedContinuation {
                    continuation = $0
                    entered.fulfill()
                }
                finished.fulfill()
                return snapshot
            }))
        session.reconnect()
        await fulfillment(of: [entered], timeout: 2)
        session.requestLogin()
        continuation?.resume(returning: SessionSnapshotDTO(loggedIn: false, mid: 0, expiresAtSecs: 0))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(session.connectionState, .login)
        XCTAssertTrue(session.isLoggedIn)
        XCTAssertEqual(session.mid, 42)
        XCTAssertEqual(cleared, 0)
        XCTAssertFalse(session.isCheckingConnection)
    }
}
