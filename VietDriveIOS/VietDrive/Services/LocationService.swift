import Combine
import CoreLocation
import Foundation
import OSLog
import UIKit

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Fix {
        let location: CLLocation
        let speedKmh: Int
        let heading: Double
        let headingSource: String
    }

    /// Published only after all properties for an accepted GPS sample are committed.
    @Published private(set) var currentFix: Fix?
    @Published private(set) var location: CLLocation?
    @Published private(set) var speedKmh = 0
    @Published private(set) var heading = 0.0
    @Published private(set) var headingSource = "compass"
    @Published private(set) var lastLocationError: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var fixQuality: LocationFixQuality = .unavailable
    @Published private(set) var horizontalAccuracy = 0.0
    @Published private(set) var lastFixAt = Date.distantPast
    @Published private(set) var isNavigationActive = false
    @Published private(set) var backgroundSessionStatus = "Chưa có phiên dẫn đường nền"
    @Published private(set) var serviceSessionStatus = "Chưa khởi tạo"
    @Published private(set) var backgroundActivityStatus = "Chưa khởi tạo"

    private let manager = CLLocationManager()
    private let logger = Logger(subsystem: "vn.vietdrive.ios", category: "LocationService")
    private var compassHeading: Double?
    private var lastCourseAt = Date.distantPast
    private var smoothedHeading: Double?
    private var backgroundSession: CLBackgroundActivitySession?
    // Stored as AnyObject because this service still supports iOS 17 while
    // CLServiceSession itself is available from iOS 18.
    private var serviceSessionStorage: AnyObject?
    private var serviceDiagnosticsTask: Task<Void, Never>?
    private var backgroundDiagnosticsTask: Task<Void, Never>?
    private var staleFixTimer: Timer?
    private var updatesStarted = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lastLocationCallbackAt = Date.distantPast
    private var lastRejectedFixDiagnosticAt = Date.distantPast

    var onDiagnostic: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 2
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
        manager.pausesLocationUpdatesAutomatically = true
        observeApplicationLifecycle()
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.delegate = nil
        staleFixTimer?.invalidate()
        serviceDiagnosticsTask?.cancel()
        backgroundDiagnosticsTask?.cancel()
        if #available(iOS 18.0, *) {
            (serviceSessionStorage as? CLServiceSession)?.invalidate()
        }
        backgroundSession?.invalidate()
    }

    func requestAuthorization() {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            start()
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    var routingLocation: CLLocation? {
        let maximumAge: TimeInterval = isNavigationActive
            && UIApplication.shared.applicationState != .active ? 30 : 20
        guard authorizationStatus == .authorizedAlways
                || authorizationStatus == .authorizedWhenInUse,
              fixQuality != .unavailable,
              let location,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 65,
              location.timestamp.timeIntervalSinceNow <= 5,
              Date().timeIntervalSince(location.timestamp) <= maximumAge else { return nil }
        return location
    }

    var authorizationDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func start() {
        guard authorizationStatus == .authorizedAlways
                || authorizationStatus == .authorizedWhenInUse else { return }
        // These methods are idempotent. Calling them again is intentional: it
        // recovers a manager that Core Location paused while the process was
        // transitioning between foreground and background.
        updatesStarted = true
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        if staleFixTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.refreshStaleFixState()
            }
            RunLoop.main.add(timer, forMode: .common)
            staleFixTimer = timer
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        updatesStarted = false
        staleFixTimer?.invalidate()
        staleFixTimer = nil
    }

    func shutdown() {
        setNavigationActive(false)
        stop()
        location = nil
        currentFix = nil
        speedKmh = 0
        fixQuality = .unavailable
        lastFixAt = .distantPast
        lastLocationCallbackAt = .distantPast
        publishDiagnostic("Core Location đã dừng hoàn toàn")
    }

    func setNavigationActive(_ active: Bool) {
        isNavigationActive = active
        authorizationStatus = manager.authorizationStatus
        manager.pausesLocationUpdatesAutomatically = !active
        manager.allowsBackgroundLocationUpdates = active
        manager.showsBackgroundLocationIndicator = active
        if active {
            guard authorizationStatus == .authorizedAlways
                    || authorizationStatus == .authorizedWhenInUse else {
                serviceSessionStatus = "Đang chờ quyền vị trí"
                backgroundActivityStatus = "Sẽ bật sau khi được cấp quyền"
                refreshCombinedSessionStatus()
                return
            }
            if authorizationStatus == .authorizedWhenInUse, #unavailable(iOS 18.0) {
                manager.requestAlwaysAuthorization()
            }
            ensureNavigationContinuity(reason: "navigation_started")
        } else {
            invalidateNavigationSessions()
            serviceSessionStatus = "Đã kết thúc"
            backgroundActivityStatus = "Đã kết thúc"
            refreshCombinedSessionStatus()
            publishDiagnostic(backgroundSessionStatus)
        }
    }

    /// Reasserts the active Core Location workflow without depending on a
    /// SwiftUI view lifecycle callback. This is safe to call repeatedly.
    func ensureNavigationContinuity(reason: String) {
        guard isNavigationActive else { return }
        authorizationStatus = manager.authorizationStatus
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 2
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        createNavigationSessionsIfNeeded()
        start()
        refreshCombinedSessionStatus()
        publishDiagnostic("continuity=\(reason) · \(backgroundSessionStatus)")
    }

    var diagnosticSnapshot: String {
        let age = lastFixAt == .distantPast
            ? "chưa có fix"
            : "fix \(Int(max(0, Date().timeIntervalSince(lastFixAt))))s trước"
        return "\(backgroundSessionStatus) · \(age) · accuracy=\(Int(horizontalAccuracy))m"
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            if isNavigationActive {
                ensureNavigationContinuity(reason: "authorization_changed")
            } else {
                start()
            }
        } else if authorizationDenied {
            stop()
            invalidateNavigationSessions()
            serviceSessionStatus = "Quyền vị trí bị từ chối"
            backgroundActivityStatus = "Không thể chạy nền"
            refreshCombinedSessionStatus()
        }
        publishDiagnostic("authorization=\(authorizationDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Core Location can deliver a batch after the screen is locked. Pick
        // the freshest valid sample instead of trusting array position, then
        // allow the small delivery delay that is normal for background batches.
        guard let latest = locations
            .filter({ $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 65 })
            .max(by: { $0.timestamp < $1.timestamp })
        else {
            fixQuality = .unavailable
            return
        }
        let hasPreviousCallback = lastLocationCallbackAt != .distantPast
        let callbackGap = Date().timeIntervalSince(lastLocationCallbackAt)
        lastLocationCallbackAt = Date()
        if isNavigationActive,
           hasPreviousCallback,
           callbackGap > 15,
           callbackGap.isFinite {
            publishDiagnostic("GPS resumed after \(Int(callbackGap))s · state=\(applicationStateDescription)")
        }
        horizontalAccuracy = max(0, latest.horizontalAccuracy)
        let age = Date().timeIntervalSince(latest.timestamp)
        let maximumAge: TimeInterval = isNavigationActive
            && UIApplication.shared.applicationState != .active ? 30 : 12
        guard age >= -5, age <= maximumAge else {
            fixQuality = .weak
            if Date().timeIntervalSince(lastRejectedFixDiagnosticAt) >= 30 {
                lastRejectedFixDiagnosticAt = Date()
                publishDiagnostic(
                    "Discarded delayed GPS sample age=\(Int(max(0, age)))s · state=\(applicationStateDescription)"
                )
            }
            return
        }
        lastFixAt = Date()
        switch latest.horizontalAccuracy {
        case ...12: fixQuality = .excellent
        case ...32: fixQuality = .good
        default: fixQuality = .weak
        }
        lastLocationError = nil
        speedKmh = latest.speed > 0 ? Int((latest.speed * 3.6).rounded()) : 0

        // GPS course is much more reliable than the magnetometer inside a car.
        // Keep compass as the fallback while stopped or before course stabilises.
        let hasReliableCourse = latest.speed >= 2.5
            && latest.course >= 0
            && (latest.courseAccuracy < 0 || latest.courseAccuracy <= 35)
        if hasReliableCourse {
            lastCourseAt = Date()
            applyHeading(latest.course, source: "gps_course", alpha: 0.38)
        } else if let compassHeading,
                  Date().timeIntervalSince(lastCourseAt) > 3 {
            applyHeading(compassHeading, source: "compass", alpha: 0.18)
        }
        location = latest
        currentFix = Fix(location: latest, speedKmh: speedKmh,
                         heading: heading, headingSource: headingSource)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0,
              newHeading.headingAccuracy <= 45 else { return }
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        compassHeading = value
        guard Date().timeIntervalSince(lastCourseAt) > 3 else { return }
        applyHeading(value, source: "compass", alpha: 0.18)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code != .locationUnknown else { return }
        lastLocationError = error.localizedDescription
        fixQuality = .unavailable
        publishDiagnostic("location_error=\(error.localizedDescription)")
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        updatesStarted = false
        publishDiagnostic("Core Location paused updates · state=\(applicationStateDescription)")
        if isNavigationActive {
            ensureNavigationContinuity(reason: "location_updates_paused")
        }
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        updatesStarted = true
        publishDiagnostic("Core Location resumed updates · state=\(applicationStateDescription)")
    }

    private func applyHeading(_ newValue: Double, source: String, alpha: Double) {
        let normalized = (newValue + 360).truncatingRemainder(dividingBy: 360)
        guard let current = smoothedHeading else {
            smoothedHeading = normalized
            heading = normalized
            headingSource = source
            return
        }
        var delta = normalized - current
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        let result = (current + delta * alpha + 360).truncatingRemainder(dividingBy: 360)
        smoothedHeading = result
        heading = result
        headingSource = source
    }

    private func refreshStaleFixState() {
        guard lastFixAt != .distantPast else { return }
        let age = Date().timeIntervalSince(lastFixAt)
        let isBackgroundNavigation = isNavigationActive
            && UIApplication.shared.applicationState != .active
        let thresholds: (weak: TimeInterval, unavailable: TimeInterval)
        if isBackgroundNavigation, speedKmh < 8 {
            // iOS legitimately batches stationary background fixes. Treating
            // an 8-second gap as signal loss caused repeated false “GPS lost”
            // announcements every time the process woke up.
            thresholds = (75, 180)
        } else if isNavigationActive {
            thresholds = (15, 45)
        } else {
            thresholds = (12, 30)
        }
        if age > thresholds.unavailable {
            fixQuality = .unavailable
            speedKmh = 0
        } else if age > thresholds.weak,
                  fixQuality == .good || fixQuality == .excellent {
            fixQuality = .weak
        }
    }

    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensureNavigationContinuity(reason: "did_enter_background")
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensureNavigationContinuity(reason: "will_enter_foreground")
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensureNavigationContinuity(reason: "did_become_active")
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // A force-quit must end the explicit iOS 18 service/background
            // sessions as well as the classic CLLocationManager updates.
            self?.shutdown()
        })
    }

    private func createNavigationSessionsIfNeeded() {
        if #available(iOS 18.0, *), serviceSessionStorage == nil {
            serviceSessionStatus = "Đang khởi tạo"
            let session = CLServiceSession(authorization: .always)
            serviceSessionStorage = session
            observeDiagnostics(for: session)
        } else if #unavailable(iOS 18.0) {
            serviceSessionStatus = "Core Location iOS 17"
        }
        if backgroundSession == nil {
            backgroundActivityStatus = "Đang khởi tạo"
            let session = CLBackgroundActivitySession()
            backgroundSession = session
            if #available(iOS 18.0, *) {
                observeDiagnostics(for: session)
            } else {
                backgroundActivityStatus = "Background activity session hoạt động"
            }
        }
        refreshCombinedSessionStatus()
    }

    private func invalidateNavigationSessions() {
        serviceDiagnosticsTask?.cancel()
        serviceDiagnosticsTask = nil
        backgroundDiagnosticsTask?.cancel()
        backgroundDiagnosticsTask = nil
        if #available(iOS 18.0, *) {
            (serviceSessionStorage as? CLServiceSession)?.invalidate()
            serviceSessionStorage = nil
        }
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    @available(iOS 18.0, *)
    private func observeDiagnostics(for session: CLServiceSession) {
        serviceDiagnosticsTask?.cancel()
        serviceDiagnosticsTask = Task { @MainActor [weak self] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard !Task.isCancelled else { return }
                    let detail = Self.description(for: diagnostic)
                    self?.serviceSessionStatus = detail
                    self?.refreshCombinedSessionStatus()
                    self?.publishDiagnostic("service_session · \(detail)")
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.publishDiagnostic("service_session_diagnostics_error=\(error.localizedDescription)")
            }
        }
    }

    @available(iOS 18.0, *)
    private func observeDiagnostics(for session: CLBackgroundActivitySession) {
        backgroundDiagnosticsTask?.cancel()
        backgroundDiagnosticsTask = Task { @MainActor [weak self] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard !Task.isCancelled else { return }
                    let detail = Self.description(for: diagnostic)
                    self?.backgroundActivityStatus = detail
                    self?.refreshCombinedSessionStatus()
                    self?.publishDiagnostic("background_session · \(detail)")
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.publishDiagnostic("background_session_diagnostics_error=\(error.localizedDescription)")
            }
        }
    }

    @available(iOS 18.0, *)
    private static func description(for diagnostic: CLServiceSession.Diagnostic) -> String {
        var issues: [String] = []
        if diagnostic.authorizationDenied { issues.append("quyền bị từ chối") }
        if diagnostic.authorizationDeniedGlobally { issues.append("Location Services đang tắt") }
        if diagnostic.authorizationRestricted { issues.append("quyền bị giới hạn") }
        if diagnostic.insufficientlyInUse { issues.append("ứng dụng chưa đủ điều kiện chạy nền") }
        if diagnostic.serviceSessionRequired { issues.append("thiếu service session") }
        if diagnostic.fullAccuracyDenied { issues.append("Precise Location đang tắt") }
        if diagnostic.alwaysAuthorizationDenied { issues.append("chưa cấp quyền Luôn luôn") }
        if diagnostic.authorizationRequestInProgress { issues.append("đang chờ xác nhận quyền") }
        return issues.isEmpty ? "Service session hoạt động" : issues.joined(separator: " · ")
    }

    @available(iOS 18.0, *)
    private static func description(for diagnostic: CLBackgroundActivitySession.Diagnostic) -> String {
        var issues: [String] = []
        if diagnostic.authorizationDenied { issues.append("quyền bị từ chối") }
        if diagnostic.authorizationDeniedGlobally { issues.append("Location Services đang tắt") }
        if diagnostic.authorizationRestricted { issues.append("quyền bị giới hạn") }
        if diagnostic.insufficientlyInUse { issues.append("background session chưa active") }
        if diagnostic.serviceSessionRequired { issues.append("thiếu service session") }
        if diagnostic.authorizationRequestInProgress { issues.append("đang chờ xác nhận quyền") }
        return issues.isEmpty ? "Background session hoạt động" : issues.joined(separator: " · ")
    }

    private var authorizationDescription: String {
        switch authorizationStatus {
        case .authorizedAlways: "always"
        case .authorizedWhenInUse: "when_in_use"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
    }

    private var applicationStateDescription: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private func refreshCombinedSessionStatus() {
        guard isNavigationActive else {
            backgroundSessionStatus = "Phiên dẫn đường nền đã kết thúc"
            return
        }
        backgroundSessionStatus = "Quyền \(authorizationDescription) · Service: \(serviceSessionStatus) · Nền: \(backgroundActivityStatus)"
    }

    private func publishDiagnostic(_ message: String) {
        logger.info("\(message, privacy: .public)")
        onDiagnostic?(message)
    }
}
