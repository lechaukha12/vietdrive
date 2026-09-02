import ActivityKit
import Foundation
import UIKit

@MainActor
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()

    private let enabledDefaultsKey = "liveActivitiesEnabled"
    private var lastState: VietDriveActivityAttributes.ContentState?
    private var lastUpdateAt = Date.distantPast
    private var isDriveSessionActive = false
    private var terminationObserver: NSObjectProtocol?

    private init() {
        if UserDefaults.standard.object(forKey: enabledDefaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Must end Live Activities synchronously during termination.
            // A fire-and-forget Task won't complete before the process exits.
            let group = DispatchGroup()
            group.enter()
            Task.detached {
                for activity in Activity<VietDriveActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                group.leave()
            }
            _ = group.wait(timeout: .now() + 2)
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func setDriveSessionActive(_ active: Bool) {
        isDriveSessionActive = active
        if active {
            if let lastState { synchronize(lastState, force: true) }
        } else {
            // Block briefly so Live Activities are ended before the caller
            // returns. This is critical when called from terminateApplicationSession()
            // during willTerminate — a fire-and-forget Task would never finish.
            let group = DispatchGroup()
            group.enter()
            Task.detached { [weak self] in
                await self?.endAll(dismissImmediately: true)
                group.leave()
            }
            _ = group.wait(timeout: .now() + 2)
        }
    }

    func publish(snapshot: DriveSnapshot, isNavigating: Bool) {
        let previousState = lastState
        let alert = snapshot.primaryAlert
        let state = VietDriveActivityAttributes.ContentState(
            speedKmh: max(0, snapshot.speedKmh),
            speedLimitKmh: snapshot.speedLimitKmh > 0 ? snapshot.speedLimitKmh : nil,
            roadName: snapshot.roadName,
            isNavigating: isNavigating,
            instruction: isNavigating ? snapshot.nextManeuver : nil,
            instructionDistanceMeters: isNavigating ? snapshot.maneuverDistanceMeters : nil,
            alertText: alert?.message,
            alertDistanceMeters: alert.map { max(0, Int($0.distanceMeters.rounded())) },
            alertSymbolName: alert.map(Self.symbolName),
            isOverSpeed: snapshot.isOverSpeed,
            updatedAt: Date()
        )
        lastState = state
        guard isDriveSessionActive else { return }
        synchronize(state, force: Self.requiresImmediateUpdate(from: previousState, to: state))
    }

    func refreshPreference() {
        guard isEnabled else {
            Task { await endAll(dismissImmediately: true) }
            return
        }
        if isDriveSessionActive, let lastState {
            synchronize(lastState, force: true)
        }
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    private func synchronize(
        _ state: VietDriveActivityAttributes.ContentState,
        force: Bool
    ) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdateAt) >= 1 else { return }
        lastUpdateAt = now
        let content = ActivityContent(
            state: state,
            staleDate: now.addingTimeInterval(12),
            relevanceScore: state.isOverSpeed || state.alertText != nil ? 1 : 0.75
        )
        if let activity = Activity<VietDriveActivityAttributes>.activities.first {
            Task { await activity.update(content) }
            return
        }
        let attributes = VietDriveActivityAttributes(
            sessionID: UUID().uuidString,
            startedAt: now
        )
        do {
            _ = try Activity.request(attributes: attributes, content: content)
        } catch {
            // ActivityKit can reject requests when the user disabled Live Activities.
        }
    }

    /// Ends all VietDrive Live Activities. Called externally when the
    /// ViewModel detects a stale session after a force-quit.
    func endAllActivities() async {
        await endAll(dismissImmediately: true)
    }

    private func endAll(dismissImmediately: Bool) async {
        let finalContent = lastState.map {
            ActivityContent(state: $0, staleDate: Date(), relevanceScore: 0)
        }
        for activity in Activity<VietDriveActivityAttributes>.activities {
            await activity.end(
                finalContent,
                dismissalPolicy: dismissImmediately ? .immediate : .default
            )
        }
    }

    private static func requiresImmediateUpdate(
        from oldState: VietDriveActivityAttributes.ContentState?,
        to newState: VietDriveActivityAttributes.ContentState
    ) -> Bool {
        guard let oldState else { return true }
        return oldState.alertText != newState.alertText
            || oldState.isOverSpeed != newState.isOverSpeed
            || oldState.instruction != newState.instruction
            || oldState.speedLimitKmh != newState.speedLimitKmh
    }

    private static func symbolName(for alert: DriveAlert) -> String {
        switch alert.kind {
        case .camera: "camera.fill"
        case .speedLimit: "gauge.with.dots.needle.67percent"
        case .toll: "creditcard.fill"
        case .townBoundary: "building.2.fill"
        case .parkingRestriction: "parkingsign.slash"
        case .turnRestriction: "arrow.turn.up.left"
        case .roadSign: "signpost.right.and.left.fill"
        case .hazard: "exclamationmark.triangle.fill"
        }
    }
}
