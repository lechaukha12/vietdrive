import CoreLocation
import Foundation

enum AlertKind: String, Codable, CaseIterable {
    case camera
    case speedLimit = "speed_limit"
    case toll
    case hazard
    case townBoundary = "town_boundary"
    case roadSign = "road_sign"
    case turnRestriction = "turn_restriction"
    case parkingRestriction = "parking_restriction"

    init(databaseValue: String) {
        switch databaseValue {
        case "camera", "camera_alert": self = .camera
        case "speed_limit": self = .speedLimit
        case "toll_booth": self = .toll
        case "town_boundary": self = .townBoundary
        case "road_sign": self = .roadSign
        case "turn_restriction": self = .turnRestriction
        case "parking_restriction": self = .parkingRestriction
        default: self = .hazard
        }
    }

    var iconName: String {
        switch self {
        case .camera: "camera.metering.center.weighted"
        case .speedLimit: "gauge.with.dots.needle.67percent"
        case .toll: "creditcard.fill"
        case .hazard: "exclamationmark.triangle.fill"
        case .townBoundary: "building.2.fill"
        case .roadSign: "signpost.right.and.left.fill"
        case .turnRestriction: "arrow.turn.up.left"
        case .parkingRestriction: "parkingsign.slash"
        }
    }

    var title: String {
        switch self {
        case .camera: "Camera giám sát"
        case .speedLimit: "Biển giới hạn"
        case .toll: "Trạm thu phí"
        case .hazard: "Cảnh báo giao thông"
        case .townBoundary: "Ranh giới khu đông dân cư"
        case .roadSign: "Biển báo giao thông"
        case .turnRestriction: "Hạn chế hướng đi"
        case .parkingRestriction: "Hạn chế dừng đỗ"
        }
    }
}

struct TrafficSignDefinition: Equatable {
    let code: String
    let assetName: String
    let defaultMessage: String
    let voicePromptKey: String?
    let voicePhrase: String?

    init(
        _ code: String,
        _ assetName: String,
        _ defaultMessage: String,
        voicePromptKey: String? = nil,
        voicePhrase: String? = nil
    ) {
        self.code = code
        self.assetName = "TrafficSigns/\(assetName)"
        self.defaultMessage = defaultMessage
        self.voicePromptKey = voicePromptKey
        self.voicePhrase = voicePhrase
    }
}

struct FirmwareAlertDefinition: Equatable {
    let kind: AlertKind
    let signCode: String
    let assetName: String?
    let message: String
}

/// Nguồn duy nhất ánh xạ mã biển ↔ asset ↔ nội dung mặc định ↔ voice.
/// Các service không được tự duy trì dictionary/switch mã biển riêng.
enum TrafficSignCatalog {
    static let sectionCameraCode = "CAMERA_SECTION"
    static let speedCodePrefix = "P127."

    static let definitions: [String: TrafficSignDefinition] = Dictionary(
        uniqueKeysWithValues: [
            TrafficSignDefinition("P101", "TrafficSign_P101", "Đường cấm"),
            TrafficSignDefinition("P102", "TrafficSign_P102", "Cấm đi ngược chiều"),
            TrafficSignDefinition("P103a", "TrafficSign_P103a", "Cấm ô tô"),
            TrafficSignDefinition("P103c", "TrafficSign_P103c", "Cấm ô tô rẽ trái"),
            TrafficSignDefinition("P105", "TrafficSign_P105", "Cấm ô tô và mô tô"),
            TrafficSignDefinition("P122", "TrafficSign_P122", "Dừng lại"),
            TrafficSignDefinition("P123a", "TrafficSign_P123a", "Cấm rẽ trái"),
            TrafficSignDefinition("P123b", "TrafficSign_P123b", "Cấm rẽ phải"),
            TrafficSignDefinition("P123c", "TrafficSign_NoStraight", "Cấm đi thẳng"),
            TrafficSignDefinition("P124a", "TrafficSign_P124a", "Cấm quay đầu xe bên trái"),
            TrafficSignDefinition("P124b", "TrafficSign_P124b", "Cấm quay đầu xe bên phải"),
            TrafficSignDefinition(
                "P125", "TrafficSign_P125", "Cấm vượt",
                voicePromptKey: "alert.overtaking.in",
                voicePhrase: "có đoạn đường cấm vượt"
            ),
            TrafficSignDefinition("P130", "TrafficSign_P130", "Cấm dừng và đỗ xe"),
            TrafficSignDefinition("P131a", "TrafficSign_P131a", "Cấm đỗ xe"),
            TrafficSignDefinition("P131b", "TrafficSign_P131b", "Cấm đỗ xe ngày lẻ"),
            TrafficSignDefinition("P131c", "TrafficSign_P131c", "Cấm đỗ xe ngày chẵn"),
            TrafficSignDefinition("R301a", "TrafficSign_R301a", "Chỉ được đi thẳng"),
            TrafficSignDefinition("R301b", "TrafficSign_R301b", "Chỉ được rẽ phải"),
            TrafficSignDefinition("R301c", "TrafficSign_R301c", "Chỉ được rẽ trái"),
            TrafficSignDefinition("R301d", "TrafficSign_R301d", "Chỉ được đi thẳng và rẽ trái"),
            TrafficSignDefinition("R301e", "TrafficSign_R301e", "Chỉ được đi thẳng và rẽ phải"),
            TrafficSignDefinition("R301f", "TrafficSign_R301f", "Chỉ được rẽ trái và rẽ phải"),
            TrafficSignDefinition("R302a", "TrafficSign_R302a", "Hướng phải phải đi vòng"),
            TrafficSignDefinition(
                "R420", "TrafficSign_R420Official", "Bắt đầu khu đông dân cư",
                voicePromptKey: "alert.town.in",
                voicePhrase: "bắt đầu khu đông dân cư"
            ),
            TrafficSignDefinition(
                "R421", "TrafficSign_R421Official", "Hết khu đông dân cư",
                voicePromptKey: "alert.town.out",
                voicePhrase: "hết khu đông dân cư"
            ),
            // iGO/firmware type 10 is a logical town-entry alert. It must not
            // be presented as proof that a physical Vietnamese R420 sign is
            // installed at the stored coordinate.
            TrafficSignDefinition(
                "TOWN_ENTRY", "TrafficSign_TownEntry", "Đi vào khu đông dân cư",
                voicePromptKey: "alert.town.in",
                voicePhrase: "đi vào khu đông dân cư"
            ),
            TrafficSignDefinition(
                "DP133", "TrafficSign_DP133", "Hết cấm vượt",
                voicePromptKey: "alert.overtaking.out",
                voicePhrase: "hết đoạn đường cấm vượt"
            ),
            TrafficSignDefinition("W208", "TrafficSign_W208", "Nhường đường"),
            TrafficSignDefinition(
                "W210", "TrafficSign_Railway", "Giao nhau với đường sắt",
                voicePromptKey: "alert.railway",
                voicePhrase: "có giao nhau với đường sắt"
            ),
            TrafficSignDefinition("W224", "TrafficSign_W224", "Đường người đi bộ cắt ngang"),
            TrafficSignDefinition("W225", "TrafficSign_W225", "Trẻ em"),
            TrafficSignDefinition(
                "W240", "TrafficSign_Tunnel", "Đường hầm",
                voicePromptKey: "alert.tunnel",
                voicePhrase: "có đường hầm"
            ),
            TrafficSignDefinition("W245a", "TrafficSign_W245a", "Đi chậm"),
            TrafficSignDefinition("I437", "TrafficSign_I437", "Đường cao tốc"),
            TrafficSignDefinition(
                "I433", "TrafficSign_RestArea", "Trạm dừng nghỉ",
                voicePromptKey: "alert.rest_area",
                voicePhrase: "có trạm dừng nghỉ"
            ),
            TrafficSignDefinition("CAMERA_SPEED", "TrafficSign_CameraSpeed", "Camera giám sát tốc độ"),
            TrafficSignDefinition(
                "CAMERA_TRAFFIC", "TrafficSign_CameraTraffic", "Camera đèn tín hiệu giao thông",
                voicePromptKey: "alert.camera.traffic",
                voicePhrase: "có camera phạt nguội đèn đỏ"
            ),
            TrafficSignDefinition(
                "CAMERA_SECTION", "TrafficSign_CameraSection", "Camera đo tốc độ theo đoạn",
                voicePromptKey: "alert.camera.section",
                voicePhrase: "có camera đo tốc độ theo đoạn"
            ),
            TrafficSignDefinition(
                "CAMERA_DUAL", "TrafficSign_CameraDual", "Camera đèn đỏ và tốc độ",
                voicePromptKey: "alert.camera.dual",
                voicePhrase: "có camera phạt nguội đèn đỏ và tốc độ"
            ),
            TrafficSignDefinition(
                "TOLL", "TrafficSign_Toll", "Trạm thu phí",
                voicePromptKey: "alert.toll",
                voicePhrase: "có trạm thu phí"
            ),
            TrafficSignDefinition(
                "CHECKPOINT", "TrafficSign_Checkpoint", "Trạm kiểm tra tốc độ",
                voicePromptKey: "alert.checkpoint",
                voicePhrase: "có trạm kiểm tra tốc độ"
            ),
        ].map { ($0.code, $0) }
    )

    private static let aliases: [String: String] = [
        "IGO:1": "CAMERA_SPEED",
        "IGO:2": "CAMERA_TRAFFIC",
        "IGO:4": "CAMERA_SECTION",
        "IGO:5": "TOLL",
        "IGO:10": "TOWN_ENTRY",
        "IGO:11": "CAMERA_DUAL",
        "no_left_turn": "P123a",
        "no_right_turn": "P123b",
        "no_u_turn": "P124a",
        "no_straight_on": "P123c",
        "only_straight_on": "R301a",
        "only_right_turn": "R301b",
        "only_left_turn": "R301c",
        "no_entry": "P102",
        "no_parking": "P131a",
        "no_stopping": "P130",
    ]

    private static let legacyAssetAliases: [String: String] = [
        "TrafficSigns/TrafficSign_R420": "R420",
        "TrafficSigns/TrafficSign_R421": "R421",
    ]

    static func canonicalCode(
        for rawCode: String?,
        speedLimit: Int = 0,
        assetName: String? = nil
    ) -> String? {
        if let rawCode {
            if rawCode == "IGO:1", speedLimit > 0 { return "P127.\(speedLimit)" }
            if rawCode.hasPrefix(speedCodePrefix), Self.speedLimit(from: rawCode) != nil { return rawCode }
            if let alias = aliases[rawCode] { return alias }
            if definitions[rawCode] != nil { return rawCode }
        }
        guard let assetName else { return nil }
        if let legacy = legacyAssetAliases[assetName] { return legacy }
        return definitions.values.first { $0.assetName == assetName }?.code
    }

    static func definition(
        for rawCode: String?,
        speedLimit: Int = 0,
        assetName: String? = nil
    ) -> TrafficSignDefinition? {
        guard let code = canonicalCode(
            for: rawCode,
            speedLimit: speedLimit,
            assetName: assetName
        ) else { return nil }
        return definitions[code]
    }

    static func assetName(for code: String?, speedLimit: Int = 0) -> String? {
        guard let canonical = canonicalCode(for: code, speedLimit: speedLimit) else { return nil }
        if let speed = Self.speedLimit(from: canonical) {
            return "TrafficSigns/TrafficSign_P127_\(speed)"
        }
        return definitions[canonical]?.assetName
    }

    static func speedLimit(from code: String) -> Int? {
        guard code.hasPrefix(speedCodePrefix),
              let value = code.split(separator: ".").last,
              let speed = Int(value) else { return nil }
        return speed
    }

    static func speedCode(_ speedLimit: Int) -> String {
        "\(speedCodePrefix)\(speedLimit)"
    }

    static func canonicalRestrictionCode(_ restriction: String) -> String? {
        aliases[restriction]
    }

    static func parkingCode(for ruleValue: String) -> String {
        if ruleValue.contains("stopping") { return "P130" }
        if ruleValue.contains("odd") { return "P131b" }
        if ruleValue.contains("even") { return "P131c" }
        return "P131a"
    }

    static func accessCode(for ruleKey: String) -> String {
        let key = ruleKey.replacingOccurrences(of: ":conditional", with: "")
        if key == "motorcar" { return "P103a" }
        if key == "motor_vehicle" { return "P105" }
        return "P101"
    }

    static func firmwareAlert(
        typeCode: Int,
        speedLimit: Int,
        warningText: String?
    ) -> FirmwareAlertDefinition {
        let kind: AlertKind
        let code: String
        switch typeCode {
        case 1:
            kind = speedLimit > 0 ? .speedLimit : .camera
            code = speedLimit > 0 ? speedCode(speedLimit) : "CAMERA_SPEED"
        case 2:
            kind = .camera
            code = "CAMERA_TRAFFIC"
        case 4:
            kind = .camera
            code = "CAMERA_SECTION"
        case 5:
            kind = .toll
            code = "TOLL"
        case 10:
            kind = .townBoundary
            code = "TOWN_ENTRY"
        case 11:
            kind = .camera
            code = "CAMERA_DUAL"
        default:
            return FirmwareAlertDefinition(
                kind: .hazard,
                signCode: "IGO:\(typeCode)",
                assetName: nil,
                message: warningText ?? "Cảnh báo giao thông"
            )
        }
        let definition = definitions[code]
        let speedMessage = speedLimit > 0
            ? "Biển giới hạn tốc độ \(speedLimit) km/h"
            : "Camera giám sát tốc độ"
        return FirmwareAlertDefinition(
            kind: kind,
            signCode: code,
            assetName: assetName(for: code, speedLimit: speedLimit),
            message: warningText ?? (typeCode == 1 ? speedMessage : definition?.defaultMessage ?? "Cảnh báo giao thông")
        )
    }

    static func voiceAnnouncement(
        for alert: DriveAlert,
        distanceText: String
    ) -> (promptKey: String?, message: String)? {
        guard let definition = definition(
            for: alert.signCode,
            speedLimit: alert.speedLimit,
            assetName: alert.assetName
        ), let phrase = definition.voicePhrase else { return nil }
        return (
            definition.voicePromptKey,
            "Phía trước \(distanceText) \(phrase)."
        )
    }

    static func isSectionCamera(_ alert: DriveAlert) -> Bool {
        canonicalCode(
            for: alert.signCode,
            speedLimit: alert.speedLimit,
            assetName: alert.assetName
        ) == sectionCameraCode
    }
}

struct DriveAlert: Identifiable, Equatable, Codable {
    let id: Int
    let kind: AlertKind
    let speedLimit: Int
    let latitude: Double
    let longitude: Double
    let message: String
    let province: String
    var distanceMeters: Double
    var signCode: String? = nil
    var assetName: String? = nil
    var source: String = ""
    var sourceReference: String? = nil
    var confidence: Double = 0
    var conditional: String? = nil
    var directionDegrees: Double? = nil
    /// iGO DIRTYPE: 0 = mọi hướng, 1 = một hướng, 2 = hai hướng đối diện.
    var directionType: Int? = nil
    var distanceAlongRouteMeters: Double? = nil
    var lateralDistanceMeters: Double? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Các điểm tốc độ khôi phục do người dùng cung cấp có giá trị để hiển thị
    /// và đối chiếu, nhưng chưa chứa chiều/phạm vi hiệu lực để phát voice.
    var isReferenceSpeedObservation: Bool {
        kind == .speedLimit && source == "Dữ liệu tốc độ VietDrive cung cấp"
    }


    var isMapDataSpeedPoint: Bool {
        source == "map-data/edogen.bin" && speedLimit > 0
    }

    var isRoadRuleDerived: Bool {
        (20_000_000..<40_000_000).contains(id)
    }
}

struct RoadOverlay: Identifiable {
    let id: Int
    let speedLimit: Int
    let coordinates: [CLLocationCoordinate2D]
    var isPrimaryRoute = false
    var roadName = ""
    var speedSource = "Dữ liệu VietDrive cũ"
    var travelDirection: RoadTravelDirection = .both
    var confidence = 0.7
}

enum RoadTravelDirection: String, Equatable {
    case both
    case forward
    case reverse
}

struct SpeedLimitMatch: Equatable {
    let limit: Int
    let roadName: String
    let source: String
    let distanceMeters: Double
    let alignmentDegrees: Double?
    var canTriggerDrivingAlerts = true
    var province: String = ""

    var diagnosticText: String {
        let road = roadName.isEmpty ? "đoạn đường chưa có tên" : roadName
        let distance = "cách tim đường \(Int(distanceMeters.rounded())) m"
        let direction = alignmentDegrees.map { "lệch hướng \(Int($0.rounded()))°" }
        return ([source, road, distance] + [direction].compactMap { $0 })
            .joined(separator: " · ")
    }
}

struct NextSpeedMatch: Equatable {
    let limit: Int
    let distanceMeters: Double
    let roadID: Int?

    init(limit: Int, distanceMeters: Double, roadID: Int? = nil) {
        self.limit = limit
        self.distanceMeters = distanceMeters
        self.roadID = roadID
    }
}

struct SectionSpeedProgress: Equatable {
    let speedLimit: Int
    let averageSpeedKmh: Int
    let distanceTraveledMeters: Double
}

struct OfflineMapContext {
    let alerts: [DriveAlert]
    let roads: [RoadOverlay]
    let speedLimitMatch: SpeedLimitMatch?
    let nextSpeedMatch: NextSpeedMatch?
    let matchedRoadRules: [String]

    var matchedSpeedLimit: Int { speedLimitMatch?.limit ?? 0 }
}

struct DriveSnapshot {
    var coordinate = CLLocationCoordinate2D(latitude: 10.7769, longitude: 106.7009)
    var speedKmh = 0
    var speedLimitKmh = 0
    var speedLimitCanTriggerAlerts = false
    var heading = 0.0
    var province = "TP. Hồ Chí Minh"
    var roadName = "Đang xác định tuyến đường"
    var nextManeuver = "Tiếp tục đi thẳng"
    var maneuverDistanceMeters = 0
    var laneGuidance = ""
    var maneuverType = ""
    var maneuverModifier = ""
    var mascotCueLatitude: Double?
    var mascotCueLongitude: Double?
    var mascotCueDistanceMeters = 0
    var mascotCueType = ""
    var mascotCueModifier = ""
    var journeyEvent: MascotJourneyEvent = .idle
    var journeyEventRevision = 0
    var primaryAlert: DriveAlert?
    var nextSpeedLimitKmh: Int? = nil
    var nextSpeedDistanceMeters: Int? = nil
    var activeSectionSpeed: SectionSpeedProgress? = nil
    var isDemo = false

    var isOverSpeed: Bool {
        speedLimitKmh > 0 && speedKmh > speedLimitKmh
    }

    var isOverSpeedCritical: Bool {
        speedLimitKmh > 0 && speedKmh >= speedLimitKmh + 5
    }

    var isOverSpeedMinor: Bool {
        speedLimitKmh > 0 && speedKmh > speedLimitKmh && speedKmh < speedLimitKmh + 5
    }

    var mascotCueCoordinate: CLLocationCoordinate2D? {
        guard let mascotCueLatitude, let mascotCueLongitude else { return nil }
        return CLLocationCoordinate2D(
            latitude: mascotCueLatitude,
            longitude: mascotCueLongitude
        )
    }
}

enum MascotJourneyEvent: Equatable {
    case idle
    case departing
    case driving
    case braking
    case arrived
}

struct DeviceTelemetry: Codable {
    let version: Int
    let timestamp: Int64
    let latitude: Double
    let longitude: Double
    let speed: Int
    let speedLimit: Int
    let heading: Int
    let alertType: String?
    let alertDistance: Int?
    let alertText: String?

    init(snapshot: DriveSnapshot) {
        version = 1
        timestamp = Int64(Date().timeIntervalSince1970)
        latitude = snapshot.coordinate.latitude
        longitude = snapshot.coordinate.longitude
        speed = snapshot.speedKmh
        speedLimit = snapshot.speedLimitKmh
        heading = Int(snapshot.heading)
        alertType = snapshot.primaryAlert?.kind.rawValue
        alertDistance = snapshot.primaryAlert.map { Int($0.distanceMeters) }
        alertText = snapshot.primaryAlert?.message
    }
}
