import XCTest
@testable import Ibili

final class AppUpdateServiceTests: XCTestCase {
    func testReleaseVersionComparisonIgnoresVPrefix() {
        XCTAssertTrue(AppUpdateService.isNewer("v0.2.0", than: "0.1.0"))
        XCTAssertFalse(AppUpdateService.isNewer("v0.1.0", than: "0.1.0"))
        XCTAssertFalse(AppUpdateService.isNewer("v0.0.9", than: "0.1.0"))
    }

    func testReleaseVersionComparisonPadsMissingComponents() {
        XCTAssertFalse(AppUpdateService.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(AppUpdateService.isNewer("1.0.1", than: "1.0"))
    }

    func testReleaseVersionFallsBackToReleaseNameWhenTagIsNotVersioned() {
        XCTAssertEqual(
            AppUpdateService.releaseVersion(tagName: "release", name: "v0.2.0"),
            "v0.2.0"
        )
        XCTAssertNil(
            AppUpdateService.releaseVersion(tagName: "release", name: "First release")
        )
    }
}
