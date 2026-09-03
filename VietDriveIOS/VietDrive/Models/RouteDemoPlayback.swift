import CoreLocation
import Foundation

/// Synthetic fixes along a user-selected route. No location manager, database or persistence.
struct RouteDemoPlayback {
    struct Sample {
        let coordinate: CLLocationCoordinate2D
        let heading: Double
        let speedKmh: Int
        var location: CLLocation {
            CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 5,
                       verticalAccuracy: -1, course: heading, speed: Double(speedKmh) / 3.6,
                       timestamp: Date())
        }
    }

    private let coordinates: [CLLocationCoordinate2D]
    private let cumulative: [Double]
    private(set) var distanceMeters = 0.0
    private(set) var speedKmh: Int
    private(set) var isPaused = false
    var totalDistanceMeters: Double { cumulative.last ?? 0 }
    var progress: Double { min(1, distanceMeters / totalDistanceMeters) }
    var isFinished: Bool { distanceMeters >= totalDistanceMeters }

    init?(coordinates input: [CLLocationCoordinate2D], speedKmh: Int = 50) {
        // Reject corrupt geometry; don't bridge over invalid points and invent a shortcut.
        guard input.allSatisfy({ CLLocationCoordinate2DIsValid($0)
            && $0.latitude.isFinite && $0.longitude.isFinite }) else { return nil }
        var points: [CLLocationCoordinate2D] = []
        var distances: [Double] = []
        for point in input {
            if let previous = points.last {
                let segment = CLLocation(latitude: point.latitude, longitude: point.longitude)
                    .distance(from: CLLocation(latitude: previous.latitude, longitude: previous.longitude))
                guard segment.isFinite else { return nil }
                if segment < 0.05 { continue }
                distances.append((distances.last ?? 0) + segment)
            } else {
                distances.append(0)
            }
            points.append(point)
        }
        guard points.count >= 2, let total = distances.last, total >= 1 else { return nil }
        coordinates = points
        cumulative = distances
        self.speedKmh = Self.clampedSpeed(speedKmh)
    }

    mutating func setSpeed(_ speed: Int) { speedKmh = Self.clampedSpeed(speed) }
    mutating func pause() { isPaused = true }
    mutating func resume() { if !isFinished { isPaused = false } }

    mutating func seek(to fraction: Double) {
        guard fraction.isFinite else { return }
        distanceMeters = totalDistanceMeters * max(0, min(1, fraction))
        if isFinished { isPaused = true }
    }

    mutating func advance(by seconds: TimeInterval) {
        guard !isPaused, !isFinished, seconds.isFinite, seconds > 0 else { return }
        // Never fast-forward across time spent suspended or a stalled main run loop.
        distanceMeters = min(totalDistanceMeters, distanceMeters + min(1, seconds) * Double(speedKmh) / 3.6)
        if isFinished { isPaused = true }
    }

    func sample() -> Sample {
        var low = 1, high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] <= distanceMeters { low = mid + 1 } else { high = mid }
        }
        let end = low, start = end - 1
        let a = coordinates[start], b = coordinates[end]
        let length = cumulative[end] - cumulative[start]
        let fraction = min(1, max(0, (distanceMeters - cumulative[start]) / length))
        let deltaLongitude = Self.longitudeDelta(b.longitude - a.longitude)
        var longitude = a.longitude + deltaLongitude * fraction
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        let latitude = a.latitude + (b.latitude - a.latitude) * fraction
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dlon = deltaLongitude * .pi / 180
        let bearing = atan2(sin(dlon) * cos(lat2),
                            cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dlon)) * 180 / .pi
        return Sample(coordinate: .init(latitude: latitude, longitude: longitude),
                      heading: (bearing + 360).truncatingRemainder(dividingBy: 360),
                      speedKmh: isPaused || isFinished ? 0 : speedKmh)
    }

    private static func clampedSpeed(_ value: Int) -> Int { max(10, min(120, value)) }
    private static func longitudeDelta(_ value: Double) -> Double {
        value > 180 ? value - 360 : value < -180 ? value + 360 : value
    }
}
