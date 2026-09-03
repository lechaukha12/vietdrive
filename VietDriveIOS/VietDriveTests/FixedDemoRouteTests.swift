import CoreLocation
import XCTest
@testable import VietDrive

final class FixedDemoRouteTests: XCTestCase {
    func testBundledFixtureWorksWithoutRoutingProvider() throws {
        let route: NavigationRoute
        if Bundle.main.url(forResource: "saigon-phanthiet", withExtension: "json") != nil {
            route = try FixedDemoRoute.load()
        } else {
            let source = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("VietDrive/Resources/Demo/saigon-phanthiet.json")
            route = try FixedDemoRoute.decode(Data(contentsOf: source))
        }
        XCTAssertEqual(route.id, "offline-demo-saigon-phanthiet-v1")
        XCTAssertTrue(route.isCached)
        XCTAssertGreaterThan(route.coordinates.count, 1_000)
        XCTAssertTrue((160_000...180_000).contains(route.distanceMeters))
        XCTAssertEqual(route.coordinates.first!.latitude, 10.7754, accuracy: 0.001)
        XCTAssertEqual(route.coordinates.last!.longitude, 108.1077, accuracy: 0.001)
        XCTAssertTrue(zip(route.cumulativeDistances, route.cumulativeDistances.dropFirst()).allSatisfy { $0 <= $1 })
        var playback = try XCTUnwrap(RouteDemoPlayback(coordinates: route.coordinates))
        for fraction in [0.0, 0.25, 0.5, 0.75, 0.95, 1] {
            playback.seek(to: fraction)
            XCTAssertEqual(playback.progress, fraction, accuracy: 0.0001)
            XCTAssertTrue(CLLocationCoordinate2DIsValid(playback.sample().coordinate))
        }
    }

    func testCorruptFixtureIsRejected() {
        for json in [
            #"{"schemaVersion":2,"coordinates":[[106,10],[106,10.01]],"durationSeconds":20,"steps":[]}"#,
            #"{"schemaVersion":1,"coordinates":[[106,10],[108,12]],"durationSeconds":20,"steps":[]}"#,
            #"{"schemaVersion":1,"coordinates":[[106,10],[106,10.02]],"durationSeconds":20,"steps":[{"pointIndex":99,"roadName":"","type":"depart","modifier":""}]}"#
        ] { XCTAssertThrowsError(try FixedDemoRoute.decode(Data(json.utf8))) }
    }

    func testSeekClampsAndPreservesPause() throws {
        var playback = try XCTUnwrap(RouteDemoPlayback(coordinates: [
            .init(latitude: 10.7, longitude: 106.7), .init(latitude: 10.8, longitude: 106.7)
        ]))
        playback.pause()
        playback.seek(to: 0.5)
        XCTAssertTrue(playback.isPaused)
        XCTAssertEqual(playback.progress, 0.5)
        playback.seek(to: .nan)
        XCTAssertEqual(playback.progress, 0.5)
        playback.seek(to: 2)
        XCTAssertTrue(playback.isFinished)
        playback.seek(to: -1)
        playback.resume()
        playback.advance(by: 1)
        XCTAssertGreaterThan(playback.progress, 0)
        XCTAssertFalse(playback.isPaused)
    }
}
