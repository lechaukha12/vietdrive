import Combine
import CoreLocation
import Foundation
import OSLog
import UIKit

@MainActor
final class DriveViewModel: ObservableObject {
    private static let speedLogger = Logger(
        subsystem: "vn.vietdrive.ios",
        category: "SpeedLimitUI"
    )
    @Published private(set) var snapshot = DriveSnapshot()
    @Published private(set) var alerts: [DriveAlert] = []
    @Published private(set) var viewportAlerts: [DriveAlert] = []
    @Published private(set) var roads: [RoadOverlay] = []
    @Published var followUser = true
    @Published var isDemoActive = false
    @Published var showCameras = true
    @Published var showRoadSigns = true
    @Published var showValidatedRoads = true
    @Published var voiceEnabled = UserDefaults.standard.object(forKey: "voiceEnabled") as? Bool ?? true
    @Published private(set) var cameraRevision = 0
    @Published private(set) var communityRevision = 0

    @Published private(set) var routePhase: RoutePhase = .idle
    @Published private(set) var routeOrigin: PlaceSearchResult?
    @Published private(set) var destination: PlaceSearchResult?
    @Published private(set) var navigationRoute: NavigationRoute?
    @Published private(set) var routeAlternatives: [NavigationRoute] = []
    @Published private(set) var selectedRouteIndex = 0
    @Published var routePreferences = DriveViewModel.loadRoutePreferences()
    @Published private(set) var routeErrorMessage: String?
    @Published private(set) var isRerouting = false
    @Published private(set) var remainingDistanceMeters = 0.0
    @Published private(set) var remainingDurationSeconds = 0.0
    @Published private(set) var didArrive = false
    @Published private(set) var routeViewportRevision = 0
    @Published private(set) var isCheckingDataUpdate = false
    @Published private(set) var dataUpdateStatus = ""
    @Published private(set) var routingHealth = RoutingHealthSnapshot.idle
    @Published private(set) var savedTraces: [DriveTrace] = []
    @Published private(set) var isTraceRecording = false
    @Published private(set) var isTraceReplayActive = false
    @Published private(set) var traceReplayProgress = 0.0
    @Published private(set) var mapMatchStatus = "Chưa bắt đầu dẫn đường"
    @Published private(set) var speedLimitDiagnosticText = "Chưa khớp đoạn đường"
    @Published private(set) var voiceDiagnosticText = "Chưa phát prompt"
    @Published private(set) var mapIssueReportCount = 0
    @Published private(set) var dataReportStatus = ""
    @Published private(set) var offlineMapStatus = "Cache tự động 150 MB đang hoạt động"
    @Published private(set) var offlineMapProgress = 0.0
    @Published private(set) var offlineMapPackCount = 0

    let locationService = LocationService()

    private let alertStore = OfflineAlertStore()
    private let voice = VoiceAlertService()
    private var demoRouteService: DemoRouteService?
    private let openMapService = OpenMapService()
    private let mapDataUpdateService = MapDataUpdateService()
    private let communityStore = CommunityContributionStore.shared
    private let navigationSessionStore = NavigationSessionStore.shared
    private let telemetry = NavigationTelemetryRecorder.shared
    private let traceStore = DriveTraceStore()
    private let mapDataIssueStore = MapDataIssueStore()
    private let offlineMapDownloadService = OfflineMapDownloadService()
    private var cancellables = Set<AnyCancellable>()
    private var demoTimer: AnyCancellable?
    private var demoDistanceMeters = 0.0
    private var demoSpeedKmh = 0.0
    private var lastDatabaseQuery = Date.distantPast
    private var isDatabaseQueryInFlight = false
    private var lastViewportCenter: CLLocationCoordinate2D?
    private var lastViewportRadius = 0.0
    private var viewportQueryToken = UUID()
    private var offRouteSamples = 0
    private var wrongDirectionSamples = 0
    private var lastRerouteAt = Date.distantPast
    private var lastHapticAlertID: Int?
    private var wasOverSpeed = false
    private var matchedRouteDistanceMeters: Double?
    private var lastSessionSaveAt = Date.distantPast
    private var journeyTask: Task<Void, Never>?
    private var routePlanningToken = UUID()
    private var traceReplay: DriveTraceReplay?
    private var traceReplayTimer: AnyCancellable?
    private var traceReplayElapsed = 0.0

    init() {
        voice.isEnabled = voiceEnabled
        voice.onDiagnostic = { [weak self] message in
            self?.voiceDiagnosticText = message
        }
        savedTraces = traceStore.traces()
        mapIssueReportCount = mapDataIssueStore.reports().count
        offlineMapPackCount = offlineMapDownloadService.packCount
        offlineMapDownloadService.onUpdate = { [weak self] status, progress, count in
            self?.offlineMapStatus = status
            self?.offlineMapProgress = progress
            self?.offlineMapPackCount = count
        }
        openMapService.onRoutingHealthUpdate = { [weak self] health in
            self?.routingHealth = health
        }
        communityStore.$contributions
            .sink { [weak self] _ in
                guard let self else { return }
                self.communityRevision += 1
                self.snapshot.primaryAlert = self.preferredPrimaryAlert(from: self.visibleAlerts)
            }
            .store(in: &cancellables)
        locationService.$location
            .compactMap { $0 }
            .sink { [weak self] location in
                guard let self, !self.isDemoActive, !self.isTraceReplayActive else { return }
                self.process(
                    location: location,
                    speed: self.locationService.speedKmh,
                    heading: self.locationService.heading,
                    isDemo: false
                )
            }
            .store(in: &cancellables)
        locationService.$fixQuality
            .removeDuplicates()
            .sink { [weak self] quality in
                guard let self, self.isNavigating, !self.isTraceReplayActive else { return }
                self.voice.updateGPSAvailability(quality == .good || quality == .excellent)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self, self.routePhase == .navigating else { return }
                self.persistNavigationSession(force: true)
                self.telemetry.event("application_background", routeID: self.navigationRoute?.id)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard let self, self.routePhase == .navigating else { return }
                self.telemetry.event("application_foreground", routeID: self.navigationRoute?.id)
            }
            .store(in: &cancellables)
    }

    var visibleAlerts: [DriveAlert] {
        let communityAlerts = communityStore.approvedAlerts(near: snapshot.coordinate)
        return (alerts + communityAlerts).filter { alert in
            guard alert.confidence == 0 || alert.confidence >= 0.55 else { return false }
            if Self.isTurnRestrictionAlert(alert) {
                return showRoadSigns
                    && isGuidanceActive
                    && isTurnRestrictionOnActiveRoute(alert)
            }
            return switch alert.kind {
            case .camera: showCameras
            case .roadSign, .speedLimit, .turnRestriction, .parkingRestriction: showRoadSigns
            default: true
            }
        }
    }

    /// Bao gồm dữ liệu quanh xe để cảnh báo và dữ liệu trong viewport để vẽ.
    /// Hai nguồn dùng cùng ID nên được gộp mà không tạo marker trùng nhau.
    var mapDisplayAlerts: [DriveAlert] {
        var indexed = Dictionary(uniqueKeysWithValues: viewportAlerts.map { ($0.id, $0) })
        for alert in visibleAlerts { indexed[alert.id] = alert }
        return indexed.values.filter { alert in
            switch alert.kind {
            case .camera: showCameras
            case .roadSign, .speedLimit, .turnRestriction, .parkingRestriction:
                showRoadSigns
            default: true
            }
        }
        .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    var visibleRoads: [RoadOverlay] {
        roads.filter { $0.isPrimaryRoute || showValidatedRoads }
    }

    /// Camera vẫn được vẽ trên bản đồ và có thể phát voice, nhưng không còn
    /// chiếm thanh cảnh báo đếm ngược trên màn hình dẫn đường.
    var countdownBannerAlert: DriveAlert? {
        preferredPrimaryAlert(from: visibleAlerts.filter { $0.kind != .camera })
    }

    var isNavigating: Bool { routePhase == .navigating }
    var isRoutePreview: Bool { routePhase == .preview }
    var isPlanningRoute: Bool { routePhase == .planning }
    var isGuidanceActive: Bool { isNavigating || isDemoActive || isTraceReplayActive }
    var canStartSimulation: Bool {
        navigationRoute != nil && destination != nil && !isPlanningRoute
    }
    var routeOriginText: String { routeOrigin?.name ?? "Vị trí hiện tại" }
    var selectedRouteTitle: String {
        "\(routeOriginText) → \(destination?.name ?? "Điểm đến")"
    }
    var voiceDescription: String { voice.voiceDescription }
    var locationFixQuality: LocationFixQuality {
        isDemoActive || isTraceReplayActive ? .excellent : locationService.fixQuality
    }
    var shouldShowGuidanceMascot: Bool {
        isGuidanceActive
            && !isRerouting
            && locationFixQuality != .weak
            && snapshot.laneGuidance.isEmpty
            && !(countdownBannerAlert.map { $0.distanceMeters <= 250 } ?? false)
    }
    var trafficSignCount: Int { alertStore.trafficSignCount }
    var suppliedSpeedObservationCount: Int { alertStore.suppliedSpeedObservationCount }
    var mapDataPointCount: Int { alertStore.mapDataPointCount }
    var mapDataCameraCount: Int { alertStore.mapDataCameraCount }
    var mapDataSpeedPointCount: Int { alertStore.mapDataSpeedPointCount }
    var mapDataRoadLinkCount: Int { alertStore.mapDataRoadLinkCount }
    var turnRestrictionCount: Int { alertStore.turnRestrictionCount }
    var roadRuleCount: Int { alertStore.roadRuleCount }
    var pendingReviewCount: Int { alertStore.pendingReviewCount }
    var datasetVersion: String { alertStore.datasetVersion }
    var isDataUpdateConfigured: Bool { mapDataUpdateService.isConfigured }

    var routeDistanceText: String {
        Self.distanceText(isGuidanceActive || didArrive
            ? remainingDistanceMeters
            : navigationRoute?.distanceMeters ?? 0)
    }

    var routeDurationText: String {
        let seconds = isGuidanceActive || didArrive
            ? remainingDurationSeconds
            : navigationRoute?.durationSeconds ?? 0
        if seconds <= 30 { return didArrive ? "Đã đến" : "< 1 phút" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes >= 60 {
            return "\(minutes / 60) giờ \(minutes % 60) phút"
        }
        return "\(minutes) phút"
    }

    var arrivalTimeText: String {
        let seconds = isGuidanceActive || didArrive
            ? remainingDurationSeconds
            : navigationRoute?.durationSeconds ?? 0
        guard seconds > 30 else { return didArrive ? "Đã đến nơi" : "Sắp đến" }
        return Date()
            .addingTimeInterval(seconds)
            .formatted(date: .omitted, time: .shortened)
    }

    var routeProgress: Double {
        guard isGuidanceActive || didArrive else { return 0 }
        let total = isDemoActive
            ? demoRouteService?.totalDistanceMeters ?? 0
            : navigationRoute?.distanceMeters ?? 0
        guard total > 0 else { return didArrive ? 1 : 0 }
        return min(1, max(0, 1 - remainingDistanceMeters / total))
    }

    func start() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--route-preview") {
            locationService.requestAuthorization()
            planRoute(to: PlaceSearchResult(
                id: "debug-phan-thiet",
                name: "Phan Thiết",
                subtitle: "Bình Thuận, Việt Nam",
                latitude: 10.9296264,
                longitude: 108.1043869
            ))
            return
        }
        #endif
        restoreNavigationSessionIfNeeded()
        locationService.requestAuthorization()
    }

    func searchDestinations(query: String) async throws -> [PlaceSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        return try await openMapService.search(
            query: trimmed,
            near: locationService.location?.coordinate ?? snapshot.coordinate
        )
    }

    func planRoute(
        from selectedOrigin: PlaceSearchResult?,
        to result: PlaceSearchResult
    ) {
        if isDemoActive { stopDemo() }
        routeOrigin = selectedOrigin
        destination = result
        routePhase = .planning
        didArrive = false
        routeErrorMessage = nil
        navigationRoute = nil
        remainingDistanceMeters = 0
        remainingDurationSeconds = 0
        let origin = selectedOrigin?.coordinate
            ?? locationService.location?.coordinate
            ?? snapshot.coordinate
        let movingBearing = selectedOrigin == nil
            && (locationService.location?.speed ?? -1) >= 2.5
            ? locationService.heading : nil
        let originAccuracy = selectedOrigin == nil
            ? locationService.location?.horizontalAccuracy : nil
        let planningToken = UUID()
        routePlanningToken = planningToken

        Task {
            do {
                let routes = try await openMapService.routes(
                    from: origin,
                    to: result.coordinate,
                    preferences: routePreferences,
                    originBearing: movingBearing,
                    originAccuracy: originAccuracy
                )
                guard routePlanningToken == planningToken,
                      destination?.id == result.id else { return }
                guard let route = routes.first else { throw OpenMapServiceError.noRoute }
                routeAlternatives = routes
                selectedRouteIndex = 0
                navigationRoute = route
                routePhase = .preview
                roads = [route.overlay]
                routeViewportRevision += 1
                followUser = false
            } catch is CancellationError {
                return
            } catch {
                guard routePlanningToken == planningToken,
                      destination?.id == result.id else { return }
                routePhase = .idle
                navigationRoute = nil
                routeErrorMessage = error.localizedDescription
            }
        }
    }

    func planRoute(to result: PlaceSearchResult) {
        planRoute(from: nil, to: result)
    }

    func startNavigation() {
        guard let navigationRoute, let destination else { return }
        voice.resetNavigation()
        routePhase = .navigating
        mapMatchStatus = "Đang chờ GPS khớp vào tuyến"
        didArrive = false
        remainingDistanceMeters = navigationRoute.distanceMeters
        remainingDurationSeconds = navigationRoute.durationSeconds
        followUser = true
        cameraRevision += 1
        offRouteSamples = 0
        wrongDirectionSamples = 0
        matchedRouteDistanceMeters = nil
        locationService.setNavigationActive(true)
        navigationSessionStore.save(
            destination: destination,
            route: navigationRoute,
            matchedDistanceMeters: nil
        )
        telemetry.start(routeID: navigationRoute.id)
        if UserDefaults.standard.object(forKey: "autoRecordDriveTrace") == nil
            || UserDefaults.standard.bool(forKey: "autoRecordDriveTrace") {
            startTraceRecording()
        }
        triggerJourney(.departing, then: .driving, after: 1.8)
        if let location = locationService.location {
            process(
                location: location,
                speed: locationService.speedKmh,
                heading: locationService.heading,
                isDemo: false
            )
        }
    }

    func selectRoute(at index: Int) {
        guard routeAlternatives.indices.contains(index), routePhase == .preview else { return }
        selectedRouteIndex = index
        navigationRoute = routeAlternatives[index]
        roads = [routeAlternatives[index].overlay]
        routeViewportRevision += 1
    }

    func updateRoutePreferences(_ preferences: RoutePreferences) {
        routePreferences = preferences
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: "routePreferences")
        }
    }

    func cancelRoute() {
        if isTraceReplayActive { stopTraceReplay() }
        if isDemoActive { stopDemo() }
        finishTraceRecording()
        routePlanningToken = UUID()
        routeOrigin = nil
        destination = nil
        navigationRoute = nil
        routeAlternatives = []
        selectedRouteIndex = 0
        routePhase = .idle
        mapMatchStatus = "Chưa bắt đầu dẫn đường"
        routeErrorMessage = nil
        isRerouting = false
        didArrive = false
        offRouteSamples = 0
        wrongDirectionSamples = 0
        remainingDistanceMeters = 0
        remainingDurationSeconds = 0
        locationService.setNavigationActive(false)
        navigationSessionStore.clear()
        telemetry.finish(event: "navigation_cancelled")
        roads.removeAll { $0.isPrimaryRoute }
        snapshot.nextManeuver = "Tiếp tục đi thẳng"
        snapshot.maneuverDistanceMeters = 0
        snapshot.laneGuidance = ""
        snapshot.maneuverType = ""
        snapshot.maneuverModifier = ""
        clearMascotCue()
        triggerJourney(.idle)
        matchedRouteDistanceMeters = nil
    }

    func dismissRouteError() {
        routeErrorMessage = nil
    }

    func recenter() {
        followUser = true
        cameraRevision += 1
    }

    func refreshLayerVisibility() {
        snapshot.primaryAlert = preferredPrimaryAlert(from: visibleAlerts)
    }

    func updateMapViewport(
        center: CLLocationCoordinate2D,
        radiusMeters: Double
    ) {
        let radius = min(max(radiusMeters * 1.2, 700), 50_000)
        if let previous = lastViewportCenter {
            let moved = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            let radiusChanged = abs(radius - lastViewportRadius) > max(250, lastViewportRadius * 0.18)
            guard moved > max(120, radius * 0.12) || radiusChanged else { return }
        }
        lastViewportCenter = center
        lastViewportRadius = radius
        let token = UUID()
        viewportQueryToken = token
        alertStore.mapDataPoints(center: center, radiusMeters: radius) { [weak self] points in
            guard let self, self.viewportQueryToken == token else { return }
            self.viewportAlerts = points
        }
    }

    func updateVoiceEnabled(_ enabled: Bool) {
        voiceEnabled = enabled
        voice.isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "voiceEnabled")
    }

    func previewVoice() {
        voice.preview()
    }

    func startTraceRecording() {
        guard isNavigating, !isTraceRecording, !isTraceReplayActive else { return }
        traceStore.start(routeTitle: selectedRouteTitle)
        isTraceRecording = true
    }

    func finishTraceRecording() {
        guard isTraceRecording else { return }
        _ = traceStore.finish()
        isTraceRecording = false
        savedTraces = traceStore.traces()
    }

    func replayTrace(id: UUID) {
        guard let trace = savedTraces.first(where: { $0.id == id }),
              trace.samples.count >= 2,
              navigationRoute != nil else { return }
        if isDemoActive { stopDemo() }
        finishTraceRecording()
        traceReplayTimer?.cancel()
        traceReplay = DriveTraceReplay(trace: trace)
        traceReplayElapsed = 0
        traceReplayProgress = 0
        isTraceReplayActive = true
        mapMatchStatus = "Đang phát lại GPS đã ghi · x4"
        didArrive = false
        routePhase = .navigating
        matchedRouteDistanceMeters = nil
        offRouteSamples = 0
        wrongDirectionSamples = 0
        voice.resetNavigation()
        locationService.setNavigationActive(false)
        locationService.stop()
        followUser = true
        cameraRevision += 1
        triggerJourney(.departing, then: .driving, after: 1.2)
        tickTraceReplay()
        traceReplayTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickTraceReplay() }
    }

    func stopTraceReplay() {
        isTraceReplayActive = false
        traceReplayTimer?.cancel()
        traceReplayTimer = nil
        traceReplay = nil
        traceReplayElapsed = 0
        traceReplayProgress = 0
        didArrive = false
        routePhase = navigationRoute == nil ? .idle : .preview
        mapMatchStatus = "Đã dừng phát lại GPS"
        snapshot.isDemo = false
        snapshot.speedKmh = 0
        roads = navigationRoute.map { [$0.overlay] } ?? []
        locationService.start()
    }

    func deleteTrace(id: UUID) {
        guard !isTraceReplayActive else { return }
        traceStore.delete(id: id)
        savedTraces = traceStore.traces()
    }

    func reportIncorrectAlert(_ alert: DriveAlert, reason: String) {
        _ = mapDataIssueStore.submit(
            alert: alert,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Dữ liệu không chính xác"
                : reason
        )
        mapIssueReportCount = mapDataIssueStore.reports().count
        dataReportStatus = "Đã gửi vào hàng chờ kiểm duyệt"
    }

    func downloadOfflineMapAroundCurrentLocation(night: Bool) {
        offlineMapDownloadService.downloadArea(
            around: locationService.location?.coordinate ?? snapshot.coordinate,
            night: night
        )
    }

    func checkForDataUpdate() {
        guard !isCheckingDataUpdate else { return }
        isCheckingDataUpdate = true
        dataUpdateStatus = "Đang kiểm tra dữ liệu…"
        Task {
            defer { isCheckingDataUpdate = false }
            do {
                dataUpdateStatus = try await mapDataUpdateService.checkForUpdate(
                    currentVersion: datasetVersion
                )
            } catch {
                dataUpdateStatus = error.localizedDescription
            }
        }
    }

    func toggleDemo() {
        isDemoActive ? stopDemo() : startDemo()
    }

    private func startDemo() {
        guard let navigationRoute, let destination else { return }
        voice.resetNavigation()
        let demoRouteService = DemoRouteService(
            route: navigationRoute,
            originName: routeOriginText,
            destinationName: destination.name
        )
        self.demoRouteService = demoRouteService
        if routePhase == .navigating {
            locationService.setNavigationActive(false)
            navigationSessionStore.clear()
            telemetry.finish(event: "navigation_replaced_by_simulation")
        }
        routePhase = .idle
        isDemoActive = true
        mapMatchStatus = "Đang mô phỏng tuyến đã chọn"
        didArrive = false
        locationService.stop()
        followUser = true
        cameraRevision += 1
        demoDistanceMeters = 0
        demoSpeedKmh = 0
        remainingDistanceMeters = demoRouteService.totalDistanceMeters
        remainingDurationSeconds = demoRouteService.durationSeconds
        lastDatabaseQuery = .distantPast
        roads = [demoRouteService.routeOverlay]
        triggerJourney(.departing, then: .driving, after: 1.8)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--arrived-screen") {
            demoDistanceMeters = demoRouteService.totalDistanceMeters
            let position = demoRouteService.position(at: demoDistanceMeters)
            process(
                location: CLLocation(
                    latitude: position.coordinate.latitude,
                    longitude: position.coordinate.longitude
                ),
                speed: 0,
                heading: position.heading,
                isDemo: true,
                demoPosition: position
            )
            didArrive = true
            remainingDistanceMeters = 0
            remainingDurationSeconds = 0
            snapshot.nextManeuver = "Bạn đã đến \(destination.name)"
            snapshot.maneuverDistanceMeters = 0
            clearMascotCue()
            triggerJourney(.arrived)
            voice.announceArrival()
            return
        }
#endif
        tickDemo()
        demoTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickDemo() }
    }

    private func stopDemo() {
        isDemoActive = false
        demoTimer?.cancel()
        demoTimer = nil
        demoDistanceMeters = 0
        demoSpeedKmh = 0
        remainingDistanceMeters = 0
        remainingDurationSeconds = 0
        didArrive = false
        demoRouteService = nil
        routePhase = navigationRoute == nil ? .idle : .preview
        mapMatchStatus = "Đã dừng mô phỏng"
        roads = navigationRoute.map { [$0.overlay] } ?? []
        if let navigationRoute {
            remainingDistanceMeters = navigationRoute.distanceMeters
            remainingDurationSeconds = navigationRoute.durationSeconds
            routeViewportRevision += 1
        }
        snapshot.speedLimitKmh = 0
        snapshot.speedLimitCanTriggerAlerts = false
        snapshot.isDemo = false
        clearMascotCue()
        triggerJourney(.idle)
        locationService.start()
    }

    private func tickDemo() {
        guard let demoRouteService else { return }
        if demoDistanceMeters >= demoRouteService.totalDistanceMeters {
            didArrive = true
            demoSpeedKmh = 0
            remainingDistanceMeters = 0
            remainingDurationSeconds = 0
            demoTimer?.cancel()
            demoTimer = nil
            snapshot.speedKmh = 0
            snapshot.nextManeuver = "Bạn đã đến \(destination?.name ?? "điểm đến")"
            snapshot.maneuverDistanceMeters = 0
            clearMascotCue()
            triggerJourney(.arrived)
            voice.announceArrival()
            return
        }
        let position = demoRouteService.position(at: demoDistanceMeters)
        let targetSpeed = max(20, Double(position.simulatedCruisingSpeedKmh) * 0.90)
        let speedDelta = max(-1.2, min(1.2, targetSpeed - demoSpeedKmh))
        demoSpeedKmh += speedDelta
        demoDistanceMeters += (
            demoSpeedKmh / 3.6
            * 0.1
            * demoRouteService.demoTimeScale
        )
        demoDistanceMeters = min(demoDistanceMeters, demoRouteService.totalDistanceMeters)
        remainingDistanceMeters = max(0, demoRouteService.totalDistanceMeters - demoDistanceMeters)
        remainingDurationSeconds = demoRouteService.totalDistanceMeters > 0
            ? Self.proportionalRemainingDuration(
                totalDuration: demoRouteService.durationSeconds,
                totalDistance: demoRouteService.totalDistanceMeters,
                remainingDistance: remainingDistanceMeters
            ) : 0
        let location = CLLocation(
            latitude: position.coordinate.latitude,
            longitude: position.coordinate.longitude
        )
        process(
            location: location,
            speed: Int(demoSpeedKmh.rounded()),
            heading: position.heading,
            isDemo: true,
            demoPosition: position
        )
        if remainingDistanceMeters <= 180,
           snapshot.journeyEvent == .driving {
            triggerJourney(.braking)
        }
        if remainingDistanceMeters <= 1 {
            tickDemo()
        }
    }

    private func tickTraceReplay() {
        guard let traceReplay else { return }
        if traceReplayElapsed >= traceReplay.trace.durationSeconds {
            stopTraceReplay()
            return
        }
        let sample = traceReplay.sample(at: traceReplayElapsed)
        traceReplayElapsed += 0.4
        traceReplayProgress = traceReplay.trace.durationSeconds > 0
            ? min(1, traceReplayElapsed / traceReplay.trace.durationSeconds)
            : 1
        process(
            location: sample.location,
            speed: Int((sample.speedMetersPerSecond * 3.6).rounded()),
            heading: sample.course,
            isDemo: false,
            isReplay: true
        )
    }

    private func process(
        location: CLLocation,
        speed: Int,
        heading: Double,
        isDemo: Bool,
        demoPosition: DemoRoutePosition? = nil,
        isReplay: Bool = false
    ) {
        snapshot.coordinate = location.coordinate
        snapshot.speedKmh = speed
        snapshot.heading = heading
        snapshot.isDemo = isDemo || isReplay

        if isDemo {
            snapshot.roadName = demoPosition?.roadName.isEmpty == false
                ? demoPosition!.roadName
                : demoRouteService?.routeTitle ?? selectedRouteTitle
            snapshot.province = "Tuyến OSRM · Mô phỏng x8"
            snapshot.nextManeuver = demoPosition?.nextManeuver?.instruction ?? "Tiếp tục đi thẳng"
            snapshot.maneuverDistanceMeters = demoPosition?.maneuverDistanceMeters ?? 0
            snapshot.maneuverType = demoPosition?.nextManeuver?.type ?? ""
            snapshot.maneuverModifier = demoPosition?.nextManeuver?.modifier ?? ""
            voice.updateNavigation(
                step: demoPosition?.nextManeuver,
                distanceMeters: demoPosition?.maneuverDistanceMeters ?? 0
            )
            if let cue = demoPosition?.maneuverCoordinate,
               let maneuver = demoPosition?.nextManeuver {
                setMascotCue(
                    coordinate: cue,
                    distanceMeters: demoPosition?.maneuverDistanceMeters ?? 0,
                    type: maneuver.type,
                    modifier: maneuver.modifier
                )
            } else {
                clearMascotCue()
            }
        } else if routePhase == .navigating,
                  !didArrive,
                  let route = navigationRoute,
                  let progress = RouteProgressEngine.progress(
                    on: route,
                    location: location.coordinate,
                    previousDistanceMeters: matchedRouteDistanceMeters,
                    course: isReplay || (speed >= 9 && locationService.headingSource == "gps_course")
                        ? heading : nil
                  ) {
            updateNavigationProgress(
                progress,
                route: route,
                location: location,
                speedKmh: speed,
                heading: heading
            )
        } else {
            snapshot.roadName = "Đang xác định tuyến đường"
            snapshot.province = String(
                format: "%.4f, %.4f",
                location.coordinate.latitude,
                location.coordinate.longitude
            )
        }


        if routePhase == .navigating, !isDemo, !isReplay, isTraceRecording {
            traceStore.append(location: location, resolvedHeading: heading)
        }

        let queryInterval = isDemo ? 0.5 : 1.0
        if Date().timeIntervalSince(lastDatabaseQuery) >= queryInterval,
           !isDatabaseQueryInFlight {
            lastDatabaseQuery = Date()
            isDatabaseQueryInFlight = true
            let queryLocation = location
            let primaryRoute = isDemo
                ? demoRouteService?.routeOverlay
                : navigationRoute?.overlay
            alertStore.nearbyContext(
                location: location,
                heading: heading,
                speedKmh: speed,
                route: navigationRoute,
                matchedDistanceMeters: isDemo ? demoDistanceMeters : matchedRouteDistanceMeters
            ) { [weak self] context in
                guard let self else { return }
                self.isDatabaseQueryInFlight = false
                let currentLocation = CLLocation(
                    latitude: self.snapshot.coordinate.latitude,
                    longitude: self.snapshot.coordinate.longitude
                )
                // Không cho một truy vấn chậm từ vị trí cũ ghi đè giới hạn
                // của đoạn đường hiện tại. Vị trí mới sẽ truy vấn lại ngay.
                guard currentLocation.distance(from: queryLocation) <= 90 else {
                    self.lastDatabaseQuery = .distantPast
                    Self.speedLogger.debug("discarded stale speed query")
                    return
                }
                self.apply(
                    context,
                    routeOverlay: primaryRoute
                )
            }
        }

        let isOverConfirmedLimit = snapshot.isOverSpeed
            && snapshot.speedLimitCanTriggerAlerts
        voice.updateOverSpeed(isOverConfirmedLimit, limit: snapshot.speedLimitKmh)
        if isOverConfirmedLimit, !wasOverSpeed, hapticsEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        wasOverSpeed = isOverConfirmedLimit
    }

    private func updateNavigationProgress(
        _ progress: NavigationProgress,
        route: NavigationRoute,
        location: CLLocation,
        speedKmh: Int,
        heading: Double
    ) {
        remainingDistanceMeters = progress.remainingDistanceMeters
        matchedRouteDistanceMeters = progress.matchedDistanceMeters
        remainingDurationSeconds = Self.proportionalRemainingDuration(
            totalDuration: route.durationSeconds,
            totalDistance: route.distanceMeters,
            remainingDistance: progress.remainingDistanceMeters
        )
        if progress.remainingDistanceMeters <= 25 {
            remainingDistanceMeters = 0
            remainingDurationSeconds = 0
            didArrive = true
            snapshot.speedKmh = 0
            snapshot.nextManeuver = "Bạn đã đến nơi"
            snapshot.maneuverDistanceMeters = 0
            snapshot.maneuverType = "arrive"
            snapshot.maneuverModifier = ""
            clearMascotCue()
            triggerJourney(.arrived)
            voice.announceArrival(modifier: progress.nextStep?.modifier ?? "")
            snapshot.roadName = destination?.name ?? "Điểm đến"
            snapshot.province = "Hành trình đã hoàn tất"
            locationService.setNavigationActive(false)
            navigationSessionStore.clear()
            telemetry.finish(event: "arrived")
            finishTraceRecording()
            return
        }
        snapshot.roadName = progress.nextStep?.roadName.isEmpty == false
            ? progress.nextStep!.roadName
            : destination?.name ?? "Đang dẫn đường"
        snapshot.province = isRerouting
            ? "Đang tìm tuyến mới…"
            : "OSRM · còn \(Self.distanceText(progress.remainingDistanceMeters))"
        snapshot.nextManeuver = progress.nextStep?.instruction ?? "Tiếp tục đi thẳng"
        snapshot.maneuverDistanceMeters = progress.distanceToNextStepMeters
        snapshot.maneuverType = progress.nextStep?.type ?? ""
        snapshot.maneuverModifier = progress.nextStep?.modifier ?? ""
        snapshot.laneGuidance = progress.nextStep?.lanes
            .map { ($0.isValid ? "●" : "○") + $0.displayText }
            .joined(separator: "  ") ?? ""
        updateMascotCue(progress: progress, route: route)
        if progress.remainingDistanceMeters <= 180,
           snapshot.journeyEvent == .driving {
            triggerJourney(.braking)
        }
        voice.updateNavigation(
            step: progress.nextStep,
            distanceMeters: progress.distanceToNextStepMeters
        )

        let accuracy = max(0, location.horizontalAccuracy)
        let routeCorridor = max(28, min(60, accuracy * 1.5 + 14))
        let isLaterallyOffRoute = progress.distanceFromRouteMeters > routeCorridor
        let isClearlyOffRoute = progress.distanceFromRouteMeters > routeCorridor * 1.8
        let isApproachingTurn = progress.distanceToNextStepMeters < 65
        let isWrongDirection = speedKmh >= 12
            && !isApproachingTurn
            && (progress.headingDifferenceDegrees ?? 0) > 72

        let hasReliableFix = isTraceReplayActive
            || (accuracy <= 42 && abs(location.timestamp.timeIntervalSinceNow) <= 8)
        if !hasReliableFix {
            offRouteSamples = 0
            wrongDirectionSamples = 0
            mapMatchStatus = "GPS yếu · giữ tuyến hiện tại"
        } else if isLaterallyOffRoute {
            offRouteSamples += 1
            mapMatchStatus = "Lệch tuyến \(Int(progress.distanceFromRouteMeters)) m · đang xác minh"
        } else {
            offRouteSamples = 0
            mapMatchStatus = "Đang bám đúng tuyến · sai số \(Int(progress.distanceFromRouteMeters)) m"
        }
        if hasReliableFix, isWrongDirection {
            wrongDirectionSamples += 1
            mapMatchStatus = "Hướng di chuyển ngược tuyến · đang xác minh"
        } else {
            wrongDirectionSamples = 0
        }

        telemetry.sample(
            location: location,
            resolvedHeading: heading,
            headingSource: locationService.headingSource,
            routeID: route.id,
            progress: progress,
            offRouteSamples: max(offRouteSamples, wrongDirectionSamples)
        )
        persistNavigationSession(force: false)

        let shouldReroute = hasReliableFix && ((isClearlyOffRoute && offRouteSamples >= 2)
            || offRouteSamples >= 3
            || wrongDirectionSamples >= 3)
        guard shouldReroute,
              !isRerouting,
              Date().timeIntervalSince(lastRerouteAt) >= 8 else { return }
        reroute(from: location)
    }

    private func reroute(from origin: CLLocation) {
        guard let destination else { return }
        isRerouting = true
        mapMatchStatus = "Đã xác nhận lệch tuyến · đang tính đường mới"
        voice.announceReroute()
        telemetry.event("reroute_started", routeID: navigationRoute?.id)
        lastRerouteAt = Date()
        offRouteSamples = 0
        wrongDirectionSamples = 0
        Task {
            defer { isRerouting = false }
            do {
                let route = try await openMapService.route(
                    from: origin.coordinate,
                    to: destination.coordinate,
                    preferences: routePreferences,
                    originBearing: locationService.headingSource == "gps_course"
                        ? locationService.heading : nil,
                    originAccuracy: origin.horizontalAccuracy
                )
                guard routePhase == .navigating else { return }
                navigationRoute = route
                matchedRouteDistanceMeters = nil
                voice.resetNavigation()
                roads = [route.overlay]
                mapMatchStatus = "Đã chuyển sang tuyến mới"
                persistNavigationSession(force: true)
                telemetry.event("reroute_succeeded", routeID: route.id)
            } catch {
                guard routePhase == .navigating else { return }
                telemetry.event("reroute_failed", routeID: navigationRoute?.id)
                mapMatchStatus = "Chưa đổi được tuyến · tiếp tục theo dõi GPS"
                routeErrorMessage = "Chưa thể đổi tuyến: \(error.localizedDescription)"
            }
        }
    }

    private func restoreNavigationSessionIfNeeded() {
        guard routePhase == .idle,
              let restored = navigationSessionStore.restore() else { return }
        destination = restored.destination
        navigationRoute = restored.route
        routeAlternatives = [restored.route]
        selectedRouteIndex = 0
        routePhase = .navigating
        didArrive = false
        matchedRouteDistanceMeters = restored.matchedDistanceMeters
        remainingDistanceMeters = max(
            0,
            restored.route.distanceMeters - (restored.matchedDistanceMeters ?? 0)
        )
        remainingDurationSeconds = Self.proportionalRemainingDuration(
            totalDuration: restored.route.durationSeconds,
            totalDistance: restored.route.distanceMeters,
            remainingDistance: remainingDistanceMeters
        )
        roads = [restored.route.overlay]
        followUser = true
        offRouteSamples = 0
        wrongDirectionSamples = 0
        locationService.setNavigationActive(true)
        telemetry.start(routeID: restored.route.id, restored: true)
    }

    private func persistNavigationSession(force: Bool) {
        guard routePhase == .navigating,
              let destination,
              let navigationRoute else { return }
        guard force || Date().timeIntervalSince(lastSessionSaveAt) >= 5 else { return }
        lastSessionSaveAt = Date()
        navigationSessionStore.save(
            destination: destination,
            route: navigationRoute,
            matchedDistanceMeters: matchedRouteDistanceMeters
        )
    }

    private func updateMascotCue(
        progress: NavigationProgress,
        route: NavigationRoute
    ) {
        let curve = RouteProgressEngine.upcomingCurve(
            on: route,
            after: progress.matchedDistanceMeters
        )
        let curveDistance = curve.map {
            max(0, Int(($0.distanceAlongRouteMeters - progress.matchedDistanceMeters).rounded()))
        }
        if let curve, let curveDistance,
           curveDistance < max(80, progress.distanceToNextStepMeters - 70) {
            setMascotCue(
                coordinate: curve.coordinate,
                distanceMeters: curveDistance,
                type: "curve",
                modifier: curve.modifier
            )
        } else if let step = progress.nextStep,
                  step.type != "arrive" {
            setMascotCue(
                coordinate: step.coordinate,
                distanceMeters: progress.distanceToNextStepMeters,
                type: step.type,
                modifier: step.modifier
            )
        } else {
            clearMascotCue()
        }
    }

    private func setMascotCue(
        coordinate: CLLocationCoordinate2D,
        distanceMeters: Int,
        type: String,
        modifier: String
    ) {
        snapshot.mascotCueLatitude = coordinate.latitude
        snapshot.mascotCueLongitude = coordinate.longitude
        snapshot.mascotCueDistanceMeters = distanceMeters
        snapshot.mascotCueType = type
        snapshot.mascotCueModifier = modifier
    }

    private func clearMascotCue() {
        snapshot.mascotCueLatitude = nil
        snapshot.mascotCueLongitude = nil
        snapshot.mascotCueDistanceMeters = 0
        snapshot.mascotCueType = ""
        snapshot.mascotCueModifier = ""
    }

    private func triggerJourney(
        _ event: MascotJourneyEvent,
        then nextEvent: MascotJourneyEvent? = nil,
        after delay: Double = 0
    ) {
        journeyTask?.cancel()
        snapshot.journeyEvent = event
        snapshot.journeyEventRevision += 1
        guard let nextEvent, delay > 0 else { return }
        journeyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.snapshot.journeyEvent = nextEvent
            self.snapshot.journeyEventRevision += 1
        }
    }

    private func apply(
        _ context: OfflineMapContext,
        routeOverlay: RoadOverlay? = nil
    ) {
        let cameras = context.alerts.filter { $0.kind == .camera }.prefix(160)
        let speedObservations = context.alerts.filter { $0.kind == .speedLimit }.prefix(80)
        let signs = context.alerts.filter { $0.kind == .roadSign }.prefix(80)
        let restrictions = context.alerts.filter {
            $0.kind == .turnRestriction || $0.kind == .parkingRestriction
        }.prefix(24)
        alerts = Array(cameras) + Array(speedObservations) + Array(signs) + Array(restrictions)
        // Add the primary route last so MapLibre paints it above nearby
        // validation overlays instead of hiding the navigation line.
        roads = context.roads + (routeOverlay.map { [$0] } ?? [])
        snapshot.primaryAlert = preferredPrimaryAlert(from: visibleAlerts)
        snapshot.speedLimitKmh = context.matchedSpeedLimit
        snapshot.speedLimitCanTriggerAlerts = context.speedLimitMatch?.canTriggerDrivingAlerts ?? false
        if let match = context.speedLimitMatch {
            if !match.roadName.isEmpty && (routePhase != .navigating || snapshot.roadName == "Đang xác định tuyến đường") {
                snapshot.roadName = match.roadName
            }
            speedLimitDiagnosticText = "\(match.limit) km/h · \(match.diagnosticText)"
            Self.speedLogger.info(
                "display limit=\(match.limit, privacy: .public) source=\(match.source, privacy: .public) road=\(match.roadName, privacy: .public)"
            )
        } else {
            speedLimitDiagnosticText = "Chưa có điểm tốc độ map-data phù hợp gần vị trí hiện tại"
            Self.speedLogger.info("display limit=unknown")
        }
        if let nearest = snapshot.primaryAlert {
            voice.announce(alert: nearest)
            if nearest.distanceMeters <= 450,
               lastHapticAlertID != nearest.id,
               hapticsEnabled {
                lastHapticAlertID = nearest.id
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private var hapticsEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "hapticsEnabled") == nil
            ? true
            : defaults.bool(forKey: "hapticsEnabled")
    }

    private func preferredPrimaryAlert(from candidates: [DriveAlert]) -> DriveAlert? {
        let nearby = candidates.filter {
            $0.distanceMeters <= 1_500
                && !Self.isTurnRestrictionAlert($0)
                && !$0.isReferenceSpeedObservation
        }
        if let imminent = nearby
            .filter({ $0.distanceMeters <= 250 })
            .min(by: { $0.distanceMeters < $1.distanceMeters }) {
            return imminent
        }

        // Camera points are much denser than physical signs. Prioritise a
        // safety rule so prohibition/speed-limit banners are not starved.
        let safetyKinds: Set<AlertKind> = [
            .roadSign, .speedLimit, .parkingRestriction
        ]
        return nearby
            .filter { safetyKinds.contains($0.kind) }
            .min { $0.distanceMeters < $1.distanceMeters }
            ?? nearby.min { $0.distanceMeters < $1.distanceMeters }
    }

    nonisolated private static func isTurnRestrictionAlert(_ alert: DriveAlert) -> Bool {
        if alert.kind == .turnRestriction { return true }
        let code = (alert.signCode ?? "").lowercased()
        return code.hasPrefix("p103")
            || code.hasPrefix("p123")
            || code.contains("left_turn")
            || code.contains("right_turn")
            || code.contains("u_turn")
            || code.contains("straight_on")
    }

    private func isTurnRestrictionOnActiveRoute(_ alert: DriveAlert) -> Bool {
        guard let route = navigationRoute,
              let projection = RouteProgressEngine.projection(
                on: route,
                coordinate: alert.coordinate
              ),
              let currentDistance = isDemoActive
                ? demoDistanceMeters
                : matchedRouteDistanceMeters
                    ?? RouteProgressEngine.projection(
                        on: route,
                        coordinate: snapshot.coordinate
                    )?.distanceAlongRouteMeters
        else { return false }
        let ahead = projection.distanceAlongRouteMeters - currentDistance
        return projection.lateralDistanceMeters <= 65
            && ahead >= -30
            && ahead <= 3_500
    }

    nonisolated static func proportionalRemainingDuration(
        totalDuration: Double,
        totalDistance: Double,
        remainingDistance: Double
    ) -> Double {
        guard totalDuration > 0, totalDistance > 0 else { return 0 }
        let fraction = min(1, max(0, remainingDistance / totalDistance))
        return totalDuration * fraction
    }

    nonisolated private static func loadRoutePreferences() -> RoutePreferences {
        guard let data = UserDefaults.standard.data(forKey: "routePreferences"),
              let preferences = try? JSONDecoder().decode(RoutePreferences.self, from: data)
        else { return RoutePreferences() }
        return preferences
    }

    private static func distanceText(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.1f km", meters / 1_000)
        }
        return "\(max(0, Int(meters.rounded()))) m"
    }
}
