import CoreLocation
import Foundation

struct PlaceSearchResult: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum RoutePhase: Equatable {
    case idle
    case planning
    case preview
    case navigating

    var isActive: Bool {
        self == .preview || self == .navigating
    }
}

struct NavigationStep: Identifiable {
    let id: Int
    let instruction: String
    let roadName: String
    let type: String
    let modifier: String
    let coordinate: CLLocationCoordinate2D
    let distanceAlongRouteMeters: Double
    var lanes: [NavigationLane] = []
    var exitNumber: Int? = nil
    var bearingBefore: Double? = nil
    var bearingAfter: Double? = nil
}

struct NavigationLane: Equatable {
    let indications: [String]
    let isValid: Bool

    var displayText: String {
        let arrows = indications.map {
            switch $0 {
            case "left", "sharp left", "slight left": "←"
            case "right", "sharp right", "slight right": "→"
            case "uturn": "↶"
            default: "↑"
            }
        }
        return arrows.joined(separator: "/")
    }
}

enum RouteStrategy: String, CaseIterable, Codable, Identifiable {
    case fastest
    case shortest

    var id: String { rawValue }
    var title: String { self == .fastest ? "Nhanh nhất" : "Ngắn nhất" }
}

struct RoutePreferences: Equatable, Codable {
    var strategy: RouteStrategy = .fastest
    var avoidTolls = false
    var avoidMotorways = false
    var avoidFerries = true

    var excludedClasses: [String] {
        var values: [String] = []
        if avoidTolls { values.append("toll") }
        if avoidMotorways { values.append("motorway") }
        if avoidFerries { values.append("ferry") }
        return values
    }
}

struct NavigationRoute {
    var id = UUID().uuidString
    let distanceMeters: Double
    let durationSeconds: Double
    let coordinates: [CLLocationCoordinate2D]
    let cumulativeDistances: [Double]
    let steps: [NavigationStep]
    var isCached = false
    var preferencesApplied = true

    var laneGuidanceStepCount: Int { steps.filter { !$0.lanes.isEmpty }.count }

    var overlay: RoadOverlay {
        RoadOverlay(
            id: -20_000,
            speedLimit: 0,
            coordinates: coordinates,
            isPrimaryRoute: true
        )
    }
}

struct NavigationProgress {
    let matchedDistanceMeters: Double
    let remainingDistanceMeters: Double
    let distanceFromRouteMeters: Double
    let nextStep: NavigationStep?
    let distanceToNextStepMeters: Int
    var matchedSegmentIndex = 0
    var routeBearing = 0.0
    var headingDifferenceDegrees: Double? = nil
}

struct RouteCurve {
    let coordinate: CLLocationCoordinate2D
    let distanceAlongRouteMeters: Double
    let modifier: String
}

struct RoutingHealthSnapshot: Equatable {
    let endpoint: String
    let latencyMilliseconds: Int
    let usedFallback: Bool
    let usedCache: Bool
    let status: String
    let updatedAt: Date

    static let idle = RoutingHealthSnapshot(
        endpoint: "Chưa gọi định tuyến",
        latencyMilliseconds: 0,
        usedFallback: false,
        usedCache: false,
        status: "Sẵn sàng",
        updatedAt: .distantPast
    )
}

enum LocationFixQuality: String, Equatable {
    case unavailable
    case weak
    case good
    case excellent

    var title: String {
        switch self {
        case .unavailable: "Chưa có GPS"
        case .weak: "GPS yếu"
        case .good: "GPS tốt"
        case .excellent: "GPS rất tốt"
        }
    }

    var symbol: String {
        switch self {
        case .unavailable: "location.slash.fill"
        case .weak: "location.circle"
        case .good: "location.fill"
        case .excellent: "location.north.circle.fill"
        }
    }
}

enum OpenMapServiceError: LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case noSearchResults
    case noRoute
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Cấu hình máy chủ bản đồ chưa hợp lệ."
        case .invalidResponse:
            "Máy chủ bản đồ trả về dữ liệu không hợp lệ."
        case .noSearchResults:
            "Không tìm thấy địa điểm phù hợp."
        case .noRoute:
            "Không tìm thấy tuyến đường có thể đi bằng ô tô."
        case .server(let message):
            message
        }
    }
}
