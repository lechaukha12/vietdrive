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

    func testPhotonRetriesWithoutBiasParametersAfterBadRequest() async throws {
        let lock = NSLock()
        var requests: [URLRequest] = []
        RoutingURLProtocol.handler = { request in
            lock.lock()
            requests.append(request)
            let attempt = requests.count
            lock.unlock()
            return attempt == 1
                ? (400, Data(#"{"message":"invalid bbox"}"#.utf8))
                : (200, Self.photonJSON)
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RoutingURLProtocol.self]
        let service = OpenMapService(
            configuration: .init(
                geocoderBaseURL: URL(string: "https://geocoder.invalid")!,
                routerBaseURLs: []
            ),
            session: URLSession(configuration: sessionConfiguration)
        )

        let results = try await service.search(
            query: "Bến Thành",
            near: CLLocationCoordinate2D(latitude: 10.77, longitude: 106.7)
        )

        XCTAssertEqual(results.first?.name, "Chợ Bến Thành")
        XCTAssertEqual(requests.count, 2)
        let firstItems = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        let secondItems = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertNotNil(firstItems?.first { $0.name == "bbox" })
        XCTAssertNil(firstItems?.first { $0.name == "lang" })
        XCTAssertNil(secondItems?.first { $0.name == "bbox" })
        XCTAssertNil(secondItems?.first { $0.name == "lat" })
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept-Language"), "vi,en;q=0.8")
    }

    func testValhallaUsesPOSTAndDecodesOSRMCompatibilityResponse() async throws {
        let lock = NSLock()
        var capturedRequest: URLRequest?
        RoutingURLProtocol.handler = { request in
            lock.lock()
            capturedRequest = request
            lock.unlock()
            return (200, Self.routeJSON)
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RoutingURLProtocol.self]
        let service = OpenMapService(
            configuration: .init(
                geocoderBaseURLs: [URL(string: "https://geocoder.invalid")!],
                routingEndpoints: [
                    .init(
                        baseURL: URL(string: "https://valhalla.invalid")!,
                        engine: .valhalla
                    )
                ]
            ),
            session: URLSession(configuration: sessionConfiguration)
        )

        let routes = try await service.routes(
            from: CLLocationCoordinate2D(latitude: 10, longitude: 106),
            to: CLLocationCoordinate2D(latitude: 10, longitude: 106.01),
            preferences: RoutePreferences(avoidTolls: true, avoidMotorways: true)
        )

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.path, "/route")
        let body = try XCTUnwrap(capturedRequest.flatMap(Self.bodyData))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "osrm")
        XCTAssertEqual(json["shape_format"] as? String, "geojson")
        let costingOptions = try XCTUnwrap(json["costing_options"] as? [String: Any])
        let auto = try XCTUnwrap(costingOptions["auto"] as? [String: Any])
        XCTAssertEqual(auto["use_tolls"] as? Int, 0)
        XCTAssertEqual(auto["use_highways"] as? Int, 0)
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

    private static let photonJSON = Data(#"""
    {
      "features":[{
        "geometry":{"coordinates":[106.6983,10.7725]},
        "properties":{
          "name":"Chợ Bến Thành",
          "city":"Thành phố Hồ Chí Minh",
          "country":"Việt Nam",
          "osm_type":"N",
          "osm_id":123
        }
      }]
    }
    """#.utf8)

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
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
