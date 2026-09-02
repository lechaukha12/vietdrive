import CoreLocation
import Foundation
import OSLog
import SQLite3

final class OfflineAlertStore {
    private struct RoadRuleSignDescriptor {
        let idBase: Int
        let kind: AlertKind
        let message: String
        let signCode: String
        let assetName: String
        let conditional: String?
    }

    private struct PolylineProjection {
        let coordinate: CLLocationCoordinate2D
        let distanceMeters: Double
        let segmentBearing: Double
        let distanceFromStartMeters: Double
        let totalLengthMeters: Double
    }

    private struct RoadContinuation {
        let road: FirmwareRoadCandidate
        let travelsAlongGeometry: Bool
        let speedLimit: Int?
        let roadName: String
        let exitCoordinate: CLLocationCoordinate2D
        let exitBearing: Double
        let lengthMeters: Double
        let score: Double
    }

    private struct FirmwareRoadCandidate {
        let id: Int
        let roadSerialNumber: Int
        let inlineRoadName: String
        let direction1Name: String
        let direction2Name: String
        let province: String
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
            ) + Self.scalarInt(
                database,
                """
                SELECT COUNT(*) FROM alerts
                WHERE type = 'road_sign'
                  AND sign_code NOT LIKE '\(TrafficSignCatalog.speedCodePrefix)%';
                """
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
            let queryRadius = min(max(radiusMeters, 500), 50_000)
            let points = self.queryMapDataPoints(
                database: database,
                location: centerLocation,
                radiusMeters: queryRadius
            )
            let physicalSigns = self.queryAlerts(
                database: database,
                location: centerLocation,
                radiusMeters: queryRadius
            ).filter(Self.isNonFirmwarePhysicalSign)
            // Parking restrictions and town boundaries are disabled.
            // OSM parking data covers < 2.5 k roads nationwide with extreme
            // geographic bias (283 in Hanoi, 0 in Phan Thiết) — showing them
            // implies "no marker = parking OK" which is dangerously wrong.
            // Firmware town-boundary (type 10) markers are scattered inside
            // dense urban areas where they have no real-world meaning.
            DispatchQueue.main.async {
                completion(
                    (points.filter { !$0.isFirmwareTownEntry } + physicalSigns)
                        .sorted { $0.distanceMeters < $1.distanceMeters }
                )
            }
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
                        alerts: [], roads: [], speedLimitMatch: nil, nextSpeedMatch: nil, matchedRoadRules: []
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
            // In free-drive there is no intended maneuver, so an OSM access
            // rule or turn relation cannot safely be presented as a physical
            // sign ahead. Parking restrictions are also disabled: the OSM
            // dataset covers < 2.5 k roads with extreme geographic bias
            // (283 Hanoi, 60 HCM, 0 Phan Thiết) making them misleading.
            let roadRuleResults: (alerts: [DriveAlert], matchedRules: [String])
            let turnRestrictions: [DriveAlert]
            if route == nil {
                roadRuleResults = ([], [])
                turnRestrictions = []
            } else {
                roadRuleResults = self.queryRoadRuleAlerts(
                    database: database,
                    location: location,
                    queryRadiusMeters: 400,
                    maximumRuleDistanceMeters: 25
                )
                turnRestrictions = self.queryTurnRestrictions(
                    database: database,
                    location: location,
                    radiusMeters: 5_000
                )
            }
            // Physical OSM sign nodes are a separate audited table. They were
            // previously loaded by queryAlerts() but never joined into either
            // the driving context or viewport, which made every non-firmware
            // prohibition sign effectively invisible. Firmware speed signs
            // remain authoritative and are deliberately not duplicated here.
            let physicalSigns = self.queryAlerts(
                database: database,
                location: location,
                radiusMeters: route == nil ? alertRadiusMeters : 10_000
            ).filter(Self.isNonFirmwarePhysicalSign)
            let allCandidates = mapDataAlerts + physicalSigns
                + roadRuleResults.alerts + turnRestrictions
            let matchedLimit = matchedSpeed?.limit ?? 0
            let rawAlerts = self.routeAwareAlerts(
                allCandidates,
                location: location,
                heading: heading,
                speedKmh: speedKmh,
                route: route,
                matchedDistanceMeters: matchedDistanceMeters,
                radiusMeters: alertRadiusMeters
            )
            // Suppress ALL town-boundary alerts. Firmware type-10 markers
            // are scattered inside dense city areas where they have no
            // real-world meaning. Until a reliable boundary data source is
            // available, these alerts do more harm than good.
            let alerts = rawAlerts.filter { $0.kind != .townBoundary }
            let nextSpeed = self.lookaheadNextSpeedMatch(
                currentRoadID: matchedSpeed != nil ? retainedRoadID : nil,
                currentSpeedLimit: matchedSpeed?.limit ?? 0,
                location: location,
                heading: heading,
                speedKmh: speedKmh,
                roads: mapDataRoads
            )
            let context = OfflineMapContext(
                alerts: alerts,
                // Road links are queried only for map matching. Drawing them
                // as annotations duplicates the LibreMap base and can add
                // hundreds of polylines on every GPS update.
                roads: [],
                speedLimitMatch: matchedSpeed,
                nextSpeedMatch: nextSpeed,
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

            let definition = TrafficSignCatalog.firmwareAlert(
                typeCode: typeCode,
                speedLimit: speed,
                warningText: rawWarning
            )

            result.append(DriveAlert(
                id: 50_000_000 + Int(sqlite3_column_int(statement, 0)),
                kind: definition.kind,
                speedLimit: speed,
                latitude: latitude,
                longitude: longitude,
                message: definition.message,
                province: "",
                distanceMeters: distance,
                signCode: definition.signCode,
                assetName: definition.assetName,
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
        radiusMeters: Double
    ) -> [DriveAlert] {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: radiusMeters)
        let query = """
            SELECT a.id, a.type, a.latitude, a.longitude, a.warning_text,
                   a.speed_kmh, a.sign_code, a.asset_name, a.source,
                   a.source_ref, a.confidence, a.conditional, a.direction_degrees,
                   a.direction_scope
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
            guard distance <= radiusMeters else { continue }
            let speed = Int(sqlite3_column_int(statement, 5))
            let storedCode = Self.text(statement, 6)
            let storedAsset = Self.text(statement, 7)
            let canonicalCode = TrafficSignCatalog.canonicalCode(
                for: storedCode,
                speedLimit: speed,
                assetName: storedAsset
            ) ?? storedCode

            alerts.append(DriveAlert(
                id: Int(sqlite3_column_int(statement, 0)),
                kind: kind,
                speedLimit: speed,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                message: message,
                province: "",
                distanceMeters: distance,
                signCode: canonicalCode,
                assetName: TrafficSignCatalog.assetName(
                    for: canonicalCode,
                    speedLimit: speed
                ) ?? storedAsset,
                source: Self.text(statement, 8) ?? "",
                sourceReference: Self.text(statement, 9),
                confidence: sqlite3_column_double(statement, 10),
                conditional: Self.text(statement, 11),
                directionDegrees: sqlite3_column_type(statement, 12) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 12),
                directionScope: Self.text(statement, 13)
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
                signCode: TrafficSignCatalog.speedCode(speed),
                assetName: TrafficSignCatalog.assetName(
                    for: TrafficSignCatalog.speedCode(speed)
                ),
                source: "Dữ liệu tốc độ VietDrive cung cấp",
                confidence: 0.65
            ))
        }
        return observations.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private func queryTurnRestrictions(
        database: OpaquePointer,
        location: CLLocation,
        radiusMeters: Double
    ) -> [DriveAlert] {
        let bounds = Self.bounds(around: location.coordinate, radiusMeters: radiusMeters)
        let query = """
            SELECT t.id, t.restriction, t.warning_text, t.latitude, t.longitude,
                   t.vehicle, t.conditional, t.except_text, t.source,
                   t.source_ref, t.confidence
            FROM turn_restrictions_rtree r
            JOIN turn_restrictions t ON t.id = r.restriction_id
            WHERE r.min_lat <= ? AND r.max_lat >= ?
              AND r.min_lon <= ? AND r.max_lon >= ?
            LIMIT 2_000;
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
            let distance = location.distance(from: coordinate)
            guard distance <= radiusMeters else { continue }
            let restrictionCode = Self.text(statement, 1) ?? ""
            let canonicalCode = TrafficSignCatalog.canonicalRestrictionCode(restrictionCode)
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
                distanceMeters: distance,
                signCode: canonicalCode ?? restrictionCode,
                assetName: TrafficSignCatalog.assetName(for: canonicalCode),
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
        location: CLLocation,
        queryRadiusMeters: Double,
        maximumRuleDistanceMeters: Double,
        parkingOnly: Bool = false
    ) -> (alerts: [DriveAlert], matchedRules: [String]) {
        // Query a compact spatial window before applying LIMIT. The previous
        // 2 km window could contain thousands of R-tree rows; SQLite then
        // returned an arbitrary first 240 and frequently discarded the road
        // directly under the vehicle before geometry matching happened.
        let bounds = Self.bounds(
            around: location.coordinate,
            radiusMeters: queryRadiusMeters
        )
        let query = """
            SELECT rr.id, rr.rules_json, rr.road_name, rr.geometry_json,
                   rr.source, rr.source_ref, rr.confidence
            FROM road_rules_rtree r
            JOIN road_rules rr ON rr.id = r.rule_id
            WHERE r.min_lat <= ? AND r.max_lat >= ?
              AND r.min_lon <= ? AND r.max_lon >= ?
              AND EXISTS (
                  SELECT 1
                  FROM json_each(rr.rules_json) rule
                  WHERE (
                      rule.key LIKE 'parking:%'
                      AND lower(rule.value) LIKE 'no%'
                  )\(parkingOnly ? "" : """
                   OR (
                      rule.key IN (
                          'access', 'access:conditional',
                          'motor_vehicle', 'motor_vehicle:conditional',
                          'motorcar', 'motorcar:conditional'
                      )
                      AND lower(rule.value) LIKE 'no%'
                  )
                  """)
              )
            LIMIT 5_000;
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
            ), nearest.distance <= maximumRuleDistanceMeters else { continue }
            matchedRules.append(contentsOf: rules.map { "\($0.key)=\($0.value)" })
            let ruleID = Int(sqlite3_column_int(statement, 0))
            for sign in Self.resolveRoadRuleSigns(rules) {
                alerts.append(DriveAlert(
                    id: sign.idBase + ruleID,
                    kind: sign.kind,
                    speedLimit: 0,
                    latitude: nearest.coordinate.latitude,
                    longitude: nearest.coordinate.longitude,
                    message: sign.message,
                    province: Self.text(statement, 2) ?? "",
                    distanceMeters: nearest.distance,
                    signCode: sign.signCode,
                    assetName: sign.assetName,
                    source: Self.text(statement, 4) ?? "OpenStreetMap",
                    sourceReference: Self.text(statement, 5),
                    confidence: sqlite3_column_double(statement, 6),
                    conditional: sign.conditional,
                    directionDegrees: nearest.bearing,
                    directionType: 0
                ))
            }
        }
        return (
            alerts.sorted { $0.distanceMeters < $1.distanceMeters },
            Array(Set(matchedRules)).sorted()
        )
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
        let confirmedTownEntryIDs = Self.confirmedFirmwareTownEntryIDs(in: alerts)
        let filtered: [DriveAlert] = alerts.compactMap { alert -> DriveAlert? in
            guard ConditionalRuleEvaluator.isPotentiallyActive(alert.conditional ?? "") else {
                return nil
            }
            // Firmware type 10 is directional navigation data. Showing every
            // point around a stationary car made valid boundaries look like
            // permanent signs scattered throughout a city. Expose it only as
            // a short-range approach alert while the vehicle is moving in the
            // encoded direction. A valid firmware boundary must also have an
            // opposite-direction peer nearby; isolated type-10 points are the
            // false urban markers observed in the source. Physical R.420/R.421
            // nodes are unaffected.
            if alert.isFirmwareTownEntry {
                guard confirmedTownEntryIDs.contains(alert.id),
                      speedKmh >= 8,
                      alert.distanceMeters <= min(radiusMeters, 1_000),
                      let direction = alert.directionDegrees,
                      Self.directionDifference(
                          heading,
                          target: direction,
                          directionType: alert.directionType
                      ) <= 55 else { return nil }
                if alert.distanceMeters > 25 {
                    let approachBearing = Self.bearing(
                        from: location.coordinate,
                        to: alert.coordinate
                    )
                    guard Self.angleDifference(heading, approachBearing) <= 55 else {
                        return nil
                    }
                }
            }
            var candidate = alert
            // OSM physical signs use direction_degrees to encode the sign's
            // facing direction, not the vehicle's approach heading. Applying
            // the firmware direction filter here hides signs that the driver
            // hasn't reached yet (e.g. a P123a at a junction 200 m ahead
            // whose face points 90° away from the current heading). Instead,
            // these are filtered by approach bearing below and by
            // direction_scope when a route provides travel direction.
            let isOSMPhysicalSign = alert.source.hasPrefix("OpenStreetMap")
            if !isOSMPhysicalSign,
               let direction = alert.directionDegrees, speedKmh >= 8,
               !Self.directionMatches(
                    heading,
                    target: direction,
                    directionType: alert.directionType
               ) { return nil }
            // Filter OSM signs by direction_scope when the vehicle has a
            // clear heading, so a forward-only sign is not shown to traffic
            // travelling in the opposite direction on the same road.
            if isOSMPhysicalSign, speedKmh >= 8,
               let scope = alert.directionScope, scope != "unknown",
               let direction = alert.directionDegrees {
                let angleDiff = Self.angleDifference(heading, direction)
                let isFacing = angleDiff <= 90
                if scope == "forward" && !isFacing { return nil }
                if scope == "backward" && isFacing { return nil }
            }
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
            guard alert.distanceMeters <= radiusMeters else { return nil }
            if speedKmh >= 8, alert.distanceMeters > 70 {
                let alertBearing = Self.bearing(from: location.coordinate, to: alert.coordinate)
                guard Self.angleDifference(heading, alertBearing) <= 75 else { return nil }
            }
            return candidate
        }
        return filtered.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// The firmware commonly records a town boundary once for each travel
    /// direction. Requiring that reciprocal evidence removes isolated type-10
    /// observations without inventing a boundary from OSM or administrative
    /// city polygons. The 350 m tolerance covers divided carriageways and
    /// staggered signs while remaining local to one boundary.
    private static func confirmedFirmwareTownEntryIDs(
        in alerts: [DriveAlert]
    ) -> Set<Int> {
        let entries = alerts.filter(\.isFirmwareTownEntry)
        var confirmed: Set<Int> = []
        for index in entries.indices {
            let entry = entries[index]
            guard let entryDirection = entry.directionDegrees else { continue }
            let entryLocation = CLLocation(
                latitude: entry.latitude,
                longitude: entry.longitude
            )
            for peer in entries[entries.index(after: index)...] {
                guard let peerDirection = peer.directionDegrees,
                      angleDifference(entryDirection, peerDirection) >= 140 else {
                    continue
                }
                let distance = entryLocation.distance(from: CLLocation(
                    latitude: peer.latitude,
                    longitude: peer.longitude
                ))
                guard distance <= 350 else { continue }
                confirmed.insert(entry.id)
                confirmed.insert(peer.id)
            }
        }
        return confirmed
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
                   COALESCE(c1.label, c2.label, ''),
                   l.direction_1_speed_kmh, l.direction_2_speed_kmh,
                   l.geometry_json
            FROM map_data_road_links_rtree r
            JOIN map_data_road_links l ON l.id = r.link_id
            LEFT JOIN map_data_name_lookup n1 ON n1.id = l.direction_1_name_id
            LEFT JOIN map_data_name_lookup n2 ON n2.id = l.direction_2_name_id
            LEFT JOIN map_data_city_lookup c1 ON c1.id = n1.city_id
            LEFT JOIN map_data_city_lookup c2 ON c2.id = n2.city_id
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
            guard let geometryText = Self.text(statement, 8),
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
                province: Self.text(statement, 5) ?? "",
                direction1Speed: Int(sqlite3_column_int(statement, 6)),
                direction2Speed: Int(sqlite3_column_int(statement, 7)),
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
            .min { a, b in
                var scoreA = a.distance
                var scoreB = b.distance
                let maxA = max(a.road.direction1Speed, a.road.direction2Speed)
                let maxB = max(b.road.direction1Speed, b.road.direction2Speed)
                if speedKmh >= 65 {
                    if maxA >= 70 && maxB <= 60 { scoreA -= 20 }
                    if maxB >= 70 && maxA <= 60 { scoreB -= 20 }
                }
                return scoreA < scoreB
            }
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
            alignmentDegrees: selection.alignment,
            canTriggerDrivingAlerts: true,
            province: road.province
        )
    }

    private func lookaheadNextSpeedMatch(
        currentRoadID: Int?,
        currentSpeedLimit: Int,
        location: CLLocation,
        heading: Double,
        speedKmh: Int,
        roads: [FirmwareRoadCandidate]
    ) -> NextSpeedMatch? {
        guard currentSpeedLimit > 0,
              speedKmh >= 8,
              let currentRoadID,
              let currentRoad = roads.first(where: { $0.id == currentRoadID }),
              let projection = Self.polylineProjection(
                of: location.coordinate,
                on: currentRoad.coordinates
              )
        else { return nil }

        let forwardDifference = Self.angleDifference(heading, projection.segmentBearing)
        let reverseBearing = (projection.segmentBearing + 180).truncatingRemainder(dividingBy: 360)
        let reverseDifference = Self.angleDifference(heading, reverseBearing)
        guard min(forwardDifference, reverseDifference) <= 65 else { return nil }

        let travelsAlongGeometry = forwardDifference <= reverseDifference
        var distanceAhead = travelsAlongGeometry
            ? projection.totalLengthMeters - projection.distanceFromStartMeters
            : projection.distanceFromStartMeters
        var node = travelsAlongGeometry
            ? currentRoad.coordinates.last!
            : currentRoad.coordinates.first!
        var travelBearing = Self.exitBearing(
            for: currentRoad.coordinates,
            travelsAlongGeometry: travelsAlongGeometry
        )
        var roadName = currentRoad.roadName(forDirection1: travelsAlongGeometry)
        var visited = Set([currentRoadID])

        // Follow one topologically connected chain instead of scanning every
        // road inside a forward cone. At a genuinely ambiguous fork free-drive
        // mode has no route intent, so returning no forecast is safer than
        // announcing the speed of an arbitrary branch.
        while distanceAhead <= 500, visited.count <= 80 {
            let options = roads.compactMap { road -> RoadContinuation? in
                guard !visited.contains(road.id) else { return nil }
                return Self.continuation(
                    road,
                    from: node,
                    incomingBearing: travelBearing,
                    previousRoadName: roadName
                )
            }
            .sorted { $0.score < $1.score }

            guard let selected = options.first, selected.score <= 72 else { return nil }
            if options.count > 1,
               options[1].score - selected.score < 9 {
                return nil
            }

            visited.insert(selected.road.id)
            if let limit = selected.speedLimit,
               limit != currentSpeedLimit,
               distanceAhead >= 120 {
                return NextSpeedMatch(
                    limit: limit,
                    distanceMeters: distanceAhead,
                    roadID: selected.road.id
                )
            }

            distanceAhead += selected.lengthMeters
            node = selected.exitCoordinate
            travelBearing = selected.exitBearing
            roadName = selected.roadName
        }
        return nil
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

    private static func isNonFirmwarePhysicalSign(_ alert: DriveAlert) -> Bool {
        guard alert.kind == .roadSign else { return false }
        guard let code = alert.signCode else { return true }
        return TrafficSignCatalog.speedLimit(from: code) == nil
    }

    private static func continuation(
        _ road: FirmwareRoadCandidate,
        from node: CLLocationCoordinate2D,
        incomingBearing: Double,
        previousRoadName: String
    ) -> RoadContinuation? {
        guard road.coordinates.count >= 2,
              let first = road.coordinates.first,
              let last = road.coordinates.last else { return nil }
        let firstDistance = CLLocation(latitude: node.latitude, longitude: node.longitude)
            .distance(from: CLLocation(latitude: first.latitude, longitude: first.longitude))
        let lastDistance = CLLocation(latitude: node.latitude, longitude: node.longitude)
            .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
        guard min(firstDistance, lastDistance) <= 12 else { return nil }

        let travelsAlongGeometry = firstDistance <= lastDistance
        let outgoingBearing: Double
        let exitCoordinate: CLLocationCoordinate2D
        if travelsAlongGeometry {
            outgoingBearing = bearing(from: road.coordinates[0], to: road.coordinates[1])
            exitCoordinate = last
        } else {
            outgoingBearing = bearing(
                from: road.coordinates[road.coordinates.count - 1],
                to: road.coordinates[road.coordinates.count - 2]
            )
            exitCoordinate = first
        }
        let turnDifference = angleDifference(incomingBearing, outgoingBearing)
        guard turnDifference <= 75 else { return nil }

        let roadName = road.roadName(forDirection1: travelsAlongGeometry)
        let previousName = normalizedRoadName(previousRoadName)
        let nextName = normalizedRoadName(roadName)
        let nameAdjustment: Double
        if !previousName.isEmpty, !nextName.isEmpty {
            nameAdjustment = previousName == nextName ? -24 : 8
        } else {
            nameAdjustment = 0
        }
        let literalSpeed = travelsAlongGeometry
            ? road.direction1Speed : road.direction2Speed
        return RoadContinuation(
            road: road,
            travelsAlongGeometry: travelsAlongGeometry,
            speedLimit: supportedSpeedLimits.contains(literalSpeed) ? literalSpeed : nil,
            roadName: roadName,
            exitCoordinate: exitCoordinate,
            exitBearing: exitBearing(
                for: road.coordinates,
                travelsAlongGeometry: travelsAlongGeometry
            ),
            lengthMeters: polylineLength(road.coordinates),
            score: turnDifference + nameAdjustment
        )
    }

    private static func normalizedRoadName(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func exitBearing(
        for coordinates: [CLLocationCoordinate2D],
        travelsAlongGeometry: Bool
    ) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        if travelsAlongGeometry {
            return bearing(
                from: coordinates[coordinates.count - 2],
                to: coordinates[coordinates.count - 1]
            )
        }
        return bearing(from: coordinates[1], to: coordinates[0])
    }

    private static func polylineLength(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { result, pair in
            result + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    private static func polylineProjection(
        of point: CLLocationCoordinate2D,
        on coordinates: [CLLocationCoordinate2D]
    ) -> PolylineProjection? {
        guard coordinates.count >= 2 else { return nil }
        let totalLength = polylineLength(coordinates)
        var traversed = 0.0
        var best: PolylineProjection?
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            let nearest = nearestPointOnSegment(point: point, start: start, end: end)
            let segmentStart = CLLocation(latitude: start.latitude, longitude: start.longitude)
            let segmentEnd = CLLocation(latitude: end.latitude, longitude: end.longitude)
            let segmentLength = segmentStart.distance(from: segmentEnd)
            let projectedLength = min(
                segmentLength,
                segmentStart.distance(from: CLLocation(
                    latitude: nearest.coordinate.latitude,
                    longitude: nearest.coordinate.longitude
                ))
            )
            let candidate = PolylineProjection(
                coordinate: nearest.coordinate,
                distanceMeters: nearest.distance,
                segmentBearing: nearest.bearing,
                distanceFromStartMeters: traversed + projectedLength,
                totalLengthMeters: totalLength
            )
            if best == nil || candidate.distanceMeters < best!.distanceMeters {
                best = candidate
            }
            traversed += segmentLength
        }
        return best
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

    private static func baseRuleValue(_ value: String) -> String {
        value
            .split(separator: "@", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    /// Converts every passenger-car-relevant line rule available in schema v6
    /// into a sign descriptor. Speed stays firmware-owned; truck/motorcycle
    /// rules are not shown to a passenger car without a vehicle profile.
    private static func resolveRoadRuleSigns(
        _ rules: [String: String]
    ) -> [RoadRuleSignDescriptor] {
        var result: [RoadRuleSignDescriptor] = []

        let parkingCandidates = rules
            .filter { key, value in
                let base = baseRuleValue(value)
                return key.hasPrefix("parking:")
                    && ["no", "no_parking", "no_stopping", "no_parking_odd", "no_parking_even"]
                        .contains(base)
            }
            .sorted { left, right in
                parkingPriority(left.value) < parkingPriority(right.value)
            }
        if let parking = parkingCandidates.first {
            let value = baseRuleValue(parking.value)
            if let descriptor = roadRuleDescriptor(
                idBase: 20_000_000,
                kind: .parkingRestriction,
                code: TrafficSignCatalog.parkingCode(for: value),
                conditional: ruleCondition(parking.value)
            ) {
                result.append(descriptor)
            }
        }

        let supportedAccessKeys: Set<String> = [
            "access", "access:conditional",
            "motor_vehicle", "motor_vehicle:conditional",
            "motorcar", "motorcar:conditional"
        ]
        let accessCandidates = rules
            .filter { key, value in
                supportedAccessKeys.contains(key)
                    && baseRuleValue(value) == "no"
                    && isPassengerCarRelevantAccessValue(value)
            }
            .sorted { accessPriority($0.key) < accessPriority($1.key) }
        if let access = accessCandidates.first {
            if let descriptor = roadRuleDescriptor(
                idBase: 30_000_000,
                kind: .roadSign,
                code: TrafficSignCatalog.accessCode(for: access.key),
                conditional: ruleCondition(access.value)
            ) {
                result.append(descriptor)
            }
        }

        return result
    }

    private static func roadRuleDescriptor(
        idBase: Int,
        kind: AlertKind,
        code: String,
        conditional: String?
    ) -> RoadRuleSignDescriptor? {
        guard let definition = TrafficSignCatalog.definition(for: code) else { return nil }
        return RoadRuleSignDescriptor(
            idBase: idBase,
            kind: kind,
            message: definition.defaultMessage,
            signCode: definition.code,
            assetName: definition.assetName,
            conditional: conditional
        )
    }

    private static func parkingPriority(_ value: String) -> Int {
        let base = baseRuleValue(value)
        if base.contains("stopping") { return 0 }
        if base.contains("odd") || base.contains("even") { return 1 }
        return 2
    }

    private static func accessPriority(_ key: String) -> Int {
        let conditionalPenalty = key.hasSuffix(":conditional") ? 10 : 0
        if key.hasPrefix("motorcar") { return conditionalPenalty }
        if key.hasPrefix("motor_vehicle") { return 1 + conditionalPenalty }
        return 2 + conditionalPenalty
    }

    private static func isPassengerCarRelevantAccessValue(_ value: String) -> Bool {
        let condition = value.lowercased()
        let vehicleSpecificTokens = [
            "passenger_seats", " seats", "weight", "axles", "wheels"
        ]
        return !vehicleSpecificTokens.contains { condition.contains($0) }
    }

    private static func ruleCondition(_ value: String) -> String? {
        let parts = value.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let condition = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return condition.isEmpty ? nil : condition
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

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }
}
