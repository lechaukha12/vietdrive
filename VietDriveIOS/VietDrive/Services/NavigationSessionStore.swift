import CoreLocation
import Foundation
import UIKit

struct RestoredNavigationSession {
    let destination: PlaceSearchResult
    let route: NavigationRoute
    let matchedDistanceMeters: Double?
}

final class NavigationSessionStore {
    static let shared = NavigationSessionStore()
    static let activeDefaultsKey = "VietDriveHasActiveNavigationSession"

    private let maximumAge: TimeInterval = 12 * 60 * 60
    private let fileURL: URL?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let directory = base?.appendingPathComponent("VietDrive", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        fileURL = directory?.appendingPathComponent("active-navigation.json")
    }

    func save(
        destination: PlaceSearchResult,
        route: NavigationRoute,
        matchedDistanceMeters: Double?
    ) {
        guard let fileURL else { return }
        let record = SessionRecord(
            savedAt: Date(),
            destination: PlaceRecord(destination),
            route: RouteRecord(route),
            matchedDistanceMeters: matchedDistanceMeters
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            UserDefaults.standard.set(true, forKey: Self.activeDefaultsKey)
        } catch {
            UserDefaults.standard.set(false, forKey: Self.activeDefaultsKey)
        }
    }

    func restore() -> RestoredNavigationSession? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
              Date().timeIntervalSince(record.savedAt) <= maximumAge,
              let destination = record.destination.value,
              let route = record.route.value else {
            clear()
            return nil
        }
        return RestoredNavigationSession(
            destination: destination,
            route: route,
            matchedDistanceMeters: record.matchedDistanceMeters
        )
    }

    func clear() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        UserDefaults.standard.set(false, forKey: Self.activeDefaultsKey)
    }
}

@MainActor
final class NavigationTelemetryRecorder {
    static let shared = NavigationTelemetryRecorder()

    private var fileHandle: FileHandle?
    private var fileURL: URL?

    private init() {}

    func start(routeID: String, restored: Bool = false) {
        finish(event: nil)
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let directory = base
            .appendingPathComponent("VietDrive", isDirectory: true)
            .appendingPathComponent("NavigationLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(directory: directory)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("nav-\(formatter.string(from: Date())).jsonl")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileURL = url
        event(restored ? "session_restored" : "navigation_started", routeID: routeID)
    }

    func sample(
        location: CLLocation,
        resolvedHeading: Double,
        headingSource: String,
        routeID: String,
        progress: NavigationProgress,
        offRouteSamples: Int
    ) {
        write(TelemetryRecord(
            timestamp: Date(),
            event: "location",
            routeID: routeID,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetersPerSecond: location.speed,
            gpsCourse: location.course,
            resolvedHeading: resolvedHeading,
            headingSource: headingSource,
            matchedDistanceMeters: progress.matchedDistanceMeters,
            lateralDistanceMeters: progress.distanceFromRouteMeters,
            routeBearing: progress.routeBearing,
            headingDifferenceDegrees: progress.headingDifferenceDegrees,
            nextStepID: progress.nextStep?.id,
            nextStepDistanceMeters: progress.distanceToNextStepMeters,
            offRouteSamples: offRouteSamples,
            applicationState: Self.applicationState
        ))
    }

    func event(_ name: String, routeID: String? = nil) {
        write(TelemetryRecord(
            timestamp: Date(), event: name, routeID: routeID,
            latitude: nil, longitude: nil, horizontalAccuracy: nil,
            speedMetersPerSecond: nil, gpsCourse: nil, resolvedHeading: nil,
            headingSource: nil, matchedDistanceMeters: nil,
            lateralDistanceMeters: nil, routeBearing: nil,
            headingDifferenceDegrees: nil, nextStepID: nil,
            nextStepDistanceMeters: nil, offRouteSamples: nil,
            applicationState: Self.applicationState
        ))
    }

    func finish(event name: String? = "navigation_finished") {
        if let name { event(name) }
        try? fileHandle?.close()
        fileHandle = nil
        fileURL = nil
    }

    private func write(_ record: TelemetryRecord) {
        guard let fileHandle,
              var data = try? JSONEncoder().encode(record) else { return }
        data.append(0x0A)
        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
        } catch { }
    }

    private func prune(directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let sorted = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for file in sorted.dropFirst(9) { try? FileManager.default.removeItem(at: file) }
    }

    private static var applicationState: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}

private struct SessionRecord: Codable {
    let savedAt: Date
    let destination: PlaceRecord
    let route: RouteRecord
    let matchedDistanceMeters: Double?
}

private struct CoordinateRecord: Codable {
    let latitude: Double
    let longitude: Double
    init(_ value: CLLocationCoordinate2D) {
        latitude = value.latitude
        longitude = value.longitude
    }
    var value: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

private struct PlaceRecord: Codable {
    let id: String
    let name: String
    let subtitle: String
    let coordinate: CoordinateRecord
    init(_ value: PlaceSearchResult) {
        id = value.id; name = value.name; subtitle = value.subtitle
        coordinate = CoordinateRecord(value.coordinate)
    }
    var value: PlaceSearchResult? {
        guard CLLocationCoordinate2DIsValid(coordinate.value) else { return nil }
        return PlaceSearchResult(
            id: id, name: name, subtitle: subtitle,
            latitude: coordinate.latitude, longitude: coordinate.longitude
        )
    }
}

private struct RouteRecord: Codable {
    let id: String
    let distanceMeters: Double
    let durationSeconds: Double
    let coordinates: [CoordinateRecord]
    let steps: [StepRecord]
    let isCached: Bool
    let preferencesApplied: Bool
    init(_ value: NavigationRoute) {
        id = value.id; distanceMeters = value.distanceMeters
        durationSeconds = value.durationSeconds
        coordinates = value.coordinates.map(CoordinateRecord.init)
        steps = value.steps.map(StepRecord.init)
        isCached = value.isCached; preferencesApplied = value.preferencesApplied
    }
    var value: NavigationRoute? {
        let values = coordinates.map(\.value)
        guard values.count >= 2, values.allSatisfy(CLLocationCoordinate2DIsValid) else { return nil }
        return NavigationRoute(
            id: id, distanceMeters: distanceMeters,
            durationSeconds: durationSeconds, coordinates: values,
            cumulativeDistances: RouteProgressEngine.cumulativeDistances(for: values),
            steps: steps.map(\.value), isCached: isCached,
            preferencesApplied: preferencesApplied
        )
    }
}

private struct StepRecord: Codable {
    let id: Int
    let instruction: String
    let roadName: String
    let type: String
    let modifier: String
    let coordinate: CoordinateRecord
    let distanceAlongRouteMeters: Double
    let lanes: [LaneRecord]
    let exitNumber: Int?
    let bearingBefore: Double?
    let bearingAfter: Double?
    init(_ value: NavigationStep) {
        id = value.id; instruction = value.instruction; roadName = value.roadName
        type = value.type; modifier = value.modifier
        coordinate = CoordinateRecord(value.coordinate)
        distanceAlongRouteMeters = value.distanceAlongRouteMeters
        lanes = value.lanes.map(LaneRecord.init); exitNumber = value.exitNumber
        bearingBefore = value.bearingBefore; bearingAfter = value.bearingAfter
    }
    var value: NavigationStep {
        NavigationStep(
            id: id, instruction: instruction, roadName: roadName,
            type: type, modifier: modifier, coordinate: coordinate.value,
            distanceAlongRouteMeters: distanceAlongRouteMeters,
            lanes: lanes.map(\.value), exitNumber: exitNumber,
            bearingBefore: bearingBefore, bearingAfter: bearingAfter
        )
    }
}

private struct LaneRecord: Codable {
    let indications: [String]
    let isValid: Bool
    init(_ value: NavigationLane) { indications = value.indications; isValid = value.isValid }
    var value: NavigationLane { NavigationLane(indications: indications, isValid: isValid) }
}

private struct TelemetryRecord: Codable {
    let timestamp: Date
    let event: String
    let routeID: String?
    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracy: Double?
    let speedMetersPerSecond: Double?
    let gpsCourse: Double?
    let resolvedHeading: Double?
    let headingSource: String?
    let matchedDistanceMeters: Double?
    let lateralDistanceMeters: Double?
    let routeBearing: Double?
    let headingDifferenceDegrees: Double?
    let nextStepID: Int?
    let nextStepDistanceMeters: Int?
    let offRouteSamples: Int?
    let applicationState: String
}
