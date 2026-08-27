import CoreLocation
import Foundation

/// Drives a synthetic vehicle along whichever OSRM route the user selected.
/// It deliberately reuses the production route geometry and maneuvers so the
/// simulation exercises the same UI/data path as real navigation.
final class DemoRouteService {
    let route: NavigationRoute
    let originName: String
    let destinationName: String
    let demoTimeScale = 8.0
    let estimatedCruisingSpeedKmh: Int

    init(route: NavigationRoute, originName: String, destinationName: String) {
        self.route = route
        self.originName = originName
        self.destinationName = destinationName
        let averageSpeed = route.durationSeconds > 0
            ? route.distanceMeters / route.durationSeconds * 3.6 : 45
        let rounded = Int((averageSpeed / 10).rounded(.up)) * 10 + 10
        estimatedCruisingSpeedKmh = max(30, min(100, rounded))
    }

    var totalDistanceMeters: Double {
        route.cumulativeDistances.last ?? route.distanceMeters
    }

    var durationSeconds: Double { route.durationSeconds }

    var routeOverlay: RoadOverlay {
        RoadOverlay(
            id: -10_000,
            speedLimit: 0,
            coordinates: route.coordinates,
            isPrimaryRoute: true
        )
    }

    var routeTitle: String { "\(originName) → \(destinationName)" }

    func position(at distanceMeters: Double) -> DemoRoutePosition {
        let clamped = min(max(0, distanceMeters), totalDistanceMeters)
        let upperIndex = upperPointIndex(for: clamped)
        let lowerIndex = max(0, upperIndex - 1)
        let lower = route.coordinates[lowerIndex]
        let upper = route.coordinates[upperIndex]
        let lowerDistance = route.cumulativeDistances[lowerIndex]
        let upperDistance = route.cumulativeDistances[upperIndex]
        let span = max(0.01, upperDistance - lowerDistance)
        let fraction = min(1, max(0, (clamped - lowerDistance) / span))
        let coordinate = CLLocationCoordinate2D(
            latitude: lower.latitude + (upper.latitude - lower.latitude) * fraction,
            longitude: lower.longitude + (upper.longitude - lower.longitude) * fraction
        )
        let nextManeuver = route.steps.first {
            $0.distanceAlongRouteMeters > clamped + 5
        }
        return DemoRoutePosition(
            coordinate: coordinate,
            heading: Self.bearing(from: lower, to: upper),
            simulatedCruisingSpeedKmh: estimatedCruisingSpeedKmh,
            speedSource: "route_estimate",
            roadName: nextManeuver?.roadName.isEmpty == false
                ? nextManeuver!.roadName : routeTitle,
            nextManeuver: nextManeuver,
            maneuverDistanceMeters: nextManeuver.map {
                max(0, Int(($0.distanceAlongRouteMeters - clamped).rounded()))
            } ?? 0,
            maneuverCoordinate: nextManeuver?.coordinate
        )
    }

    private func upperPointIndex(for distance: Double) -> Int {
        var lower = 0
        var upper = route.cumulativeDistances.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if route.cumulativeDistances[middle] < distance {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return min(max(1, lower), route.coordinates.count - 1)
    }

    private static func bearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2)
            - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        return (atan2(y, x) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
    }
}
