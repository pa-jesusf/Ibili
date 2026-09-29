import XCTest
import Network
@testable import Ibili

final class HLSProxyListenerTests: XCTestCase {
    func testConcurrentCallersShareListenerAndOneCancellationDoesNotStopIt() async throws {
        let listener = HLSProxyListener()
        let first = Task { try await listener.port { $0.cancel() } }
        let second = Task { try await listener.port { $0.cancel() } }
        first.cancel()
        let secondPort = try await second.value
        let firstPort = try await first.value
        XCTAssertGreaterThan(secondPort, 0)
        XCTAssertEqual(firstPort, secondPort)
        let healthy = await listener.isHealthy()
        XCTAssertTrue(healthy)
        let reused = try await listener.port { $0.cancel() }
        XCTAssertEqual(reused, secondPort)
    }
}
