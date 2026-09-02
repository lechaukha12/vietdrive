import XCTest
@testable import VietDrive

@MainActor
final class PlatformDriveCoordinatorTests: XCTestCase {
    func testCompanionPayloadFiltersCameraAlert() {
        var snapshot = DriveSnapshot()
        snapshot.speedKmh = 63
        snapshot.speedLimitKmh = 60
        snapshot.primaryAlert = alert(kind: .camera)

        let state = PlatformDriveCoordinator.makeCompanionState(
            snapshot: snapshot,
            isNavigating: true
        )

        XCTAssertEqual(state.speedKmh, 63)
        XCTAssertEqual(state.speedLimitKmh, 60)
        XCTAssertNil(state.safetyAlertID)
        XCTAssertNil(state.signAssetName)
    }

    func testCompanionPayloadIncludesProhibitorySign() throws {
        var snapshot = DriveSnapshot()
        snapshot.primaryAlert = alert(kind: .roadSign)

        let state = PlatformDriveCoordinator.makeCompanionState(
            snapshot: snapshot,
            isNavigating: false
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PlatformDriveState.self, from: encoded)

        XCTAssertEqual(decoded.safetyAlertID, 101)
        XCTAssertEqual(decoded.signCode, "P.123a")
        XCTAssertEqual(decoded.signAssetName, "TrafficSign_P123a")
        XCTAssertEqual(decoded.safetyAlertDistanceMeters, 320)
    }

    private func alert(kind: AlertKind) -> DriveAlert {
        DriveAlert(
            id: 101,
            kind: kind,
            speedLimit: 0,
            latitude: 10.77,
            longitude: 106.7,
            message: "Cấm rẽ trái",
            province: "TP. Hồ Chí Minh",
            distanceMeters: 320,
            signCode: "P.123a",
            assetName: "TrafficSign_P123a",
            source: "map-data/edogen.bin"
        )
    }
}
