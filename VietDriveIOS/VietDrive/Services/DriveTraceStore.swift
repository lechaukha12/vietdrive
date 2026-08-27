import CoreLocation
import Foundation

struct DriveTraceSample: Codable, Equatable {
    let elapsedSeconds: Double
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let speedMetersPerSecond: Double
    let course: Double

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            course: course,
            speed: speedMetersPerSecond,
            timestamp: Date()
        )
    }
}

struct DriveTrace: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let routeTitle: String
    let samples: [DriveTraceSample]

    var durationSeconds: Double { samples.last?.elapsedSeconds ?? 0 }
    var distanceMeters: Double {
        zip(samples, samples.dropFirst()).reduce(0) { result, pair in
            result + pair.0.location.distance(from: pair.1.location)
        }
    }
}

final class DriveTraceStore {
    private struct Recording {
        let id: UUID
        let createdAt: Date
        let routeTitle: String
        var samples: [DriveTraceSample]
    }

    private let directory: URL
    private var recording: Recording?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("VietDrive", isDirectory: true)
            .appendingPathComponent("DriveTraces", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }

    var isRecording: Bool { recording != nil }

    func start(routeTitle: String, at date: Date = Date()) {
        recording = Recording(
            id: UUID(),
            createdAt: date,
            routeTitle: routeTitle,
            samples: []
        )
    }

    func append(location: CLLocation, resolvedHeading: Double) {
        guard var recording else { return }
        let elapsed = max(0, location.timestamp.timeIntervalSince(recording.createdAt))
        let last = recording.samples.last
        guard last == nil || elapsed - (last?.elapsedSeconds ?? 0) >= 0.35 else { return }
        recording.samples.append(DriveTraceSample(
            elapsedSeconds: elapsed,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: max(0, location.horizontalAccuracy),
            speedMetersPerSecond: max(0, location.speed),
            course: location.course >= 0 ? location.course : resolvedHeading
        ))
        self.recording = recording
        if recording.samples.count.isMultiple(of: 10) {
            persist(recording)
        }
    }

    @discardableResult
    func finish() -> DriveTrace? {
        guard let recording else { return nil }
        self.recording = nil
        guard recording.samples.count >= 2 else { return nil }
        let trace = trace(from: recording)
        persist(recording)
        prune(keeping: 10)
        return trace
    }

    func traces() -> [DriveTrace] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.vietDrive.decode(DriveTrace.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func delete(id: UUID) {
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        try? FileManager.default.removeItem(at: url)
    }

    private func prune(keeping limit: Int) {
        for trace in traces().dropFirst(limit) {
            delete(id: trace.id)
        }
    }

    private func persist(_ recording: Recording) {
        let trace = trace(from: recording)
        if let data = try? JSONEncoder.vietDrive.encode(trace) {
            try? data.write(
                to: directory.appendingPathComponent(trace.id.uuidString).appendingPathExtension("json"),
                options: .atomic
            )
        }
    }

    private func trace(from recording: Recording) -> DriveTrace {
        DriveTrace(
            id: recording.id,
            createdAt: recording.createdAt,
            routeTitle: recording.routeTitle,
            samples: recording.samples
        )
    }
}

struct DriveTraceReplay {
    let trace: DriveTrace

    func sample(at elapsedSeconds: Double) -> DriveTraceSample {
        guard let first = trace.samples.first else {
            return DriveTraceSample(
                elapsedSeconds: 0,
                latitude: 10.7769,
                longitude: 106.7009,
                altitude: 0,
                horizontalAccuracy: 10,
                speedMetersPerSecond: 0,
                course: 0
            )
        }
        let clamped = min(max(0, elapsedSeconds), trace.durationSeconds)
        guard let upperIndex = trace.samples.firstIndex(where: {
            $0.elapsedSeconds >= clamped
        }), upperIndex > 0 else { return first }
        let lower = trace.samples[upperIndex - 1]
        let upper = trace.samples[upperIndex]
        let span = max(0.001, upper.elapsedSeconds - lower.elapsedSeconds)
        let fraction = min(1, max(0, (clamped - lower.elapsedSeconds) / span))
        return DriveTraceSample(
            elapsedSeconds: clamped,
            latitude: lower.latitude + (upper.latitude - lower.latitude) * fraction,
            longitude: lower.longitude + (upper.longitude - lower.longitude) * fraction,
            altitude: lower.altitude + (upper.altitude - lower.altitude) * fraction,
            horizontalAccuracy: lower.horizontalAccuracy
                + (upper.horizontalAccuracy - lower.horizontalAccuracy) * fraction,
            speedMetersPerSecond: lower.speedMetersPerSecond
                + (upper.speedMetersPerSecond - lower.speedMetersPerSecond) * fraction,
            course: Self.interpolateHeading(lower.course, upper.course, fraction: fraction)
        )
    }

    private static func interpolateHeading(_ start: Double, _ end: Double, fraction: Double) -> Double {
        var delta = end - start
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return (start + delta * fraction + 360).truncatingRemainder(dividingBy: 360)
    }
}

private extension JSONEncoder {
    static var vietDrive: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var vietDrive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
