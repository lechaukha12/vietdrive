import CoreLocation
import XCTest
@testable import VietDrive

final class RouteDemoPlaybackTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 10.7769, longitude: 106.7009)
    private func point(east: Double = 0, north: Double = 0) -> CLLocationCoordinate2D {
        .init(latitude: origin.latitude + north / 111_195,
              longitude: origin.longitude + east / (111_195 * cos(origin.latitude * .pi / 180)))
    }

    func testStartsAtSelectedOriginWithoutGPS() throws {
        let demo = try XCTUnwrap(RouteDemoPlayback(coordinates: [origin, point(north: 1_000)], speedKmh: 60))
        let sample = demo.sample()
        XCTAssertEqual(sample.coordinate.latitude, origin.latitude)
        XCTAssertEqual(sample.coordinate.longitude, origin.longitude)
        XCTAssertEqual(sample.heading, 0, accuracy: 0.01)
        XCTAssertEqual(sample.speedKmh, 60)
        XCTAssertEqual(sample.location.speed, 60 / 3.6, accuracy: 0.01)
        XCTAssertEqual(demo.progress, 0)
    }

    func testInterpolatesSpeedAndDistance() throws {
        var demo = try XCTUnwrap(RouteDemoPlayback(coordinates: [origin, point(north: 1_000)], speedKmh: 36))
        for _ in 0..<50 { demo.advance(by: 0.2) }
        XCTAssertEqual(demo.distanceMeters, 100, accuracy: 0.01)
        XCTAssertEqual(demo.sample().location.distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude)), 100, accuracy: 0.2)
        demo.setSpeed(72)
        demo.advance(by: 1)
        XCTAssertEqual(demo.distanceMeters, 120, accuracy: 0.01)
    }

    func testTurnFollowsPolylineNotStraightShortcut() throws {
        var demo = try XCTUnwrap(RouteDemoPlayback(coordinates: [origin, point(north: 100), point(east: 100, north: 100)], speedKmh: 36))
        for _ in 0..<12 { demo.advance(by: 1) }
        let sample = demo.sample()
        XCTAssertEqual(sample.coordinate.latitude, point(north: 100).latitude, accuracy: 0.000_001)
        XCTAssertGreaterThan(sample.coordinate.longitude, origin.longitude)
        XCTAssertLessThan(sample.coordinate.longitude, point(east: 100).longitude)
        XCTAssertEqual(sample.heading, 90, accuracy: 0.1)
    }

    func testPauseAndResumeDoNotAdvancePosition() throws {
        var demo = try XCTUnwrap(RouteDemoPlayback(coordinates: [origin, point(north: 1_000)]))
        demo.advance(by: 1)
        let before = demo.distanceMeters
        demo.pause()
        demo.advance(by: 900)
        XCTAssertEqual(demo.distanceMeters, before)
        XCTAssertEqual(demo.sample().speedKmh, 0)
        demo.setSpeed(80)
        XCTAssertTrue(demo.isPaused)
        XCTAssertEqual(demo.sample().speedKmh, 0)
        demo.resume()
        demo.advance(by: 0.5)
        XCTAssertEqual(demo.distanceMeters - before, 80 / 3.6 * 0.5, accuracy: 0.01)
    }

    func testBackgroundOrStalledClockCannotJumpAcrossRoute() throws {
        var demo = try XCTUnwrap(RouteDemoPlayback(coordinates: [origin, point(north: 1_000)], speedKmh: 36))
        demo.advance(by: 900)
        XCTAssertEqual(demo.distanceMeters, 10, accuracy: 0.01)
        demo.advance(by: .nan)
        demo.advance(by: .infinity)
        demo.advance(by: -3)
        XCTAssertEqual(demo.distanceMeters, 10, accuracy: 0.01)
    }

    func testFinishesAtEndpointAndRemainsStopped() throws {
        let end = point(north: 35)
        var demo = try XCTUnwrap(RouteDemoPlayback(coordinates: [origin, end], speedKmh: 120))
        for _ in 0..<5 { demo.advance(by: 1) }
        XCTAssertEqual(demo.progress, 1)
        XCTAssertTrue(demo.isFinished)
        XCTAssertTrue(demo.isPaused)
        XCTAssertEqual(demo.sample().speedKmh, 0)
        XCTAssertEqual(demo.sample().coordinate.latitude, end.latitude, accuracy: 0.000_000_1)
        demo.resume()
        XCTAssertTrue(demo.isPaused)
        demo.advance(by: 1)
        XCTAssertEqual(demo.distanceMeters, demo.totalDistanceMeters)
    }

    func testRejectsEmptyStationaryAndCorruptRoutes() {
        XCTAssertNil(RouteDemoPlayback(coordinates: []))
        XCTAssertNil(RouteDemoPlayback(coordinates: [origin]))
        XCTAssertNil(RouteDemoPlayback(coordinates: [origin, origin, origin]))
        XCTAssertNil(RouteDemoPlayback(coordinates: [origin, .init(latitude: .nan, longitude: 106), point(north: 100)]))
        XCTAssertNil(RouteDemoPlayback(coordinates: [origin, .init(latitude: 91, longitude: 106)]))
    }

    func testDuplicateVerticesAreSafe() throws {
        var demo = try XCTUnwrap(RouteDemoPlayback(coordinates: [origin, origin, point(north: 100), point(north: 100)]))
        demo.advance(by: 1)
        XCTAssertTrue(demo.sample().heading.isFinite)
        XCTAssertTrue(demo.progress.isFinite)
        XCTAssertGreaterThan(demo.distanceMeters, 0)
    }

    func testSpeedHasSafeBounds() throws {
        var demo = try XCTUnwrap(RouteDemoPlayback(coordinates: [origin, point(north: 100)], speedKmh: -1))
        XCTAssertEqual(demo.speedKmh, 10)
        demo.setSpeed(Int.max)
        XCTAssertEqual(demo.speedKmh, 120)
        demo.setSpeed(Int.min)
        XCTAssertEqual(demo.speedKmh, 10)
    }

    func testAntimeridianDoesNotTravelThroughGreenwich() throws {
        var demo = try XCTUnwrap(RouteDemoPlayback(coordinates: [
            .init(latitude: 0, longitude: 179.9999), .init(latitude: 0, longitude: -179.9999)
        ], speedKmh: 36))
        demo.advance(by: 1)
        XCTAssertGreaterThan(abs(demo.sample().coordinate.longitude), 179.99)
        XCTAssertEqual(demo.sample().heading, 90, accuracy: 0.01)
    }
}
