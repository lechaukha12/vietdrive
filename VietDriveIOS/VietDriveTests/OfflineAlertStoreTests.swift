import CoreLocation
import SQLite3
import UIKit
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
            XCTAssertTrue(points.contains { $0.signCode == "P127.50" && $0.speedLimit == 50 })
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
        XCTAssertEqual(store.trafficSignCount, 1_073)

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

    func testApproachingFirmwareTownEntryUsesOfficialR420Artwork() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "map-data town entry query")
        let location = CLLocation(latitude: 9.055951, longitude: 105.039931)
        store.nearbyContext(
            location: location,
            heading: 42,
            speedKmh: 30
        ) { context in
            let observation = context.alerts.first {
                $0.signCode == "R420" && $0.kind == .townBoundary
            }
            XCTAssertNotNil(observation)
            XCTAssertEqual(
                observation?.assetName,
                "TrafficSigns/TrafficSign_R420Official"
            )
            XCTAssertEqual(observation?.message, "Bắt đầu khu đông dân cư")
            XCTAssertLessThan(observation?.distanceMeters ?? 100, 2)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testFirmwareTownEntryIsNotPaintedAsAStaticViewportSign() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "town entry viewport query")
        let center = CLLocationCoordinate2D(latitude: 9.055951, longitude: 105.039931)

        store.mapDataPoints(center: center, radiusMeters: 500) { points in
            XCTAssertFalse(points.contains { $0.isFirmwareTownEntry })
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testFirmwareTownEntryRequiresMovementInItsEncodedDirection() {
        let store = OfflineAlertStore()
        let stopped = expectation(description: "stopped town entry query")
        let wrongDirection = expectation(description: "wrong-direction town entry query")
        let location = CLLocation(latitude: 9.055951, longitude: 105.039931)

        store.nearbyContext(
            location: location,
            heading: 42,
            speedKmh: 0
        ) { context in
            XCTAssertFalse(context.alerts.contains { $0.isFirmwareTownEntry })
            stopped.fulfill()
        }
        store.nearbyContext(
            location: location,
            heading: 222,
            speedKmh: 30
        ) { context in
            XCTAssertFalse(context.alerts.contains { $0.isFirmwareTownEntry })
            wrongDirection.fulfill()
        }

        wait(for: [stopped, wrongDirection], timeout: 3)
    }

    func testIsolatedTownEntryInsideHoChiMinhCityIsRejected() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "isolated urban town entry query")
        // Firmware point #7355 on Hoàng Sa has no reciprocal type-10 point
        // for the opposite travel direction near the same boundary.
        let location = CLLocation(latitude: 10.786191, longitude: 106.682166)

        store.nearbyContext(
            location: location,
            heading: 61,
            speedKmh: 30,
            alertRadiusMeters: 1_500
        ) { context in
            XCTAssertFalse(context.alerts.contains { $0.id == 50_007_355 })
            XCTAssertFalse(context.alerts.contains { $0.isFirmwareTownEntry })
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testTownSignsUseOfficialRectangularArtwork() throws {
        let entry = try XCTUnwrap(UIImage(
            named: "TrafficSigns/TrafficSign_R420Official"
        ))
        let exit = try XCTUnwrap(UIImage(
            named: "TrafficSigns/TrafficSign_R421Official"
        ))

        XCTAssertEqual(entry.size.width / entry.size.height, 1.2, accuracy: 0.02)
        XCTAssertEqual(exit.size.width / exit.size.height, 1.2, accuracy: 0.02)
    }

    func testPhysicalProhibitionSignIsExposedInFreeDriveMode() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "physical prohibition sign query")
        let location = CLLocation(latitude: 10.8263179, longitude: 106.6265799)

        store.nearbyContext(
            location: location,
            heading: 0,
            speedKmh: 0,
            alertRadiusMeters: 1_500
        ) { context in
            let sign = context.alerts.first {
                $0.signCode == "P102" && $0.kind == .roadSign
            }
            XCTAssertNotNil(sign)
            XCTAssertEqual(sign?.assetName, "TrafficSigns/TrafficSign_P102")
            XCTAssertLessThan(sign?.distanceMeters ?? 100, 2)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testParkingRoadRuleIsHiddenInFreeDriveMode() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "parking road-rule free-drive query")
        // Đường Phó Cơ Điều, OSM way 32580466: parking:right:restriction=no_parking.
        let location = CLLocation(latitude: 10.7620, longitude: 106.65703)

        store.nearbyContext(
            location: location,
            heading: 0,
            speedKmh: 0,
            alertRadiusMeters: 1_500
        ) { context in
            let sign = context.alerts.first { $0.id == 20_000_409 }
            XCTAssertNil(sign)
            XCTAssertTrue(context.matchedRoadRules.isEmpty)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testAbsoluteVehicleAccessRuleIsHiddenInFreeDriveMode() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "vehicle prohibition query")
        // Bến Cần Giuộc, OSM way 32577220: motor_vehicle=no.
        let location = CLLocation(latitude: 10.7452906, longitude: 106.6616261)

        store.nearbyContext(
            location: location,
            heading: 0,
            speedKmh: 0,
            alertRadiusMeters: 1_500
        ) { context in
            let sign = context.alerts.first { $0.id == 30_000_302 }
            XCTAssertNil(sign)
            XCTAssertFalse(context.alerts.contains { $0.isRoadRuleDerived })
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testOneRoadRuleCannotExposeSyntheticSignsInFreeDriveMode() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "multi-sign road-rule query")
        // OSM way 231668454 contains both motorcar=no and parking:both=no.
        let location = CLLocation(latitude: 20.9668459, longitude: 107.0520588)

        store.nearbyContext(
            location: location,
            heading: 0,
            speedKmh: 0,
            alertRadiusMeters: 1_500
        ) { context in
            XCTAssertFalse(context.alerts.contains {
                $0.id == 20_008_492 && $0.signCode == "P131a"
            })
            XCTAssertFalse(context.alerts.contains {
                $0.id == 30_008_492 && $0.signCode == "P103a"
            })
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testTurnRestrictionRelationsAreHiddenFromFreeDriveViewport() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "turn restriction viewport query")
        let center = CLLocationCoordinate2D(latitude: 10.8008406, longitude: 106.6606981)

        store.mapDataPoints(center: center, radiusMeters: 500) { points in
            let restriction = points.first { $0.id == 10_000_004 }
            XCTAssertNil(restriction)
            XCTAssertFalse(points.contains { $0.kind == .turnRestriction })
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testDenseHoChiMinhViewportContainsNoSyntheticRoadRuleMarkers() {
        let store = OfflineAlertStore()
        let completed = expectation(description: "dense free-drive viewport query")
        let center = CLLocationCoordinate2D(latitude: 10.7769, longitude: 106.7009)

        store.mapDataPoints(center: center, radiusMeters: 2_000) { points in
            XCTAssertFalse(points.contains { $0.isRoadRuleDerived })
            XCTAssertFalse(points.contains { $0.isFirmwareTownEntry })
            XCTAssertFalse(points.contains { $0.kind == .turnRestriction })
            XCTAssertFalse(points.contains { $0.kind == .parkingRestriction })
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
    }

    func testVehicleRestrictionAssetsAreBundled() throws {
        XCTAssertNotNil(UIImage(named: "TrafficSigns/TrafficSign_P103a"))
        XCTAssertNotNil(UIImage(named: "TrafficSigns/TrafficSign_P105"))
    }

    func testEveryCatalogDefinitionHasABundledAsset() {
        for definition in TrafficSignCatalog.definitions.values {
            XCTAssertNotNil(
                UIImage(named: definition.assetName),
                "Thiếu asset cho \(definition.code): \(definition.assetName)"
            )
        }
        for speed in [30, 40, 50, 60, 70, 80, 90, 100, 110, 120] {
            let code = TrafficSignCatalog.speedCode(speed)
            XCTAssertNotNil(
                UIImage(named: TrafficSignCatalog.assetName(for: code) ?? ""),
                "Thiếu asset cho \(code)"
            )
        }
    }

    func testLegacyAndFirmwareCodesNormalizeThroughCatalog() {
        XCTAssertEqual(
            TrafficSignCatalog.canonicalCode(for: "IGO:10"),
            "R420"
        )
        XCTAssertEqual(
            TrafficSignCatalog.canonicalCode(for: "IGO:1", speedLimit: 60),
            "P127.60"
        )
        XCTAssertEqual(
            TrafficSignCatalog.canonicalRestrictionCode("only_left_turn"),
            "R301c"
        )
        XCTAssertEqual(
            TrafficSignCatalog.firmwareAlert(
                typeCode: 4,
                speedLimit: 0,
                warningText: nil
            ).signCode,
            TrafficSignCatalog.sectionCameraCode
        )
    }
}

final class DrivingAlertRegressionTests: XCTestCase {
    func testCrossingRoadDoesNotHideAlignedSpeedLimit() async throws {
        let store = try makeStore()
        let context = await query(store, heading: 90)
        XCTAssertEqual(context.matchedSpeedLimit, 50)
        XCTAssertEqual(context.speedLimitMatch?.roadName, "eastbound")
    }

    func testRetainedRoadIsRejectedAfterDirectionChanges() async throws {
        let store = try makeStore()
        let north = await query(store, heading: 0)
        XCTAssertEqual(north.matchedSpeedLimit, 40)
        let east = await query(store, heading: 90)
        XCTAssertEqual(east.matchedSpeedLimit, 50)
        let west = await query(store, heading: 270)
        XCTAssertEqual(west.matchedSpeedLimit, 50)
    }

    func testWrongWayOneWayCandidateDoesNotHideNextValidRoad() async throws {
        let store = try makeStore(oneWay: true)
        let context = await query(store, heading: 270)
        XCTAssertEqual(context.matchedSpeedLimit, 50)
        XCTAssertEqual(context.speedLimitMatch?.roadName, "eastbound")
    }

    func testSharedAlertFilterKeepsNearbyFreeDriveSignsAndRejectsOffRouteSigns() {
        let location = CLLocation(latitude: 10, longitude: 106)
        let alert = DriveAlert(id: 99, kind: .roadSign, speedLimit: 0, latitude: 10.0001,
                               longitude: 106.0002, message: "Cấm đi ngược chiều", province: "",
                               distanceMeters: 25, signCode: "P102", source: "OpenStreetMap", confidence: 0.9)
        let coordinates = [CLLocationCoordinate2D(latitude: 10.5, longitude: 106),
                           CLLocationCoordinate2D(latitude: 10.51, longitude: 106)]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let route = NavigationRoute(distanceMeters: cumulative.last!, durationSeconds: 100,
                                    coordinates: coordinates, cumulativeDistances: cumulative, steps: [])
        XCTAssertEqual(OfflineAlertStore.filterDrivingAlerts([alert], location: location, heading: 90,
            speedKmh: 30, route: nil, matchedDistanceMeters: nil, radiusMeters: 1_500).count, 1)
        XCTAssertTrue(OfflineAlertStore.filterDrivingAlerts([alert], location: location, heading: 90,
            speedKmh: 30, route: route, matchedDistanceMeters: nil, radiusMeters: 1_500).isEmpty)
    }

    private func query(_ store: OfflineAlertStore, heading: Double) async -> OfflineMapContext {
        await withCheckedContinuation { continuation in
            store.nearbyContext(location: CLLocation(latitude: 10, longitude: 106), heading: heading,
                                speedKmh: 30) { continuation.resume(returning: $0) }
        }
    }

    private func makeStore(oneWay: Bool = false) throws -> OfflineAlertStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let geometry = oneWay ? "[[105.999,10],[106.001,10]]" : "[[106,9.999],[106,10.001]]"
        let sql = """
            PRAGMA user_version=6;
            CREATE TABLE metadata(key TEXT, value TEXT);
            INSERT INTO metadata VALUES('contract_id','vn.vietdrive.map-data'),('contract_version','1');
            CREATE TABLE map_data_city_lookup(id INTEGER PRIMARY KEY, label TEXT);
            CREATE TABLE map_data_name_lookup(id INTEGER PRIMARY KEY, city_id INTEGER, label TEXT);
            CREATE TABLE map_data_points(id INTEGER PRIMARY KEY, source_node_id INTEGER, type_code INTEGER,
                latitude REAL, longitude REAL, speed_kmh INTEGER, direction_type INTEGER, direction_degrees REAL,
                warning_text TEXT, source TEXT, source_ref TEXT, confidence REAL);
            CREATE VIRTUAL TABLE map_data_points_rtree USING rtree(point_id,min_lat,max_lat,min_lon,max_lon);
            INSERT INTO map_data_points VALUES(1,1,2,20,106,0,0,NULL,'camera','map-data/edogen.bin','test',0.9);
            INSERT INTO map_data_points_rtree VALUES(1,20,20,106,106);
            CREATE TABLE map_data_road_links(id INTEGER PRIMARY KEY, road_serial_number INTEGER,
                provider_road_id INTEGER, inline_road_name TEXT, direction_1_name_id INTEGER, direction_2_name_id INTEGER,
                direction_1_speed_kmh INTEGER, direction_2_speed_kmh INTEGER, geometry_json TEXT);
            CREATE VIRTUAL TABLE map_data_road_links_rtree USING rtree(link_id,min_lat,max_lat,min_lon,max_lon);
            INSERT INTO map_data_road_links VALUES(1,1,1,'nearest',0,0,40,\(oneWay ? 0 : 40),'\(geometry)');
            INSERT INTO map_data_road_links VALUES(2,2,2,'eastbound',0,0,50,50,'[[105.999,10.00018],[106.001,10.00018]]');
            INSERT INTO map_data_road_links_rtree VALUES(1,9.999,10.001,105.999,106.001);
            INSERT INTO map_data_road_links_rtree VALUES(2,10.00018,10.00018,105.999,106.001);
            """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        XCTAssertEqual(result, SQLITE_OK, String(cString: sqlite3_errmsg(database)))
        return OfflineAlertStore(databasePath: path.path)
    }
}
