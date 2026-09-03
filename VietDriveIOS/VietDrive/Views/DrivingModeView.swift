import SwiftUI

/// Presents the existing driving state without creating a map or a separate alert engine.
struct DrivingModeView: View {
    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("showMascotOnMap") private var showMascot = true
    @StateObject private var sceneStore = DrivingSceneStore()

    let onSearch: () -> Void
    let onSettings: () -> Void
    let onDemo: () -> Void

    var body: some View {
        DrivingCockpit(
            snapshot: model.snapshot,
            preparedScene: sceneStore.scene,
            alerts: upcomingAlerts,
            gpsQuality: model.locationFixQuality,
            accuracyMeters: model.isSimulatedLocationActive ? nil : model.locationService.horizontalAccuracy,
            isGuiding: model.isGuidanceActive,
            isReplay: model.isTraceReplayActive,
            voiceEnabled: model.voiceEnabled,
            showsMascot: showMascot,
            animateRoad: scenePhase == .active && !systemReduceMotion,
            onSearch: onSearch,
            onSettings: onSettings,
            onDemo: onDemo,
            onToggleVoice: { model.updateVoiceEnabled(!model.voiceEnabled) }
        )
        .preferredColorScheme(.light)
        .task(id: sceneRequest) {
            guard scenePhase == .active, model.locationFixQuality != .unavailable else { return }
            await sceneStore.refresh(near: model.snapshot.coordinate, heading: model.snapshot.heading)
        }
    }

    private var sceneRequest: String {
        // Reproject every fix/heading, while the store independently caches the SQLite window.
        let coordinate = model.snapshot.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return "invalid" }
        return "\(coordinate.latitude)/\(coordinate.longitude)/\(model.snapshot.heading)/\(scenePhase == .active)/\(model.locationFixQuality)"
    }

    private var upcomingAlerts: [DriveAlert] {
        model.visibleAlerts
            .filter { $0.distanceMeters.isFinite && $0.distanceMeters >= 0 && $0.distanceMeters <= 2_500 }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }
}

/// Independent of location services so layouts and GPS states can be previewed.
private struct DrivingCockpit: View {
    @State private var passage = DrivingSignPassage()
    let snapshot: DriveSnapshot
    let preparedScene: DrivingScene
    let alerts: [DriveAlert]
    let gpsQuality: LocationFixQuality
    let accuracyMeters: Double?
    let isGuiding: Bool
    let isReplay: Bool
    let voiceEnabled: Bool
    let showsMascot: Bool
    let animateRoad: Bool
    let onSearch: () -> Void
    let onSettings: () -> Void
    let onDemo: () -> Void
    let onToggleVoice: () -> Void

    private var hasGPS: Bool { gpsQuality != .unavailable }
    private var isMoving: Bool { hasGPS && snapshot.speedKmh > 2 }
    private var isOverSpeed: Bool { hasGPS && snapshot.isOverSpeed }
    private var roadsideAlerts: [DriveAlert] {
        hasGPS ? passage.upcoming(from: alerts) : []
    }
    private var passageSample: DrivingSignPassage.Sample {
        .init(alerts: alerts, latitude: snapshot.coordinate.latitude, longitude: snapshot.coordinate.longitude,
              heading: snapshot.heading, speed: snapshot.speedKmh, hasGPS: hasGPS, accuracy: accuracyMeters)
    }
    private var statusTint: Color {
        if !hasGPS || gpsQuality == .weak { return DriveTheme.amber }
        return isOverSpeed ? DriveTheme.danger : DriveTheme.skyDeep
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.91, green: 0.97, blue: 1),
                             Color(red: 0.76, green: 0.91, blue: 0.99),
                             Color(red: 0.65, green: 0.84, blue: 0.97)],
                    startPoint: .top, endPoint: .bottom
                )
                    .ignoresSafeArea()
                VStack(spacing: landscape ? 4 : 8) {
                    header
                    if landscape {
                        landscapeCockpit
                    } else {
                        portraitCockpit
                    }
                    controls
                }
                .padding(.horizontal, landscape ? 20 : 18)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
        .foregroundStyle(DriveTheme.ink)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chế độ lái xe")
        .onChange(of: passageSample, initial: true) { _, sample in
            passage.update(sample)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(DriveTheme.skyDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text("VietDrive")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DriveTheme.skyDeep)
                Text("CHẾ ĐỘ LÁI XE")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(DriveTheme.textMuted)
            }
            Spacer(minLength: 4)
            Button(action: onDemo) {
                Image(systemName: "play.circle")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DriveTheme.skyDeep)
            .accessibilityLabel("Chạy thử tuyến DEMO")
            HStack(spacing: 5) {
                Circle().fill(statusTint).frame(width: 6, height: 6)
                Text(snapshot.isDemo ? (isReplay ? "PHÁT LẠI" : "DEMO") : (!hasGPS ? "CHỜ GPS" : "GPS"))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(statusTint)
            .accessibilityLabel(snapshot.isDemo ? "GPS mô phỏng" : gpsQuality.title)
        }
        .frame(minHeight: 42)
    }

    private var portraitCockpit: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 570
            VStack(spacing: compact ? 4 : 8) {
                speedReadout(compact: compact)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, compact ? 6 : 18)
                driveContext
                vehicleScene(maximumCarWidth: min(geometry.size.width * 0.52, 194), compact: compact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, -18)
                motionStatus
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var landscapeCockpit: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 10) {
                    speedReadout(compact: true)
                    driveContext
                }
                .frame(width: min(210, geometry.size.width * 0.32))
                VStack(spacing: 0) {
                    vehicleScene(maximumCarWidth: 180, compact: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    motionStatus
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var driveContext: some View {
        VStack(spacing: 5) {
            Text(hasGPS ? snapshot.roadName : "Đang xác định vị trí")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DriveTheme.ink.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if isGuiding {
                Text("\(snapshot.nextManeuver) · \(drivingDistance(Double(snapshot.maneuverDistanceMeters)))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DriveTheme.skyDeep)
                    .lineLimit(2)
            }
            if let section = snapshot.activeSectionSpeed {
                Text("Tốc độ TB đoạn: \(section.averageSpeedKmh) km/h")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DriveTheme.skyDeep)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 28) {
            DrivingControlButton(icon: "magnifyingglass", title: "Tìm địa điểm", tint: DriveTheme.skyDeep, action: onSearch)
            DrivingControlButton(
                icon: voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                title: voiceEnabled ? "Tắt cảnh báo giọng nói" : "Bật cảnh báo giọng nói",
                tint: voiceEnabled ? DriveTheme.skyDeep : DriveTheme.textMuted,
                action: onToggleVoice
            )
            .accessibilityValue(voiceEnabled ? "Đang bật" : "Đang tắt")
            DrivingControlButton(icon: "slider.horizontal.3", title: "Cài đặt", tint: DriveTheme.skyDeep, action: onSettings)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func vehicleScene(maximumCarWidth: CGFloat, compact: Bool) -> some View {
        GeometryReader { geometry in
            let scene = hasGPS && (accuracyMeters ?? 20) <= 65 ? preparedScene : .empty
            let carFrame = DrivingRibbon.egoFrame(size: geometry.size, maximumWidth: maximumCarWidth)
            let carWidth = carFrame.width
            let carY = carFrame.midY
            let placements = DrivingRoadsideLayout.placements(alerts: roadsideAlerts, size: geometry.size)
            let tolls = roadsideAlerts.filter { $0.kind == .toll }.map {
                DrivingSceneEvent(id: "toll-\($0.id)", kind: .toll, distanceMeters: $0.distanceMeters)
            }
            ZStack {
                DrivingSceneSurface(scene: scene, speed: snapshot.speedKmh,
                                    isAnimating: animateRoad && isMoving,
                                    hasNearbyAlert: roadsideAlerts.first.map { $0.distanceMeters < 150 } ?? false,
                                    supplementalEvents: tolls,
                                    reservedSignRects: placements.map { CGRect(x: $0.x - $0.width / 2, y: $0.top,
                                                                             width: $0.width, height: $0.readableHeight) })
                ForEach(placements) { placement in
                    DrivingRoadsideSign(placement: placement)
                        .frame(width: placement.width, height: placement.height)
                        .position(x: placement.x, y: placement.top + placement.height / 2)
                        .zIndex(placement.depth < 0.7 ? 1 : 3)
                        .transition(animateRoad && isMoving && placement.alert.distanceMeters < 90
                            ? .offset(y: geometry.size.height).combined(with: .opacity) : .opacity)
                }
                DrivingVehicleSprite(speed: snapshot.speedKmh, curve: 0,
                                     isAnimating: animateRoad && isMoving)
                    .frame(width: carWidth, height: carWidth)
                    .position(x: carFrame.midX, y: carY)
                    .zIndex(2)
                if showsMascot {
                    let mascotSize: CGFloat = compact ? 56 : 68
                    MascotMayView(mood: companionMood, size: mascotSize, isAnimationEnabled: animateRoad)
                        .position(
                            x: max(mascotSize / 2 + 4, geometry.size.width * 0.12),
                            y: min(geometry.size.height - mascotSize / 2, carY + carWidth * 0.35)
                        )
                        .zIndex(4)
                        .allowsHitTesting(false)
                }
            }
            .animation(animateRoad && isMoving ? .linear(duration: 0.22) : nil, value: placements)
            .clipped()
        }
    }

    private var companionMood: MascotMood {
        if !hasGPS { return .searching }
        if isOverSpeed { return .speedWarning }
        if let nearest = roadsideAlerts.first, nearest.distanceMeters <= 300 { return .warning }
        return isMoving ? .cruising : .neutral
    }

    private func speedReadout(compact: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: compact ? 14 : 20) {
                VStack(spacing: -3) {
                    Text(hasGPS ? "\(snapshot.speedKmh)" : "—")
                        .font(.system(size: compact ? 72 : 94, weight: .semibold))
                        .tracking(-4)
                        .monospacedDigit()
                        .foregroundStyle(isOverSpeed ? DriveTheme.danger : DriveTheme.ink)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text("km/h")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DriveTheme.ink.opacity(0.8))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hasGPS ? "Tốc độ \(snapshot.speedKmh) kilomet mỗi giờ" : "Chưa có tốc độ GPS")
                VStack(spacing: 5) {
                    DrivingLimitBadge(limit: snapshot.speedLimitKmh)
                        .frame(width: compact ? 48 : 56, height: compact ? 48 : 56)
                    Text("GIỚI HẠN")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DriveTheme.textMuted)
                }
            }
            if let nextLimit = snapshot.nextSpeedLimitKmh,
               let distance = snapshot.nextSpeedDistanceMeters,
               nextLimit > 0, nextLimit != snapshot.speedLimitKmh {
                Text("Sắp tới \(nextLimit) km/h · \(drivingDistance(Double(distance)))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DriveTheme.skyDeep)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var motionStatus: some View {
        Group {
            if !hasGPS {
                Label("Đang tìm tín hiệu GPS", systemImage: "location.magnifyingglass")
            } else if isOverSpeed {
                Label("Giảm tốc độ để lái xe an toàn", systemImage: "exclamationmark.circle.fill")
            } else if gpsQuality == .weak {
                Label("Tín hiệu GPS yếu", systemImage: "location.circle")
            } else {
                Color.clear.frame(height: 1)
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(statusTint)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 22)
    }

}
private func drivingDistance(_ meters: Double) -> String {
    let distance = max(0, Int(meters.rounded()))
    return distance >= 1_000 ? String(format: "%.1f km", Double(distance) / 1_000) : "\(distance) m"
}

private struct DrivingControlButton: View {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(.white.opacity(0.22), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct DrivingLimitBadge: View {
    let limit: Int

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().strokeBorder(limit > 0 ? DriveTheme.danger : DriveTheme.sky.opacity(0.40), lineWidth: 4)
            Text(limit > 0 ? "\(limit)" : "—")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(6)
                .foregroundStyle(DriveTheme.ink)
        }
        .accessibilityLabel(limit > 0 ? "Giới hạn \(limit) kilomet mỗi giờ" : "Chưa có giới hạn tốc độ")
    }
}

private struct DrivingSignSymbol: View {
    let alert: DriveAlert

    private var assetName: String? {
        alert.assetName.flatMap { $0.isEmpty ? nil : $0 }
            ?? TrafficSignCatalog.assetName(
                for: alert.signCode,
                speedLimit: alert.kind == .speedLimit ? alert.speedLimit : 0
            )
    }

    var body: some View {
        if let name = assetName {
            Image(name).resizable().scaledToFit()
        } else if alert.kind == .speedLimit, alert.speedLimit > 0 {
            DrivingLimitBadge(limit: alert.speedLimit)
        } else {
            Image(systemName: alert.kind.iconName)
                .resizable()
                .scaledToFit()
                .padding(7)
                .foregroundStyle(DriveTheme.alertColor(alert.kind))
        }
    }
}

/// View-only passage memory. Never changes the alert engine, limits or voice eligibility.
struct DrivingSignPassage {
    struct Sample: Equatable {
        var alerts: [DriveAlert]
        var latitude: Double
        var longitude: Double
        var heading: Double
        var speed: Int
        var hasGPS: Bool
        var accuracy: Double?
    }

    private(set) var passedIDs: Set<Int> = []

    mutating func update(_ sample: Sample) {
        passedIDs.formIntersection(Set(sample.alerts.map(\.id)))
        let accuracy = sample.accuracy ?? 20
        guard sample.hasGPS, sample.speed >= 5,
              accuracy.isFinite, accuracy >= 0, accuracy <= 65,
              sample.latitude.isFinite, abs(sample.latitude) <= 90,
              sample.longitude.isFinite, abs(sample.longitude) <= 180,
              sample.heading.isFinite, (0...360).contains(sample.heading) else { return }
        let angle = sample.heading * .pi / 180
        let tolerance = max(12, min(accuracy, 35))
        for alert in sample.alerts {
            guard alert.distanceMeters.isFinite, alert.distanceMeters <= 100,
                  alert.latitude.isFinite, abs(alert.latitude) <= 90,
                  alert.longitude.isFinite, abs(alert.longitude) <= 180 else { continue }
            // Local projection is only used within 130 m, to distinguish behind from ahead.
            let north = (alert.latitude - sample.latitude) * 111_195
            let east = (alert.longitude - sample.longitude) * 111_195 * cos(sample.latitude * .pi / 180)
            guard hypot(north, east) <= 130 else { continue }
            let forward = north * cos(angle) + east * sin(angle)
            if forward < -tolerance {
                passedIDs.insert(alert.id)
            } else if forward > max(35, tolerance * 2) {
                // The same valid incoming sign may be approached again after a U-turn.
                passedIDs.remove(alert.id)
            }
        }
    }

    func upcoming(from alerts: [DriveAlert]) -> [DriveAlert] {
        var seen: Set<Int> = []
        return alerts.filter {
            $0.distanceMeters.isFinite && (0...2_500).contains($0.distanceMeters)
                && !passedIDs.contains($0.id) && seen.insert($0.id).inserted
        }
        .sorted { $0.distanceMeters == $1.distanceMeters ? $0.id < $1.id : $0.distanceMeters < $1.distanceMeters }
        .prefix(3).map { $0 }
    }
}

/// All eligible traffic signs stay on the right shoulder. No side-balancing or sign duplication.
enum DrivingRoadsideLayout {
    struct Placement: Identifiable, Equatable {
        let alert: DriveAlert
        let depth: Double
        let faceSize: CGFloat
        let height: CGFloat
        var top: CGFloat
        var x: CGFloat
        var id: Int { alert.id }
        var width: CGFloat { max(44, faceSize) }
        var readableHeight: CGFloat { faceSize + 18 }
    }

    static func depth(distance: Double) -> Double {
        guard distance.isFinite else { return 0 }
        return DrivingRibbon.depth(distance)
    }

    static func roadPoint(depth: Double, side: Double, size: CGSize) -> CGPoint {
        DrivingRibbon.point(depth: depth, side: side, size: size)
    }

    static func placements(alerts: [DriveAlert], size: CGSize) -> [Placement] {
        guard size.width.isFinite, size.height.isFinite, size.width >= 100, size.height >= 80 else { return [] }
        let count = min(3, max(1, Int(size.height / 58)))
        let ordered = Array(DrivingSignPassage().upcoming(from: alerts).prefix(count).reversed())
        guard !ordered.isEmpty else { return [] }
        let n = CGFloat(ordered.count)
        // Reserve readable faces/labels and the final pole on the one allowed shoulder.
        let cap = max(16, min(62, size.width * 0.17,
            (size.height * 0.96 - 8 - 24 * n) / n,
            (size.height * 0.96 - 8 - 24 * (n - 1)) / (n + 0.9)))
        var posts: [Placement] = []
        for alert in ordered {
            let depth = depth(distance: alert.distanceMeters)
            let face = max(16, cap * (0.5 + 0.5 * depth))
            let height = face + max(24, face * 0.9)
            var top = max(4, roadPoint(depth: depth, side: 1, size: size).y - height)
            if let previous = posts.last {
                top = max(top, previous.top + previous.readableHeight + 6)
            }
            posts.append(.init(alert: alert, depth: depth, faceSize: face, height: height, top: top, x: 0))
        }
        for index in posts.indices.reversed() {
            // Follow the right edge upward when space is tight, never move a sign to the left.
            let maxDepth = min(1, (0.5 - (posts[index].width / 2 + 3) / size.width - 0.035) / 0.365)
            let bottom = roadPoint(depth: maxDepth, side: 1, size: size).y
            var topLimit = min(size.height - 4, bottom) - posts[index].height
            if index + 1 < posts.count {
                topLimit = min(topLimit, posts[index + 1].top - posts[index].readableHeight - 6)
            }
            posts[index].top = min(posts[index].top, topLimit)
        }
        for index in posts.indices {
            let base = posts[index].top + posts[index].height
            let visualDepth = (base / size.height - 0.04) / 0.92
            posts[index].x = roadPoint(depth: visualDepth, side: 1, size: size).x
        }
        return posts
    }
}

private struct DrivingRoadsideSign: View {
    let placement: DrivingRoadsideLayout.Placement

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [.white.opacity(0.85), DriveTheme.skyDeep.opacity(0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 2, height: placement.height - placement.faceSize / 2)
                .offset(y: placement.faceSize / 2)
            VStack(spacing: 2) {
                DrivingSignSymbol(alert: placement.alert)
                    .frame(width: placement.faceSize, height: placement.faceSize)
                    .shadow(color: DriveTheme.ink.opacity(0.12), radius: 2, y: 1)
                Text(drivingDistance(placement.alert.distanceMeters))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(.white.opacity(0.60), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(placement.alert.message), sau \(drivingDistance(placement.alert.distanceMeters))")
        .accessibilitySortPriority(-placement.alert.distanceMeters)
        .allowsHitTesting(false)
    }
}

#if DEBUG
private struct DrivingCockpitPreview: View {
    var speed = 64
    var hasGPS = true
    var populated = true
    var animateRoad = false
    var showsMascot = true
    var travelledMeters = 0.0

    var body: some View {
        var snapshot = DriveSnapshot()
        snapshot.speedKmh = speed
        snapshot.speedLimitKmh = hasGPS ? 60 : 0
        snapshot.roadName = "Đại lộ Võ Nguyên Giáp"
        snapshot.province = "TP. Hồ Chí Minh"
        snapshot.heading = 0
        snapshot.coordinate.latitude += travelledMeters / 111_195
        snapshot.nextSpeedLimitKmh = populated ? 50 : nil
        snapshot.nextSpeedDistanceMeters = populated ? max(0, Int((800 - travelledMeters).rounded())) : nil
        let alerts: [DriveAlert] = populated ? [
            DriveAlert(id: 1, kind: .camera, speedLimit: 60, latitude: 10.7769 + 250.0 / 111_195, longitude: 106.7009, message: "Camera tốc độ", province: "", distanceMeters: abs(250 - travelledMeters), assetName: TrafficSignCatalog.assetName(for: "CAMERA_SPEED")),
            DriveAlert(id: 2, kind: .parkingRestriction, speedLimit: 0, latitude: 10.7769 + 450.0 / 111_195, longitude: 106.7009, message: "Cấm dừng và đỗ xe", province: "", distanceMeters: abs(450 - travelledMeters), assetName: TrafficSignCatalog.assetName(for: "P130")),
            DriveAlert(id: 3, kind: .speedLimit, speedLimit: 50, latitude: 10.7769 + 800.0 / 111_195, longitude: 106.7009, message: "Giới hạn 50 km/h", province: "", distanceMeters: abs(800 - travelledMeters), assetName: TrafficSignCatalog.assetName(for: TrafficSignCatalog.speedCode(50)))
        ] : []
        return DrivingCockpit(
            snapshot: snapshot, preparedScene: .empty, alerts: alerts, gpsQuality: hasGPS ? .excellent : .unavailable,
            accuracyMeters: hasGPS ? 5 : nil, isGuiding: false, isReplay: false, voiceEnabled: true,
            showsMascot: showsMascot, animateRoad: animateRoad, onSearch: {}, onSettings: {}, onDemo: {}, onToggleVoice: {}
        )
    }
}

#Preview("Dọc · cảnh báo realtime") { DrivingCockpitPreview() }
#Preview("Dọc · chuyển động") { DrivingCockpitPreview(speed: 52, animateRoad: true) }
#Preview("Biển gần xe") { DrivingCockpitPreview(travelledMeters: 230) }
#Preview("Đã đi qua biển đầu") { DrivingCockpitPreview(travelledMeters: 280) }
#Preview("Dọc · đang dừng") { DrivingCockpitPreview(speed: 0, populated: false) }
#Preview("Dọc · chờ GPS") { DrivingCockpitPreview(speed: 0, hasGPS: false, populated: false) }
#endif
