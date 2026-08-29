import CoreLocation
import CryptoKit
import Foundation
import OSLog

final class OpenMapService: NavigationBackend {
    enum RoutingEngine: String {
        case valhalla
        case osrm
    }

    struct RoutingEndpoint {
        let baseURL: URL
        let engine: RoutingEngine
    }

    struct Configuration {
        let geocoderBaseURLs: [URL]
        let routingEndpoints: [RoutingEndpoint]

        init(geocoderBaseURL: URL, routerBaseURLs: [URL]) {
            geocoderBaseURLs = [geocoderBaseURL]
            routingEndpoints = routerBaseURLs.map {
                RoutingEndpoint(baseURL: $0, engine: .osrm)
            }
        }

        init(geocoderBaseURLs: [URL], routingEndpoints: [RoutingEndpoint]) {
            self.geocoderBaseURLs = geocoderBaseURLs
            self.routingEndpoints = routingEndpoints
        }

        static var bundled: Configuration? {
            guard
                let geocoderText = Bundle.main.object(
                    forInfoDictionaryKey: "VietDriveGeocoderBaseURL"
                ) as? String,
                let routerText = Bundle.main.object(
                    forInfoDictionaryKey: "VietDriveRouterBaseURL"
                ) as? String,
                let geocoderURL = URL(string: geocoderText),
                let routerURL = URL(string: routerText)
            else { return nil }
            let fallbackURLs = (Bundle.main.object(
                forInfoDictionaryKey: "VietDriveRouterFallbackBaseURLs"
            ) as? [String] ?? []).compactMap(URL.init(string:))
            let geocoderFallbackURLs = (Bundle.main.object(
                forInfoDictionaryKey: "VietDriveGeocoderFallbackBaseURLs"
            ) as? [String] ?? []).compactMap(URL.init(string:))
            let valhallaURLs = (Bundle.main.object(
                forInfoDictionaryKey: "VietDriveValhallaBaseURLs"
            ) as? [String] ?? []).compactMap(URL.init(string:))
            let geocoders = [geocoderURL]
                + geocoderFallbackURLs.filter { $0 != geocoderURL }
            let endpoints = valhallaURLs.map {
                RoutingEndpoint(baseURL: $0, engine: .valhalla)
            } + ([routerURL] + fallbackURLs.filter { $0 != routerURL }).map {
                RoutingEndpoint(baseURL: $0, engine: .osrm)
            }
            return Configuration(
                geocoderBaseURLs: geocoders,
                routingEndpoints: endpoints
            )
        }
    }

    private let configuration: Configuration?
    private let session: URLSession
    private let cache = OpenMapResponseCache()
    private let logger = Logger(subsystem: "vn.vietdrive.ios", category: "OpenMapService")
    var onRoutingHealthUpdate: ((RoutingHealthSnapshot) -> Void)?

    init(configuration: Configuration? = .bundled, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func search(
        query: String,
        near coordinate: CLLocationCoordinate2D?
    ) async throws -> [PlaceSearchResult] {
        guard let configuration else { throw OpenMapServiceError.invalidConfiguration }
        var failures: [String] = []
        for baseURL in configuration.geocoderBaseURLs {
            do {
                return try await search(query: query, near: coordinate, using: baseURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let endpoint = baseURL.host ?? baseURL.absoluteString
                failures.append("\(endpoint): \(error.localizedDescription)")
                logger.error("Geocoder endpoint \(endpoint, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw OpenMapServiceError.server(
            failures.isEmpty
                ? "Không thể kết nối dịch vụ tìm kiếm."
                : "Không thể tìm địa điểm. \(failures.joined(separator: " · "))"
        )
    }

    private func search(
        query: String,
        near coordinate: CLLocationCoordinate2D?,
        using baseURL: URL
    ) async throws -> [PlaceSearchResult] {
        let preferredURL = try photonURL(
            baseURL: baseURL,
            query: query,
            near: coordinate,
            includeBoundingBox: true
        )
        let data: Data
        do {
            (data, _) = try await self.data(
                for: preferredURL,
                cacheLifetime: 7 * 24 * 60 * 60
            )
        } catch let error as OpenMapServiceError where error.isBadRequest {
            // Some Photon deployments reject optional bias parameters. Retrying
            // the documented minimum query avoids turning that into a dead end.
            let compatibilityURL = try photonURL(
                baseURL: baseURL,
                query: query,
                near: nil,
                includeBoundingBox: false
            )
            (data, _) = try await self.data(
                for: compatibilityURL,
                cacheLifetime: 7 * 24 * 60 * 60
            )
        }

        let response = try JSONDecoder().decode(PhotonResponse.self, from: data)
        return response.features.compactMap(Self.placeSearchResult)
    }

    private func photonURL(
        baseURL: URL,
        query: String,
        near coordinate: CLLocationCoordinate2D?,
        includeBoundingBox: Bool
    ) throws -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api"),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "countrycode", value: "VN")
        ]
        if includeBoundingBox {
            items.append(URLQueryItem(name: "bbox", value: "102.0,8.0,110.0,24.0"))
        }
        if let coordinate {
            items.append(URLQueryItem(name: "lat", value: String(coordinate.latitude)))
            items.append(URLQueryItem(name: "lon", value: String(coordinate.longitude)))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw OpenMapServiceError.invalidConfiguration }
        return url
    }

    private static func placeSearchResult(from feature: PhotonFeature) -> PlaceSearchResult? {
        guard feature.geometry.coordinates.count >= 2 else { return nil }
        let properties = feature.properties
        let name = properties.name
            ?? properties.street
            ?? properties.city
            ?? properties.district
        guard let name, !name.isEmpty else { return nil }
        let parts = [
            properties.housenumber,
            properties.street == name ? nil : properties.street,
            properties.district,
            properties.city,
            properties.state,
            properties.country
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty && $0 != name }
        let osmID = properties.osmID.map(String.init) ?? UUID().uuidString
        return PlaceSearchResult(
            id: "\(properties.osmType ?? "?")-\(osmID)",
            name: name,
            subtitle: Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }
                .joined(separator: ", "),
            latitude: feature.geometry.coordinates[1],
            longitude: feature.geometry.coordinates[0]
        )
    }

    func route(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        preferences: RoutePreferences = RoutePreferences(),
        originBearing: Double? = nil,
        originAccuracy: Double? = nil
    ) async throws -> NavigationRoute {
        guard let first = try await routes(
            from: origin,
            to: destination,
            preferences: preferences,
            originBearing: originBearing,
            originAccuracy: originAccuracy
        ).first else { throw OpenMapServiceError.noRoute }
        return first
    }

    func routes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        preferences: RoutePreferences = RoutePreferences(),
        originBearing: Double? = nil,
        originAccuracy: Double? = nil
    ) async throws -> [NavigationRoute] {
        guard let configuration else { throw OpenMapServiceError.invalidConfiguration }
        var failures: [String] = []
        for (endpointIndex, endpoint) in configuration.routingEndpoints.enumerated() {
            do {
                let result = switch endpoint.engine {
                case .valhalla:
                    try await valhallaRoutes(
                        using: endpoint.baseURL,
                        origin: origin,
                        destination: destination,
                        preferences: preferences,
                        originBearing: originBearing,
                        originAccuracy: originAccuracy
                    )
                case .osrm:
                    try await osrmRoutes(
                        using: endpoint.baseURL,
                        origin: origin,
                        destination: destination,
                        preferences: preferences,
                        originBearing: originBearing,
                        originAccuracy: originAccuracy
                    )
                }
                publishHealth(RoutingHealthSnapshot(
                    endpoint: endpoint.baseURL.host ?? endpoint.baseURL.absoluteString,
                    latencyMilliseconds: result.latencyMilliseconds,
                    usedFallback: endpointIndex > 0,
                    usedCache: result.routes.first?.isCached == true,
                    status: endpointIndex > 0
                        ? "Đã chuyển máy chủ dự phòng"
                        : "Định tuyến \(endpoint.engine.rawValue.uppercased()) ổn định",
                    updatedAt: Date()
                ))
                return result.routes
            } catch {
                let endpointName = endpoint.baseURL.host ?? endpoint.baseURL.absoluteString
                failures.append("\(endpointName): \(error.localizedDescription)")
                logger.error("Routing endpoint \(endpointName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let detail = failures.joined(separator: " · ")
        publishHealth(RoutingHealthSnapshot(
            endpoint: "Không khả dụng",
            latencyMilliseconds: 0,
            usedFallback: true,
            usedCache: false,
            status: "Tất cả máy chủ định tuyến đều lỗi",
            updatedAt: Date()
        ))
        throw OpenMapServiceError.server(
            detail.isEmpty
                ? "Không thể kết nối dịch vụ định tuyến."
                : "Không thể dựng tuyến. \(detail)"
        )
    }

    private func osrmRoutes(
        using routerBaseURL: URL,
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        preferences: RoutePreferences,
        originBearing: Double?,
        originAccuracy: Double?
    ) async throws -> (routes: [NavigationRoute], latencyMilliseconds: Int) {
        let startedAt = Date()
        let excluded = preferences.excludedClasses
        var preferencesApplied = true
        let preferredURL = try routeURL(
            routerBaseURL: routerBaseURL,
            origin: origin,
            destination: destination,
            excluded: excluded,
            originBearing: originBearing,
            originAccuracy: originAccuracy
        )
        let data: Data
        let wasCached: Bool
        do {
            (data, wasCached) = try await self.data(
                for: preferredURL,
                cacheLifetime: 6 * 60 * 60
            )
        } catch where !excluded.isEmpty {
            preferencesApplied = false
            let fallbackURL = try routeURL(
                routerBaseURL: routerBaseURL,
                origin: origin,
                destination: destination,
                excluded: [],
                originBearing: originBearing,
                originAccuracy: originAccuracy
            )
            (data, wasCached) = try await self.data(
                for: fallbackURL,
                cacheLifetime: 6 * 60 * 60
            )
        }
        let routes = try decodeRoutes(
            from: data,
            isCached: wasCached,
            preferencesApplied: preferencesApplied,
            strategy: preferences.strategy
        )
        return (routes, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    private func valhallaRoutes(
        using routerBaseURL: URL,
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        preferences: RoutePreferences,
        originBearing: Double?,
        originAccuracy: Double?
    ) async throws -> (routes: [NavigationRoute], latencyMilliseconds: Int) {
        let startedAt = Date()
        let url = routerBaseURL.appendingPathComponent("route")
        var originLocation: [String: Any] = [
            "lat": origin.latitude,
            "lon": origin.longitude,
            "type": "break"
        ]
        if let originBearing {
            originLocation["heading"] = (originBearing + 360).truncatingRemainder(dividingBy: 360)
            originLocation["heading_tolerance"] = 55
        }
        if let originAccuracy {
            originLocation["radius"] = max(20, min(100, originAccuracy * 2))
        }
        let body: [String: Any] = [
            "locations": [
                originLocation,
                ["lat": destination.latitude, "lon": destination.longitude, "type": "break"]
            ],
            "costing": "auto",
            "costing_options": [
                "auto": [
                    "use_tolls": preferences.avoidTolls ? 0 : 1,
                    "use_highways": preferences.avoidMotorways ? 0 : 1,
                    "use_ferry": preferences.avoidFerries ? 0 : 1,
                    "shortest": preferences.strategy == .shortest
                ]
            ],
            "format": "osrm",
            "shape_format": "geojson",
            "alternates": 2,
            "directions_options": [
                "language": "vi-VN",
                "units": "kilometers"
            ]
        ]
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cacheKey = requestCacheKey(url: url, payload: payload)
        let (data, wasCached) = try await self.data(
            for: request,
            cacheKey: cacheKey,
            cacheLifetime: 6 * 60 * 60
        )
        let routes = try decodeRoutes(
            from: data,
            isCached: wasCached,
            preferencesApplied: true,
            strategy: preferences.strategy
        )
        return (routes, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    private func decodeRoutes(
        from data: Data,
        isCached: Bool,
        preferencesApplied: Bool,
        strategy: RouteStrategy
    ) throws -> [NavigationRoute] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(OSRMResponse.self, from: data)
        guard response.code == "Ok" else {
            throw OpenMapServiceError.server(response.message ?? "Máy chủ không thể dựng tuyến.")
        }
        guard let rawRoutes = response.routes, !rawRoutes.isEmpty else {
            throw OpenMapServiceError.noRoute
        }
        let sortedRoutes = rawRoutes.sorted {
            strategy == .shortest ? $0.distance < $1.distance : $0.duration < $1.duration
        }
        return try sortedRoutes.enumerated().map { index, selected in
            try navigationRoute(
                from: selected,
                index: index,
                isCached: isCached,
                preferencesApplied: preferencesApplied
            )
        }
    }

    private func routeURL(
        routerBaseURL: URL,
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        excluded: [String],
        originBearing: Double?,
        originAccuracy: Double?
    ) throws -> URL {
        let coordinates = String(
            format: "%.6f,%.6f;%.6f,%.6f",
            origin.longitude,
            origin.latitude,
            destination.longitude,
            destination.latitude
        )
        var components = URLComponents(
            url: routerBaseURL
                .appendingPathComponent("route/v1/driving")
                .appendingPathComponent(coordinates),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "alternatives", value: "3"),
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson")
        ]
        if !excluded.isEmpty {
            items.append(URLQueryItem(name: "exclude", value: excluded.joined(separator: ",")))
        }
        if let originBearing {
            let normalized = Int((originBearing + 360).truncatingRemainder(dividingBy: 360).rounded())
            items.append(URLQueryItem(name: "bearings", value: "\(normalized),55;"))
        }
        if originBearing != nil || originAccuracy != nil {
            let radius = max(20, min(100, (originAccuracy ?? 20) * 2))
            items.append(URLQueryItem(name: "radiuses", value: "\(Int(radius.rounded()));unlimited"))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw OpenMapServiceError.invalidConfiguration }
        return url
    }

    private func navigationRoute(
        from selected: OSRMRoute,
        index: Int,
        isCached: Bool,
        preferencesApplied: Bool
    ) throws -> NavigationRoute {
        let routeCoordinates = selected.geometry.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
        guard routeCoordinates.count >= 2 else { throw OpenMapServiceError.invalidResponse }
        let cumulative = RouteProgressEngine.cumulativeDistances(for: routeCoordinates)
        let rawSteps = selected.legs.flatMap(\.steps)
        var steps: [NavigationStep] = []
        var stepCursor = 0.0
        for (index, step) in rawSteps.enumerated() {
            guard step.maneuver.location.count >= 2 else { continue }
            let coordinate = CLLocationCoordinate2D(
                latitude: step.maneuver.location[1],
                longitude: step.maneuver.location[0]
            )
            let projectedDistance = RouteProgressEngine.distanceAlongRoute(
                to: coordinate,
                coordinates: routeCoordinates,
                cumulativeDistances: cumulative,
                afterDistanceMeters: stepCursor
            )
            stepCursor = max(stepCursor, projectedDistance)
            steps.append(NavigationStep(
                id: index,
                instruction: Self.instruction(for: step),
                roadName: step.name,
                type: step.maneuver.type,
                modifier: step.maneuver.modifier ?? "",
                coordinate: coordinate,
                distanceAlongRouteMeters: stepCursor,
                lanes: step.intersections?
                    .first(where: { !($0.lanes ?? []).isEmpty })?
                    .lanes?
                    .map { NavigationLane(indications: $0.indications ?? [], isValid: $0.valid ?? false) }
                    ?? [],
                exitNumber: step.maneuver.exit,
                bearingBefore: step.maneuver.bearingBefore,
                bearingAfter: step.maneuver.bearingAfter
            ))
        }
        return NavigationRoute(
            id: "route-\(index)-\(Int(selected.distance.rounded()))",
            distanceMeters: selected.distance,
            durationSeconds: selected.duration,
            coordinates: routeCoordinates,
            cumulativeDistances: cumulative,
            steps: steps,
            isCached: isCached,
            preferencesApplied: preferencesApplied
        )
    }

    private func data(for url: URL, cacheLifetime: TimeInterval) async throws -> (Data, Bool) {
        let request = URLRequest(url: url)
        return try await data(for: request, cacheKey: url, cacheLifetime: cacheLifetime)
    }

    private func data(
        for request: URLRequest,
        cacheKey: URL,
        cacheLifetime: TimeInterval
    ) async throws -> (Data, Bool) {
        var request = request
        request.timeoutInterval = 10
        request.setValue("VietDrive/0.3 (iOS; contact: local-development)", forHTTPHeaderField: "User-Agent")
        request.setValue("vi,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cached = cache.data(
                for: cacheKey,
                maximumAge: cacheLifetime,
                allowExpired: true
            ) {
                return (cached, true)
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenMapServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // A stale route is safer than no route during a temporary outage,
            // but never hide a malformed client request behind cached data.
            if (http.statusCode == 429 || http.statusCode >= 500),
               let cached = cache.data(
                   for: cacheKey,
                   maximumAge: cacheLifetime,
                   allowExpired: true
               ) {
                return (cached, true)
            }
            let detail = String(data: data.prefix(240), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
            throw OpenMapServiceError.http(
                status: http.statusCode,
                host: request.url?.host ?? "máy chủ",
                detail: detail
            )
        }
        cache.store(data, for: cacheKey)
        return (data, false)
    }

    private func requestCacheKey(url: URL, payload: Data) -> URL {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "payload", value: digest)]
        return components?.url ?? url
    }

    private func publishHealth(_ snapshot: RoutingHealthSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.onRoutingHealthUpdate?(snapshot)
        }
    }

    private static func instruction(for step: OSRMStep) -> String {
        let road = step.name.isEmpty ? "" : " vào \(step.name)"
        switch step.maneuver.type {
        case "depart": return step.name.isEmpty ? "Bắt đầu hành trình" : "Đi theo \(step.name)"
        case "arrive": return "Bạn đã đến điểm đến"
        case "roundabout", "rotary":
            if let exit = step.maneuver.exit {
                return "Đi vào vòng xuyến, ra ở lối thứ \(exit)\(road)"
            }
            return "Đi vào vòng xuyến\(road)"
        case "merge": return "Nhập làn\(road)"
        case "fork": return "Đi theo nhánh \(direction(step.maneuver.modifier))\(road)"
        case "on ramp": return "Đi vào đường dẫn \(direction(step.maneuver.modifier))\(road)"
        case "off ramp": return "Ra khỏi đường chính \(direction(step.maneuver.modifier))\(road)"
        case "continue", "new name": return "Tiếp tục \(direction(step.maneuver.modifier))\(road)"
        default:
            let action = turnAction(step.maneuver.modifier)
            return "\(action)\(road)"
        }
    }

    private static func turnAction(_ modifier: String?) -> String {
        switch modifier {
        case "sharp left": "Rẽ gấp trái"
        case "left": "Rẽ trái"
        case "slight left": "Chếch trái"
        case "sharp right": "Rẽ gấp phải"
        case "right": "Rẽ phải"
        case "slight right": "Chếch phải"
        case "uturn": "Quay đầu"
        default: "Đi thẳng"
        }
    }

    private static func direction(_ modifier: String?) -> String {
        switch modifier {
        case "left", "sharp left", "slight left": "bên trái"
        case "right", "sharp right", "slight right": "bên phải"
        default: "phía trước"
        }
    }
}

private struct PhotonResponse: Decodable {
    let features: [PhotonFeature]
}

private struct PhotonFeature: Decodable {
    let geometry: PhotonGeometry
    let properties: PhotonProperties
}

private struct PhotonGeometry: Decodable {
    let coordinates: [Double]
}

private struct PhotonProperties: Decodable {
    let name: String?
    let street: String?
    let housenumber: String?
    let district: String?
    let city: String?
    let state: String?
    let country: String?
    let osmType: String?
    let osmID: Int64?

    enum CodingKeys: String, CodingKey {
        case name, street, housenumber, district, city, state, country
        case osmType = "osm_type"
        case osmID = "osm_id"
    }
}

private struct OSRMResponse: Decodable {
    let code: String
    let message: String?
    let routes: [OSRMRoute]?
}

private struct OSRMRoute: Decodable {
    let distance: Double
    let duration: Double
    let geometry: OSRMGeometry
    let legs: [OSRMLeg]
}

private struct OSRMGeometry: Decodable {
    let coordinates: [[Double]]
}

private struct OSRMLeg: Decodable {
    let steps: [OSRMStep]
}

private struct OSRMStep: Decodable {
    let distance: Double
    let duration: Double
    let name: String
    let maneuver: OSRMManeuver
    let intersections: [OSRMIntersection]?
}

private struct OSRMManeuver: Decodable {
    let location: [Double]
    let type: String
    let modifier: String?
    let exit: Int?
    let bearingBefore: Double?
    let bearingAfter: Double?
}

private struct OSRMIntersection: Decodable {
    let lanes: [OSRMLane]?
}

private struct OSRMLane: Decodable {
    let indications: [String]?
    let valid: Bool?
}

private final class OpenMapResponseCache {
    private let directory: URL?

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        directory = base?.appendingPathComponent("VietDrive/OpenMapResponses", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func data(
        for url: URL,
        maximumAge: TimeInterval,
        allowExpired: Bool = false
    ) -> Data? {
        guard let file = fileURL(for: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if !allowExpired, Date().timeIntervalSince(modified) > maximumAge { return nil }
        return try? Data(contentsOf: file)
    }

    func store(_ data: Data, for url: URL) {
        guard let file = fileURL(for: url) else { return }
        try? data.write(to: file, options: .atomic)
        prune(maximumFiles: 300, maximumBytes: 80 * 1_024 * 1_024)
    }

    private func prune(maximumFiles: Int, maximumBytes: Int) {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
              ) else { return }
        let entries = urls.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey
            ]) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var totalBytes = 0
        for (index, entry) in entries.enumerated() {
            totalBytes += entry.2
            if index >= maximumFiles || totalBytes > maximumBytes {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }

    private func fileURL(for url: URL) -> URL? {
        guard let directory,
              let data = url.absoluteString.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
}
