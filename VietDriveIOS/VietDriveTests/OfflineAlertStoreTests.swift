import CoreLocation
import XCTest
@testable import VietDrive

final class OfflineAlertStoreTests: XCTestCase {
    func testViewportQueryReturnsMapDataWithoutGPSRouteFiltering() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "viewport map-data query")
        let center = CLLocationCoordinate2D(latitude: 8.576372, longitude: 104.847283)
        store.mapDataPoints(center: center, radiusMeters: 1_000) { points in
            XCTAssertFalse(points.isEmpty)
            XCTAssertTrue(points.allSatisfy { $0.source == "map-data/edogen.bin" })
            XCTAssertTrue(points.contains { $0.signCode == "IGO:1" && $0.speedLimit == 50 })
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
    }

    func testBundledDatabaseReturnsKnownMapDataSpeedCamera() {
        let store = OfflineAlertStore()
        XCTAssertEqual(store.mapDataPointCount, 36_820)
        XCTAssertEqual(store.mapDataCameraCount, 35_798)
        XCTAssertEqual(store.mapDataSpeedPointCount, 16_400)
        XCTAssertEqual(store.mapDataRoadLinkCount, 1_875_900)
        XCTAssertEqual(store.trafficSignCount, 1_022)

        let completed = expectation(description: "offline database query")
        let knownSign = CLLocation(latitude: 10.825314, longitude: 106.706716)
        store.nearbyContext(
            location: knownSign,
            heading: 0,
            speedKmh: 0,
            alertRadiusMeters: 1_500
        ) { context in
            XCTAssertEqual(context.matchedSpeedLimit, 50)
            XCTAssertNotNil(context.speedLimitMatch?.roadName)
            XCTAssertTrue(context.speedLimitMatch?.source.hasPrefix("map-data/roadsenz.bin #") == true)
            XCTAssertLessThan(context.speedLimitMatch?.distanceMeters ?? .greatestFiniteMagnitude, 2)
            XCTAssertEqual(context.speedLimitMatch?.canTriggerDrivingAlerts, true)
            XCTAssertEqual(context.speedLimitMatch?.province.isEmpty, false)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testOSMMaxspeedIsNoLongerUsedAsBusinessLayer() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "OSM maxspeed query")
        // Cầu Chương Dương, OSM way 9656730: maxspeed=50, oneway=yes.
        let location = CLLocation(latitude: 21.0397556, longitude: 105.8656403)
        store.nearbyContext(
            location: location,
            heading: 247,
            speedKmh: 35
        ) { context in
            XCTAssertNotEqual(context.speedLimitMatch?.source, "OpenStreetMap maxspeed")
            XCTAssertTrue(context.roads.allSatisfy {
                $0.speedSource.hasPrefix("map-data/roadsenz.bin")
            })
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testTownEntryTypeIsExposedAsMapDataRoadSign() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "map-data town entry query")
        let location = CLLocation(latitude: 9.055951, longitude: 105.039931)
        store.nearbyContext(
            location: location,
            heading: 0,
            speedKmh: 0
        ) { context in
            let observation = context.alerts.first {
                $0.signCode == "IGO:10" && $0.kind == .roadSign
            }
            XCTAssertNotNil(observation)
            XCTAssertLessThan(observation?.distanceMeters ?? 100, 2)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }
}
