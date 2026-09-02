import SwiftUI

struct DriveDashboardView: View {
    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showLayers = false
    @State private var showSearch = false
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("--settings-screen")
    @State private var selectedAlert: DriveAlert?
    @AppStorage("showMascotOnMap") private var showMascotOnMap = true
    @AppStorage("mapAppearance") private var mapAppearanceRaw = MapAppearance.automatic.rawValue
    @AppStorage("mapDisplayMode") private var mapDisplayModeRaw = MapDisplayMode.drive3D.rawValue
    @AppStorage("drivingModeEnabled") private var drivingModeEnabled = false

    var body: some View {
        Group {
            if drivingModeEnabled {
                DrivingModeView(
                    onSearch: { showSearch = true },
                    onSettings: { showSettings = true }
                )
                .environmentObject(model)
            } else {
                ZStack {
                    MapLibreMapView(
                        snapshot: model.snapshot,
                        alerts: model.mapDisplayAlerts,
                        roads: model.visibleRoads,
                        followUser: model.followUser,
                        cameraRevision: model.cameraRevision,
                        destination: model.destination?.coordinate,
                        routeViewportRevision: model.routeViewportRevision,
                        showGuidanceMascot: showMascotOnMap && model.shouldShowGuidanceMascot,
                        isNightMode: mapAppearance.isNight(systemScheme: colorScheme),
                        displayMode: mapDisplayMode,
                        onUserInteraction: { model.followUser = false },
                        onViewportChanged: { center, radius in
                            model.updateMapViewport(center: center, radiusMeters: radius)
                        },
                        onAlertSelected: { selectedAlert = $0 }
                    )
                    .ignoresSafeArea()

                    LinearGradient(
                        colors: mapOverlayColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    if showMascotOnMap,
                       model.snapshot.journeyEvent != .idle,
                       model.snapshot.journeyEvent != .driving {
                        JourneyMascotOverlay(event: model.snapshot.journeyEvent)
                            .id(model.snapshot.journeyEventRevision)
                            .offset(y: 28)
                            .allowsHitTesting(false)
                            .zIndex(3)
                    }

                    VStack(spacing: 10) {
                        topOverlay
                            .frame(maxWidth: overlayMaxWidth, alignment: .leading)
                        Spacer(minLength: isCompactLandscape ? 34 : 80)
                        if let section = model.snapshot.activeSectionSpeed {
                            SectionSpeedBanner(section: section)
                                .frame(maxWidth: overlayMaxWidth, alignment: .leading)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if let alert = model.countdownBannerAlert, model.isGuidanceActive {
                            CompactAlertBanner(alert: alert)
                                .frame(maxWidth: 340)
                                .frame(maxWidth: overlayMaxWidth, alignment: .leading)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if model.didArrive {
                            ArrivalCard()
                                .environmentObject(model)
                                .frame(maxWidth: overlayMaxWidth, alignment: .leading)
                                .transition(.scale(scale: 0.88).combined(with: .opacity))
                        } else if model.isRoutePreview {
                            RoutePreviewCard()
                                .environmentObject(model)
                                .frame(maxWidth: overlayMaxWidth, alignment: .leading)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if model.isPlanningRoute {
                            RoutePlanningCard(destinationName: model.destination?.name ?? "điểm đến")
                                .frame(maxWidth: overlayMaxWidth, alignment: .leading)
                        } else if model.isGuidanceActive {
                            NavigationBottomBar()
                                .environmentObject(model)
                                .frame(maxWidth: overlayMaxWidth, alignment: .leading)
                        } else {
                            FreeDriveHUD(alert: model.countdownBannerAlert)
                                .environmentObject(model)
                                .frame(maxWidth: overlayMaxWidth, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            mapControls
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, controlClearance)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.35), value: model.countdownBannerAlert?.id)
        .preferredColorScheme(dashboardColorScheme)
        .task {
            model.start()
        }
        .sheet(isPresented: $showLayers) {
            MapLayerSheet()
                .environmentObject(model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSearch) {
            DestinationSearchView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .sheet(item: $selectedAlert) { alert in
            AlertDetailSheet(alert: alert)
                .environmentObject(model)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "Không thể hoàn tất tuyến",
            isPresented: Binding(
                get: { model.routeErrorMessage != nil },
                set: { if !$0 { model.dismissRouteError() } }
            )
        ) {
            Button("Đã hiểu", role: .cancel) { model.dismissRouteError() }
        } message: {
            Text(model.routeErrorMessage ?? "Lỗi không xác định")
        }
    }

    private var mapAppearance: MapAppearance {
        MapAppearance(rawValue: mapAppearanceRaw) ?? .automatic
    }

    private var mapDisplayMode: MapDisplayMode {
        MapDisplayMode(rawValue: mapDisplayModeRaw) ?? .drive3D
    }

    private var mapOverlayColors: [Color] {
        if mapDisplayMode == .satellite {
            return [Color.black.opacity(0.06), .clear, Color.black.opacity(0.04)]
        }
        return [DriveTheme.skySoft.opacity(0.07), .clear, DriveTheme.pinkSoft.opacity(0.025)]
    }

    @ViewBuilder
    private var topOverlay: some View {
        if model.isGuidanceActive, !model.didArrive {
            NavigationInstructionBanner(
                snapshot: model.snapshot,
                isRerouting: model.isRerouting
            ) {
                model.cancelRoute()
            }
        } else if model.isRoutePreview || model.isPlanningRoute {
            RouteSearchTopBar(
                destinationName: model.destination?.name ?? "Tìm điểm đến",
                onSearch: { showSearch = true },
                onCancel: { model.cancelRoute() },
                onSettings: { showSettings = true }
            )
        } else {
            FreeDriveTopBar(
                snapshot: model.snapshot,
                mascotMood: idleMascotMood,
                showsMascot: showMascotOnMap && model.snapshot.speedKmh <= 3,
                onSearch: { showSearch = true },
                onSettings: { showSettings = true }
            )
        }
    }

    private var mapControls: some View {
        VStack(spacing: 10) {
            MapControlButton(icon: "location.fill", tint: DriveTheme.cyan) {
                model.recenter()
            }
            MapControlButton(icon: mapDisplayMode.iconName, tint: DriveTheme.amber) {
                showLayers = true
            }
        }
    }

    private var controlClearance: CGFloat {
        if isCompactLandscape { return 18 }
        if model.isRoutePreview || model.isPlanningRoute || model.isGuidanceActive || model.didArrive {
            return 224
        }
        return 132
    }

    private var isCompactLandscape: Bool { verticalSizeClass == .compact }

    private var overlayMaxWidth: CGFloat {
        isCompactLandscape ? 560 : .infinity
    }

    private var dashboardColorScheme: ColorScheme {
        mapAppearance.isNight(systemScheme: colorScheme) ? .dark : .light
    }

    private var idleMascotMood: MascotMood {
        if model.snapshot.isOverSpeed { return .speedWarning }
        if model.isPlanningRoute { return .searching }
        if model.snapshot.primaryAlert != nil { return .warning }
        if model.snapshot.speedKmh > 5 { return .cruising }
        return .neutral
    }
}

private struct FreeDriveTopBar: View {
    let snapshot: DriveSnapshot
    let mascotMood: MascotMood
    let showsMascot: Bool
    let onSearch: () -> Void
    let onSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 9) {
            if showsMascot {
                MascotMayView(mood: mascotMood, size: 58)
                    .transition(.scale.combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(snapshot.speedKmh > 3 ? DriveTheme.mint : DriveTheme.skyDeep)
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle()
                                .stroke(
                                    snapshot.speedKmh > 3 ? DriveTheme.mint : DriveTheme.skyDeep,
                                    lineWidth: 2
                                )
                                .scaleEffect(pulse ? 2.1 : 0.8)
                                .opacity(pulse ? 0 : 0.65)
                        }
                    Text(snapshot.speedKmh > 3 ? "ĐANG LÁI TỰ DO" : "SẴN SÀNG LÁI TỰ DO")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                }
                Text(snapshot.primaryAlert == nil
                     ? "Camera · biển báo · tốc độ"
                     : "Mây đang theo dõi cảnh báo phía trước")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TopCircleActionButton(
                icon: "magnifyingglass",
                tint: DriveTheme.skyDeep,
                accessibilityLabel: "Tìm điểm đến",
                action: onSearch
            )
            TopCircleActionButton(
                icon: "gearshape.fill",
                tint: DriveTheme.pink,
                accessibilityLabel: "Cài đặt",
                action: onSettings
            )
        }
        .padding(.leading, showsMascot ? 3 : 15)
        .padding(.trailing, 7)
        .frame(minHeight: 58)
        .background(.regularMaterial, in: Capsule())
        .background(DriveTheme.surfaceStrong.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1.2))
        .shadow(color: DriveTheme.skyDeep.opacity(0.14), radius: 13, y: 5)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.15).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct RouteSearchTopBar: View {
    let destinationName: String
    let onSearch: () -> Void
    let onCancel: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onSearch) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DriveTheme.skyDeep)
                    Text(destinationName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            TopCircleActionButton(
                icon: "xmark",
                tint: DriveTheme.secondaryLabel,
                accessibilityLabel: "Hủy tuyến",
                action: onCancel
            )
            TopCircleActionButton(
                icon: "gearshape.fill",
                tint: DriveTheme.pink,
                accessibilityLabel: "Cài đặt",
                action: onSettings
            )
        }
        .font(.subheadline.weight(.semibold))
        .padding(.leading, 15)
        .padding(.trailing, 7)
        .frame(height: 52)
        .background(.regularMaterial, in: Capsule())
        .background(DriveTheme.surfaceStrong.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1.2))
        .shadow(color: DriveTheme.skyDeep.opacity(0.14), radius: 13, y: 5)
    }
}

private struct TopCircleActionButton: View {
    let icon: String
    let tint: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(tint.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct NavigationInstructionBanner: View {
    let snapshot: DriveSnapshot
    let isRerouting: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            MascotMayView(mood: mascotMood, size: 68)
            VStack(alignment: .leading, spacing: 3) {
                if isRerouting {
                    Text("Mây đang tìm lại đường…")
                        .font(.caption.weight(.black))
                        .foregroundStyle(DriveTheme.pink)
                }
                if snapshot.maneuverDistanceMeters > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: maneuverIcon)
                        Text(distanceText)
                    }
                    .font(.system(size: 21, weight: .black, design: .rounded))
                    .foregroundStyle(DriveTheme.skyDeep)
                }
                Text(snapshot.nextManeuver)
                    .font(.headline)
                    .lineLimit(2)
                if !snapshot.laneGuidance.isEmpty {
                    Text(snapshot.laneGuidance)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(DriveTheme.mint)
                        .accessibilityLabel("Làn đường: \(snapshot.laneGuidance)")
                }
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.secondary)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .accessibilityLabel("Kết thúc dẫn đường")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(DriveTheme.surfaceStrong.opacity(0.74), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.12), lineWidth: 1.2))
        .shadow(color: DriveTheme.skyDeep.opacity(0.15), radius: 15, y: 6)
    }

    private var distanceText: String {
        snapshot.maneuverDistanceMeters >= 1_000
            ? String(format: "%.1f km", Double(snapshot.maneuverDistanceMeters) / 1_000)
            : "\(snapshot.maneuverDistanceMeters) m"
    }

    private var maneuverIcon: String {
        let instruction = snapshot.nextManeuver.lowercased()
        if instruction.contains("trái") { return "arrow.turn.up.left" }
        if instruction.contains("phải") { return "arrow.turn.up.right" }
        if instruction.contains("quay") { return "arrow.uturn.backward" }
        return "arrow.up"
    }

    private var mascotMood: MascotMood {
        if isRerouting { return .rerouting }
        if snapshot.isOverSpeed { return .speedWarning }
        if snapshot.maneuverType == "roundabout" || snapshot.maneuverModifier.contains("uturn") {
            return .uTurn
        }
        if !snapshot.laneGuidance.isEmpty, snapshot.maneuverDistanceMeters <= 700 {
            return .laneGuide
        }
        let instruction = snapshot.nextManeuver.lowercased()
        if instruction.contains("trái") {
            return snapshot.maneuverModifier.contains("slight") ? .curveLeft : .turnLeft
        }
        if instruction.contains("phải") {
            return snapshot.maneuverModifier.contains("slight") ? .curveRight : .turnRight
        }
        if instruction.contains("đến") { return .arrived }
        if let alert = snapshot.primaryAlert, alert.distanceMeters <= 450 { return .warning }
        return snapshot.speedKmh > 5 ? .cruising : .searching
    }
}

private struct JourneyMascotOverlay: View {
    let event: MascotJourneyEvent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mood: MascotMood = .running
    @State private var xOffset: CGFloat = -260
    @State private var opacity = 0.0
    @State private var scale = 0.76
    @State private var bubbleOpacity = 0.0

    var body: some View {
        VStack(spacing: 4) {
            Text(message)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(DriveTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.white.opacity(0.96), in: Capsule())
                .overlay(Capsule().stroke(DriveTheme.pink.opacity(0.30), lineWidth: 2))
                .shadow(color: DriveTheme.pink.opacity(0.18), radius: 10, y: 4)
                .opacity(bubbleOpacity)
            MascotMayView(mood: mood, size: 154)
                .scaleEffect(scale)
        }
        .offset(x: xOffset)
        .opacity(opacity)
        .task { await animateSequence() }
    }

    private var message: String {
        switch event {
        case .departing: "Lên đường thôi!"
        case .braking: "Sắp tới rồi, chậm lại nhé!"
        case .arrived: "Tới nơi an toàn rồi!"
        default: "Mây đi cùng bạn!"
        }
    }

    @MainActor
    private func animateSequence() async {
        if reduceMotion {
            mood = event == .arrived ? .celebrate : (event == .braking ? .braking : .running)
            xOffset = 0
            opacity = 1
            scale = 1
            bubbleOpacity = 1
            return
        }
        switch event {
        case .departing:
            mood = .running
            withAnimation(.spring(response: 0.52, dampingFraction: 0.68)) {
                xOffset = 0
                opacity = 1
                scale = 1
                bubbleOpacity = 1
            }
            try? await Task.sleep(for: .seconds(1.05))
            withAnimation(.easeIn(duration: 0.52)) {
                xOffset = 300
                opacity = 0
                scale = 0.82
                bubbleOpacity = 0
            }
        case .braking:
            mood = .braking
            xOffset = 260
            withAnimation(.spring(response: 0.62, dampingFraction: 0.58)) {
                xOffset = 0
                opacity = 1
                scale = 1
                bubbleOpacity = 1
            }
        case .arrived:
            mood = .braking
            xOffset = 240
            withAnimation(.spring(response: 0.55, dampingFraction: 0.58)) {
                xOffset = 0
                opacity = 1
                scale = 1
                bubbleOpacity = 1
            }
            try? await Task.sleep(for: .seconds(0.72))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.48)) {
                mood = .celebrate
                scale = 1.14
            }
        default:
            break
        }
    }
}

private struct NavigationBottomBar: View {
    @EnvironmentObject private var model: DriveViewModel

    var body: some View {
        HStack(spacing: 13) {
            CompactSpeed(speed: model.snapshot.speedKmh, overSpeed: model.snapshot.isOverSpeed)
            SpeedLimitSign(
                limit: model.snapshot.speedLimitKmh,
                isOverSpeedCritical: model.snapshot.isOverSpeedCritical,
                isOverSpeedMinor: model.snapshot.isOverSpeedMinor,
                nextLimit: model.snapshot.nextSpeedLimitKmh,
                nextDistanceMeters: model.snapshot.nextSpeedDistanceMeters
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.arrivalTimeText)
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(DriveTheme.pink)
                            .contentTransition(.numericText())
                        Text("DỰ KIẾN ĐẾN")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(DriveTheme.ink.opacity(0.48))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.routeDurationText)
                            .font(.caption.weight(.black))
                        Text("\(model.routeDistanceText) còn lại")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DriveTheme.ink.opacity(0.55))
                    }
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DriveTheme.skySoft)
                        Capsule()
                            .fill(LinearGradient(
                                colors: [DriveTheme.skyDeep, DriveTheme.pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: max(8, proxy.size.width * model.routeProgress))
                    }
                }
                .frame(height: 6)
                Text(model.snapshot.roadName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DriveTheme.ink.opacity(0.60))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: model.locationFixQuality.symbol)
                    Text(model.mapMatchStatus)
                }
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(model.locationFixQuality == .weak
                    ? DriveTheme.amber
                    : DriveTheme.mint)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(DriveTheme.sky.opacity(0.28), lineWidth: 1.5))
        .shadow(color: DriveTheme.skyDeep.opacity(0.16), radius: 15, y: 7)
    }
}

private struct FreeDriveHUD: View {
    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let alert: DriveAlert?
    @State private var alertPulse = false

    var body: some View {
        HStack(spacing: 11) {
            FreeDriveSpeedGauge(snapshot: model.snapshot)

            if let alert {
                alertContent(alert)
            } else {
                drivingContext
            }

            VStack(spacing: 2) {
                Text("GIỚI HẠN")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(DriveTheme.secondaryLabel)
                SpeedLimitSign(
                    limit: model.snapshot.speedLimitKmh,
                    isOverSpeedCritical: model.snapshot.isOverSpeedCritical,
                    isOverSpeedMinor: model.snapshot.isOverSpeedMinor,
                    nextLimit: model.snapshot.nextSpeedLimitKmh,
                    nextDistanceMeters: model.snapshot.nextSpeedDistanceMeters
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            DriveTheme.surfaceStrong.opacity(0.76),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    panelTint.opacity(model.snapshot.isOverSpeed || alert != nil ? 0.66 : 0.30),
                    lineWidth: model.snapshot.isOverSpeed ? 2.5 : 1.5
                )
        }
        .shadow(
            color: panelTint.opacity(0.18),
            radius: 14,
            y: 6
        )
        .animation(.snappy(duration: 0.32), value: model.snapshot.isOverSpeed)
        .animation(.snappy(duration: 0.30), value: alert?.id)
        .onAppear { updateAlertPulse() }
        .onChange(of: alert?.id) { _, _ in updateAlertPulse() }
    }

    private var drivingContext: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: model.locationFixQuality.symbol)
                Text(model.locationFixQuality.title.uppercased())
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(locationTint)

            Text(roadTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)

            Text(areaText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alertContent(_ alert: DriveAlert) -> some View {
        HStack(spacing: 9) {
            if showsDistinctIcon(for: alert) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(alertTint.opacity(0.13))
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(alertTint.opacity(0.52), lineWidth: 1.5)
                        .scaleEffect(alertPulse ? 1.14 : 0.94)
                        .opacity(alertPulse ? 0 : 0.72)
                    Group {
                        if let assetName = alert.assetName {
                            Image(assetName).resizable().scaledToFit().padding(6)
                        } else {
                            Image(systemName: alert.kind.iconName)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(alertTint)
                        }
                    }
                }
                .frame(width: 44, height: 44)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "location.north.line.fill")
                    Text("PHÍA TRƯỚC")
                    Spacer(minLength: 4)
                    Text(distanceText(alert))
                        .monospacedDigit()
                }
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(alertTint)

                Text(alert.message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                Text(alert.signCode ?? alert.kind.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var areaText: String {
        if model.snapshot.isDemo { return "Đang phát lại hành trình GPS" }
        return model.snapshot.province.isEmpty ? "Đang xác định khu vực" : model.snapshot.province
    }

    private var roadTitle: String {
        model.snapshot.roadName == "Đang xác định tuyến đường"
            ? "Đang xác định đường hiện tại"
            : model.snapshot.roadName
    }

    private var locationTint: Color {
        switch model.locationFixQuality {
        case .unavailable, .weak: DriveTheme.amber
        case .good, .excellent: DriveTheme.mint
        }
    }

    private var alertTint: Color {
        alert.map { DriveTheme.alertColor($0.kind) } ?? DriveTheme.skyDeep
    }

    private var panelTint: Color {
        model.snapshot.isOverSpeed ? DriveTheme.danger : (alert == nil ? DriveTheme.skyDeep : alertTint)
    }

    private func showsDistinctIcon(for alert: DriveAlert) -> Bool {
        guard let code = alert.signCode else { return true }
        return TrafficSignCatalog.speedLimit(from: code) == nil
    }

    private func distanceText(_ alert: DriveAlert) -> String {
        alert.distanceMeters >= 1_000
            ? String(format: "%.1f KM", alert.distanceMeters / 1_000)
            : "\(Int(alert.distanceMeters.rounded())) M"
    }

    private func updateAlertPulse() {
        alertPulse = false
        guard alert != nil, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.92).repeatForever(autoreverses: false)) {
            alertPulse = true
        }
    }
}

private struct FreeDriveSpeedGauge: View {
    let snapshot: DriveSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var warningPulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(DriveTheme.ink.opacity(0.94))
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: min(1, CGFloat(snapshot.speedKmh) / 140))
                .stroke(
                    snapshot.isOverSpeed ? DriveTheme.danger : DriveTheme.cyan,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(
                    color: (snapshot.isOverSpeed ? DriveTheme.danger : DriveTheme.cyan).opacity(0.50),
                    radius: 5
                )
            if snapshot.isOverSpeed {
                Circle()
                    .stroke(DriveTheme.danger.opacity(0.58), lineWidth: 3)
                    .scaleEffect(warningPulse ? 1.19 : 0.96)
                    .opacity(warningPulse ? 0 : 0.82)
            }
            VStack(spacing: -3) {
                Text("\(snapshot.speedKmh)")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(snapshot.isOverSpeed ? DriveTheme.danger : .white)
                    .contentTransition(.numericText())
                Text("KM/H")
                    .font(.system(size: 8, weight: .black))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .frame(width: 74, height: 74)
        .onAppear { updateWarningAnimation() }
        .onChange(of: snapshot.isOverSpeed) { _, _ in updateWarningAnimation() }
    }

    private func updateWarningAnimation() {
        warningPulse = false
        guard snapshot.isOverSpeed, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.72).repeatForever(autoreverses: false)) {
            warningPulse = true
        }
    }
}

private struct CompactSpeed: View {
    let speed: Int
    let overSpeed: Bool

    var body: some View {
        VStack(spacing: -2) {
            Text("\(speed)")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(overSpeed ? DriveTheme.danger : .white)
                .contentTransition(.numericText())
            Text("KM/H")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(DriveTheme.textMuted)
        }
        .frame(width: 58, height: 58)
        .background(DriveTheme.ink.opacity(0.74), in: Circle())
        .overlay(Circle().stroke(overSpeed ? DriveTheme.danger : DriveTheme.cyan, lineWidth: 2))
    }
}

private struct CompactAlertBanner: View {
    let alert: DriveAlert

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let assetName = alert.assetName {
                    Image(assetName).resizable().scaledToFit()
                } else {
                    Image(systemName: alert.kind.iconName)
                        .foregroundStyle(DriveTheme.alertColor(alert.kind))
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.message)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text(alert.signCode ?? alert.kind.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(alert.distanceMeters >= 1_000
                 ? String(format: "%.1f km", alert.distanceMeters / 1_000)
                 : "\(Int(alert.distanceMeters)) m")
                .font(.subheadline.weight(.black))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(DriveTheme.alertColor(alert.kind).opacity(0.35)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

private struct SectionSpeedBanner: View {
    let section: SectionSpeedProgress

    var body: some View {
        HStack(spacing: 10) {
            Image(TrafficSignCatalog.assetName(
                for: TrafficSignCatalog.sectionCameraCode
            ) ?? "")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("ĐOẠN ĐO TỐC ĐỘ TỰ ĐỘNG")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(DriveTheme.pink)
                HStack(spacing: 8) {
                    Text("Tốc độ TB: \(section.averageSpeedKmh) km/h")
                        .font(.caption.weight(.black))
                        .foregroundStyle(section.averageSpeedKmh > section.speedLimit ? DriveTheme.danger : DriveTheme.mint)
                    Text("· Giới hạn: \(section.speedLimit) km/h")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(DriveTheme.surfaceStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(DriveTheme.pink.opacity(0.35)))
        .shadow(color: DriveTheme.pink.opacity(0.15), radius: 8, y: 3)
    }
}

private struct RoutePlanningCard: View {
    let destinationName: String

    var body: some View {
        HStack(spacing: 13) {
            MascotMayView(mood: .searching, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mây đang tìm tuyến phù hợp")
                    .font(.subheadline.weight(.bold))
                Text("Tới \(destinationName) · OSRM/OpenStreetMap")
                    .font(.caption)
                    .foregroundStyle(DriveTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(16)
        .glassPanel(cornerRadius: 22)
    }
}

private struct RoutePreviewCard: View {
    @EnvironmentObject private var model: DriveViewModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                MascotMayView(mood: .celebrate, size: 62)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedRouteTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Tuyến \(model.routePreferences.strategy.title.lowercased()) · OSRM/OpenStreetMap")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DriveTheme.textMuted)
                }
                Spacer()
            }
            if model.routeAlternatives.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.routeAlternatives.enumerated()), id: \.element.id) { index, route in
                            Button {
                                model.selectRoute(at: index)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(index == 0 ? "Đề xuất" : "Tuyến \(index + 1)")
                                        .font(.caption2.weight(.black))
                                    Text("\(Self.durationText(route.durationSeconds)) · \(Self.distanceText(route.distanceMeters))")
                                        .font(.caption.weight(.bold))
                                }
                                .foregroundStyle(index == model.selectedRouteIndex ? .white : DriveTheme.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    index == model.selectedRouteIndex ? DriveTheme.cyan : DriveTheme.skySoft,
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if let route = model.navigationRoute {
                HStack(spacing: 8) {
                    if route.isCached {
                        Label("Tuyến từ bộ nhớ offline", systemImage: "externaldrive.fill")
                    }
                    if !route.preferencesApplied {
                        Label("Máy chủ chưa hỗ trợ đủ bộ lọc", systemImage: "exclamationmark.triangle.fill")
                    }
                    if route.laneGuidanceStepCount > 0 {
                        Label("\(route.laneGuidanceStepCount) chỉ dẫn làn", systemImage: "road.lanes")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DriveTheme.ink.opacity(0.56))
            }
            HStack(spacing: 8) {
                TripMetric(
                    title: "ĐẾN NƠI",
                    value: model.arrivalTimeText,
                    icon: "flag.checkered",
                    tint: DriveTheme.pink
                )
                TripMetric(
                    title: "THỜI GIAN",
                    value: model.routeDurationText,
                    icon: "clock.fill",
                    tint: DriveTheme.skyDeep
                )
                TripMetric(
                    title: "QUÃNG ĐƯỜNG",
                    value: model.routeDistanceText,
                    icon: "road.lanes",
                    tint: DriveTheme.mint
                )
            }
            HStack(spacing: 10) {
                Button("Hủy", role: .cancel) { model.cancelRoute() }
                    .buttonStyle(.bordered)
                Button { model.startNavigation() } label: {
                    Label("Bắt đầu dẫn đường", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DriveTheme.cyan)
            }
            .font(.subheadline.weight(.bold))
            Label(
                "Chỉ dẫn và định vị nền sẽ hoạt động sau khi bạn nhấn Bắt đầu dẫn đường.",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DriveTheme.ink.opacity(0.62))
        }
        .padding(16)
        .glassPanel(cornerRadius: 26)
    }

    private static func durationText(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60)g \(minutes % 60)p" : "\(minutes)p"
    }

    private static func distanceText(_ meters: Double) -> String {
        meters >= 1_000 ? String(format: "%.1f km", meters / 1_000) : "\(Int(meters)) m"
    }
}

private struct TripMetric: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(tint)
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(DriveTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(DriveTheme.ink.opacity(0.44))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct ArrivalCard: View {
    @EnvironmentObject private var model: DriveViewModel

    var body: some View {
        HStack(spacing: 13) {
            MascotMayView(mood: .arrived, size: 78)
            VStack(alignment: .leading, spacing: 3) {
                Text("Đã đến nơi!")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(DriveTheme.ink)
                Text(model.destination?.name ?? "Điểm đến")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(DriveTheme.pink)
                Text("Mây đã đồng hành trọn vẹn chuyến đi.")
                    .font(.caption)
                    .foregroundStyle(DriveTheme.ink.opacity(0.56))
            }
            Spacer(minLength: 4)
            Button {
                model.cancelRoute()
            } label: {
                Image(systemName: "checkmark")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(DriveTheme.mint, in: Circle())
            }
            .accessibilityLabel("Kết thúc hành trình")
        }
        .padding(14)
        .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(DriveTheme.mint.opacity(0.34), lineWidth: 2))
        .shadow(color: DriveTheme.mint.opacity(0.18), radius: 16, y: 7)
    }
}

private struct AlertDetailSheet: View {
    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.dismiss) private var dismiss
    let alert: DriveAlert
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 14) {
                    SignAssetPreview(
                        asset: alert.assetName ?? "",
                        code: alert.signCode ?? alert.kind.title
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alert.message)
                            .font(.headline)
                            .foregroundStyle(DriveTheme.ink)
                        Text(alert.source.isEmpty ? "Nguồn chưa xác định" : alert.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if alert.confidence > 0 {
                            Text("Độ tin cậy \(Int(alert.confidence * 100))%")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(alert.confidence >= 0.75 ? DriveTheme.mint : DriveTheme.amber)
                        }
                    }
                }
                TextField("Mô tả điểm sai: vị trí, chiều đường, loại biển…", text: $reason, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(DriveTheme.skySoft.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                Button {
                    model.reportIncorrectAlert(alert, reason: reason)
                    dismiss()
                } label: {
                    Label("Báo dữ liệu sai để kiểm duyệt", systemImage: "exclamationmark.bubble.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(DriveTheme.pink)
                Text("Báo cáo chỉ vào hàng chờ; dữ liệu đang dùng không bị xóa tự động.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(18)
            .navigationTitle("Chi tiết dữ liệu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}

private struct MapLayerSheet: View {
    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mapDisplayMode") private var mapDisplayModeRaw = MapDisplayMode.drive3D.rawValue

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 12) {
                MapDisplayModePicker(selection: $mapDisplayModeRaw)
                LayerToggle(
                    title: "Camera từ map-data",
                    subtitle: "\(model.mapDataCameraCount) điểm, lọc theo tuyến và hướng chạy",
                    icon: "camera.metering.center.weighted",
                    tint: DriveTheme.danger,
                    isOn: $model.showCameras
                )
                LayerToggle(
                    title: "Biển báo & tốc độ map-data",
                    subtitle: "\(model.mapDataPointCount) điểm · \(model.mapDataRoadLinkCount) đoạn đường hai chiều",
                    icon: "signpost.right.and.left.fill",
                    tint: DriveTheme.amber,
                    isOn: $model.showRoadSigns
                )
                LayerToggle(
                    title: "Tuyến dẫn đường",
                    subtitle: "Nền và tuyến vẫn do MapLibre hiển thị",
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    tint: DriveTheme.cyan,
                    isOn: $model.showValidatedRoads
                )
                VStack(spacing: 10) {
                    HStack(spacing: 13) {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(DriveTheme.mint)
                            .frame(width: 40, height: 40)
                            .background(DriveTheme.mint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Hướng dẫn bằng giọng nói").font(.subheadline.weight(.bold))
                            Text(model.voiceDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { model.voiceEnabled },
                                set: { model.updateVoiceEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .tint(DriveTheme.mint)
                    }
                    Button {
                        model.previewVoice()
                    } label: {
                        Label("Nghe thử giọng đang chọn", systemImage: "play.fill")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.voiceEnabled)
                }
                .padding(12)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                Label(
                    "Vị trí chỉ dùng cho dẫn đường; không quảng cáo, không tracking.",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .padding(16)
            }
            .navigationTitle("Lớp dữ liệu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                }
            }
            .onDisappear { model.refreshLayerVisibility() }
            .onChange(of: model.showCameras) {
                model.refreshLayerVisibility()
            }
            .onChange(of: model.showRoadSigns) {
                model.refreshLayerVisibility()
            }
        }
    }
}

private struct MapDisplayModePicker: View {
    @Binding var selection: String

    private var selectedMode: MapDisplayMode {
        MapDisplayMode(rawValue: selection) ?? .drive3D
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Góc nhìn bản đồ")
                        .font(.headline)
                    Text(selectedMode.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: selectedMode.iconName)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(DriveTheme.skyDeep)
            }

            HStack(spacing: 8) {
                ForEach(MapDisplayMode.allCases) { mode in
                    Button {
                        withAnimation(.snappy(duration: 0.28)) {
                            selection = mode.rawValue
                        }
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: mode.iconName)
                                .font(.system(size: 18, weight: .bold))
                            Text(mode.title)
                                .font(.caption2.weight(.bold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selectedMode == mode ? .white : DriveTheme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            selectedMode == mode ? DriveTheme.skyDeep : Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                }
            }

            if selectedMode == .satellite {
                Label("Ảnh vệ tinh cần mạng; cảnh báo firmware vẫn hoạt động bình thường.", systemImage: "wifi")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(DriveTheme.skySoft.opacity(0.30), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DriveTheme.sky.opacity(0.28), lineWidth: 1)
        )
    }
}

private struct SignAssetPreview: View {
    let asset: String
    let code: String

    var body: some View {
        VStack(spacing: 5) {
            if asset.isEmpty {
                Image(systemName: "signpost.right.and.left.fill")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(DriveTheme.amber)
                    .frame(width: 42, height: 42)
            } else {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
            }
            Text(code)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(width: 58, height: 68)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct LayerToggle: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.bold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $isOn).labelsHidden().tint(tint)
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct MapControlButton: View {
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        }
    }
}

private struct AlertBanner: View {
    let alert: DriveAlert

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(DriveTheme.alertColor(alert.kind).opacity(0.18))
                if let assetName = alert.assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .padding(7)
                } else {
                    Image(systemName: alert.kind.iconName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(DriveTheme.alertColor(alert.kind))
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text((alert.signCode ?? alert.kind.title).uppercased())
                    .font(.caption2.weight(.black))
                    .tracking(1.1)
                    .foregroundStyle(DriveTheme.alertColor(alert.kind))
                Text(alert.message)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Int(alert.distanceMeters))")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .contentTransition(.numericText())
                Text("MÉT")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(DriveTheme.textMuted)
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: 22)
    }
}

private struct DriveHUD: View {
    let snapshot: DriveSnapshot

    var body: some View {
        HStack(spacing: 13) {
            SpeedDial(snapshot: snapshot)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "location.fill")
                        .font(.caption)
                        .foregroundStyle(DriveTheme.cyan)
                    Text(snapshot.roadName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                }
                Text(snapshot.province)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DriveTheme.textMuted)

                Divider().overlay(Color.white.opacity(0.12))

                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.up.right")
                        .foregroundStyle(DriveTheme.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.nextManeuver)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                        if snapshot.maneuverDistanceMeters > 0 {
                            Text("sau \(snapshot.maneuverDistanceMeters) m")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DriveTheme.textMuted)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            SpeedLimitSign(limit: snapshot.speedLimitKmh)
        }
        .padding(14)
        .frame(minHeight: 126)
        .glassPanel(cornerRadius: 28)
    }
}

private struct SpeedDial: View {
    let snapshot: DriveSnapshot

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(1, CGFloat(snapshot.speedKmh) / 140))
                .stroke(
                    snapshot.isOverSpeed ? DriveTheme.danger : DriveTheme.cyan,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: (snapshot.isOverSpeed ? DriveTheme.danger : DriveTheme.cyan).opacity(0.5), radius: 6)
            VStack(spacing: -2) {
                Text("\(snapshot.speedKmh)")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .contentTransition(.numericText())
                    .foregroundStyle(snapshot.isOverSpeed ? DriveTheme.danger : .white)
                Text("KM/H")
                    .font(.system(size: 9, weight: .black))
                    .tracking(1)
                    .foregroundStyle(DriveTheme.textMuted)
            }
        }
        .frame(width: 96, height: 96)
    }
}

struct SpeedLimitSign: View {
    let limit: Int
    var isOverSpeedCritical: Bool = false
    var isOverSpeedMinor: Bool = false
    var nextLimit: Int? = nil
    var nextDistanceMeters: Int? = nil

    private let supportedLimits = Set([30, 40, 50, 60, 70, 80, 90, 100, 110, 120])

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if supportedLimits.contains(limit) {
                    Image(TrafficSignCatalog.assetName(
                        for: TrafficSignCatalog.speedCode(limit)
                    ) ?? "")
                        .resizable()
                        .scaledToFit()
                        .background(Color.white, in: Circle())
                } else {
                    ZStack {
                        Circle().fill(limit > 0 ? Color.white : Color.white.opacity(0.08))
                        Circle().stroke(
                            limit > 0 ? DriveTheme.danger : Color.white.opacity(0.14),
                            lineWidth: 5
                        )
                        if limit > 0 {
                            Text("\(limit)")
                                .font(.system(size: 20, weight: .black, design: .rounded))
                                .foregroundStyle(DriveTheme.ink)
                        } else {
                            Image(systemName: "minus")
                                .font(.title2.bold())
                                .foregroundStyle(DriveTheme.textMuted)
                        }
                    }
                }
            }
            .frame(width: 48, height: 48)
            .overlay(
                Circle()
                    .stroke(
                        isOverSpeedCritical ? Color.red : (isOverSpeedMinor ? Color.orange : Color.clear),
                        lineWidth: 3.5
                    )
            )

            if let nextLimit, let nextDistanceMeters, nextLimit != limit {
                VStack(spacing: 1) {
                    ZStack {
                        if supportedLimits.contains(nextLimit) {
                            Image(TrafficSignCatalog.assetName(
                                for: TrafficSignCatalog.speedCode(nextLimit)
                            ) ?? "")
                                .resizable()
                                .scaledToFit()
                                .background(Color.white, in: Circle())
                        } else {
                            Circle().fill(Color.white)
                            Circle().stroke(DriveTheme.danger, lineWidth: 2.5)
                            Text("\(nextLimit)")
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .foregroundStyle(DriveTheme.ink)
                        }
                    }
                    .frame(width: 26, height: 26)
                    Text("\(nextDistanceMeters)m")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(DriveTheme.ink.opacity(0.70))
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityLabel(
            limit > 0
                ? "Giới hạn tốc độ \(limit)"
                : "Chưa có giới hạn tốc độ"
        )
    }
}
