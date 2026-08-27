import Combine
import CoreLocation
import Foundation

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var speedKmh = 0
    @Published private(set) var heading = 0.0
    @Published private(set) var headingSource = "compass"
    @Published private(set) var lastLocationError: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var fixQuality: LocationFixQuality = .unavailable
    @Published private(set) var horizontalAccuracy = 0.0
    @Published private(set) var lastFixAt = Date.distantPast

    private let manager = CLLocationManager()
    private var compassHeading: Double?
    private var lastCourseAt = Date.distantPast
    private var smoothedHeading: Double?
    private var backgroundSession: CLBackgroundActivitySession?
    private var staleFixTimer: Timer?

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
        guard authorizationStatus == .authorizedAlways
                || authorizationStatus == .authorizedWhenInUse,
              fixQuality != .unavailable,
              let location,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 65,
              abs(location.timestamp.timeIntervalSinceNow) <= 20 else { return nil }
        return location
    }

    var authorizationDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func start() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        if staleFixTimer == nil {
            staleFixTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, self.lastFixAt != .distantPast else { return }
                let age = Date().timeIntervalSince(self.lastFixAt)
                if age > 20 {
                    self.fixQuality = .unavailable
                } else if age > 8 {
                    self.fixQuality = .weak
                }
            }
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        staleFixTimer?.invalidate()
        staleFixTimer = nil
    }

    func shutdown() {
        setNavigationActive(false)
        stop()
    }

    func setNavigationActive(_ active: Bool) {
        manager.pausesLocationUpdatesAutomatically = !active
        manager.allowsBackgroundLocationUpdates = active
        manager.showsBackgroundLocationIndicator = active
        if active {
            if backgroundSession == nil {
                backgroundSession = CLBackgroundActivitySession()
            }
            start()
        } else {
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            start()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        horizontalAccuracy = max(0, latest.horizontalAccuracy)
        let age = abs(latest.timestamp.timeIntervalSinceNow)
        guard latest.horizontalAccuracy >= 0,
              latest.horizontalAccuracy <= 65,
              age <= 12 else {
            fixQuality = latest.horizontalAccuracy > 65 || age > 12 ? .weak : .unavailable
            return
        }
        lastFixAt = Date()
        switch latest.horizontalAccuracy {
        case ...12: fixQuality = .excellent
        case ...32: fixQuality = .good
        default: fixQuality = .weak
        }
        location = latest
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
}
