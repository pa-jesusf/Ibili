import XCTest
@testable import Ibili

final class AppVersionTests: XCTestCase {
    func testDisplayStringIncludesBuildNumber() {
        let version = AppVersion(marketingVersion: "0.2.0", buildNumber: "12")

        XCTAssertEqual(version.displayString, "0.2.0 (12)")
    }

    func testDisplayStringOmitsEmptyBuildNumber() {
        let version = AppVersion(marketingVersion: "0.2.0", buildNumber: "")

        XCTAssertEqual(version.displayString, "0.2.0")
    }
}
