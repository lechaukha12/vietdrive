import Combine
import CoreLocation
import Foundation
import SQLite3

/// Owns a separate read-only SQLite connection; lifetime is limited to this screen's query.
@MainActor
final class DrivingSceneStore: ObservableObject {
    @Published private(set) var roads: [DrivingSceneRoad] = []
    @Published private(set) var scene = DrivingScene.empty
    private var lastCenter: CLLocation?
    private var lastPath: String?
    private var generation = 0
    private let queue = DispatchQueue(label: "vn.vietdrive.driving-scene", qos: .utility)
    private var pending: (CLLocationCoordinate2D, Double)?
    private var processing = false

    func refresh(near coordinate: CLLocationCoordinate2D, heading: Double = 0) async {
        guard CLLocationCoordinate2DIsValid(coordinate), coordinate.latitude.isFinite,
              coordinate.longitude.isFinite, heading.isFinite else { return }
        pending = (coordinate, heading)
        guard !processing else { return }
        processing = true
        defer { processing = false }
        // Coalesce pending fixes instead of cancelling every database query as the car moves.
        while let request = pending {
            pending = nil
            await prepare(near: request.0, heading: request.1)
        }
    }

    private func prepare(near coordinate: CLLocationCoordinate2D, heading: Double) async {
        let paths = [UserDefaults.standard.string(forKey: "activeMapDatabasePath"),
                     Bundle.main.path(forResource: "map_database_v2", ofType: "sqlite")]
            .compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let reuse = lastCenter.map { lastPath == paths.first && location.distance(from: $0) < 65 } ?? false
        let cached = roads
        generation += 1
        let requestedGeneration = generation
        let result: ([DrivingSceneRoad], DrivingScene) = await withCheckedContinuation { continuation in
            queue.async {
                if reuse {
                    continuation.resume(returning: (cached, .make(roads: cached, origin: coordinate, heading: heading, hasGPS: true)))
                    return
                }
                for path in paths {
                    if let roads = DrivingSceneReader.read(path: path, center: coordinate) {
                        continuation.resume(returning: (roads, .make(roads: roads, origin: coordinate, heading: heading, hasGPS: true)))
                        return
                    }
                }
                continuation.resume(returning: ([], .empty))
            }
        }
        guard generation == requestedGeneration else { return }
        // Cache loads even if a newer fix is pending; don't enqueue duplicate SQLite work.
        if !reuse { roads = result.0; lastCenter = location; lastPath = paths.first }
        if pending == nil { scene = result.1 }
    }
}

enum DrivingSceneReader {
    static func read(path: String, center: CLLocationCoordinate2D) -> [DrivingSceneRoad]? {
        guard CLLocationCoordinate2DIsValid(center), center.latitude.isFinite,
              center.longitude.isFinite else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        let firmware = query(database, center: center, osm: false)
        guard let firmware else { return nil }
        let metadata = query(database, center: center, osm: true) ?? []
        var matched = Set<String>()
        let enriched = firmware.map { road -> DrivingSceneRoad in
            guard road.coordinates.count >= 2 else { return road }
            let a = road.coordinates.first!, b = road.coordinates.last!
            let midpoint = road.coordinates[road.coordinates.count / 2]
            let origin = midpoint
            let axis = DrivingScene.local(b, origin: a, heading: 0)
            let candidates = metadata.compactMap { candidate -> (DrivingSceneRoad, Double, Bool)? in
                let local = candidate.coordinates.map { DrivingScene.local($0, origin: origin, heading: 0) }
                var best = Double.infinity
                var reverse = false
                for (c, d) in zip(local, local.dropFirst()) {
                    let delta = d - c
                    guard delta.length > 0.1, axis.length > 0.1 else { continue }
                    let dot = (axis.x * delta.x + axis.z * delta.z) / (axis.length * delta.length)
                    guard abs(dot) > 0.97 else { continue }
                    let distance = distance(.init(x: 0, z: 0), to: c, d)
                    if distance < best { best = distance; reverse = dot < 0 }
                }
                guard best < 8 else { return nil }
                // Require both endpoints to agree too: don't borrow bridge/lane tags at a crossing.
                for endpoint in [a, b] {
                    let p = DrivingScene.local(endpoint, origin: origin, heading: 0)
                    let nearest = zip(local, local.dropFirst()).map { distance(p, to: $0.0, $0.1) }.min() ?? .infinity
                    guard nearest < 12 else { return nil }
                }
                return (candidate, best, reverse)
            }.sorted { $0.1 < $1.1 }
            guard let match = candidates.first else { return road }
            matched.insert(match.0.id)
            var result = road
            result.name = road.name.isEmpty ? match.0.name : road.name
            result.highway = match.0.highway
            result.lanes = match.0.lanes
            result.direction = match.0.direction.map { match.2 ? -$0 : $0 }
            result.bridge = match.0.bridge
            result.tunnel = match.0.tunnel
            result.layer = match.0.layer
            return result
        }
        return enriched + metadata.filter { candidate in
            guard matched.contains(candidate.id) else { return true }
            // Suppress only a fully covered OSM way. A 15 m firmware link must not erase
            // the remaining hundreds of metres of the same presentation geometry.
            let points = candidate.coordinates.map { DrivingScene.local($0, origin: center, heading: 0) }
            let coverage = enriched.map { road in
                road.coordinates.map { DrivingScene.local($0, origin: center, heading: 0) }
            }
            let samples = points + zip(points, points.dropFirst()).map { ($0 + $1) * 0.5 }
            return !samples.allSatisfy { point in
                coverage.contains { line in
                    zip(line, line.dropFirst()).contains { distance(point, to: $0.0, $0.1) < 4 }
                }
            }
        }
    }

    static func distance(_ p: DrivingScenePoint, to a: DrivingScenePoint, _ b: DrivingScenePoint) -> Double {
        let delta = b - a
        guard delta.length > 0.01 else { return (p - a).length }
        let q = p - a
        let t = max(0, min(1, (q.x * delta.x + q.z * delta.z) / pow(delta.length, 2)))
        return (p - (a + delta * t)).length
    }

    private static func query(_ database: OpaquePointer?, center: CLLocationCoordinate2D,
                              osm: Bool) -> [DrivingSceneRoad]? {
        let latitudeDelta = 650.0 / 111_195
        let longitudeDelta = latitudeDelta / max(0.1, cos(center.latitude * .pi / 180))
        let table = osm ? "road_rules" : "map_data_road_links"
        let join = osm ? "rule_id" : "link_id"
        let fields = osm ? "s.id, s.geometry_json, s.road_name, s.raw_tags_json" :
            "s.id, s.geometry_json, s.inline_road_name, '{}'"
        let sql = """
            SELECT \(fields) FROM \(table)_rtree r JOIN \(table) s ON s.id = r.\(join)
            WHERE r.min_lat <= ? AND r.max_lat >= ? AND r.min_lon <= ? AND r.max_lon >= ?
            ORDER BY ((r.min_lat+r.max_lat)/2-?)*((r.min_lat+r.max_lat)/2-?)
                   + ((r.min_lon+r.max_lon)/2-?)*((r.min_lon+r.max_lon)/2-?)
            LIMIT \(osm ? 120 : 180);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        for (index, value) in [center.latitude + latitudeDelta, center.latitude - latitudeDelta,
                               center.longitude + longitudeDelta, center.longitude - longitudeDelta,
                               center.latitude, center.latitude, center.longitude, center.longitude].enumerated() {
            sqlite3_bind_double(statement, Int32(index + 1), value)
        }
        var result: [DrivingSceneRoad] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let data = text(statement, 1)?.data(using: .utf8),
                  let pairs = try? JSONDecoder().decode([[Double]].self, from: data) else { continue }
            let coordinates = pairs.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite,
                      abs(pair[0]) <= 180, abs(pair[1]) <= 90 else { return nil }
                return .init(latitude: pair[1], longitude: pair[0])
            }
            guard coordinates.count >= 2 else { continue }
            let tags = text(statement, 3)?.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            let highway = tags["highway"] as? String ?? ""
            if ["footway", "path", "cycleway", "steps", "pedestrian", "construction"].contains(highway) { continue }
            let oneWay = (tags["oneway"] as? String)?.lowercased()
            let implicitOneWay = highway == "motorway" || (tags["junction"] as? String) == "roundabout"
            let direction: Int?
            if !osm { direction = nil }
            else if oneWay == "-1" { direction = -1 }
            else if ["no", "false", "0"].contains(oneWay ?? "") { direction = 0 }
            else if ["yes", "true", "1"].contains(oneWay ?? "") || implicitOneWay { direction = 1 }
            else if oneWay == nil { direction = 0 }
            else { direction = nil } // reversible/alternating: do not invent the active direction.
            let lanes = (tags["lanes"] as? String).flatMap(Int.init)
            let bridge = positive(tags["bridge"])
            let tunnel = positive(tags["tunnel"])
            let layer = (tags["layer"] as? String).flatMap(Int.init) ?? (bridge ? 1 : tunnel ? -1 : 0)
            result.append(.init(id: "\(osm ? "osm" : "firmware")-\(sqlite3_column_int64(statement, 0))",
                                coordinates: coordinates, name: text(statement, 2) ?? "", highway: highway,
                                lanes: lanes, direction: direction, bridge: bridge, tunnel: tunnel,
                                layer: max(-3, min(3, layer))))
        }
        return result
    }

    private static func positive(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !["", "no", "false", "0"].contains(value.lowercased())
    }
    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
