import CoreLocation
import SQLite3
import XCTest
@testable import VietDrive

final class DrivingSceneTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 10.7769, longitude: 106.7009)

    private func coordinate(_ x: Double, _ z: Double) -> CLLocationCoordinate2D {
        .init(latitude: origin.latitude + z / 111_195,
              longitude: origin.longitude + x / (111_195 * cos(origin.latitude * .pi / 180)))
    }
    private func road(_ id: String = "primary", _ points: [(Double, Double)] = [(0, -80), (0, 400)],
                      direction: Int? = 0, layer: Int = 0, bridge: Bool = false) -> DrivingSceneRoad {
        .init(id: id, coordinates: points.map { coordinate($0.0, $0.1) }, lanes: 2,
              direction: direction, bridge: bridge, layer: layer)
    }
    private func scene(_ roads: [DrivingSceneRoad], heading: Double = 0, gps: Bool = true) -> DrivingScene {
        DrivingScene.make(roads: roads, origin: origin, heading: heading, hasGPS: gps)
    }

    func testProjectionUsesHeadingAndRejectsInvalidInputs() {
        let north = DrivingScene.local(coordinate(0, 100), origin: origin, heading: 0)
        XCTAssertEqual(north.x, 0, accuracy: 0.01)
        XCTAssertEqual(north.z, 100, accuracy: 0.01)
        let east = DrivingScene.local(coordinate(100, 0), origin: origin, heading: 90)
        XCTAssertEqual(east.x, 0, accuracy: 0.01)
        XCTAssertEqual(east.z, 100, accuracy: 0.01)
        XCTAssertFalse(scene([road()], gps: false).isLocated)
        XCTAssertFalse(scene([road()], heading: .nan).isLocated)
        XCTAssertNil(DrivingScene.project(.init(x: .nan, z: 5), size: .init(width: 300, height: 400)))
    }

    func testNoRoadDoesNotInventGeometry() {
        XCTAssertFalse(scene([]).isLocated)
        XCTAssertFalse(scene([road("distant", [(100, 0), (100, 500)])]).isLocated)
        XCTAssertTrue(scene([]).events.isEmpty)
        XCTAssertFalse(DrivingTrafficActor.placements(scene: .empty, distance: 100, crowded: false).contains { $0.pedestrian || $0.motorbike })
    }

    func testCrossroadsAndTJunctionsUseActualGeometry() {
        for branch in [[(-100.0, 100.0), (100.0, 100.0)], [(0, 100), (100, 100)]] {
            let result = scene([road(), road("crossing", branch)])
            XCTAssertEqual(result.junctions.count, 1)
            XCTAssertEqual(result.junctions[0].point.z, 100, accuracy: 0.1)
        }
        XCTAssertTrue(scene([road()]).junctions.isEmpty)
    }

    func testBridgeIsNotAnAtGradeIntersection() {
        let crossing = road("overpass", [(-100, 100), (100, 100)], layer: 1, bridge: true)
        XCTAssertTrue(scene([road(), crossing]).junctions.isEmpty)
        XCTAssertTrue(scene([road("bridge", layer: 1, bridge: true)]).currentStructure?.contains("Cầu") == true)
    }

    func testCurvedRoadRetainsCoordinatesAndDoesNotExtrapolate() {
        let result = scene([road("curve", [(0, -30), (0, 10), (20, 45), (60, 100)])])
        XCTAssertGreaterThan(result.curve, 7)
        XCTAssertNotNil(result.point(ahead: 50, lateral: 0))
        XCTAssertNil(result.point(ahead: 300, lateral: 0))
        XCTAssertNil(result.point(ahead: .nan, lateral: 0))
        XCTAssertEqual(result.roads[0].points.count, 4)
    }

    func testAmbiguousForkDoesNotChooseAnInventedDirection() {
        let result = scene([road("start", [(0, -20), (0, 30)]),
                            road("left", [(0, 30), (-60, 130)]),
                            road("right", [(0, 30), (60, 130)])])
        XCTAssertEqual(result.aheadLength, 30, accuracy: 0.1)
        // Presentation keeps a straight ribbon, but must not infer a turn from the fork.
        XCTAssertNil(result.point(ahead: 100, lateral: 0))
    }

    func testUnambiguousLinkContinuesForward() {
        let result = scene([road("start", [(0, -20), (0, 30)]), road("next", [(0, 30), (0, 180)])])
        XCTAssertEqual(result.aheadLength, 180, accuracy: 0.1)
    }

    func testLeftLaneIsAlwaysDecorativeOncomingAndRightLaneIsSameDirection() {
        for direction: Int? in [1, nil] {
            let result = scene([road(direction: direction)])
            XCTAssertFalse(result.allowsOncoming)
            let actors = DrivingTrafficActor.placements(scene: result, distance: 30, crowded: false)
            XCTAssertTrue(actors.contains { $0.lane.rawValue < 0 && $0.asset.hasSuffix("Front") })
            for actor in actors where !actor.pedestrian {
                XCTAssertTrue(actor.asset.hasSuffix(actor.lane.rawValue < 0 ? "Front" : "Rear"))
            }
        }
        XCTAssertFalse(scene([road(direction: -1)]).isLocated)
        XCTAssertTrue(scene([road(direction: -1)], heading: 180).isLocated)
    }

    func testTrafficIsBoundedDeterministicAndReducedNearWarnings() {
        let result = scene([road()])
        let first = DrivingTrafficActor.placements(scene: result, distance: 100, crowded: false)
        let second = DrivingTrafficActor.placements(scene: result, distance: 100, crowded: false)
        XCTAssertEqual(first.map(\.point), second.map(\.point))
        XCTAssertEqual(first.count, 8)
        XCTAssertTrue(first.contains { $0.asset.hasSuffix("Front") })
        XCTAssertEqual(DrivingTrafficActor.placements(scene: result, distance: 100, crowded: true).count, 3)
        for actor in first {
            XCTAssertGreaterThan(actor.point.z, 0)
            XCTAssertLessThan(actor.point.z, 525) // illustrative corridor, independent of map-link length
            XCTAssertTrue((0...1).contains(actor.opacity))
        }
    }

    func testHalfVehicleBudgetRetainsBothSidesAndPedestrians() {
        var street = road()
        street.highway = "residential"
        let actors = DrivingTrafficActor.placements(scene: scene([street]), distance: 0, crowded: false)
        XCTAssertEqual(actors.filter { !$0.pedestrian }.count, 8) // previously 16
        XCTAssertEqual(actors.filter(\.pedestrian).count, 6) // pedestrian budget unchanged
        XCTAssertEqual(actors.filter { !$0.pedestrian && $0.lane.rawValue < 0 }.count, 4)
        XCTAssertEqual(actors.filter { !$0.pedestrian && $0.lane.rawValue > 0 }.count, 4)
        street.direction = 1
        XCTAssertEqual(DrivingTrafficActor.placements(scene: scene([street]), distance: 0, crowded: false)
            .filter { !$0.pedestrian }.count, 8) // left is illustrative, independent of one-way metadata
        street.highway = "motorway"
        XCTAssertEqual(DrivingTrafficActor.placements(scene: scene([street]), distance: 0, crowded: false).count, 4)
        XCTAssertEqual(DrivingTrafficActor.placements(scene: .empty, distance: 0, crowded: false).count, 4)
    }

    func testTrafficDoesNotOccupyIntersections() {
        let result = scene([road(), road("crossing", [(-100, 100), (100, 100)])])
        for distance in stride(from: 0.0, to: 1_000, by: 13) {
            for actor in DrivingTrafficActor.placements(scene: result, distance: distance, crowded: false) {
                XCTAssertFalse(result.events.contains { $0.cutsRoad && abs($0.distanceMeters - actor.point.z) < 20 })
            }
        }
    }

    func testMotionFreezesAndResumesWithoutAccumulatingBackgroundTime() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var motion = DrivingSceneMotion(date: start)
        motion.update(speed: 36, running: true, now: start)
        XCTAssertEqual(motion.value(at: start.addingTimeInterval(10)), 100, accuracy: 0.01)
        motion.update(speed: 72, running: true, now: start.addingTimeInterval(10))
        XCTAssertEqual(motion.value(at: start.addingTimeInterval(11)), 120, accuracy: 0.01)
        motion.update(speed: 72, running: false, now: start.addingTimeInterval(11))
        XCTAssertEqual(motion.value(at: start.addingTimeInterval(1_000)), 120, accuracy: 0.01)
        motion.update(speed: 36, running: true, now: start.addingTimeInterval(1_000))
        XCTAssertEqual(motion.value(at: start.addingTimeInterval(1_001)), 130, accuracy: 0.01)
    }

    func testShortFirmwareLinkCanContinueInsideLongerOSMWay() {
        let result = scene([road("firmware-1", [(0, -15), (0, 15)]),
                            road("osm-1", [(0, -80), (0, 400)]),
                            road("firmware-2", [(0, 15), (0, 100)])])
        XCTAssertGreaterThan(result.aheadLength, 390)
        XCTAssertTrue(result.junctions.isEmpty)
    }

    func testActorPositionsDoNotChangeWithRoadLinkID() {
        let a = DrivingTrafficActor.placements(scene: scene([road("first")]), distance: 40, crowded: false)
        let b = DrivingTrafficActor.placements(scene: scene([road("second")]), distance: 40, crowded: false)
        XCTAssertEqual(a.map(\.point), b.map(\.point))
        XCTAssertEqual(a.map(\.asset), b.map(\.asset))
    }

    func testPedestriansAreOnVergeAndExcludedFromMotorwaysAndBridges() {
        var street = road()
        street.highway = "residential"
        let pedestrians = DrivingTrafficActor.placements(scene: scene([street]), distance: 0, crowded: false).filter(\.pedestrian)
        XCTAssertGreaterThanOrEqual(pedestrians.count, 4)
        for actor in pedestrians { XCTAssertTrue(actor.asset.hasPrefix("DrivingPedestrian")) }
        street.highway = "motorway"
        street.direction = 1
        let motorway = DrivingTrafficActor.placements(scene: scene([street]), distance: 0, crowded: false)
        XCTAssertFalse(motorway.contains { $0.pedestrian || $0.motorbike })
        street.highway = "primary"
        street.bridge = true
        XCTAssertFalse(DrivingTrafficActor.placements(scene: scene([street]), distance: 0, crowded: false).contains(where: \.pedestrian))
    }

    func testTrafficKeepsItsSideAcrossMotionWrapsAndWarningDensityChanges() {
        var street = road()
        street.highway = "residential"
        let result = scene([street])
        var assigned: [Int: DrivingTrafficActor.Lane] = [:]
        for distance in stride(from: 0.0, through: 10_050, by: 31) {
            for crowded in [false, true] {
                for actor in DrivingTrafficActor.placements(scene: result, distance: distance, crowded: crowded) {
                    if let lane = assigned[actor.id] { XCTAssertEqual(actor.lane, lane) }
                    assigned[actor.id] = actor.lane
                    XCTAssertGreaterThanOrEqual(abs(actor.lane.rawValue), 0.5)
                }
            }
        }
        XCTAssertGreaterThan(assigned.count, 12)
    }

    func testWholeSpritesKeepTheirLaneAndPedestriansStayOutsideRoad() {
        var street = road()
        street.highway = "residential"
        let result = scene([street])
        for distance in stride(from: 0.0, through: 1_000, by: 17) {
            for size in [CGSize(width: 320, height: 360), .init(width: 780, height: 180)] {
                for actor in DrivingTrafficActor.placements(scene: result, distance: distance, crowded: false) {
                    let frame = actor.frame(in: size)
                    let halfRoad = DrivingRibbon.point(distance: actor.distanceMeters, side: 1, size: size).x - size.width / 2
                    let reserved = actor.pedestrian ? halfRoad : 2
                    if actor.lane.rawValue < 0 {
                        XCTAssertLessThanOrEqual(frame.maxX, size.width / 2 - reserved + 0.001)
                    } else {
                        XCTAssertGreaterThanOrEqual(frame.minX, size.width / 2 + reserved - 0.001)
                    }
                    if !actor.pedestrian {
                        let topDepth = (frame.minY / size.height - 0.04) / 0.92
                        let topLeft = DrivingRibbon.point(depth: topDepth, side: -1, size: size).x
                        let topRight = DrivingRibbon.point(depth: topDepth, side: 1, size: size).x
                        XCTAssertGreaterThanOrEqual(frame.minX, topLeft - 0.001)
                        XCTAssertLessThanOrEqual(frame.maxX, topRight + 0.001)
                    }
                    XCTAssertGreaterThan(frame.width, 0)
                }
            }
        }
    }

    func testEqualLaneWidthsAndMazdaStaysInRightLane() {
        XCTAssertEqual(DrivingTrafficActor.Lane.leftVehicle.rawValue, DrivingRibbon.leftLaneCenter)
        XCTAssertEqual(DrivingTrafficActor.Lane.rightVehicle.rawValue, DrivingRibbon.rightLaneCenter)
        for size in [CGSize(width: 320, height: 360), .init(width: 357, height: 430),
                     .init(width: 520, height: 200), .init(width: 780, height: 180)] {
            for depth in [0.2, 0.5, 0.9] {
                let left = DrivingRibbon.point(depth: depth, side: -1, size: size)
                let middle = DrivingRibbon.point(depth: depth, side: 0, size: size)
                let right = DrivingRibbon.point(depth: depth, side: 1, size: size)
                XCTAssertEqual(middle.x - left.x, right.x - middle.x, accuracy: 0.001)
            }
            let ego = DrivingRibbon.egoFrame(size: size)
            let topDepth = (ego.minY / size.height - 0.04) / 0.92
            XCTAssertGreaterThan(ego.minX, size.width / 2)
            XCTAssertLessThan(ego.maxX, DrivingRibbon.point(depth: topDepth, side: 1, size: size).x)
            let groundY = ego.minY + ego.height * 0.89
            let groundDepth = (groundY / size.height - 0.04) / 0.92
            XCTAssertEqual(ego.midX, DrivingRibbon.point(depth: groundDepth, side: 0.5, size: size).x, accuracy: 0.001)
            let result = scene([road()])
            for distance in stride(from: 0.0, through: 2_000, by: 19) {
                for actor in DrivingTrafficActor.placements(scene: result, distance: distance, crowded: false)
                    where !actor.pedestrian && actor.lane.rawValue > 0 {
                    XCTAssertFalse(actor.frame(in: size).intersects(ego), "Same-direction sprite overlaps Mazda")
                }
            }
        }
    }

    func testFramePredictionIsBoundedAndNeverChangesGPSGeometry() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var clock = DrivingSceneFrameClock()
        clock.receive(at: start)
        XCTAssertEqual(clock.advance(speed: 36, running: true, at: start.addingTimeInterval(0.5)), 5)
        XCTAssertEqual(clock.advance(speed: 36, running: true, at: start.addingTimeInterval(90)), 10)
        XCTAssertEqual(clock.advance(speed: 120, running: true, at: start.addingTimeInterval(90)), 24)
        XCTAssertEqual(clock.advance(speed: 36, running: false, at: start.addingTimeInterval(0.5)), 0)
        let size = CGSize(width: 357, height: 420)
        for advance in [0.0, 5, 20] {
            let transform = DrivingScene.groundTransform(advance: advance, size: size)
            for point in [DrivingScenePoint(x: -4, z: 60), .init(x: 3, z: 140)] {
                let p = try XCTUnwrap(DrivingScene.project(point, size: size))
                let expected = try XCTUnwrap(DrivingScene.project(.init(x: point.x, z: point.z - advance), size: size))
                let denominator = p.y * transform.m24 + transform.m44
                XCTAssertEqual((p.x + p.y * transform.m21 + transform.m41) / denominator, expected.x, accuracy: 0.001)
                XCTAssertEqual((p.y * transform.m22 + transform.m42) / denominator, expected.y, accuracy: 0.001)
            }
        }
    }

    func testRibbonClassifiesLeftRightAndCrossroadsWithoutChangingMainPath() throws {
        for (points, left, right) in [([(0.0, 180.0), (90.0, 180.0)], false, true),
                                     ([(-90.0, 180.0), (0.0, 180.0)], true, false),
                                     ([(-90.0, 180.0), (90.0, 180.0)], true, true)] {
            let event = try XCTUnwrap(scene([road(), road("branch", points)]).events.first)
            XCTAssertEqual(event.kind, .junction)
            XCTAssertEqual(event.left, left)
            XCTAssertEqual(event.right, right)
            XCTAssertEqual(event.distanceMeters, 180, accuracy: 0.1)
        }
    }

    func testRoadsidePostsStayOnStraightRibbonEvenOnCurvedMapGeometry() throws {
        let size = CGSize(width: 357, height: 430)
        let straight = scene([road()])
        let curve = scene([road("curve", [(0, -10), (0, 20), (20, 60), (90, 180)])])
        XCTAssertEqual(straight.roadsidePosition(distance: 120, size: size), curve.roadsidePosition(distance: 120, size: size))
        XCTAssertEqual(DrivingRibbon.point(distance: 180, side: 0, size: size).x, size.width / 2)
        XCTAssertGreaterThan(DrivingRibbon.point(distance: 20, side: 0, size: size).y,
                             DrivingRibbon.point(distance: 180, side: 0, size: size).y)
    }

    func testBridgeEntryRequiresAConnectionNotAnOverheadCrossing() throws {
        let approach = road("approach", [(0, -50), (0, 150)])
        let bridge = road("bridge", [(0, 150), (0, 350)], layer: 1, bridge: true)
        let event = try XCTUnwrap(scene([approach, bridge]).events.first { $0.kind == .bridge })
        XCTAssertEqual(event.distanceMeters, 150, accuracy: 0.1)
        let overpass = road("overpass", [(-100, 100), (100, 100)], layer: 1, bridge: true)
        XCTAssertFalse(scene([road(), overpass]).events.contains { $0.kind == .bridge })
    }

    func testEventDistanceFollowsGPSAndDropsBehindCar() throws {
        let roads = [road(), road("cross", [(-100, 180), (100, 180)])]
        let before = try XCTUnwrap(scene(roads).events.first)
        let after = DrivingScene.make(roads: roads, origin: coordinate(0, 40), heading: 0, hasGPS: true)
        XCTAssertEqual(try XCTUnwrap(after.events.first).id, before.id)
        XCTAssertEqual(try XCTUnwrap(after.events.first).distanceMeters, before.distanceMeters - 40, accuracy: 0.2)
        XCTAssertTrue(DrivingScene.make(roads: roads, origin: coordinate(0, 200), heading: 0, hasGPS: true).events.isEmpty)
    }

    func testOnlyNearbyDataEventsAreRenderedWithBoundedDensity() {
        let events: [DrivingSceneEvent] = [
            .init(id: "bad", kind: .junction, distanceMeters: .nan),
            .init(id: "behind", kind: .bridge, distanceMeters: -10),
            .init(id: "far", kind: .toll, distanceMeters: 900),
            .init(id: "one", kind: .junction, distanceMeters: 100, left: true),
            .init(id: "duplicate", kind: .junction, distanceMeters: 105, left: true),
            .init(id: "two", kind: .toll, distanceMeters: 250),
            .init(id: "three", kind: .tunnel, distanceMeters: 400)
        ]
        XCTAssertEqual(DrivingRibbon.visibleEvents(events).map(\.id), ["one", "two"])
        XCTAssertTrue(DrivingRibbon.visibleEvents([]).isEmpty)
    }

    func testTollIsNotHiddenByNearbyIllustrativeJunctionOrTraffic() {
        let toll = DrivingSceneEvent(id: "toll", kind: .toll, distanceMeters: 160)
        let events: [DrivingSceneEvent] = [
            .init(id: "cross", kind: .junction, distanceMeters: 150, left: true, right: true), toll,
            .init(id: "bridge", kind: .bridge, distanceMeters: 300)
        ]
        XCTAssertEqual(DrivingRibbon.visibleEvents(events).map(\.id), ["toll", "bridge"])
        let actors = DrivingTrafficActor.placements(scene: scene([road()]), distance: 0, crowded: false, events: events)
        XCTAssertFalse(actors.contains { abs($0.point.z - toll.distanceMeters) < 25 })
    }

    func testReaderIsReadOnlyAndDoesNotBorrowBridgeAtCrossing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scene.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let setup = """
        CREATE TABLE map_data_road_links(id INTEGER PRIMARY KEY, geometry_json TEXT, inline_road_name TEXT);
        CREATE VIRTUAL TABLE map_data_road_links_rtree USING rtree(link_id,min_lat,max_lat,min_lon,max_lon);
        CREATE TABLE road_rules(id INTEGER PRIMARY KEY, geometry_json TEXT, road_name TEXT, raw_tags_json TEXT);
        CREATE VIRTUAL TABLE road_rules_rtree USING rtree(rule_id,min_lat,max_lat,min_lon,max_lon);
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        let inputs: [(String, Int, [(Double, Double)], String)] = [
            ("map_data_road_links", 1, [(0, -50), (0, 200)], "{}"),
            ("road_rules", 2, [(0, -100), (0, 400)], "{\"highway\":\"primary\",\"lanes\":\"2\"}"),
            ("road_rules", 3, [(-100, 100), (100, 100)], "{\"highway\":\"primary\",\"bridge\":\"yes\",\"layer\":\"1\"}")
        ]
        for (table, id, points, tags) in inputs {
            let coordinates = points.map { coordinate($0.0, $0.1) }
            let json = String(data: try JSONEncoder().encode(coordinates.map { [$0.longitude, $0.latitude] }), encoding: .utf8)!
            let osm = table == "road_rules"
            let insert = "INSERT INTO \(table) VALUES (\(id), '\(json)', 'Fixture'\(osm ? ", '\(tags)'" : ""));"
                + "INSERT INTO \(table)_rtree VALUES (\(id),\(coordinates.map(\.latitude).min()!),\(coordinates.map(\.latitude).max()!),\(coordinates.map(\.longitude).min()!),\(coordinates.map(\.longitude).max()!));"
            XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        let roads = try XCTUnwrap(DrivingSceneReader.read(path: url.path, center: origin))
        let primary = try XCTUnwrap(roads.first { $0.id == "firmware-1" })
        XCTAssertEqual(primary.lanes, 2)
        XCTAssertEqual(primary.direction, 0)
        XCTAssertFalse(primary.bridge)
        XCTAssertTrue(roads.contains { $0.id == "osm-2" }, "A partly covered OSM way must retain its remaining geometry")
        XCTAssertGreaterThan(scene(roads).aheadLength, 390)
        XCTAssertTrue(roads.contains { $0.bridge && $0.layer == 1 })
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertNil(DrivingSceneReader.read(path: url.path, center: .init(latitude: .nan, longitude: 0)))
        XCTAssertNil(DrivingSceneReader.read(path: directory.appendingPathComponent("missing").path, center: origin))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing").path))
    }
}
