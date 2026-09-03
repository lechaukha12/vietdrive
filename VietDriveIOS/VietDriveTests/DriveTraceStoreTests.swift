import CoreLocation
import XCTest
@testable import VietDrive

final class DriveTraceStoreTests: XCTestCase {
    func testSectionAverageAccumulatesTravelAroundACorner() throws {
        let date = Date()
        let samples = [(10.0, 106.0), (10.0009, 106.0), (10.0009, 106.0009)].map {
            CLLocation(coordinate: .init(latitude: $0.0, longitude: $0.1), altitude: 0,
                       horizontalAccuracy: 5, verticalAccuracy: -1, course: 0, speed: 60 / 3.6, timestamp: date)
        }
        var tracker = SectionSpeedTracker()
        tracker.start(limit: 50, location: samples[0], time: 0)
        let firstLeg = samples[1].distance(from: samples[0])
        let distance = firstLeg + samples[2].distance(from: samples[1])
        _ = tracker.update(location: samples[1], time: firstLeg / (60 / 3.6))
        let progress = try XCTUnwrap(tracker.update(location: samples[2], time: distance / (60 / 3.6)))
        XCTAssertEqual(progress.averageSpeedKmh, 60)
        XCTAssertEqual(progress.distanceTraveledMeters, distance, accuracy: 0.01)
        XCTAssertGreaterThan(progress.distanceTraveledMeters, samples[2].distance(from: samples[0]) + 50)
    }

    func testSectionIgnoresStationaryJitterAndExpiresAfterAnOutage() throws {
        let date = Date()
        func stopped(_ latitude: Double) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: 106), altitude: 0,
                       horizontalAccuracy: 8, verticalAccuracy: -1, course: -1, speed: 0, timestamp: date)
        }
        var tracker = SectionSpeedTracker()
        tracker.start(limit: 50, location: stopped(10), time: 0)
        let progress = try XCTUnwrap(tracker.update(location: stopped(10.00004), time: 5))
        XCTAssertEqual(progress.averageSpeedKmh, 0)
        XCTAssertEqual(progress.distanceTraveledMeters, 0)
        XCTAssertNil(tracker.update(location: stopped(10.0001), time: 60))
        XCTAssertNil(tracker.update(location: stopped(10.0001), time: 61))
    }

    func testSectionUsesPlaybackClockAndRejectsTeleports() throws {
        var playback = try XCTUnwrap(RouteDemoPlayback(coordinates: [
            .init(latitude: 10, longitude: 106), .init(latitude: 10.01, longitude: 106)
        ], speedKmh: 60))
        var tracker = SectionSpeedTracker()
        tracker.start(limit: 50, location: playback.sample().location, time: playback.elapsedSeconds)
        for _ in 0..<6 {
            playback.advance(by: 1)
            _ = tracker.update(location: playback.sample().location, time: playback.elapsedSeconds)
        }
        playback.pause()
        playback.advance(by: 3_600)
        XCTAssertEqual(playback.elapsedSeconds, 6)
        let paused = try XCTUnwrap(tracker.update(location: playback.sample().location, time: playback.elapsedSeconds))
        XCTAssertEqual(paused.averageSpeedKmh, 60)
        playback.resume()
        playback.advance(by: 1)
        XCTAssertEqual(tracker.update(location: playback.sample().location, time: playback.elapsedSeconds)?.averageSpeedKmh, 60)
        let teleport = CLLocation(latitude: 11, longitude: 107)
        XCTAssertNil(tracker.update(location: teleport, time: 8))
        XCTAssertNil(tracker.update(location: playback.sample().location, time: 9))
    }

    func testTracePersistsAndReplaysSmoothly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DriveTraceStore(directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date(timeIntervalSince1970: 1_000)
        store.start(routeTitle: "A → B", at: startedAt)
        store.append(
            location: location(latitude: 10, longitude: 106, course: 350, date: startedAt),
            resolvedHeading: 350
        )
        store.append(
            location: location(latitude: 10, longitude: 106.01, course: 10, date: startedAt.addingTimeInterval(2)),
            resolvedHeading: 10
        )

        let trace = try XCTUnwrap(store.finish())
        XCTAssertEqual(store.traces().count, 1)
        XCTAssertEqual(trace.routeTitle, "A → B")
        let middle = DriveTraceReplay(trace: trace).sample(at: 1)
        XCTAssertEqual(middle.longitude, 106.005, accuracy: 0.000_01)
        XCTAssertTrue(middle.course < 1 || middle.course > 359)
    }

    private func location(
        latitude: Double,
        longitude: Double,
        course: Double,
        date: Date
    ) -> CLLocation {
        CLLocation(
            coordinate: .init(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 8,
            verticalAccuracy: 8,
            course: course,
            speed: 12,
            timestamp: date
        )
    }
}
