import CoreLocation
import XCTest
@testable import VietDrive

final class DriveTraceStoreTests: XCTestCase {
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
