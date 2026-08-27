import XCTest
@testable import VietDrive

@MainActor
final class AppSessionModelTests: XCTestCase {
    func testEveryNewSessionStartsAtOnboarding() {
        let session = AppSessionModel()
        XCTAssertEqual(session.stage, .onboarding)
    }

    func testPrototypeCredentialsAreExact() {
        let session = AppSessionModel()
        session.finishOnboarding()
        XCTAssertFalse(session.login(username: "Admin", password: "admin"))
        XCTAssertFalse(session.login(username: "admin", password: "wrong"))
        XCTAssertTrue(session.login(username: "admin", password: "admin"))
        XCTAssertEqual(session.stage, .drive)
        XCTAssertEqual(session.username, "admin")
    }

    func testLogoutReturnsToLoginWithoutRepeatingOnboarding() {
        let session = AppSessionModel()
        session.finishOnboarding()
        XCTAssertTrue(session.login(username: "admin", password: "admin"))
        session.logout()
        XCTAssertEqual(session.stage, .login)
        XCTAssertTrue(session.username.isEmpty)
    }
}
