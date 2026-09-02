import SwiftUI
import UIKit

@main
struct VietDriveApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("drivingModeEnabled") private var drivingModeEnabled = false
    @StateObject private var model = DriveViewModel()
    @StateObject private var session = AppSessionModel()
    private let isRunningTests = ProcessInfo.processInfo.environment[
        "XCTestConfigurationFilePath"
    ] != nil

    var body: some Scene {
        WindowGroup {
            if isRunningTests {
                Color.clear
            } else {
                Group {
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--community-screen") {
                        NavigationStack { CommunityDataHubView() }
                    } else {
                        appContent
                    }
#else
                    appContent
#endif
                }
                .environmentObject(model)
                .environmentObject(session)
                .animation(.snappy(duration: 0.42), value: session.stage)
                .onChange(of: keepsDrivingScreenAwake, initial: true) { _, keepAwake in
                    UIApplication.shared.isIdleTimerDisabled = keepAwake
                }
            }
        }
    }

    /// Only suppress automatic sleep while the signed-in driving screen is in the foreground.
    /// App-level scenePhase also handles multiple windows without competing view callbacks.
    private var keepsDrivingScreenAwake: Bool {
        !isRunningTests && scenePhase == .active && session.stage == .drive && drivingModeEnabled
    }

    @ViewBuilder
    private var appContent: some View {
                    switch session.stage {
                    case .onboarding:
                        OnboardingView { session.finishOnboarding() }
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    case .login:
                        LoginView { username, password in
                            session.login(username: username, password: password)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    case .drive:
                        DriveDashboardView()
                            .transition(.opacity)
                    }
    }
}
