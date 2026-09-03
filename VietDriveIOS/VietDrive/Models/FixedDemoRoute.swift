import CoreLocation
import Foundation

/// A bundled route snapshot, not a routing request or a source of speed limits/signs.
enum FixedDemoRoute {
    struct Document: Decodable {
        struct Step: Decodable {
            let pointIndex: Int
            let roadName: String
            let type: String
            let modifier: String
        }
        let schemaVersion: Int
        let coordinates: [[Double]]
        let durationSeconds: Double
        let steps: [Step]
    }

    static func load(bundle: Bundle = .main) throws -> NavigationRoute {
        let url = bundle.url(forResource: "saigon-phanthiet", withExtension: "json", subdirectory: "Demo")
            ?? bundle.url(forResource: "saigon-phanthiet", withExtension: "json")
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> NavigationRoute {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == 1, document.coordinates.count >= 2,
              document.durationSeconds.isFinite, document.durationSeconds > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let coordinates = try document.coordinates.map { pair -> CLLocationCoordinate2D in
            guard pair.count == 2, pair[0].isFinite, pair[1].isFinite,
                  abs(pair[0]) <= 180, abs(pair[1]) <= 90 else { throw CocoaError(.fileReadCorruptFile) }
            return .init(latitude: pair[1], longitude: pair[0])
        }
        var cumulative = [0.0]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let meters = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            guard meters.isFinite, meters < 5_000 else { throw CocoaError(.fileReadCorruptFile) }
            cumulative.append(cumulative.last! + meters)
        }
        guard cumulative.last! > 1_000 else { throw CocoaError(.fileReadCorruptFile) }
        guard zip(document.steps, document.steps.dropFirst()).allSatisfy({ $0.pointIndex <= $1.pointIndex }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let steps = try document.steps.enumerated().map { index, step -> NavigationStep in
            guard coordinates.indices.contains(step.pointIndex) else { throw CocoaError(.fileReadCorruptFile) }
            let action: String
            switch step.type {
            case "depart": action = "Khởi hành"
            case "arrive": action = "Đã đến Phan Thiết"
            case "roundabout", "rotary": action = "Đi vào vòng xuyến"
            default:
                action = step.modifier.contains("left") ? "Rẽ trái"
                    : step.modifier.contains("right") ? "Rẽ phải" : "Tiếp tục đi thẳng"
            }
            return NavigationStep(id: index, instruction: step.roadName.isEmpty ? action : "\(action) · \(step.roadName)",
                                  roadName: step.roadName, type: step.type, modifier: step.modifier,
                                  coordinate: coordinates[step.pointIndex], distanceAlongRouteMeters: cumulative[step.pointIndex])
        }
        return NavigationRoute(id: "offline-demo-saigon-phanthiet-v1", distanceMeters: cumulative.last!,
                               durationSeconds: document.durationSeconds, coordinates: coordinates,
                               cumulativeDistances: cumulative, steps: steps, isCached: true)
    }
}
