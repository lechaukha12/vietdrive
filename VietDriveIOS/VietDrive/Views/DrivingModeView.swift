import SwiftUI

/// Presents the existing driving state without creating a map or a separate alert engine.
struct DrivingModeView: View {
    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("showMascotOnMap") private var showMascot = true

    let onSearch: () -> Void
    let onSettings: () -> Void

    var body: some View {
        DrivingCockpit(
            snapshot: model.snapshot,
            alerts: upcomingAlerts,
            gpsQuality: model.locationFixQuality,
            accuracyMeters: model.isTraceReplayActive ? nil : model.locationService.horizontalAccuracy,
            isGuiding: model.isGuidanceActive,
            isReplay: model.isTraceReplayActive,
            voiceEnabled: model.voiceEnabled,
            showsMascot: showMascot,
            animateRoad: scenePhase == .active && !systemReduceMotion,
            onSearch: onSearch,
            onSettings: onSettings,
            onToggleVoice: { model.updateVoiceEnabled(!model.voiceEnabled) }
        )
        .preferredColorScheme(.light)
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
        if !hasGPS { return DriveTheme.amber }
        return isOverSpeed ? DriveTheme.danger : DriveTheme.skyDeep
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                LinearGradient(
                    colors: [DriveTheme.skySoft.opacity(0.6), .white, Color(red: 0.85, green: 0.91, blue: 0.96)],
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
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(DriveTheme.skyDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text("CHẾ ĐỘ LÁI XE")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                Text("VietDrive · Mazda CX-5")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DriveTheme.textMuted)
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Circle().fill(statusTint).frame(width: 6, height: 6)
                Text(isReplay ? "PHÁT LẠI" : (!hasGPS ? "CHỜ GPS" : (isMoving ? "ĐANG CHẠY" : "SẴN SÀNG")))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(statusTint)
        }
        .frame(minHeight: 42)
    }

    private var portraitCockpit: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 570
            let sideWidth = max(74, min(138, geometry.size.width * 0.235))
            VStack(spacing: compact ? 4 : 8) {
                HStack(alignment: .top, spacing: 8) {
                    journeyContext(compact: compact)
                        .frame(width: sideWidth, alignment: .leading)
                    speedReadout(compact: compact)
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)
                    gpsContext(compact: compact)
                        .frame(width: sideWidth, alignment: .trailing)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, compact ? 6 : 18)
                vehicleScene(maximumCarWidth: min(geometry.size.width * 0.52, 194), compact: compact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                motionStatus
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var landscapeCockpit: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    journeyContext(compact: true)
                    Label(gpsQuality.title, systemImage: gpsQuality.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(gpsTint)
                    if let section = snapshot.activeSectionSpeed {
                        Text("TB đoạn: \(section.averageSpeedKmh) km/h")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: min(142, geometry.size.width * 0.20))
                speedReadout(compact: true)
                    .frame(width: 110)
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

    private func journeyContext(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isGuiding ? "DẪN ĐƯỜNG" : "LÁI TỰ DO")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(DriveTheme.skyDeep)
                Text(hasGPS ? snapshot.roadName : "Đang xác định vị trí")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(compact ? 3 : 4)
                if hasGPS && !compact {
                    Text(snapshot.province)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DriveTheme.textMuted)
                        .lineLimit(2)
                }
            }
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: hasGPS ? "location.north.fill" : "location.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(hasGPS ? snapshot.heading : 0))
                    .foregroundStyle(DriveTheme.skyDeep)
                Text(hasGPS ? compassDirection : "Chờ GPS")
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isGuiding {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.nextManeuver)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(2)
                    if snapshot.maneuverDistanceMeters > 0 {
                        Text(drivingDistance(Double(snapshot.maneuverDistanceMeters)))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(DriveTheme.skyDeep)
                    }
                }
            }
        }
        .multilineTextAlignment(.leading)
    }

    private func gpsContext(compact: Bool) -> some View {
        VStack(alignment: .trailing, spacing: compact ? 9 : 14) {
            Text("TÍN HIỆU GPS")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(DriveTheme.skyDeep)
            Image(systemName: gpsQuality.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(gpsTint)
            Text(gpsQuality.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(gpsTint)
            if hasGPS, let accuracyMeters, accuracyMeters.isFinite, accuracyMeters > 0, !compact {
                Text("Sai số ±\(Int(accuracyMeters.rounded())) m")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DriveTheme.textMuted)
            }
            if let section = snapshot.activeSectionSpeed {
                Text("TB đoạn: \(section.averageSpeedKmh) km/h")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
        }
        .multilineTextAlignment(.trailing)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: onSearch) {
                Label("Tìm địa điểm", systemImage: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DriveTheme.skyDeep)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 46)
                    .background(.white.opacity(0.78), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            DrivingControlButton(
                icon: voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                title: voiceEnabled ? "Tắt cảnh báo giọng nói" : "Bật cảnh báo giọng nói",
                tint: voiceEnabled ? DriveTheme.skyDeep : DriveTheme.textMuted,
                action: onToggleVoice
            )
            .accessibilityValue(voiceEnabled ? "Đang bật" : "Đang tắt")
            DrivingControlButton(icon: "slider.horizontal.3", title: "Cài đặt", tint: DriveTheme.ink, action: onSettings)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func vehicleScene(maximumCarWidth: CGFloat, compact: Bool) -> some View {
        GeometryReader { geometry in
            let carWidth = min(maximumCarWidth, geometry.size.height * 0.64, geometry.size.width * 0.52)
            let carY = geometry.size.height * 0.92 - carWidth / 2
            let placements = DrivingRoadsideLayout.placements(alerts: roadsideAlerts, size: geometry.size)
            ZStack {
                DrivingRoadSurface(speed: snapshot.speedKmh, isAnimating: animateRoad && isMoving)
                ForEach(placements) { placement in
                    DrivingRoadsideSign(placement: placement)
                        .frame(width: placement.width, height: placement.height)
                        .position(x: placement.x, y: placement.top + placement.height / 2)
                        .zIndex(placement.depth < 0.7 ? 1 : 3)
                        .transition(animateRoad && isMoving && placement.alert.distanceMeters < 90
                            ? .offset(y: geometry.size.height).combined(with: .opacity) : .opacity)
                }
                DrivingMazdaCar(isAnimating: animateRoad && isMoving)
                    .frame(width: carWidth, height: carWidth)
                    .position(x: geometry.size.width / 2, y: carY)
                    .zIndex(2)
                if showsMascot {
                    let mascotSize: CGFloat = compact ? 56 : 68
                    MascotMayView(mood: companionMood, size: mascotSize, isAnimationEnabled: animateRoad)
                        .position(
                            x: max(mascotSize / 2, geometry.size.width / 2 - carWidth / 2 - mascotSize * 0.25),
                            y: min(geometry.size.height - mascotSize / 2, carY + carWidth * 0.35)
                        )
                        .zIndex(4)
                        .allowsHitTesting(false)
                }
            }
            .animation(animateRoad && isMoving ? .linear(duration: 0.65) : nil, value: placements)
            .clipped()
            .overlay(alignment: .topLeading) {
                if roadsideAlerts.isEmpty {
                    Text(hasGPS ? "Chưa có cảnh báo phía trước" : "Chờ GPS để cập nhật biển báo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DriveTheme.textMuted)
                        .padding(.top, 10)
                }
            }
        }
    }

    private var companionMood: MascotMood {
        if !hasGPS { return .searching }
        if isOverSpeed { return .speedWarning }
        if let nearest = roadsideAlerts.first, nearest.distanceMeters <= 300 { return .warning }
        return isMoving ? .cruising : .neutral
    }

    private func speedReadout(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 10) {
            VStack(spacing: -2) {
                Text(hasGPS ? "\(snapshot.speedKmh)" : "—")
                    .font(.system(size: compact ? 56 : 76, weight: .bold, design: .rounded))
                    .tracking(-3)
                    .monospacedDigit()
                    .foregroundStyle(isOverSpeed ? DriveTheme.danger : DriveTheme.ink)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("km/h")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DriveTheme.textMuted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hasGPS ? "Tốc độ \(snapshot.speedKmh) kilomet mỗi giờ" : "Chưa có tốc độ GPS")

            HStack(spacing: 7) {
                DrivingLimitBadge(limit: snapshot.speedLimitKmh)
                    .frame(width: compact ? 40 : 48, height: compact ? 40 : 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("GIỚI HẠN")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                    Text(snapshot.speedLimitKmh > 0 ? "Hiện tại" : "Chưa có dữ liệu")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DriveTheme.textMuted)
                }
            }
            if let nextLimit = snapshot.nextSpeedLimitKmh,
               let distance = snapshot.nextSpeedDistanceMeters,
               nextLimit > 0, nextLimit != snapshot.speedLimitKmh {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                    Text("\(nextLimit) km/h · \(drivingDistance(Double(distance)))")
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
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

    private var compassDirection: String {
        let directions = ["Bắc", "Đông Bắc", "Đông", "Đông Nam", "Nam", "Tây Nam", "Tây", "Tây Bắc"]
        let normalized = (snapshot.heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return directions[Int((normalized / 45).rounded()) % directions.count]
    }

    private var gpsTint: Color {
        switch gpsQuality {
        case .unavailable, .weak: DriveTheme.amber
        case .good, .excellent: DriveTheme.skyDeep
        }
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
                .background(.white.opacity(0.60), in: Circle())
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

/// Illustrative right-shoulder placement, not surveyed pole or lane geometry.
enum DrivingRoadsideLayout {
    struct Placement: Identifiable, Equatable {
        let alert: DriveAlert
        let depth: Double
        let faceSize: CGFloat
        let height: CGFloat
        var top: CGFloat
        var x: CGFloat
        var id: Int { alert.id }
        var width: CGFloat { max(52, faceSize) }
        var readableHeight: CGFloat { faceSize + 18 }
    }

    static func depth(distance: Double) -> Double {
        guard distance.isFinite else { return 0 }
        return 220 / (220 + max(0, distance))
    }

    static func roadPoint(depth: Double, side: Double, size: CGSize) -> CGPoint {
        CGPoint(x: size.width * (0.5 + side * (0.045 + depth * 0.275)),
                y: size.height * (0.05 + depth * 0.93))
    }

    static func placements(alerts: [DriveAlert], size: CGSize) -> [Placement] {
        guard size.width.isFinite, size.height.isFinite, size.width >= 100, size.height >= 80 else { return [] }
        let count = min(3, max(1, Int(size.height / 58)))
        let ordered = Array(DrivingSignPassage().upcoming(from: alerts).prefix(count).reversed())
        guard !ordered.isEmpty else { return [] }
        let n = CGFloat(ordered.count)
        // Reserve all metre labels, gaps, the final pole and both outer margins.
        let cap = max(16, min(62, size.width * 0.17,
            (size.height - 8 - 24 * n) / n,
            (size.height - 8 - 24 * (n - 1)) / (n + 0.9)))
        var result: [Placement] = []
        for alert in ordered {
            let depth = depth(distance: alert.distanceMeters)
            let face = max(16, cap * (0.5 + 0.5 * depth))
            let height = face + max(24, face * 0.9)
            var top = max(4, roadPoint(depth: depth, side: 1, size: size).y - height)
            if let previous = result.last {
                top = max(top, previous.top + previous.readableHeight + 6)
            }
            result.append(.init(alert: alert, depth: depth, faceSize: face, height: height, top: top, x: 0))
        }
        // Only separate overlapping faces/labels. Metre labels and relative order remain unchanged.
        for index in result.indices.reversed() {
            let bottomLimit = index == result.count - 1
                ? size.height - 4 - result[index].height
                : result[index + 1].top - result[index].readableHeight - 6
            result[index].top = min(result[index].top, bottomLimit)
        }
        for index in result.indices {
            let base = result[index].top + result[index].height
            let visualDepth = max(0, min(1, (base / size.height - 0.05) / 0.93))
            let shoulder = roadPoint(depth: visualDepth, side: 1, size: size).x + size.width * 0.065
            result[index].x = min(size.width - result[index].width / 2 - 3, shoulder)
        }
        return result
    }
}

private struct DrivingRoadsideSign: View {
    let placement: DrivingRoadsideLayout.Placement

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(red: 0.48, green: 0.58, blue: 0.66), .white,
                                              Color(red: 0.55, green: 0.63, blue: 0.70)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: max(3, placement.faceSize * 0.075), height: placement.height - placement.faceSize / 2)
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
                    .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(placement.alert.message), sau \(drivingDistance(placement.alert.distanceMeters))")
        .accessibilitySortPriority(-placement.alert.distanceMeters)
        .allowsHitTesting(false)
    }
}

private struct DrivingRoadSurface: View {
    let speed: Int
    let isAnimating: Bool
    @State private var phaseOffset = 0.0
    @State private var phaseDate = Date()
    @State private var phaseRate = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
            let phase = phaseOffset + max(0, timeline.date.timeIntervalSince(phaseDate)) * phaseRate
            Canvas { context, size in
                let h = size.height
                var road = Path()
                road.move(to: DrivingRoadsideLayout.roadPoint(depth: 0, side: -1, size: size))
                road.addLine(to: DrivingRoadsideLayout.roadPoint(depth: 0, side: 1, size: size))
                road.addLine(to: DrivingRoadsideLayout.roadPoint(depth: 1.1, side: 1, size: size))
                road.addLine(to: DrivingRoadsideLayout.roadPoint(depth: 1.1, side: -1, size: size))
                road.closeSubpath()
                context.fill(road, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), Color(red: 0.73, green: 0.83, blue: 0.90).opacity(0.52)]),
                    startPoint: CGPoint(x: 0, y: h * 0.05), endPoint: CGPoint(x: 0, y: h)
                ))
                for side in [-1.0, 1.0] {
                    var edge = Path()
                    edge.move(to: DrivingRoadsideLayout.roadPoint(depth: 0, side: side, size: size))
                    edge.addLine(to: DrivingRoadsideLayout.roadPoint(depth: 1.1, side: side, size: size))
                    context.stroke(edge, with: .color(.white.opacity(0.70)), lineWidth: 2)
                    for index in 0..<10 {
                        let t = (Double(index) / 10 + phase).truncatingRemainder(dividingBy: 1)
                        let near = pow(t, 1.7)
                        let far = pow(max(0, t - 0.036), 1.7)
                        var dash = Path()
                        dash.move(to: DrivingRoadsideLayout.roadPoint(depth: far, side: side * 0.64, size: size))
                        dash.addLine(to: DrivingRoadsideLayout.roadPoint(depth: near, side: side * 0.64, size: size))
                        context.stroke(dash, with: .color(DriveTheme.skyDeep.opacity(0.10 * t)), style: StrokeStyle(lineWidth: 3 + near * 5, lineCap: .round))
                        context.stroke(dash, with: .color(.white.opacity(0.95 * t)), style: StrokeStyle(lineWidth: 1.5 + near * 4, lineCap: .round))
                    }
                }
            }
        }
        .onAppear { updateRate() }
        .onChange(of: speed) { _, _ in updateRate() }
        .onChange(of: isAnimating) { _, _ in updateRate() }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                     .init(color: .black, location: 0.88),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Integrate the old rate first, so speed changes do not jump the road markings.
    private func updateRate() {
        let now = Date()
        phaseOffset = (phaseOffset + now.timeIntervalSince(phaseDate) * phaseRate).truncatingRemainder(dividingBy: 1)
        phaseDate = now
        phaseRate = isAnimating ? Double(max(0, min(speed, 160))) / 3.6 / 70 : 0
    }
}

private struct DrivingMazdaCar: View {
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
            Image("DrivingMazdaCX5Rear")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .offset(y: isAnimating ? sin(timeline.date.timeIntervalSinceReferenceDate * 9) * 1.2 : 0)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mazda CX-5 màu trắng, biển số 86A 26427")
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
            snapshot: snapshot, alerts: alerts, gpsQuality: hasGPS ? .excellent : .unavailable,
            accuracyMeters: hasGPS ? 5 : nil, isGuiding: false, isReplay: false, voiceEnabled: true,
            showsMascot: showsMascot, animateRoad: animateRoad, onSearch: {}, onSettings: {}, onToggleVoice: {}
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
