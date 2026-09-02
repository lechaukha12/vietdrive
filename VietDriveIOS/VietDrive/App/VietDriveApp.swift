import SwiftUI

@main
struct VietDriveApp: App {
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
            }
        }
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
