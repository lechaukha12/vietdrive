import XCTest
@testable import VietDrive

final class VoiceAlertServiceTests: XCTestCase {
    func testBorrowedVietMapCatalogAndPromptAreBundled() throws {
        let catalog = try XCTUnwrap(RecordedVoiceCatalog())

        XCTAssertEqual(catalog.manifest.schemaVersion, 2)
        XCTAssertEqual(catalog.manifest.voiceName, "Nữ miền Nam · dùng tạm nội bộ")
        XCTAssertEqual(
            try XCTUnwrap(catalog.url(for: "maneuver.now.left")).lastPathComponent,
            "turn_left.mp3"
        )
        XCTAssertEqual(
            try XCTUnwrap(catalog.url(for: "maneuver.300.right")).lastPathComponent,
            "300_turn_right.mp3"
        )
        XCTAssertNil(catalog.manifest.prompts["alert.turn_restriction"])
    }

    func testLeftAndRightManeuversResolveToVietMapPromptKeys() {
        let left = step(id: 1, modifier: "left")
        let right = step(id: 2, modifier: "right")

        XCTAssertEqual(
            VoiceAlertService.maneuverPromptKey(step: left, stage: 1),
            "maneuver.300.left"
        )
        XCTAssertEqual(
            VoiceAlertService.maneuverPromptKey(step: left, stage: 2),
            "maneuver.now.left"
        )
        XCTAssertEqual(
            VoiceAlertService.maneuverPromptKey(step: right, stage: 1),
            "maneuver.300.right"
        )
        XCTAssertEqual(
            VoiceAlertService.maneuverPromptKey(step: right, stage: 2),
            "maneuver.now.right"
        )
    }

    func testTurnRestrictionAlertsAreAlwaysSilent() {
        let relationRestriction = alert(kind: .turnRestriction, signCode: "no_left_turn")
        let physicalNoRightTurnSign = alert(kind: .roadSign, signCode: "P103c")
        let physicalNoLeftTurnSign = alert(kind: .roadSign, signCode: "P123a")
        let camera = alert(kind: .camera, signCode: nil)

        XCTAssertTrue(VoiceAlertService.isSilentTurnRestriction(relationRestriction))
        XCTAssertTrue(VoiceAlertService.isSilentTurnRestriction(physicalNoRightTurnSign))
        XCTAssertTrue(VoiceAlertService.isSilentTurnRestriction(physicalNoLeftTurnSign))
        XCTAssertFalse(VoiceAlertService.isSilentTurnRestriction(camera))
    }

    private func alert(kind: AlertKind, signCode: String?) -> DriveAlert {
        DriveAlert(
            id: 1,
            kind: kind,
            speedLimit: 0,
            latitude: 10.77,
            longitude: 106.70,
            message: "Test",
            province: "",
            distanceMeters: 200,
            signCode: signCode
        )
    }

    private func step(id: Int, modifier: String) -> NavigationStep {
        NavigationStep(
            id: id,
            instruction: modifier == "left" ? "Rẽ trái" : "Rẽ phải",
            roadName: "Đường thử nghiệm",
            type: "turn",
            modifier: modifier,
            coordinate: .init(latitude: 10.77, longitude: 106.70),
            distanceAlongRouteMeters: 1_000
        )
    }
}
