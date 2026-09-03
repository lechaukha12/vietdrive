import AVFoundation
import CryptoKit
import XCTest
@testable import VietDrive

final class VoiceAlertServiceTests: XCTestCase {
    func testAdamCatalogAndPromptsAreBundled() throws {
        let catalog = try XCTUnwrap(RecordedVoiceCatalog())

        XCTAssertEqual(catalog.manifest.schemaVersion, 2)
        XCTAssertEqual(catalog.manifest.voiceName, "Adam · Nam miền Nam")
        XCTAssertEqual(catalog.manifest.baseDirectory, "VoicePacks/south_male_adam")
        XCTAssertEqual(
            try XCTUnwrap(catalog.url(for: "maneuver.now.left")).lastPathComponent,
            "turn_left.mp3"
        )
        XCTAssertEqual(
            try XCTUnwrap(catalog.url(for: "maneuver.300.right")).lastPathComponent,
            "300_turn_right.mp3"
        )
        XCTAssertEqual(
            try XCTUnwrap(catalog.url(for: "speed.next.60")).lastPathComponent,
            "next_speed_60.mp3"
        )
        XCTAssertEqual(
            try XCTUnwrap(catalog.url(for: "alert.camera.traffic")).lastPathComponent,
            "camera_traffic.mp3"
        )
        XCTAssertEqual(
            try XCTUnwrap(catalog.url(for: "alert.town.in")).lastPathComponent,
            "vao_kdc.mp3"
        )
        XCTAssertEqual(
            try XCTUnwrap(catalog.url(for: "preview")).lastPathComponent,
            "preview.mp3"
        )
        XCTAssertNil(catalog.manifest.prompts["alert.turn_restriction"])
    }

    func testEveryMappedPromptMatchesAdamChecksumAndDecodes() throws {
        let catalog = try XCTUnwrap(RecordedVoiceCatalog())
        let checksumURL = try XCTUnwrap(
            Bundle.main.url(forResource: "checksums", withExtension: "json",
                            subdirectory: catalog.manifest.baseDirectory)
                ?? Bundle.main.url(forResource: "checksums", withExtension: "json",
                                   subdirectory: "south_male_adam")
                ?? Bundle.main.url(forResource: "checksums", withExtension: "json")
        )
        let checksums = try JSONDecoder().decode(
            [String: AudioChecksum].self, from: Data(contentsOf: checksumURL)
        )
        XCTAssertEqual(checksums.count, 107)
        XCTAssertEqual(catalog.manifest.prompts.count, 104)
        XCTAssertEqual(Set(catalog.manifest.prompts.values).count, 104)

        for (key, filename) in catalog.manifest.prompts.sorted(by: { $0.key < $1.key }) {
            let url = try XCTUnwrap(catalog.url(for: key), "Missing audio for \(key)")
            let expected = try XCTUnwrap(checksums[filename], "Missing checksum for \(filename)")
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(data.count, expected.bytes, filename)
            XCTAssertEqual(hash, expected.sha256, filename)
            let player = try AVAudioPlayer(contentsOf: url)
            XCTAssertGreaterThan(player.duration, 0, filename)
            XCTAssertEqual(player.numberOfChannels, 1, filename)
        }
    }

    func testSectionCameraDoesNotPlayDualCameraRecording() throws {
        let catalog = try XCTUnwrap(RecordedVoiceCatalog())
        let announcement = try XCTUnwrap(TrafficSignCatalog.voiceAnnouncement(
            for: alert(kind: .camera, signCode: "CAMERA_SECTION"),
            distanceText: "khoảng 300 mét"
        ))
        XCTAssertEqual(announcement.promptKey, "alert.camera.section")
        XCTAssertTrue(announcement.message.contains("camera đo tốc độ theo đoạn"))
        XCTAssertEqual(
            catalog.url(for: "alert.camera.section")?.lastPathComponent,
            "camera_section.mp3"
        )
        XCTAssertEqual(catalog.url(for: "alert.camera.dual")?.lastPathComponent, "camera_ai.mp3")
    }

    func testEveryCatalogSignUsesBundledAdamRecording() throws {
        let catalog = try XCTUnwrap(RecordedVoiceCatalog())

        for definition in TrafficSignCatalog.definitions.values {
            let announcement = try XCTUnwrap(TrafficSignCatalog.voiceAnnouncement(
                for: alert(kind: .roadSign, signCode: definition.code),
                distanceText: "khoảng 300 mét"
            ), definition.code)
            XCTAssertNotNil(catalog.url(for: announcement.promptKey), definition.code)
        }
    }

    func testUnsupportedDynamicPromptsUseRecordedAdamFallbacks() throws {
        let catalog = try XCTUnwrap(RecordedVoiceCatalog())
        XCTAssertEqual(VoiceAlertService.speedPromptKey(limit: 110), "speed.generic")
        XCTAssertNotNil(catalog.url(for: "speed.generic"))

        let unknownManeuver = NavigationStep(
            id: 9,
            instruction: "Đi theo chỉ dẫn",
            roadName: "Đường thử nghiệm",
            type: "fork",
            modifier: "unknown",
            coordinate: .init(latitude: 10.77, longitude: 106.70),
            distanceAlongRouteMeters: 1_000
        )
        XCTAssertEqual(
            VoiceAlertService.maneuverPromptKey(step: unknownManeuver, stage: 2),
            "maneuver.generic"
        )
        XCTAssertNotNil(catalog.url(for: "maneuver.generic"))
        XCTAssertNotNil(catalog.url(for: "alert.generic"))
    }

    func testLeftAndRightManeuversResolveToRecordedPromptKeys() {
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

    func testOnlyInferredTurnRestrictionsAreSilent() {
        let relationRestriction = alert(kind: .turnRestriction, signCode: "no_left_turn")
        let physicalNoRightTurnSign = alert(kind: .roadSign, signCode: "P103c")
        let physicalNoLeftTurnSign = alert(kind: .roadSign, signCode: "P123a")
        let camera = alert(kind: .camera, signCode: nil)

        XCTAssertTrue(VoiceAlertService.isSilentTurnRestriction(relationRestriction))
        XCTAssertFalse(VoiceAlertService.isSilentTurnRestriction(physicalNoRightTurnSign))
        XCTAssertFalse(VoiceAlertService.isSilentTurnRestriction(physicalNoLeftTurnSign))
        XCTAssertFalse(VoiceAlertService.isSilentTurnRestriction(camera))
    }

    private struct AudioChecksum: Decodable {
        let bytes: Int
        let sha256: String
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
