import Combine
import CoreLocation
import Foundation
import WatchConnectivity

@MainActor
final class PlatformDriveCoordinator: ObservableObject {
    static let shared = PlatformDriveCoordinator()

    @Published private(set) var snapshot = DriveSnapshot()
    @Published private(set) var alerts: [DriveAlert] = []
    @Published private(set) var roads: [RoadOverlay] = []
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    @Published private(set) var destinationName: String?
    @Published private(set) var isNavigating = false
    @Published private(set) var remainingDistanceMeters = 0.0
    @Published private(set) var remainingDurationSeconds = 0.0
    @Published private(set) var mapRevision = 0
    @Published private(set) var companionState = PlatformDriveState.idle

    private let watchSender = WatchContextSender()

    private init() {}

    func publish(
        snapshot: DriveSnapshot,
        alerts: [DriveAlert],
        roads: [RoadOverlay],
        destination: PlaceSearchResult?,
        isNavigating: Bool,
        remainingDistanceMeters: Double,
        remainingDurationSeconds: Double
    ) {
        self.snapshot = snapshot
        self.alerts = alerts
        self.roads = roads
        destinationCoordinate = destination?.coordinate
        destinationName = destination?.name
        self.isNavigating = isNavigating
        self.remainingDistanceMeters = remainingDistanceMeters
        self.remainingDurationSeconds = remainingDurationSeconds

        let state = Self.makeCompanionState(
            snapshot: snapshot,
            isNavigating: isNavigating
        )
        companionState = state
        watchSender.send(state)
    }

    static func makeCompanionState(
        snapshot: DriveSnapshot,
        isNavigating: Bool
    ) -> PlatformDriveState {
        let safetyAlert = snapshot.primaryAlert.flatMap(watchSafetyAlert)
        return PlatformDriveState(
            version: PlatformDriveState.schemaVersion,
            timestamp: Date(),
            speedKmh: snapshot.speedKmh,
            speedLimitKmh: snapshot.speedLimitKmh > 0 ? snapshot.speedLimitKmh : nil,
            roadName: snapshot.roadName,
            isNavigating: isNavigating,
            maneuverText: isNavigating ? snapshot.nextManeuver : nil,
            maneuverDistanceMeters: isNavigating ? snapshot.maneuverDistanceMeters : nil,
            safetyAlertID: safetyAlert?.id,
            safetyAlertText: safetyAlert?.message,
            safetyAlertDistanceMeters: safetyAlert.map { Int($0.distanceMeters.rounded()) },
            signCode: safetyAlert?.signCode,
            signAssetName: safetyAlert?.assetName
        )
    }

    func requestCarPlayRecenter() {
        mapRevision &+= 1
    }

    private static func watchSafetyAlert(_ alert: DriveAlert) -> DriveAlert? {
        switch alert.kind {
        case .speedLimit, .roadSign, .turnRestriction, .parkingRestriction:
            alert
        case .camera, .toll, .hazard, .townBoundary:
            nil
        }
    }
}

private final class WatchContextSender: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "vn.vietdrive.watch-context")
    private var latestPayload: Data?
    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func send(_ state: PlatformDriveState) {
        guard let payload = try? JSONEncoder().encode(state) else { return }
        queue.async { [weak self] in
            self?.latestPayload = payload
            self?.flushIfPossible()
        }
    }

    private func flushIfPossible() {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled,
              let latestPayload else { return }
        do {
            try session.updateApplicationContext(["driveState": latestPayload])
        } catch {
            // Keep the latest payload; activation/reachability changes will retry it.
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        queue.async { [weak self] in self?.flushIfPossible() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        queue.async { [weak self] in self?.flushIfPossible() }
    }
}
