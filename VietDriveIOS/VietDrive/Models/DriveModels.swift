import CoreLocation
import Foundation

enum AlertKind: String, Codable, CaseIterable {
    case camera
    case speedLimit = "speed_limit"
    case toll
    case hazard
    case roadSign = "road_sign"
    case turnRestriction = "turn_restriction"
    case parkingRestriction = "parking_restriction"

    init(databaseValue: String) {
        switch databaseValue {
        case "camera", "camera_alert": self = .camera
        case "speed_limit": self = .speedLimit
        case "toll_booth": self = .toll
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
        case .roadSign: "Biển báo giao thông"
        case .turnRestriction: "Hạn chế hướng đi"
        case .parkingRestriction: "Hạn chế dừng đỗ"
        }
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
