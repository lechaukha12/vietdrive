import CoreLocation
import XCTest
@testable import VietDrive

final class DemoRouteServiceTests: XCTestCase {
    func testSimulationUsesSelectedRouteAndNames() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.0),
            CLLocationCoordinate2D(latitude: 10.0, longitude: 106.01),
            CLLocationCoordinate2D(latitude: 10.01, longitude: 106.01)
        ]
        let cumulative = RouteProgressEngine.cumulativeDistances(for: coordinates)
        let maneuver = NavigationStep(
            id: 7,
            instruction: "Rẽ trái vào đường B",
            roadName: "Đường B",
            type: "turn",
            modifier: "left",
            coordinate: coordinates[2],
            distanceAlongRouteMeters: cumulative[2]
        )
        let route = NavigationRoute(
            distanceMeters: cumulative[2],
            durationSeconds: 240,
            coordinates: coordinates,
            cumulativeDistances: cumulative,
            steps: [maneuver]
        )

        let service = DemoRouteService(
            route: route,
            originName: "Điểm A tự chọn",
            destinationName: "Điểm B tự chọn"
        )
        let position = service.position(at: cumulative[1] / 2)

        XCTAssertEqual(service.routeTitle, "Điểm A tự chọn → Điểm B tự chọn")
        XCTAssertEqual(service.routeOverlay.coordinates.count, coordinates.count)
        XCTAssertEqual(position.nextManeuver?.id, maneuver.id)
        XCTAssertEqual(position.coordinate.latitude, 10.0, accuracy: 0.000_001)
        XCTAssertEqual(position.coordinate.longitude, 106.005, accuracy: 0.000_1)
        XCTAssertGreaterThan(position.maneuverDistanceMeters, 0)
        XCTAssertEqual(
            position.simulatedCruisingSpeedKmh,
            service.estimatedCruisingSpeedKmh
        )
    }

    func testSimulationClampsAtDestination() {
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

        let position = DemoRouteService(
            route: route,
            originName: "A",
            destinationName: "B"
        ).position(at: cumulative[1] + 5_000)

        XCTAssertEqual(position.coordinate.latitude, coordinates[1].latitude, accuracy: 0.000_001)
        XCTAssertEqual(position.coordinate.longitude, coordinates[1].longitude, accuracy: 0.000_001)
        XCTAssertNil(position.nextManeuver)
    }
}
