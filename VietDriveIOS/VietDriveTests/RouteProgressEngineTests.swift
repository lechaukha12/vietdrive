import CoreLocation
import Combine
import XCTest
@testable import VietDrive

final class RouteProgressEngineTests: XCTestCase {
    func testRemainingDurationTracksRemainingDistance() {
        XCTAssertEqual(
            DriveViewModel.proportionalRemainingDuration(
                totalDuration: 7_200,
                totalDistance: 180_000,
                remainingDistance: 90_000
            ),
            3_600,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DriveViewModel.proportionalRemainingDuration(
                totalDuration: 7_200,
                totalDistance: 180_000,
                remainingDistance: -50
            ),
            0,
            accuracy: 0.001
        )
    }

    func testCumulativeDistanceIsMonotonic() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.001, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.002, longitude: 106.0)
        ]
        let distances = RouteProgressEngine.cumulativeDistances(for: coordinates)
        XCTAssertEqual(distances.count, 3)
        XCTAssertEqual(distances[0], 0)
        XCTAssertGreaterThan(distances[1], 100)
        XCTAssertGreaterThan(distances[2], distances[1])
    }

    func testProgressProjectsOntoRouteAndFindsNextStep() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.01),
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.02)
        ]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let step = NavigationStep(
            id: 1,
            instruction: "Rẽ phải",
            roadName: "Đường thử nghiệm",
            type: "turn",
            modifier: "right",
            coordinate: coordinates[2],
            distanceAlongRouteMeters: cumulative[2]
        )
        let route = NavigationRoute(
            distanceMeters: cumulative[2],
            durationSeconds: 120,
            coordinates: coordinates,
            cumulativeDistances: cumulative,
            steps: [step]
        )
        let location = CLLocationCoordinate2D(latitude: 10.00005, longitude: 106.005)
        let progress = try XCTUnwrap(RouteProgressEngine.progress(on: route, location: location))

        XCTAssertLessThan(progress.distanceFromRouteMeters, 10)
        XCTAssertEqual(progress.nextStep?.id, 1)
        XCTAssertGreaterThan(progress.remainingDistanceMeters, 1_000)
        XCTAssertGreaterThan(progress.distanceToNextStepMeters, 1_000)
    }

    func testOffRouteDistanceIsDetected() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.01)
        ]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let route = NavigationRoute(
            distanceMeters: cumulative[1],
            durationSeconds: 60,
            coordinates: coordinates,
            cumulativeDistances: cumulative,
            steps: []
        )
        let location = CLLocationCoordinate2D(latitude: 10.002, longitude: 106.005)
        let progress = try XCTUnwrap(RouteProgressEngine.progress(on: route, location: location))
        XCTAssertGreaterThan(progress.distanceFromRouteMeters, 200)
    }

    func testAlertProjectionReportsAheadDistanceAndLateralOffset() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.02)
        ]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let route = NavigationRoute(
            distanceMeters: cumulative[1],
            durationSeconds: 120,
            coordinates: coordinates,
            cumulativeDistances: cumulative,
            steps: []
        )
        let projection = try XCTUnwrap(RouteProgressEngine.projection(
            on: route,
            coordinate: CLLocationCoordinate2D(latitude: 10.00005, longitude: 106.015)
        ))
        XCTAssertGreaterThan(projection.distanceAlongRouteMeters, 1_500)
        XCTAssertLessThan(projection.lateralDistanceMeters, 10)
    }

    func testUpcomingCurveDetectsRightBend() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.0000, longitude: 106.0000),
            CLLocationCoordinate2D(latitude: 10.0005, longitude: 106.0000),
            CLLocationCoordinate2D(latitude: 10.0010, longitude: 106.0000),
            CLLocationCoordinate2D(latitude: 10.0010, longitude: 106.0005),
            CLLocationCoordinate2D(latitude: 10.0010, longitude: 106.0010)
        ]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let route = NavigationRoute(
            distanceMeters: cumulative.last ?? 0,
            durationSeconds: 60,
            coordinates: coordinates,
            cumulativeDistances: cumulative,
            steps: []
        )

        let curve = try XCTUnwrap(RouteProgressEngine.upcomingCurve(on: route, after: 0))
        XCTAssertEqual(curve.modifier, "right")
        XCTAssertEqual(curve.coordinate.latitude, coordinates[2].latitude, accuracy: 0.000_001)
    }

    func testUpcomingCurveIgnoresStraightGeometry() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.0000, longitude: 106.0000),
            CLLocationCoordinate2D(latitude: 10.0005, longitude: 106.0000),
            CLLocationCoordinate2D(latitude: 10.0010, longitude: 106.0000),
            CLLocationCoordinate2D(latitude: 10.0015, longitude: 106.0000)
        ]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let route = NavigationRoute(
            distanceMeters: cumulative.last ?? 0,
            durationSeconds: 60,
            coordinates: coordinates,
            cumulativeDistances: cumulative,
            steps: []
        )

        XCTAssertNil(RouteProgressEngine.upcomingCurve(on: route, after: 0))
    }

    func testHeadingChoosesCorrectParallelCarriageway() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.00000, longitude: 106.0000),
            CLLocationCoordinate2D(latitude: 10.00000, longitude: 106.0100),
            CLLocationCoordinate2D(latitude: 10.00010, longitude: 106.0100),
            CLLocationCoordinate2D(latitude: 10.00010, longitude: 106.0000)
        ]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let route = NavigationRoute(
            distanceMeters: cumulative.last ?? 0,
            durationSeconds: 120,
            coordinates: coordinates,
            cumulativeDistances: cumulative,
            steps: []
        )
        let position = CLLocationCoordinate2D(latitude: 10.00005, longitude: 106.0050)

        let eastbound = try XCTUnwrap(RouteProgressEngine.projection(
            on: route, coordinate: position, course: 90
        ))
        let westbound = try XCTUnwrap(RouteProgressEngine.projection(
            on: route, coordinate: position, course: 270
        ))

        XCTAssertEqual(eastbound.segmentIndex, 0)
        XCTAssertEqual(westbound.segmentIndex, 2)
    }

    func testPreviousProgressPreventsJumpToDistantRepeatedGeometry() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.000, longitude: 106.000),
            CLLocationCoordinate2D(latitude: 10.000, longitude: 106.010),
            CLLocationCoordinate2D(latitude: 10.020, longitude: 106.010),
            CLLocationCoordinate2D(latitude: 10.020, longitude: 106.000),
            CLLocationCoordinate2D(latitude: 10.000, longitude: 106.000),
            CLLocationCoordinate2D(latitude: 10.000, longitude: 106.010)
        ]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let route = NavigationRoute(
            distanceMeters: cumulative.last ?? 0,
            durationSeconds: 600,
            coordinates: coordinates,
            cumulativeDistances: cumulative,
            steps: []
        )
        let position = CLLocationCoordinate2D(latitude: 10.00001, longitude: 106.005)
        let projection = try XCTUnwrap(RouteProgressEngine.projection(
            on: route,
            coordinate: position,
            previousDistanceMeters: 400,
            course: 90
        ))

        XCTAssertEqual(projection.segmentIndex, 0)
        XCTAssertLessThan(projection.distanceAlongRouteMeters, 1_000)
    }

    func testSequentialStepProjectionUsesLaterOccurrence() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.000, longitude: 106.000),
            CLLocationCoordinate2D(latitude: 10.000, longitude: 106.010),
            CLLocationCoordinate2D(latitude: 10.010, longitude: 106.010),
            CLLocationCoordinate2D(latitude: 10.010, longitude: 106.000),
            CLLocationCoordinate2D(latitude: 10.000, longitude: 106.000)
        ]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let first = RouteProgressEngine.distanceAlongRoute(
            to: coordinates[0], coordinates: coordinates,
            cumulativeDistances: cumulative
        )
        let later = RouteProgressEngine.distanceAlongRoute(
            to: coordinates[0], coordinates: coordinates,
            cumulativeDistances: cumulative,
            afterDistanceMeters: cumulative[3]
        )

        XCTAssertLessThan(first, 1)
        XCTAssertGreaterThan(later, cumulative[3])
    }

    func testAngularDifferenceWrapsNorthAndDetectsReverse() {
        XCTAssertEqual(RouteProgressEngine.angularDifference(355, 5), 10, accuracy: 0.001)
        XCTAssertEqual(RouteProgressEngine.angularDifference(90, 270), 180, accuracy: 0.001)
    }
}

final class NavigationArrivalRegressionTests: XCTestCase {
    func testArrivalRequiresARecentAccurateFixAtTheActualEndpoint() throws {
        let coordinates = [CLLocationCoordinate2D(latitude: 10, longitude: 106),
                           CLLocationCoordinate2D(latitude: 10.01, longitude: 106)]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let route = NavigationRoute(distanceMeters: cumulative.last!, durationSeconds: 120,
                                    coordinates: coordinates, cumulativeDistances: cumulative, steps: [])
        let now = Date()
        func fix(_ coordinate: CLLocationCoordinate2D, accuracy: Double = 5, age: Double = 0) -> CLLocation {
            CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy,
                       verticalAccuracy: -1, course: 0, speed: 10, timestamp: now.addingTimeInterval(-age))
        }
        let far = fix(.init(latitude: 10.0101, longitude: 106.005))
        let offRoute = try XCTUnwrap(RouteProgressEngine.progress(on: route, location: far.coordinate))
        XCTAssertEqual(offRoute.remainingDistanceMeters, 0)
        XCTAssertGreaterThan(offRoute.distanceFromRouteMeters, 500)
        XCTAssertFalse(RouteProgressEngine.hasArrived(on: route, progress: offRoute, location: far, at: now))

        let atEnd = fix(coordinates.last!)
        let endProgress = try XCTUnwrap(RouteProgressEngine.progress(on: route, location: atEnd.coordinate))
        XCTAssertTrue(RouteProgressEngine.hasArrived(on: route, progress: endProgress, location: atEnd, at: now))
        for inaccurate in [fix(coordinates.last!, accuracy: 60), fix(coordinates.last!, accuracy: -1),
                           fix(coordinates.last!, age: 30), fix(coordinates.last!, age: -20),
                           fix(.init(latitude: 10.012, longitude: 106))] {
            let progress = try XCTUnwrap(RouteProgressEngine.progress(on: route, location: inaccurate.coordinate))
            XCTAssertFalse(RouteProgressEngine.hasArrived(on: route, progress: progress, location: inaccurate, at: now))
        }
    }
}

final class DriveInputRegressionTests: XCTestCase {
    @MainActor
    func testCompletedDemoReturnsAlertsToFreeDriveWhileKeepingArrivalRoute() {
        let model = DriveViewModel(navigationBackend: PreviewRoutingBackend())
        XCTAssertTrue(model.startFixedRouteDemo())
        defer { model.stopRouteDemo() }
        XCTAssertNotNil(model.activeAlertRoute)
        model.seekRouteDemo(to: 1)
        XCTAssertTrue(model.didArrive)
        XCTAssertEqual(model.routePhase, .preview)
        XCTAssertNotNil(model.navigationRoute)
        XCTAssertNil(model.activeAlertRoute)
    }

    @MainActor
    func testGPSPublishesSpeedHeadingAndStoredLocationFromTheSameFix() {
        let service = LocationService()
        let manager = CLLocationManager()
        let now = Date()
        let fixes = [(10.0, 60.0, 90.0), (10.001, 36.0, 180.0)].map {
            CLLocation(coordinate: .init(latitude: $0.0, longitude: 106), altitude: 0,
                       horizontalAccuracy: 5, verticalAccuracy: -1, course: $0.2,
                       speed: $0.1 / 3.6, timestamp: now)
        }
        var received: [LocationService.Fix] = []
        let subscription = service.$currentFix.compactMap { $0 }.sink { fix in
            received.append(fix)
            XCTAssertEqual(fix.location, service.location)
            XCTAssertEqual(fix.speedKmh, Int((fix.location.speed * 3.6).rounded()))
            XCTAssertEqual(fix.heading, service.heading)
            XCTAssertEqual(fix.headingSource, "gps_course")
        }
        for fix in fixes { service.locationManager(manager, didUpdateLocations: [fix]) }
        XCTAssertEqual(received.map(\.speedKmh), [60, 36])
        XCTAssertEqual(received.first?.heading, 90)
        XCTAssertGreaterThan(received.last?.heading ?? 0, 90)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testPreviewKeepsRouteForMapButDoesNotUseItForDrivingAlerts() async throws {
        let backend = PreviewRoutingBackend()
        let model = DriveViewModel(navigationBackend: backend)
        let ready = expectation(description: "route preview")
        let subscription = model.$routePhase.filter { $0 == .preview }.first().sink { _ in ready.fulfill() }
        let start = PlaceSearchResult(id: "start", name: "Start", subtitle: "", latitude: 10.5, longitude: 106)
        let end = PlaceSearchResult(id: "end", name: "End", subtitle: "", latitude: 10.51, longitude: 106)
        model.planRoute(from: start, to: end)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNotNil(model.navigationRoute)
        XCTAssertNil(model.activeAlertRoute)
        XCTAssertFalse(model.roads.isEmpty)
        withExtendedLifetime(subscription) {}
    }
}

private final class PreviewRoutingBackend: NavigationBackend {
    var onRoutingHealthUpdate: ((RoutingHealthSnapshot) -> Void)?
    func search(query: String, near coordinate: CLLocationCoordinate2D?) async throws -> [PlaceSearchResult] { [] }
    func route(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
               preferences: RoutePreferences, originBearing: Double?, originAccuracy: Double?) async throws -> NavigationRoute {
        let coordinates = [origin, destination]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        return NavigationRoute(distanceMeters: cumulative.last!, durationSeconds: 120,
                               coordinates: coordinates, cumulativeDistances: cumulative, steps: [])
    }
    func routes(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                preferences: RoutePreferences, originBearing: Double?, originAccuracy: Double?) async throws -> [NavigationRoute] {
        [try await route(from: origin, to: destination, preferences: preferences,
                         originBearing: originBearing, originAccuracy: originAccuracy)]
    }
}
