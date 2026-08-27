import CoreLocation
import Foundation

enum ContributionKind: String, Codable, CaseIterable, Identifiable {
    case roadSign = "road_sign"
    case turnRestriction = "turn_restriction"
    case parkingRestriction = "parking_restriction"
    case speedLimit = "speed_limit"
    case vehicleRestriction = "vehicle_restriction"
    case roadHazard = "road_hazard"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roadSign: "Biển báo giao thông"
        case .turnRestriction: "Cấm hoặc bắt buộc hướng đi"
        case .parkingRestriction: "Cấm dừng, cấm đỗ"
        case .speedLimit: "Giới hạn tốc độ"
        case .vehicleRestriction: "Hạn chế phương tiện"
        case .roadHazard: "Nguy hiểm hoặc thay đổi trên đường"
        }
    }

    var iconName: String {
        switch self {
        case .roadSign: "signpost.right.and.left.fill"
        case .turnRestriction: "arrow.turn.up.left"
        case .parkingRestriction: "parkingsign.slash"
        case .speedLimit: "gauge.with.dots.needle.67percent"
        case .vehicleRestriction: "truck.box.fill"
        case .roadHazard: "exclamationmark.triangle.fill"
        }
    }

    var alertKind: AlertKind {
        switch self {
        case .roadSign: .roadSign
        case .turnRestriction: .turnRestriction
        case .parkingRestriction: .parkingRestriction
        case .speedLimit: .speedLimit
        case .vehicleRestriction, .roadHazard: .hazard
        }
    }

    var defaultMessage: String {
        switch self {
        case .roadSign: "Biển báo giao thông"
        case .turnRestriction: "Hạn chế hướng đi"
        case .parkingRestriction: "Hạn chế dừng đỗ"
        case .speedLimit: "Giới hạn tốc độ"
        case .vehicleRestriction: "Hạn chế phương tiện"
        case .roadHazard: "Cảnh báo trên đường"
        }
    }
}

enum ContributionStatus: String, Codable, CaseIterable {
    case pending
    case approved
    case rejected

    var title: String {
        switch self {
        case .pending: "Chờ duyệt"
        case .approved: "Đã duyệt"
        case .rejected: "Từ chối"
        }
    }
}

enum ContributionGeometryType: String, Codable {
    case point = "Point"
    case lineString = "LineString"
}

struct ContributionGeometry: Codable, Equatable {
    let type: ContributionGeometryType
    /// GeoJSON coordinate order: longitude, latitude.
    let coordinates: [[Double]]

    static func point(latitude: Double, longitude: Double) -> Self {
        Self(type: .point, coordinates: [[longitude, latitude]])
    }

    var anchor: CLLocationCoordinate2D? {
        let valid = coordinates.filter { $0.count >= 2 }
        guard !valid.isEmpty else { return nil }
        return CLLocationCoordinate2D(
            latitude: valid.reduce(0) { $0 + $1[1] } / Double(valid.count),
            longitude: valid.reduce(0) { $0 + $1[0] } / Double(valid.count)
        )
    }
}

struct CommunityContribution: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ContributionKind
    var status: ContributionStatus
    var signCode: String
    var warningText: String
    var geometry: ContributionGeometry
    var conditional: String
    var sourceReference: String
    var notes: String
    var submitter: String
    var createdAt: Date
    var reviewedAt: Date?
    var reviewer: String?
    var rejectionReason: String?
    var importedFileName: String?
    var confidence: Double

    init(
        id: UUID = UUID(),
        kind: ContributionKind,
        status: ContributionStatus = .pending,
        signCode: String = "",
        warningText: String,
        geometry: ContributionGeometry,
        conditional: String = "",
        sourceReference: String = "",
        notes: String = "",
        submitter: String,
        createdAt: Date = Date(),
        reviewedAt: Date? = nil,
        reviewer: String? = nil,
        rejectionReason: String? = nil,
        importedFileName: String? = nil,
        confidence: Double = 0.55
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.signCode = signCode
        self.warningText = warningText
        self.geometry = geometry
        self.conditional = conditional
        self.sourceReference = sourceReference
        self.notes = notes
        self.submitter = submitter
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
        self.reviewer = reviewer
        self.rejectionReason = rejectionReason
        self.importedFileName = importedFileName
        self.confidence = confidence
    }

    var anchor: CLLocationCoordinate2D? { geometry.anchor }

    var assetName: String? {
        let assets = [
            "P101": "TrafficSigns/TrafficSign_P101",
            "P102": "TrafficSigns/TrafficSign_P102",
            "P103c": "TrafficSigns/TrafficSign_P103c",
            "P122": "TrafficSigns/TrafficSign_P122",
            "P123a": "TrafficSigns/TrafficSign_P123a",
            "P123b": "TrafficSigns/TrafficSign_P123b",
            "P124a": "TrafficSigns/TrafficSign_P124a",
            "P124b": "TrafficSigns/TrafficSign_P124b",
            "P125": "TrafficSigns/TrafficSign_P125",
            "P130": "TrafficSigns/TrafficSign_P130",
            "P131a": "TrafficSigns/TrafficSign_P131a",
            "P131b": "TrafficSigns/TrafficSign_P131b",
            "P131c": "TrafficSigns/TrafficSign_P131c",
            "R301a": "TrafficSigns/TrafficSign_R301a",
            "R301b": "TrafficSigns/TrafficSign_R301b",
            "R301c": "TrafficSigns/TrafficSign_R301c",
            "R301d": "TrafficSigns/TrafficSign_R301d",
            "R301e": "TrafficSigns/TrafficSign_R301e",
            "R301f": "TrafficSigns/TrafficSign_R301f",
            "R420": "TrafficSigns/TrafficSign_R420",
            "R421": "TrafficSigns/TrafficSign_R421",
            "DP133": "TrafficSigns/TrafficSign_DP133",
            "W208": "TrafficSigns/TrafficSign_W208",
            "W210": "TrafficSigns/TrafficSign_Railway",
            "W224": "TrafficSigns/TrafficSign_W224",
            "W225": "TrafficSigns/TrafficSign_W225",
            "W240": "TrafficSigns/TrafficSign_Tunnel",
            "W245a": "TrafficSigns/TrafficSign_W245a",
            "R302a": "TrafficSigns/TrafficSign_R302a",
            "I437": "TrafficSigns/TrafficSign_I437",
            "CAMERA_SPEED": "TrafficSigns/TrafficSign_CameraSpeed",
            "CAMERA_TRAFFIC": "TrafficSigns/TrafficSign_CameraTraffic",
            "CAMERA_SECTION": "TrafficSigns/TrafficSign_CameraSection",
            "CAMERA_DUAL": "TrafficSigns/TrafficSign_CameraDual",
            "TOLL": "TrafficSigns/TrafficSign_Toll",
        ]
        if signCode.hasPrefix("P127."),
           let speed = Int(signCode.split(separator: ".").last ?? "") {
            return "TrafficSigns/TrafficSign_P127_\(speed)"
        }
        return assets[signCode]
    }

    var speedLimit: Int {
        guard kind == .speedLimit || signCode.hasPrefix("P127."),
              let value = signCode.split(separator: ".").last,
              let speed = Int(value) else { return 0 }
        return speed
    }

    var stableAlertID: Int {
        let prefix = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return 40_000_000 + (Int(prefix, radix: 16) ?? 0) % 1_000_000_000
    }
}

struct CommunityImportIssue: Identifiable, Equatable {
    let id = UUID()
    let row: Int
    let message: String
}

struct CommunityImportPreview: Identifiable {
    let id = UUID()
    let fileName: String
    let candidates: [CommunityContribution]
    let issues: [CommunityImportIssue]
    let duplicateCount: Int
}

struct ContributionValidationResult: Equatable {
    let errors: [String]
    var isValid: Bool { errors.isEmpty }
}
