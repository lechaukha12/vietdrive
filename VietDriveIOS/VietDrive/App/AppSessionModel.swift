import Foundation

@MainActor
final class AppSessionModel: ObservableObject {
    enum Stage: Equatable {
        case onboarding
        case login
        case drive
    }

    @Published var stage: Stage = .onboarding
    @Published private(set) var username = ""

    init() {
        if UserDefaults.standard.bool(forKey: NavigationSessionStore.activeDefaultsKey) {
            stage = .drive
            username = "admin"
            return
        }
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--drive-screen") ||
            arguments.contains("--settings-screen") ||
            arguments.contains("--community-screen") {
            stage = .drive
            username = "admin"
        } else if arguments.contains("--login-screen") {
            stage = .login
        }
#endif
    }

    func finishOnboarding() {
        stage = .login
    }

    func login(username: String, password: String) -> Bool {
        guard username == "admin", password == "admin" else { return false }
        self.username = username
        stage = .drive
        return true
    }

    func logout() {
        username = ""
        stage = .login
    }
}
