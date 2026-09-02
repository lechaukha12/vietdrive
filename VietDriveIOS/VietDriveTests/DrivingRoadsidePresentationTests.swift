import XCTest
@testable import VietDrive

final class DrivingRoadsidePresentationTests: XCTestCase {
    func testOnlyIncomingValidAlertsAreUsedInDistanceOrder() {
        let alerts = [alert(4, distance: 900), alert(2, distance: 200), alert(1, distance: 20),
                      alert(3, distance: 400), alert(1, distance: 20),
                      alert(5, distance: -.infinity), alert(6, distance: .nan),
                      alert(7, distance: -1), alert(8, distance: 2_501)]
        XCTAssertEqual(DrivingSignPassage().upcoming(from: alerts).map(\.id), [1, 2, 3])
        XCTAssertTrue(DrivingSignPassage().upcoming(from: []).isEmpty)
    }

    func testPassingDoesNotLetUnsignedDistanceBringSignBack() {
        var passage = DrivingSignPassage()
        let sign = alert(1, distance: 40, northMeters: 40)
        passage.update(sample([sign]))
        XCTAssertEqual(passage.upcoming(from: [sign]).map(\.id), [1])
        passage.update(sample([alert(1, distance: 20, northMeters: 40)], carNorth: 60))
        XCTAssertEqual(passage.passedIDs, [1])
        passage.update(sample([alert(1, distance: 30, northMeters: 40)], carNorth: 70, speed: 0))
        XCTAssertTrue(passage.upcoming(from: [sign]).isEmpty)
        XCTAssertEqual(passage.upcoming(from: [sign, alert(2, distance: 200)]).map(\.id), [2])
    }

    func testUTurnCanRearmAnIncomingSign() {
        var passage = DrivingSignPassage()
        let sign = alert(1, distance: 60, northMeters: 0)
        passage.update(sample([sign], carNorth: 60))
        XCTAssertEqual(passage.passedIDs, [1])
        passage.update(sample([sign], carNorth: 60, heading: 180))
        XCTAssertTrue(passage.passedIDs.isEmpty)
        XCTAssertEqual(passage.upcoming(from: [sign]).count, 1)
    }

    func testStationaryNoGPSAndPoorFixDoNotMarkPassed() {
        let sign = alert(1, distance: 50)
        for input in [sample([sign], carNorth: 50, speed: 0),
                      sample([sign], carNorth: 50, gps: false),
                      sample([sign], carNorth: 50, accuracy: 100),
                      sample([sign], carNorth: 50, accuracy: .nan),
                      sample([sign], carNorth: 50, heading: .nan)] {
            var passage = DrivingSignPassage()
            passage.update(input)
            XCTAssertTrue(passage.passedIDs.isEmpty)
        }
    }

    func testGPSJitterAndDistantSignsAreNotTreatedAsPassed() {
        var passage = DrivingSignPassage()
        passage.update(sample([alert(1, distance: 5)], carNorth: 5))
        passage.update(sample([alert(1, distance: 20)], carNorth: 20, accuracy: 30))
        passage.update(sample([alert(1, distance: 500)], carNorth: 50))
        XCTAssertTrue(passage.passedIDs.isEmpty)
    }

    func testPassageMemoryIsPrunedWhenEngineRemovesSign() {
        var passage = DrivingSignPassage()
        passage.update(sample([alert(1, distance: 50)], carNorth: 50))
        XCTAssertEqual(passage.passedIDs, [1])
        passage.update(sample([]))
        XCTAssertTrue(passage.passedIDs.isEmpty)
    }

    func testPassageDoesNotMutateAlertData() {
        let sign = alert(1, distance: 50)
        let original = sign
        var passage = DrivingSignPassage()
        passage.update(sample([sign], carNorth: 50))
        XCTAssertEqual(sign, original)
        XCTAssertEqual(sign.distanceMeters, 50)
    }

    func testPerspectiveMovesNearerSignsDownRightAndMakesThemLarger() {
        let size = CGSize(width: 357, height: 430)
        let far = DrivingRoadsideLayout.placements(alerts: [alert(1, distance: 1_000)], size: size)[0]
        let near = DrivingRoadsideLayout.placements(alerts: [alert(1, distance: 20)], size: size)[0]
        XCTAssertGreaterThan(near.depth, far.depth)
        XCTAssertGreaterThan(near.top, far.top)
        XCTAssertGreaterThan(near.x, far.x)
        XCTAssertGreaterThan(near.faceSize, far.faceSize)
        XCTAssertEqual(near.alert.distanceMeters, 20)
        XCTAssertEqual(DrivingRoadsideLayout.depth(distance: .nan), 0)
    }

    func testCrowdedSignsStayOrderedReadableAndInsideScene() {
        for size in [CGSize(width: 357, height: 430), CGSize(width: 339, height: 300),
                     CGSize(width: 450, height: 220), CGSize(width: 300, height: 130),
                     CGSize(width: 100, height: 80), CGSize(width: 250, height: 174)] {
            for distances: [Double] in [[0, 2, 3], [250, 450, 800], [2_300, 2_400, 2_500]] {
                let alerts = distances.enumerated().map { alert($0.offset + 1, distance: $0.element) }
                let placements = DrivingRoadsideLayout.placements(alerts: alerts, size: size)
                XCTAssertFalse(placements.isEmpty)
                for (index, placement) in placements.enumerated() {
                    XCTAssertGreaterThan(placement.x, size.width / 2)
                    XCTAssertGreaterThanOrEqual(placement.top, 0, "\(size), \(distances)")
                    XCTAssertLessThanOrEqual(placement.top + placement.height, size.height)
                    XCTAssertLessThanOrEqual(placement.x + placement.width / 2, size.width)
                    if index > 0 {
                        let previous = placements[index - 1]
                        XCTAssertGreaterThanOrEqual(placement.top + 0.001, previous.top + previous.readableHeight + 6)
                        XCTAssertLessThanOrEqual(placement.alert.distanceMeters, previous.alert.distanceMeters)
                        XCTAssertGreaterThanOrEqual(placement.faceSize, previous.faceSize)
                    }
                }
            }
        }
    }

    func testInvalidOrEmptySceneProducesNoPosts() {
        XCTAssertTrue(DrivingRoadsideLayout.placements(alerts: [alert(1, distance: 50)], size: .zero).isEmpty)
        XCTAssertTrue(DrivingRoadsideLayout.placements(alerts: [], size: CGSize(width: 357, height: 430)).isEmpty)
    }

    private func alert(_ id: Int, distance: Double, northMeters: Double = 0) -> DriveAlert {
        DriveAlert(id: id, kind: .roadSign, speedLimit: 0,
                   latitude: 10 + northMeters / 111_195, longitude: 106,
                   message: "Biển đã có trong dữ liệu", province: "", distanceMeters: distance,
                   signCode: "P130", assetName: TrafficSignCatalog.assetName(for: "P130"))
    }

    private func sample(_ alerts: [DriveAlert], carNorth: Double = 0, speed: Int = 40,
                        gps: Bool = true, accuracy: Double = 5, heading: Double = 0) -> DrivingSignPassage.Sample {
        .init(alerts: alerts, latitude: 10 + carNorth / 111_195, longitude: 106,
              heading: heading, speed: speed, hasGPS: gps, accuracy: accuracy)
    }
}
