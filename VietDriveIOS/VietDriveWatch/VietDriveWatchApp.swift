import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct VietDriveWatchApp: App {
    @StateObject private var model = WatchDriveModel()

    var body: some Scene {
        WindowGroup {
            WatchDriveView(state: model.state, isConnected: model.isConnected)
        }
    }
}

@MainActor
private final class WatchDriveModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var state = PlatformDriveState.idle
    @Published private(set) var isConnected = false

    private var lastHapticAlertID: Int?
    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
        session?.delegate = self
        session?.activate()
        if let context = session?.receivedApplicationContext {
            apply(context)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.isConnected = activationState == .activated
            self?.apply(session.receivedApplicationContext)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in self?.apply(applicationContext) }
    }

    private func apply(_ context: [String: Any]) {
        guard let payload = context["driveState"] as? Data,
              let newState = try? JSONDecoder().decode(PlatformDriveState.self, from: payload)
        else { return }
        state = newState
        isConnected = true
        if let alertID = newState.safetyAlertID,
           alertID != lastHapticAlertID,
           (newState.safetyAlertDistanceMeters ?? .max) <= 450 {
            lastHapticAlertID = alertID
            WKInterfaceDevice.current().play(.notification)
        }
    }
}

private struct WatchDriveView: View {
    let state: PlatformDriveState
    let isConnected: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(spacing: 0) {
                        Text("\(state.speedKmh)")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("km/h")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    speedLimitBadge
                }

                if let alertText = state.safetyAlertText {
                    Divider()
                    HStack(spacing: 9) {
                        if let assetName = state.signAssetName {
                            Image(assetName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundStyle(.yellow)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alertText)
                                .font(.caption.weight(.semibold))
                                .lineLimit(3)
                            if let distance = state.safetyAlertDistanceMeters {
                                Text("Còn \(distance) m")
                                    .font(.caption2)
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                } else if state.isNavigating, let maneuver = state.maneuverText {
                    Divider()
                    Text(maneuver)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }

                Text(isConnected ? state.roadName : "Đang chờ kết nối iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var speedLimitBadge: some View {
        if let limit = state.speedLimitKmh {
            ZStack {
                Circle().fill(.white)
                Circle().stroke(.red, lineWidth: 5)
                Text("\(limit)")
                    .font(.system(size: limit >= 100 ? 17 : 21, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
            }
            .frame(width: 53, height: 53)
        } else {
            Image(systemName: "road.lanes")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 53, height: 53)
        }
    }
}
