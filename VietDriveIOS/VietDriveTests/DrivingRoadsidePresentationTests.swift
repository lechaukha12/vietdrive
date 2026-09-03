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
                    XCTAssertGreaterThanOrEqual(placement.x - placement.width / 2, 0)
                    XCTAssertLessThanOrEqual(placement.x + placement.width / 2, size.width)
                    if index > 0 {
                        let previous = placements[index - 1]
                        XCTAssertLessThanOrEqual(placement.alert.distanceMeters, previous.alert.distanceMeters)
                        XCTAssertGreaterThanOrEqual(placement.faceSize, previous.faceSize)
                    }
                    if let previous = placements[..<index].last {
                        XCTAssertGreaterThanOrEqual(placement.top + 0.001, previous.top + previous.readableHeight + 6)
                    }
                    let base = placement.top + placement.height
                    let depth = (base / size.height - 0.04) / 0.92
                    let edge = DrivingRibbon.point(depth: depth, side: 1, size: size)
                    XCTAssertEqual(placement.x, edge.x, accuracy: 0.001)
                    XCTAssertEqual(base, edge.y, accuracy: 0.001)
                }
            }
        }
    }

    func testSignsAtEqualDistanceAllRemainOnRightWithoutDuplication() {
        for size in [CGSize(width: 357, height: 430), .init(width: 780, height: 180)] {
            for distance in [0.0, 150, 500, 2_500] {
                let posts = DrivingRoadsideLayout.placements(alerts: [alert(1, distance: distance), alert(2, distance: distance)], size: size)
                XCTAssertEqual(Set(posts.map(\.id)), [1, 2])
                XCTAssertEqual(posts.count, 2)
                XCTAssertTrue(posts.allSatisfy { $0.x > size.width / 2 })
                XCTAssertEqual(posts[0].faceSize, posts[1].faceSize, accuracy: 0.001)
            }
        }
    }

    func testSignsNeverMoveToLeftWhenReorderedOrOnePasses() {
        let initial = [alert(1, distance: 100), alert(2, distance: 200), alert(3, distance: 300)]
        let reordered = [alert(3, distance: 90), alert(1, distance: 100), alert(2, distance: 110)]
        let next = [alert(3, distance: 90), alert(4, distance: 200), alert(5, distance: 300)]
        let size = CGSize(width: 357, height: 430)
        for input in [initial, reordered, next] {
            let placements = DrivingRoadsideLayout.placements(alerts: input, size: size)
            XCTAssertEqual(Set(placements.map(\.id)), Set(input.map(\.id)))
            XCTAssertTrue(placements.allSatisfy { $0.x > size.width / 2 })
            XCTAssertTrue(placements.allSatisfy { input.contains($0.alert) })
        }
    }

    func testLandmarkCaptionsClearRightSideSigns() throws {
        let size = CGSize(width: 357, height: 430)
        let posts = DrivingRoadsideLayout.placements(
            alerts: [alert(1, distance: 300), alert(2, distance: 330), alert(3, distance: 650)], size: size)
        let rects = posts.map { CGRect(x: $0.x - $0.width / 2, y: $0.top, width: $0.width, height: $0.readableHeight) }
        let caption = try XCTUnwrap(DrivingRibbon.captionFrame(preferredY: posts[1].top + 10, width: 160,
                                                              size: size, excluding: rects))
        XCTAssertFalse(rects.contains { $0.intersects(caption) })
        XCTAssertEqual(caption.midX, size.width / 2)
        XCTAssertNil(DrivingRibbon.captionFrame(preferredY: 150, width: 160, size: size,
                                               excluding: [.init(origin: .zero, size: size)]))
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
