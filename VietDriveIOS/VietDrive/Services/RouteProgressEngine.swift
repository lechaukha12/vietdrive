import CoreLocation
import Foundation

enum RouteProgressEngine {
    /// Projection reaching the route's end is insufficient when the car is off-route.
    static func hasArrived(
        on route: NavigationRoute,
        progress: NavigationProgress,
        location: CLLocation,
        at date: Date = Date()
    ) -> Bool {
        guard let end = route.coordinates.last,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 42,
              (-5...8).contains(date.timeIntervalSince(location.timestamp)),
              progress.remainingDistanceMeters <= 25,
              progress.distanceFromRouteMeters <= 25 else { return false }
        return location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)) <= 35
    }

    struct Projection {
        let distanceAlongRouteMeters: Double
        let lateralDistanceMeters: Double
        let segmentIndex: Int
        let segmentBearing: Double
    }

    static func progress(
        on route: NavigationRoute,
        location: CLLocationCoordinate2D,
        previousDistanceMeters: Double? = nil,
        course: Double? = nil
    ) -> NavigationProgress? {
        guard route.coordinates.count >= 2,
              route.cumulativeDistances.count == route.coordinates.count else { return nil }

        guard let routeProjection = projection(
            on: route,
            coordinate: location,
            previousDistanceMeters: previousDistanceMeters,
            course: course
        ) else { return nil }
        let bestDistance = routeProjection.lateralDistanceMeters
        let bestRouteDistance = previousDistanceMeters.map {
            max(routeProjection.distanceAlongRouteMeters, $0 - 30)
        } ?? routeProjection.distanceAlongRouteMeters

        let nextStep = route.steps.first {
            $0.distanceAlongRouteMeters > bestRouteDistance + 12
        } ?? route.steps.last
        let distanceToStep = nextStep.map {
            max(0, Int(($0.distanceAlongRouteMeters - bestRouteDistance).rounded()))
        } ?? 0

        return NavigationProgress(
            matchedDistanceMeters: bestRouteDistance,
            remainingDistanceMeters: max(0, route.distanceMeters - bestRouteDistance),
            distanceFromRouteMeters: bestDistance,
            nextStep: nextStep,
            distanceToNextStepMeters: distanceToStep,
            matchedSegmentIndex: routeProjection.segmentIndex,
            routeBearing: routeProjection.segmentBearing,
            headingDifferenceDegrees: course.map {
                angularDifference($0, routeProjection.segmentBearing)
            }
        )
    }

    static func projection(
        on route: NavigationRoute,
        coordinate: CLLocationCoordinate2D,
        previousDistanceMeters: Double? = nil,
        course: Double? = nil
    ) -> Projection? {
        guard route.coordinates.count >= 2,
              route.cumulativeDistances.count == route.coordinates.count else { return nil }
        var bestScore = Double.greatestFiniteMagnitude
        var bestDistance = Double.greatestFiniteMagnitude
        var bestRouteDistance = 0.0
        var bestIndex = 0
        var bestBearing = 0.0
        for index in 0..<(route.coordinates.count - 1) {
            let segmentStart = route.cumulativeDistances[index]
            let segmentEnd = route.cumulativeDistances[index + 1]
            if let previousDistanceMeters,
               (segmentEnd < previousDistanceMeters - 160
                || segmentStart > previousDistanceMeters + 1_200) {
                continue
            }
            let candidate = project(
                point: coordinate,
                start: route.coordinates[index],
                end: route.coordinates[index + 1]
            )
            let candidateRouteDistance = segmentStart
                + (segmentEnd - segmentStart) * candidate.fraction
            let candidateBearing = bearing(
                from: route.coordinates[index],
                to: route.coordinates[index + 1]
            )
            let headingPenalty = course.map {
                let difference = angularDifference($0, candidateBearing)
                // Strongly reject the opposite carriageway while still allowing
                // noisy headings at low speed and around a junction.
                return difference > 120 ? 95.0 : difference * 0.32
            } ?? 0
            let continuityPenalty: Double
            if let previousDistanceMeters {
                let delta = candidateRouteDistance - previousDistanceMeters
                continuityPenalty = delta < -35
                    ? min(130, abs(delta) * 0.55)
                    : max(0, delta - 350) * 0.04
            } else {
                continuityPenalty = 0
            }
            let score = candidate.distanceMeters + headingPenalty + continuityPenalty
            guard score < bestScore else { continue }
            bestScore = score
            bestDistance = candidate.distanceMeters
            bestRouteDistance = candidateRouteDistance
            bestIndex = index
            bestBearing = candidateBearing
        }
        guard bestScore.isFinite else { return nil }
        return Projection(
            distanceAlongRouteMeters: bestRouteDistance,
            lateralDistanceMeters: bestDistance,
            segmentIndex: bestIndex,
            segmentBearing: bestBearing
        )
    }

    static func cumulativeDistances(
        for coordinates: [CLLocationCoordinate2D]
    ) -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        var result = [0.0]
        result.reserveCapacity(coordinates.count)
        for index in 1..<coordinates.count {
            let previous = CLLocation(
                latitude: coordinates[index - 1].latitude,
                longitude: coordinates[index - 1].longitude
            )
            let current = CLLocation(
                latitude: coordinates[index].latitude,
                longitude: coordinates[index].longitude
            )
            result.append(result[index - 1] + current.distance(from: previous))
        }
        return result
    }

    static func distanceAlongRoute(
        to point: CLLocationCoordinate2D,
        coordinates: [CLLocationCoordinate2D],
        cumulativeDistances: [Double],
        afterDistanceMeters: Double? = nil
    ) -> Double {
        guard coordinates.count >= 2,
              coordinates.count == cumulativeDistances.count else { return 0 }
        var bestDistance = Double.greatestFiniteMagnitude
        var routeDistance = 0.0
        for index in 0..<(coordinates.count - 1) {
            if let afterDistanceMeters,
               cumulativeDistances[index + 1] < afterDistanceMeters - 20 {
                continue
            }
            let projection = project(
                point: point,
                start: coordinates[index],
                end: coordinates[index + 1]
            )
            guard projection.distanceMeters < bestDistance else { continue }
            bestDistance = projection.distanceMeters
            let segmentLength = cumulativeDistances[index + 1] - cumulativeDistances[index]
            routeDistance = cumulativeDistances[index] + segmentLength * projection.fraction
        }
        return routeDistance
    }

    static func angularDifference(_ first: Double, _ second: Double) -> Double {
        let delta = abs(
            (first - second + 540).truncatingRemainder(dividingBy: 360) - 180
        )
        return min(180, max(0, delta))
    }

    /// Finds the next meaningful bend in the route geometry. A 35 m window on
    /// both sides smooths dense/noisy polyline points before classifying it.
    static func upcomingCurve(
        on route: NavigationRoute,
        after distanceMeters: Double,
        lookAheadMeters: Double = 750
    ) -> RouteCurve? {
        guard route.coordinates.count >= 3,
              route.coordinates.count == route.cumulativeDistances.count else { return nil }
        let minimumDistance = distanceMeters + 65
        let maximumDistance = min(route.distanceMeters, distanceMeters + lookAheadMeters)

        for index in 1..<(route.coordinates.count - 1) {
            let candidateDistance = route.cumulativeDistances[index]
            guard candidateDistance >= minimumDistance else { continue }
            guard candidateDistance <= maximumDistance else { break }

            var before = index - 1
            while before > 0,
                  candidateDistance - route.cumulativeDistances[before] < 35 {
                before -= 1
            }
            var after = index + 1
            while after < route.coordinates.count - 1,
                  route.cumulativeDistances[after] - candidateDistance < 35 {
                after += 1
            }
            let incoming = bearing(
                from: route.coordinates[before],
                to: route.coordinates[index]
            )
            let outgoing = bearing(
                from: route.coordinates[index],
                to: route.coordinates[after]
            )
            var delta = outgoing - incoming
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            guard abs(delta) >= 28, abs(delta) <= 145 else { continue }
            return RouteCurve(
                coordinate: route.coordinates[index],
                distanceAlongRouteMeters: candidateDistance,
                modifier: delta < 0 ? "left" : "right"
            )
        }
        return nil
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

    private static func project(
        point: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> (distanceMeters: Double, fraction: Double) {
        let latitudeScale = 111_320.0
        let longitudeScale = latitudeScale * cos(point.latitude * .pi / 180)
        let ax = (start.longitude - point.longitude) * longitudeScale
        let ay = (start.latitude - point.latitude) * latitudeScale
        let bx = (end.longitude - point.longitude) * longitudeScale
        let by = (end.latitude - point.latitude) * latitudeScale
        let dx = bx - ax
        let dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (hypot(ax, ay), 0) }
        let fraction = max(0, min(1, -(ax * dx + ay * dy) / lengthSquared))
        return (hypot(ax + fraction * dx, ay + fraction * dy), fraction)
    }
}
