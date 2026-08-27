import CoreLocation
import Foundation
import OSLog
import SQLite3

final class OfflineAlertStore {
    private struct FirmwareRoadCandidate {
        let id: Int
        let roadSerialNumber: Int
        let inlineRoadName: String
        let direction1Name: String
        let direction2Name: String
        let direction1Speed: Int
        let direction2Speed: Int
        let coordinates: [CLLocationCoordinate2D]

        func roadName(forDirection1: Bool) -> String {
            if !inlineRoadName.isEmpty { return inlineRoadName }
            let name = forDirection1 ? direction1Name : direction2Name
            if !name.isEmpty { return name }
            return forDirection1 ? direction2Name : direction1Name
        }
    }

    private static let databaseContract = "vn.vietdrive.map-data"
    private static let databaseContractVersion = 1
    private static let databaseSchemaVersion = 6
    private static let logger = Logger(subsystem: "vn.vietdrive.ios", category: "SpeedLimitMatch")
    private static let supportedSpeedLimits = Set([30, 40, 50, 60, 70, 80, 90, 100, 110, 120])
    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "vn.vietdrive.database", qos: .userInitiated)
    private var previousFirmwareLocation: CLLocation?
    private var retainedRoadID: Int?
    private(set) var trafficSignCount = 0
    private(set) var suppliedSpeedObservationCount = 0
    private(set) var mapDataPointCount = 0
    private(set) var mapDataCameraCount = 0
    private(set) var mapDataSpeedPointCount = 0
    private(set) var mapDataRoadLinkCount = 0
    private(set) var turnRestrictionCount = 0
    private(set) var roadRuleCount = 0
    private(set) var pendingReviewCount = 0
    private(set) var datasetVersion = "Không rõ"

    init() {
        let downloadedPath = UserDefaults.standard.string(forKey: "activeMapDatabasePath")
        let bundledPath = Bundle.main.path(forResource: "map_database_v2", ofType: "sqlite")
        let candidates = [downloadedPath, bundledPath]
            .compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !candidates.isEmpty else {
            print("VietDrive: map_database_v2.sqlite chưa được bundle")
            return
        }

        for path in candidates {
            var candidate: OpaquePointer?
            let opened = sqlite3_open_v2(
                path,
                &candidate,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK
            if opened, let candidate, Self.isUsable(candidate) {
                database = candidate
                break
            }
            if let candidate { sqlite3_close(candidate) }
            if path == downloadedPath {
                UserDefaults.standard.removeObject(forKey: "activeMapDatabasePath")
            }
        }

        if let database {
            mapDataPointCount = Self.scalarInt(database, "SELECT COUNT(*) FROM map_data_points;")
            mapDataCameraCount = Self.scalarInt(
                database,
                "SELECT COUNT(*) FROM map_data_points WHERE type_code IN (1, 2, 4, 11);"
            )
            mapDataSpeedPointCount = Self.scalarInt(
                database,
                "SELECT COUNT(*) FROM map_data_points WHERE type_code = 1 AND speed_kmh > 0;"
            )
            mapDataRoadLinkCount = Self.scalarInt(
                database,
                "SELECT COUNT(*) FROM map_data_road_links;"
            )
            trafficSignCount = Self.scalarInt(
                database,
                "SELECT COUNT(*) FROM map_data_points WHERE type_code = 10;"
            )
            suppliedSpeedObservationCount = mapDataSpeedPointCount
            turnRestrictionCount = Self.scalarInt(database, "SELECT COUNT(*) FROM turn_restrictions;")
            roadRuleCount = Self.scalarInt(database, "SELECT COUNT(*) FROM road_rules;")
            pendingReviewCount = Self.scalarInt(
                database,
                "SELECT COUNT(*) FROM data_issues WHERE review_status = 'pending';"
            )
            datasetVersion = Self.scalarText(
                database,
                "SELECT value FROM metadata WHERE key = 'dataset_version';"
            ) ?? "Không rõ"
        } else {
            print("VietDrive: không tìm thấy database map-data contract v1/schema v6 hợp lệ")
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    /// Truy vấn độc lập theo vùng bản đồ đang nhìn. Không áp dụng bộ lọc
    /// tuyến/hướng lái vì đây là lớp hiển thị, không phải cảnh báo bằng giọng nói.
    func mapDataPoints(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        completion: @escaping ([DriveAlert]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let database = self.database else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let centerLocation = CLLocation(
                latitude: center.latitude,
                longitude: center.longitude
            )
            let points = self.queryMapDataPoints(
                database: database,
                location: centerLocation,
                radiusMeters: min(max(radiusMeters, 500), 50_000)
            )
            DispatchQueue.main.async { completion(points) }
        }
    }

    func nearbyContext(
        location: CLLocation,
        heading: Double,
        speedKmh: Int,
        route: NavigationRoute? = nil,
        matchedDistanceMeters: Double? = nil,
        alertRadiusMeters: Double = 1_500,
        completion: @escaping (OfflineMapContext) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let database = self.database else {
                DispatchQueue.main.async {
                    completion(OfflineMapContext(
                        alerts: [], roads: [], speedLimitMatch: nil, matchedRoadRules: []
                    ))
                }
                return
            }
            let previousLocation = self.previousFirmwareLocation
            self.previousFirmwareLocation = location
            let mapDataAlerts = self.queryMapDataPoints(
                database: database,
                location: location,
                radiusMeters: 10_000
            )
            let mapDataRoads = self.queryMapDataRoadLinks(
                database: database,
                location: location,
                radiusMeters: 500
            )
            let matchedSpeed = self.matchSpeedLimit(
                roads: mapDataRoads,
                location: location,
                speedKmh: speedKmh,
                heading: heading,
                previousLocation: previousLocation
            ) ?? self.matchMapDataSpeedPoint(
                mapDataAlerts,
                location: location,
                heading: heading,
                speedKmh: speedKmh,
                route: route,
                matchedDistanceMeters: matchedDistanceMeters
            )
            let roadRuleResults = self.queryRoadRuleAlerts(
                database: database,
                location: location
            )
            let turnRestrictions = self.queryTurnRestrictions(
                database: database,
                location: location
            )
            let allCandidates = mapDataAlerts + roadRuleResults.alerts + turnRestrictions
            let alerts = self.routeAwareAlerts(
                allCandidates,
                location: location,
                heading: heading,
                speedKmh: speedKmh,
                route: route,
                matchedDistanceMeters: matchedDistanceMeters,
                radiusMeters: alertRadiusMeters
            )
            let context = OfflineMapContext(
                alerts: alerts,
                // Road links are queried only for map matching. Drawing them
                // as annotations duplicates the LibreMap base and can add
                // hundreds of polylines on every GPS update.
                roads: [],
                speedLimitMatch: matchedSpeed,
                matchedRoadRules: roadRuleResults.matchedRules
            )
            if let matchedSpeed {
                Self.logger.debug(
                    "limit=\(matchedSpeed.limit, privacy: .public) source=\(matchedSpeed.source, privacy: .public) road=\(matchedSpeed.roadName, privacy: .public) distance=\(matchedSpeed.distanceMeters, format: .fixed(precision: 1), privacy: .public)"
                )
            } else {
                Self.logger.debug(
                    "limit=unknown lat=\(location.coordinate.latitude, format: .fixed(precision: 5), privacy: .private) lon=\(location.coordinate.longitude, format: .fixed(precision: 5), privacy: .private)"
                )
            }
            DispatchQueue.main.async { completion(context) }
        }
    }

    /// Lớp nghiệp vụ duy nhất được đắp lên nền MapLibre. Các bảng OSM/legacy
    /// vẫn nằm trong database để kiểm toán nhưng không tham gia cảnh báo lái xe.
    private func queryMapDataPoints(
        database: OpaquePointer,
        location: CLLocation,
        radiusMeters: Double
    ) -> [DriveAlert] {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: radiusMeters)
        let query = """
            SELECT p.id, p.source_node_id, p.type_code, p.latitude, p.longitude,
                   p.speed_kmh, p.direction_type, p.direction_degrees,
                   p.warning_text, p.source, p.source_ref, p.confidence
            FROM map_data_points_rtree r
            JOIN map_data_points p ON p.id = r.point_id
            WHERE r.min_lat <= ? AND r.max_lat >= ?
              AND r.min_lon <= ? AND r.max_lon >= ?
            LIMIT 5000;
            """
        var statement: OpaquePointer?
        var result: [DriveAlert] = []
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        Self.bind(bounds, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            let latitude = sqlite3_column_double(statement, 3)
            let longitude = sqlite3_column_double(statement, 4)
            let distance = location.distance(from: CLLocation(
                latitude: latitude,
                longitude: longitude
            ))
            guard distance <= radiusMeters else { continue }
            let typeCode = Int(sqlite3_column_int(statement, 2))
            let speed = Int(sqlite3_column_int(statement, 5))
            let rawWarning = Self.text(statement, 8)
            let directionType = Int(sqlite3_column_int(statement, 6))

            let kind: AlertKind
            let signCode: String
            let assetName: String?
            let message: String

            switch typeCode {
            case 1:
                kind = speed > 0 ? .speedLimit : .camera
                signCode = "IGO:1"
                assetName = speed > 0 ? "TrafficSigns/TrafficSign_P127_\(speed)" : "TrafficSigns/TrafficSign_CameraSpeed"
                message = rawWarning ?? (speed > 0 ? "Biển giới hạn tốc độ \(speed) km/h" : "Camera giám sát tốc độ")
            case 2:
                kind = .camera
                signCode = "IGO:2"
                assetName = "TrafficSigns/TrafficSign_CameraTraffic"
                message = rawWarning ?? "Camera đèn tín hiệu giao thông"
            case 4:
                kind = .camera
                signCode = "IGO:4"
                assetName = "TrafficSigns/TrafficSign_CameraSection"
                message = rawWarning ?? "Camera đo tốc độ theo đoạn"
            case 5:
                kind = .toll
                signCode = "IGO:5"
                assetName = "TrafficSigns/TrafficSign_Toll"
                message = rawWarning ?? "Trạm thu phí"
            case 10:
                kind = .roadSign
                signCode = "IGO:10"
                assetName = "TrafficSigns/TrafficSign_R420"
                message = rawWarning ?? "Khu đông dân cư"
            case 11:
                kind = .camera
                signCode = "IGO:11"
                assetName = "TrafficSigns/TrafficSign_CameraDual"
                message = rawWarning ?? (speed > 0 ? "Camera phạt nguội đèn đỏ và tốc độ \(speed) km/h" : "Camera phạt nguội đèn đỏ và tốc độ")
            default:
                kind = .hazard
                signCode = "IGO:\(typeCode)"
                assetName = nil
                message = rawWarning ?? "Cảnh báo giao thông"
            }

            result.append(DriveAlert(
                id: 50_000_000 + Int(sqlite3_column_int(statement, 0)),
                kind: kind,
                speedLimit: speed,
                latitude: latitude,
                longitude: longitude,
                message: message,
                province: "",
                distanceMeters: distance,
                signCode: signCode,
                assetName: assetName,
                source: Self.text(statement, 9) ?? "map-data/edogen.bin",
                sourceReference: Self.text(statement, 10),
                confidence: sqlite3_column_double(statement, 11),
                directionDegrees: directionType == 0 || sqlite3_column_type(statement, 7) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 7),
                directionType: directionType
            ))
        }
        return result.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private func queryAlerts(
        database: OpaquePointer,
        location: CLLocation,
        heading: Double,
        speedKmh: Int,
        radiusMeters: Double
    ) -> [DriveAlert] {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: 10_000)
        let query = """
            SELECT a.id, a.type, a.latitude, a.longitude, a.warning_text,
                   a.speed_kmh, a.sign_code, a.asset_name, a.source,
                   a.source_ref, a.confidence, a.conditional, a.direction_degrees
            FROM alerts_rtree r
            JOIN alerts a ON a.id = r.alert_id
            WHERE r.min_lat <= ? AND r.max_lat >= ?
              AND r.min_lon <= ? AND r.max_lon >= ?;
            """
        var statement: OpaquePointer?
        var alerts: [DriveAlert] = []
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_bind_double(statement, 1, bounds.maxLatitude)
        sqlite3_bind_double(statement, 2, bounds.minLatitude)
        sqlite3_bind_double(statement, 3, bounds.maxLongitude)
        sqlite3_bind_double(statement, 4, bounds.minLongitude)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let typeText = Self.text(statement, 1),
                  let message = Self.text(statement, 4) else { continue }
            let coordinate = CLLocationCoordinate2D(
                latitude: sqlite3_column_double(statement, 2),
                longitude: sqlite3_column_double(statement, 3)
            )
            let alertLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = location.distance(from: alertLocation)
            let kind = AlertKind(databaseValue: typeText)
            let allowedRadius = kind == .roadSign ? 10_000.0 : radiusMeters
            guard distance <= allowedRadius else { continue }

            alerts.append(DriveAlert(
                id: Int(sqlite3_column_int(statement, 0)),
                kind: kind,
                speedLimit: Int(sqlite3_column_int(statement, 5)),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                message: message,
                province: "",
                distanceMeters: distance,
                signCode: Self.text(statement, 6),
                assetName: Self.text(statement, 7),
                source: Self.text(statement, 8) ?? "",
                sourceReference: Self.text(statement, 9),
                confidence: sqlite3_column_double(statement, 10),
                conditional: Self.text(statement, 11),
                directionDegrees: sqlite3_column_type(statement, 12) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 12)
            ))
        }
        return alerts.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// Lớp dữ liệu tốc độ do người dùng cung cấp đã được normalize vào
    /// `speed_observations`, nhưng trước đây app không query nên 2.049 điểm bị
    /// ẩn hoàn toàn. Chúng được trả về như một lớp MapLibre có thể kiểm tra.
    private func querySuppliedSpeedObservations(
        database: OpaquePointer,
        location: CLLocation,
        radiusMeters: Double
    ) -> [DriveAlert] {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: radiusMeters)
        let query = """
            SELECT id, speed_kmh, latitude, longitude, source_province
            FROM speed_observations
            WHERE latitude BETWEEN ? AND ?
              AND longitude BETWEEN ? AND ?
            LIMIT 500;
            """
        var statement: OpaquePointer?
        var observations: [DriveAlert] = []
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_bind_double(statement, 1, bounds.minLatitude)
        sqlite3_bind_double(statement, 2, bounds.maxLatitude)
        sqlite3_bind_double(statement, 3, bounds.minLongitude)
        sqlite3_bind_double(statement, 4, bounds.maxLongitude)

        while sqlite3_step(statement) == SQLITE_ROW {
            let speed = Int(sqlite3_column_int(statement, 1))
            guard Self.supportedSpeedLimits.contains(speed) else { continue }
            let latitude = sqlite3_column_double(statement, 2)
            let longitude = sqlite3_column_double(statement, 3)
            let observationLocation = CLLocation(latitude: latitude, longitude: longitude)
            let distance = location.distance(from: observationLocation)
            guard distance <= radiusMeters else { continue }
            observations.append(DriveAlert(
                id: 40_000_000 + Int(sqlite3_column_int(statement, 0)),
                kind: .speedLimit,
                speedLimit: speed,
                latitude: latitude,
                longitude: longitude,
                message: "Điểm dữ liệu giới hạn tốc độ \(speed) km/h",
                province: Self.text(statement, 4) ?? "",
                distanceMeters: distance,
                signCode: "P127.\(speed)",
                assetName: "TrafficSigns/TrafficSign_P127_\(speed)",
                source: "Dữ liệu tốc độ VietDrive cung cấp",
                confidence: 0.65
            ))
        }
        return observations.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private func queryTurnRestrictions(
        database: OpaquePointer,
        location: CLLocation
    ) -> [DriveAlert] {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: 10_000)
        let query = """
            SELECT t.id, t.restriction, t.warning_text, t.latitude, t.longitude,
                   t.vehicle, t.conditional, t.except_text, t.source,
                   t.source_ref, t.confidence
            FROM turn_restrictions_rtree r
            JOIN turn_restrictions t ON t.id = r.restriction_id
            WHERE r.min_lat <= ? AND r.max_lat >= ?
              AND r.min_lon <= ? AND r.max_lon >= ?
            LIMIT 300;
            """
        var statement: OpaquePointer?
        var result: [DriveAlert] = []
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        Self.bind(bounds, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            let latitude = sqlite3_column_double(statement, 3)
            let longitude = sqlite3_column_double(statement, 4)
            let conditional = Self.text(statement, 6) ?? ""
            let exceptText = (Self.text(statement, 7) ?? "").lowercased()
            guard !exceptText.contains("motorcar"),
                  ConditionalRuleEvaluator.isPotentiallyActive(conditional) else { continue }
            let coordinate = CLLocation(latitude: latitude, longitude: longitude)
            let restrictionCode = Self.text(statement, 1) ?? ""
            var message = Self.text(statement, 2) ?? "Hạn chế hướng đi"
            if !conditional.isEmpty { message += " · \(conditional)" }
            result.append(DriveAlert(
                id: 10_000_000 + Int(sqlite3_column_int(statement, 0)),
                kind: .turnRestriction,
                speedLimit: 0,
                latitude: latitude,
                longitude: longitude,
                message: message,
                province: "",
                distanceMeters: location.distance(from: coordinate),
                signCode: restrictionCode,
                assetName: Self.assetName(forRestriction: restrictionCode),
                source: Self.text(statement, 8) ?? "OpenStreetMap",
                sourceReference: Self.text(statement, 9),
                confidence: sqlite3_column_double(statement, 10),
                conditional: conditional
            ))
        }
        return result
    }

    private func queryRoadRuleAlerts(
        database: OpaquePointer,
        location: CLLocation
    ) -> (alerts: [DriveAlert], matchedRules: [String]) {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: 2_000)
        let query = """
            SELECT rr.id, rr.rules_json, rr.road_name, rr.geometry_json,
                   rr.source, rr.source_ref, rr.confidence
            FROM road_rules_rtree r
            JOIN road_rules rr ON rr.id = r.rule_id
            WHERE r.min_lat <= ? AND r.max_lat >= ?
              AND r.min_lon <= ? AND r.max_lon >= ?
            LIMIT 240;
            """
        var statement: OpaquePointer?
        var alerts: [DriveAlert] = []
        var matchedRules: [String] = []
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return ([], [])
        }
        Self.bind(bounds, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rulesText = Self.text(statement, 1),
                  let rulesData = rulesText.data(using: .utf8),
                  let rules = try? JSONSerialization.jsonObject(with: rulesData) as? [String: String],
                  let geometryText = Self.text(statement, 3),
                  let geometryData = geometryText.data(using: .utf8),
                  let pairs = try? JSONSerialization.jsonObject(with: geometryData) as? [[Double]]
            else { continue }
            let coordinates = pairs.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
            guard let nearest = Self.nearestCoordinate(
                to: location.coordinate,
                in: coordinates
            ), nearest.distance <= 80 else { continue }
            matchedRules.append(contentsOf: rules.map { "\($0.key)=\($0.value)" })

            let parking = rules.first { key, value in
                key.contains("parking") && ["no", "no_parking", "no_stopping"].contains(value.lowercased())
            }
            let access = rules.first { key, value in
                ["access", "motor_vehicle", "motorcar"].contains(key)
                    && ["no", "private", "destination", "delivery"].contains(value.lowercased())
            }
            guard parking != nil || access != nil else { continue }
            let message: String
            let kind: AlertKind
            let assetName: String?
            if let parking {
                kind = .parkingRestriction
                let val = parking.value.lowercased()
                let isStopping = val.contains("stopping")
                let isOdd = val.contains("odd")
                let isEven = val.contains("even")
                if isStopping {
                    message = "Cấm dừng và đỗ xe"
                    assetName = "TrafficSigns/TrafficSign_P130"
                } else if isOdd {
                    message = "Cấm đỗ xe ngày lẻ"
                    assetName = "TrafficSigns/TrafficSign_P131b"
                } else if isEven {
                    message = "Cấm đỗ xe ngày chẵn"
                    assetName = "TrafficSigns/TrafficSign_P131c"
                } else {
                    message = "Cấm đỗ xe"
                    assetName = "TrafficSigns/TrafficSign_P131a"
                }
            } else {
                kind = .turnRestriction
                message = "Đường hạn chế phương tiện"
                assetName = "TrafficSigns/TrafficSign_P101"
            }
            alerts.append(DriveAlert(
                id: 20_000_000 + Int(sqlite3_column_int(statement, 0)),
                kind: kind,
                speedLimit: 0,
                latitude: nearest.coordinate.latitude,
                longitude: nearest.coordinate.longitude,
                message: message,
                province: Self.text(statement, 2) ?? "",
                distanceMeters: nearest.distance,
                signCode: parking?.key ?? access?.key,
                assetName: assetName,
                source: Self.text(statement, 4) ?? "OpenStreetMap",
                sourceReference: Self.text(statement, 5),
                confidence: sqlite3_column_double(statement, 6)
            ))
        }
        return (alerts, Array(Set(matchedRules)).sorted())
    }

    private func routeAwareAlerts(
        _ alerts: [DriveAlert],
        location: CLLocation,
        heading: Double,
        speedKmh: Int,
        route: NavigationRoute?,
        matchedDistanceMeters: Double?,
        radiusMeters: Double
    ) -> [DriveAlert] {
        alerts.compactMap { alert in
            guard ConditionalRuleEvaluator.isPotentiallyActive(alert.conditional ?? "") else {
                return nil
            }
            var candidate = alert
            if let direction = alert.directionDegrees, speedKmh >= 8,
               !Self.directionMatches(
                    heading,
                    target: direction,
                    directionType: alert.directionType
               ) { return nil }
            if let route,
               let projection = RouteProgressEngine.projection(on: route, coordinate: alert.coordinate),
               let currentDistance = matchedDistanceMeters
                    ?? RouteProgressEngine.projection(on: route, coordinate: location.coordinate)?.distanceAlongRouteMeters {
                if let direction = alert.directionDegrees,
                   !Self.directionMatches(
                        projection.segmentBearing,
                        target: direction,
                        directionType: alert.directionType
                   ) {
                    return nil
                }
                let lateralLimit: Double = alert.kind == .camera ? 130 : 65
                let ahead = projection.distanceAlongRouteMeters - currentDistance
                guard projection.lateralDistanceMeters <= lateralLimit,
                      ahead >= -30, ahead <= 3_500 else { return nil }
                candidate.distanceMeters = max(0, ahead)
                candidate.distanceAlongRouteMeters = projection.distanceAlongRouteMeters
                candidate.lateralDistanceMeters = projection.lateralDistanceMeters
                return candidate
            }
            guard alert.distanceMeters <= radiusMeters || alert.kind == .roadSign else { return nil }
            if speedKmh >= 8, alert.distanceMeters > 70 {
                let alertBearing = Self.bearing(from: location.coordinate, to: alert.coordinate)
                guard Self.angleDifference(heading, alertBearing) <= 75 else { return nil }
            }
            return candidate
        }
        .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// map-data type 1 stores the enforced speed together with camera position
    /// and direction. It replaces both OSM maxspeed and recovered road estimates.
    private func matchMapDataSpeedPoint(
        _ alerts: [DriveAlert],
        location: CLLocation,
        heading: Double,
        speedKmh: Int,
        route: NavigationRoute?,
        matchedDistanceMeters: Double?
    ) -> SpeedLimitMatch? {
        let currentRouteDistance = route.flatMap {
            matchedDistanceMeters
                ?? RouteProgressEngine.projection(
                    on: $0,
                    coordinate: location.coordinate
                )?.distanceAlongRouteMeters
        }
        var best: (score: Double, match: SpeedLimitMatch)?
        for alert in alerts where alert.isMapDataSpeedPoint {
            var candidateDistance = alert.distanceMeters
            var alignment: Double?
            var score: Double
            if let route, let currentRouteDistance,
               let projection = RouteProgressEngine.projection(
                    on: route,
                    coordinate: alert.coordinate
               ) {
                let ahead = projection.distanceAlongRouteMeters - currentRouteDistance
                guard projection.lateralDistanceMeters <= 130,
                      ahead >= -50, ahead <= 1_500 else { continue }
                if let direction = alert.directionDegrees {
                    let difference = Self.directionDifference(
                        projection.segmentBearing,
                        target: direction,
                        directionType: alert.directionType
                    )
                    guard difference <= 70 else { continue }
                    alignment = difference
                }
                candidateDistance = max(0, ahead)
                score = projection.lateralDistanceMeters * 3
                    + max(0, ahead) * 0.08
                    + (ahead < 0 ? 80 : 0)
                    + (alignment ?? 0) * 0.4
            } else {
                guard alert.distanceMeters <= 1_500 else { continue }
                if let direction = alert.directionDegrees, speedKmh >= 8 {
                    let difference = Self.directionDifference(
                        heading,
                        target: direction,
                        directionType: alert.directionType
                    )
                    guard difference <= 70 else { continue }
                    alignment = difference
                }
                if speedKmh >= 8, alert.distanceMeters > 60 {
                    let bearing = Self.bearing(
                        from: location.coordinate,
                        to: alert.coordinate
                    )
                    guard Self.angleDifference(heading, bearing) <= 75 else { continue }
                }
                score = alert.distanceMeters + (alignment ?? 0) * 0.4
            }
            let sourceID = alert.sourceReference?.split(separator: "#").last ?? "?"
            let match = SpeedLimitMatch(
                limit: alert.speedLimit,
                roadName: "Điểm map-data #\(sourceID)",
                source: "map-data/edogen.bin (iGO type 1)",
                distanceMeters: candidateDistance,
                alignmentDegrees: alignment,
                canTriggerDrivingAlerts: true
            )
            if best == nil || score < best!.score { best = (score, match) }
        }
        return best?.match
    }

    /// Mạng đường gốc trong roadsenz.bin có giới hạn riêng cho chiều dương
    /// (theo thứ tự geometry) và chiều âm. Đây là nguồn tốc độ hiện hành;
    /// các điểm iGO type 1 chỉ còn là vị trí camera sắp tới.
    private func queryMapDataRoadLinks(
        database: OpaquePointer,
        location: CLLocation,
        radiusMeters: Double
    ) -> [FirmwareRoadCandidate] {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: radiusMeters)
        let query = """
            SELECT l.id, l.road_serial_number,
                   COALESCE(l.inline_road_name, ''),
                   COALESCE(n1.label, ''),
                   COALESCE(n2.label, ''),
                   l.direction_1_speed_kmh, l.direction_2_speed_kmh,
                   l.geometry_json
            FROM map_data_road_links_rtree r
            JOIN map_data_road_links l ON l.id = r.link_id
            LEFT JOIN map_data_name_lookup n1 ON n1.id = l.direction_1_name_id
            LEFT JOIN map_data_name_lookup n2 ON n2.id = l.direction_2_name_id
            WHERE r.min_lat <= ? AND r.max_lat >= ?
              AND r.min_lon <= ? AND r.max_lon >= ?;
            """
        var statement: OpaquePointer?
        var roads: [FirmwareRoadCandidate] = []
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        Self.bind(bounds, to: statement)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let geometryText = Self.text(statement, 7),
                  let geometryData = geometryText.data(using: .utf8),
                  let pairs = try? JSONSerialization.jsonObject(with: geometryData) as? [[Double]]
            else { continue }
            let coordinates = pairs.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
            guard coordinates.count >= 2 else { continue }

            roads.append(FirmwareRoadCandidate(
                id: Int(sqlite3_column_int(statement, 0)),
                roadSerialNumber: Int(sqlite3_column_int(statement, 1)),
                inlineRoadName: Self.text(statement, 2) ?? "",
                direction1Name: Self.text(statement, 3) ?? "",
                direction2Name: Self.text(statement, 4) ?? "",
                direction1Speed: Int(sqlite3_column_int(statement, 5)),
                direction2Speed: Int(sqlite3_column_int(statement, 6)),
                coordinates: coordinates
            ))
        }
        return roads
    }

    private func queryRoads(
        database: OpaquePointer,
        location: CLLocation,
        radiusMeters: Double
    ) -> [RoadOverlay] {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: radiusMeters)
        let query = """
            SELECT s.id, s.speed_kmh, s.geometry_json
            FROM road_segments_rtree r
            JOIN road_segments s ON s.id = r.segment_id
            WHERE r.min_lat <= ? AND r.max_lat >= ?
              AND r.min_lon <= ? AND r.max_lon >= ?
            LIMIT 120;
            """
        var statement: OpaquePointer?
        var roads: [RoadOverlay] = []
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_bind_double(statement, 1, bounds.maxLatitude)
        sqlite3_bind_double(statement, 2, bounds.minLatitude)
        sqlite3_bind_double(statement, 3, bounds.maxLongitude)
        sqlite3_bind_double(statement, 4, bounds.minLongitude)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let geometryText = Self.text(statement, 2),
                  let data = geometryText.data(using: .utf8),
                  let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
            else { continue }
            let coordinates = pairs.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
            guard coordinates.count >= 2 else { continue }
            roads.append(RoadOverlay(
                id: Int(sqlite3_column_int(statement, 0)),
                speedLimit: Int(sqlite3_column_int(statement, 1)),
                coordinates: coordinates,
                speedSource: "VietDrive road_lines"
            ))
        }
        return roads
    }

    /// Nguồn road_lines khôi phục chỉ có vài trăm đoạn có tốc độ. Cơ sở dữ
    /// liệu OSM đi kèm app còn có hơn 20.000 way chứa maxspeed trong raw tags;
    /// trước đây chúng bị bỏ qua hoàn toàn nên UI thường giữ một giá trị sai.
    private func queryOSMSpeedRoads(
        database: OpaquePointer,
        location: CLLocation,
        radiusMeters: Double
    ) -> [RoadOverlay] {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: radiusMeters)
        let query = """
            SELECT rr.id, rr.road_name, rr.geometry_json,
                   rr.raw_tags_json, rr.confidence
            FROM road_rules_rtree r
            JOIN road_rules rr ON rr.id = r.rule_id
            WHERE r.min_lat <= ? AND r.max_lat >= ?
              AND r.min_lon <= ? AND r.max_lon >= ?
              AND rr.raw_tags_json LIKE '%"maxspeed%'
            LIMIT 320;
            """
        var statement: OpaquePointer?
        var roads: [RoadOverlay] = []
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        Self.bind(bounds, to: statement)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let geometryText = Self.text(statement, 2),
                  let geometryData = geometryText.data(using: .utf8),
                  let pairs = try? JSONSerialization.jsonObject(with: geometryData) as? [[Double]],
                  let tagsText = Self.text(statement, 3),
                  let tagsData = tagsText.data(using: .utf8),
                  let tags = try? JSONSerialization.jsonObject(with: tagsData) as? [String: Any]
            else { continue }
            let coordinates = pairs.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
            guard coordinates.count >= 2 else { continue }
            let rowID = Int(sqlite3_column_int(statement, 0))
            let roadName = Self.text(statement, 1) ?? ""
            let confidence = sqlite3_column_double(statement, 4)
            let common = Self.parseSpeedLimit(tags["maxspeed"])
            let forward = Self.parseSpeedLimit(tags["maxspeed:forward"])
            let backward = Self.parseSpeedLimit(tags["maxspeed:backward"])
            let wayDirection = Self.travelDirection(from: tags["oneway"])

            if forward != nil || backward != nil {
                if let limit = forward ?? (wayDirection != .reverse ? common : nil) {
                    roads.append(RoadOverlay(
                        id: 30_000_000 + rowID * 3,
                        speedLimit: limit,
                        coordinates: coordinates,
                        roadName: roadName,
                        speedSource: forward == nil
                            ? "OpenStreetMap maxspeed" : "OpenStreetMap maxspeed:forward",
                        travelDirection: .forward,
                        confidence: confidence
                    ))
                }
                if let limit = backward ?? (wayDirection != .forward ? common : nil) {
                    roads.append(RoadOverlay(
                        id: 30_000_001 + rowID * 3,
                        speedLimit: limit,
                        coordinates: coordinates,
                        roadName: roadName,
                        speedSource: backward == nil
                            ? "OpenStreetMap maxspeed" : "OpenStreetMap maxspeed:backward",
                        travelDirection: .reverse,
                        confidence: confidence
                    ))
                }
            } else if let common {
                roads.append(RoadOverlay(
                    id: 30_000_002 + rowID * 3,
                    speedLimit: common,
                    coordinates: coordinates,
                    roadName: roadName,
                    speedSource: "OpenStreetMap maxspeed",
                    travelDirection: wayDirection,
                    confidence: confidence
                ))
            }
        }
        return roads
    }

    private func matchSpeedLimit(
        roads: [FirmwareRoadCandidate],
        location: CLLocation,
        speedKmh: Int,
        heading: Double? = nil,
        previousLocation: CLLocation? = nil
    ) -> SpeedLimitMatch? {
        let movementBearing: Double? = previousLocation.flatMap { previous in
            guard previous.distance(from: location) >= 0.5 else { return nil }
            return Self.bearing(from: previous.coordinate, to: location.coordinate)
        }
        let measured = roads.compactMap { road -> (road: FirmwareRoadCandidate, distance: Double, segmentBearing: Double)? in
            guard let nearest = Self.nearestCoordinate(
                to: location.coordinate,
                in: road.coordinates
            ) else { return nil }
            return (road, nearest.distance, nearest.bearing)
        }

        // Hysteresis: Keep retained road if still within 8 meters
        let retained = measured.first { $0.road.id == retainedRoadID && $0.distance <= 8 }

        // Firmware tolerance radius: 100m when stationary / starting, 50m when moving
        let maxSearchRadius = speedKmh < 7 ? 100.0 : 50.0
        let candidate = retained ?? measured
            .filter { $0.distance <= maxSearchRadius }
            .filter { Self.supportedSpeedLimits.contains($0.road.direction1Speed) || Self.supportedSpeedLimits.contains($0.road.direction2Speed) }
            .min { $0.distance < $1.distance }
            ?? measured.filter { $0.distance <= maxSearchRadius }.min { $0.distance < $1.distance }

        guard let candidate else {
            retainedRoadID = nil
            return nil
        }

        let road = candidate.road
        let segBearing = candidate.segmentBearing
        let d1 = road.direction1Speed
        let d2 = road.direction2Speed
        let selection: (speed: Int, alignment: Double?, roadName: String)?

        if speedKmh < 7 || (movementBearing == nil && heading == nil) {
            // FIRMWARE STATIONARY LOGIC (When stopped or starting a trip):
            if d1 == d2, Self.supportedSpeedLimits.contains(d1) {
                // Symmetrical road (e.g. 50 km/h both directions) - Display immediately!
                selection = (d1, nil, road.roadName(forDirection1: true))
            } else if Self.supportedSpeedLimits.contains(d1), !Self.supportedSpeedLimits.contains(d2) {
                // One-way or single-direction speed limit
                selection = (d1, nil, road.roadName(forDirection1: true))
            } else if Self.supportedSpeedLimits.contains(d2), !Self.supportedSpeedLimits.contains(d1) {
                selection = (d2, nil, road.roadName(forDirection1: false))
            } else if let heading {
                // If heading (compass) is available while stopped, align with local subsegment
                let forward = Self.angleDifference(heading, segBearing)
                let reverse = Self.angleDifference(heading, (segBearing + 180).truncatingRemainder(dividingBy: 360))
                if forward <= 55, Self.supportedSpeedLimits.contains(d1) {
                    selection = (d1, forward, road.roadName(forDirection1: true))
                } else if reverse <= 55, Self.supportedSpeedLimits.contains(d2) {
                    selection = (d2, reverse, road.roadName(forDirection1: false))
                } else {
                    let literal = max(d1, d2)
                    let isD1 = d1 >= d2
                    selection = Self.supportedSpeedLimits.contains(literal)
                        ? (literal, nil, road.roadName(forDirection1: isD1)) : nil
                }
            } else {
                let literal = max(d1, d2)
                let isD1 = d1 >= d2
                selection = Self.supportedSpeedLimits.contains(literal)
                    ? (literal, nil, road.roadName(forDirection1: isD1)) : nil
            }
        } else {
            // FIRMWARE MOVING LOGIC: Use movement bearing (or compass heading fallback)
            let effectiveBearing = movementBearing ?? heading ?? 0
            let forward = Self.angleDifference(effectiveBearing, segBearing)
            let reverse = Self.angleDifference(
                effectiveBearing,
                (segBearing + 180).truncatingRemainder(dividingBy: 360)
            )
            let direction1: (speed: Int, alignment: Double, roadName: String)? =
                Self.supportedSpeedLimits.contains(d1) && forward <= 60
                ? (d1, forward, road.roadName(forDirection1: true)) : nil
            let direction2: (speed: Int, alignment: Double, roadName: String)? =
                Self.supportedSpeedLimits.contains(d2) && reverse <= 60
                ? (d2, reverse, road.roadName(forDirection1: false)) : nil

            if let direction1, let direction2 {
                selection = direction1.alignment <= direction2.alignment ? direction1 : direction2
            } else if let direction1 {
                selection = (direction1.speed, direction1.alignment, direction1.roadName)
            } else if let direction2 {
                selection = (direction2.speed, direction2.alignment, direction2.roadName)
            } else {
                selection = nil
            }
        }

        guard let selection else { return nil }
        retainedRoadID = road.id
        return SpeedLimitMatch(
            limit: selection.speed,
            roadName: selection.roadName,
            source: "map-data/roadsenz.bin #\(road.roadSerialNumber)",
            distanceMeters: candidate.distance,
            alignmentDegrees: selection.alignment
        )
    }

    /// Chỉ dùng điểm khôi phục cho HUD khi GPS nằm ngay trên điểm đó. Không
    /// kéo dài giá trị sang đoạn đường kế tiếp vì nguồn chưa có hướng và điểm
    /// kết thúc hiệu lực. OSM maxspeed luôn được xét trước hàm này.
    private func matchSuppliedSpeedObservation(
        _ observations: [DriveAlert],
        location: CLLocation,
        route: NavigationRoute?
    ) -> SpeedLimitMatch? {
        observations
            .filter { observation in
                guard observation.distanceMeters <= 30 else { return false }
                guard let route else { return true }
                guard let projection = RouteProgressEngine.projection(
                    on: route,
                    coordinate: observation.coordinate
                ) else { return false }
                return projection.lateralDistanceMeters <= 25
            }
            .min { $0.distanceMeters < $1.distanceMeters }
            .map { observation in
                SpeedLimitMatch(
                    limit: observation.speedLimit,
                    roadName: observation.province,
                    source: observation.source,
                    distanceMeters: location.distance(from: CLLocation(
                        latitude: observation.latitude,
                        longitude: observation.longitude
                    )),
                    alignmentDegrees: nil,
                    canTriggerDrivingAlerts: false
                )
            }
    }

    private static func parseSpeedLimit(_ rawValue: Any?) -> Int? {
        let text: String
        if let value = rawValue as? String {
            text = value
        } else if let value = rawValue as? NSNumber {
            text = value.stringValue
        } else {
            return nil
        }
        guard let match = text.range(of: #"\d{2,3}"#, options: .regularExpression),
              let value = Int(text[match]),
              supportedSpeedLimits.contains(value) else { return nil }
        return value
    }

    private static func travelDirection(from rawValue: Any?) -> RoadTravelDirection {
        let value = String(describing: rawValue ?? "").lowercased()
        if value == "-1" || value == "reverse" { return .reverse }
        if ["yes", "1", "true"].contains(value) { return .forward }
        return .both
    }

    private static func distanceToSegment(
        point: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> Double {
        nearestPointOnSegment(point: point, start: start, end: end).distance
    }

    private static func nearestPointOnSegment(
        point: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> (coordinate: CLLocationCoordinate2D, distance: Double, bearing: Double) {
        let latitudeScale = 111_320.0
        let longitudeScale = latitudeScale * cos(point.latitude * .pi / 180)
        let ax = (start.longitude - point.longitude) * longitudeScale
        let ay = (start.latitude - point.latitude) * latitudeScale
        let bx = (end.longitude - point.longitude) * longitudeScale
        let by = (end.latitude - point.latitude) * latitudeScale
        let dx = bx - ax
        let dy = by - ay
        let segBearing = bearing(from: start, to: end)
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (start, hypot(ax, ay), segBearing) }
        let projection = max(0, min(1, -(ax * dx + ay * dy) / lengthSquared))
        return (
            CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * projection,
                longitude: start.longitude + (end.longitude - start.longitude) * projection
            ),
            hypot(ax + projection * dx, ay + projection * dy),
            segBearing
        )
    }

    private static func nearestCoordinate(
        to point: CLLocationCoordinate2D,
        in coordinates: [CLLocationCoordinate2D]
    ) -> (coordinate: CLLocationCoordinate2D, distance: Double, bearing: Double)? {
        guard coordinates.count >= 2 else { return nil }
        return zip(coordinates, coordinates.dropFirst())
            .map { nearestPointOnSegment(point: point, start: $0.0, end: $0.1) }
            .min { $0.distance < $1.distance }
    }

    private static func bounds(
        around coordinate: CLLocationCoordinate2D,
        radiusMeters: Double
    ) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        let latitudeDelta = radiusMeters / 111_320
        let longitudeScale = max(0.2, cos(coordinate.latitude * .pi / 180))
        let longitudeDelta = radiusMeters / (111_320 * longitudeScale)
        return (
            coordinate.latitude - latitudeDelta,
            coordinate.latitude + latitudeDelta,
            coordinate.longitude - longitudeDelta,
            coordinate.longitude + longitudeDelta
        )
    }

    private static func bearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func angleDifference(_ left: Double, _ right: Double) -> Double {
        abs((left - right + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    private static func directionDifference(
        _ heading: Double,
        target: Double,
        directionType: Int?
    ) -> Double {
        let forward = angleDifference(heading, target)
        guard directionType == 2 else { return forward }
        return min(forward, angleDifference(heading, target + 180))
    }

    private static func directionMatches(
        _ heading: Double,
        target: Double,
        directionType: Int?
    ) -> Bool {
        directionDifference(
            heading,
            target: target,
            directionType: directionType
        ) <= 70
    }

    private static func bind(
        _ bounds: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double),
        to statement: OpaquePointer?
    ) {
        sqlite3_bind_double(statement, 1, bounds.maxLatitude)
        sqlite3_bind_double(statement, 2, bounds.minLatitude)
        sqlite3_bind_double(statement, 3, bounds.maxLongitude)
        sqlite3_bind_double(statement, 4, bounds.minLongitude)
    }



    private static func scalarInt(_ database: OpaquePointer?, _ query: String) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func isUsable(_ database: OpaquePointer?) -> Bool {
        let requiredTables = scalarInt(database, """
            SELECT COUNT(*) FROM sqlite_master
            WHERE name IN (
                'map_data_points', 'map_data_points_rtree',
                'map_data_road_links', 'map_data_road_links_rtree',
                'map_data_city_lookup', 'map_data_name_lookup', 'metadata'
            );
            """)
        let requiredColumns = scalarInt(database, """
            SELECT COUNT(*) FROM pragma_table_info('map_data_road_links')
            WHERE name IN ('road_serial_number', 'provider_road_id', 'inline_road_name',
                           'direction_1_name_id', 'direction_2_name_id',
                           'direction_1_speed_kmh', 'direction_2_speed_kmh', 'geometry_json');
            """)
        return requiredTables == 7
            && requiredColumns == 8
            && scalarInt(database, "PRAGMA user_version;") == databaseSchemaVersion
            && scalarText(database, "SELECT value FROM metadata WHERE key='contract_id';") == databaseContract
            && scalarInt(database, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='contract_version';") == databaseContractVersion
            && scalarInt(database, "SELECT COUNT(*) FROM map_data_points;") > 0
            && scalarInt(database, "SELECT COUNT(*) FROM map_data_road_links;") > 0
    }

    private static func scalarText(_ database: OpaquePointer?, _ query: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private static func assetName(forRestriction restriction: String) -> String? {
        switch restriction {
        case "no_left_turn": "TrafficSigns/TrafficSign_P123a"
        case "no_right_turn": "TrafficSigns/TrafficSign_P123b"
        case "no_u_turn": "TrafficSigns/TrafficSign_P124a"
        case "no_straight_on": "TrafficSigns/TrafficSign_NoStraight"
        case "only_straight_on": "TrafficSigns/TrafficSign_R301a"
        case "only_right_turn": "TrafficSigns/TrafficSign_R301b"
        case "only_left_turn": "TrafficSigns/TrafficSign_R301c"
        case "no_entry": "TrafficSigns/TrafficSign_P102"
        case "no_parking": "TrafficSigns/TrafficSign_P131a"
        case "no_stopping": "TrafficSigns/TrafficSign_P130"
        default: nil
        }
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }
}
