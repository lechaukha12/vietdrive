import XCTest
@testable import VietDrive

@MainActor
final class AppSessionModelTests: XCTestCase {
    func testEveryNewSessionStartsAtOnboarding() {
        NavigationSessionStore.shared.clear()
        let session = AppSessionModel()
        XCTAssertEqual(session.stage, .onboarding)
    }

    func testPrototypeCredentialsAreExact() {
        NavigationSessionStore.shared.clear()
        let session = AppSessionModel()
        session.finishOnboarding()
        XCTAssertFalse(session.login(username: "Admin", password: "admin"))
        XCTAssertFalse(session.login(username: "admin", password: "wrong"))
        XCTAssertTrue(session.login(username: "admin", password: "admin"))
        XCTAssertEqual(session.stage, .drive)
        XCTAssertEqual(session.username, "admin")
    }

    func testLogoutReturnsToLoginWithoutRepeatingOnboarding() {
        NavigationSessionStore.shared.clear()
        let session = AppSessionModel()
        session.finishOnboarding()
        XCTAssertTrue(session.login(username: "admin", password: "admin"))
        UserDefaults.standard.set(true, forKey: NavigationSessionStore.activeDefaultsKey)
        session.logout()
        XCTAssertEqual(session.stage, .login)
        XCTAssertTrue(session.username.isEmpty)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: NavigationSessionStore.activeDefaultsKey))
    }
}
