import CoreLocation
import XCTest
@testable import VietDrive

final class OpenMapServiceTests: XCTestCase {
    override func tearDown() {
        RoutingURLProtocol.handler = nil
        super.tearDown()
    }

    func testRoutingFallsBackWhenPrimaryIsBusy() async throws {
        let lock = NSLock()
        var requestedHosts: [String] = []
        RoutingURLProtocol.handler = { request in
            let host = request.url?.host ?? ""
            lock.lock()
            requestedHosts.append(host)
            lock.unlock()
            if host == "primary.invalid" {
                return (503, Data("busy".utf8))
            }
            return (200, Self.routeJSON)
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RoutingURLProtocol.self]
        let service = OpenMapService(
            configuration: .init(
                geocoderBaseURL: URL(string: "https://geocoder.invalid")!,
                routerBaseURLs: [
                    URL(string: "https://primary.invalid")!,
                    URL(string: "https://fallback.invalid")!
                ]
            ),
            session: URLSession(configuration: sessionConfiguration)
        )

        let routes = try await service.routes(
            from: CLLocationCoordinate2D(latitude: 10, longitude: 106),
            to: CLLocationCoordinate2D(latitude: 10, longitude: 106.01)
        )

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].steps.first?.instruction, "Đi theo Đường A")
        XCTAssertTrue(requestedHosts.contains("primary.invalid"))
        XCTAssertTrue(requestedHosts.contains("fallback.invalid"))
    }

    private static let routeJSON = Data(#"""
    {
      "code":"Ok",
      "routes":[{
        "distance":1096.0,
        "duration":120.0,
        "geometry":{"coordinates":[[106.0,10.0],[106.01,10.0]]},
        "legs":[{"steps":[{
          "distance":1096.0,
          "duration":120.0,
          "name":"Đường A",
          "maneuver":{"location":[106.0,10.0],"type":"depart","modifier":"straight"}
        }]}]
      }]
    }
    """#.utf8)
}

private final class RoutingURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
