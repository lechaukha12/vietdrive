import SwiftUI

/// Low-distraction driving surface. The map is deliberately not created in
/// this view so MapLibre cannot compete with the speed and sign information.
struct DrivingModeView: View {
    @EnvironmentObject private var model: DriveViewModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMascotMotion") private var userReduceMotion = false

    let onSearch: () -> Void
    let onSettings: () -> Void

    private var reduceMotion: Bool { systemReduceMotion || userReduceMotion }
    private var carIsMoving: Bool {
        model.snapshot.speedKmh > 2 || model.isGuidanceActive
    }

    var body: some View {
        ZStack {
            DrivingModeBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    statusCard
                    DrivingModeCarIllustration(
                        isMoving: carIsMoving,
                        reduceMotion: reduceMotion
                    )
                    .frame(height: 250)
                    .glassPanel(cornerRadius: 30)

                    speedCard
                    upcomingSignsCard
                    if model.isGuidanceActive {
                        guidanceCard
                    }
                    modeNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 26)
            }
        }
        .preferredColorScheme(.light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chế độ lái xe VietDrive")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: "car.side.fill")
                        .foregroundStyle(DriveTheme.cyan)
                    Text("CHẾ ĐỘ LÁI XE")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(0.75)
                }
                Text("Mây giữ mắt đường, bạn giữ tay lái")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DriveTheme.ink.opacity(0.60))
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                DrivingModeHeaderButton(
                    icon: "magnifyingglass",
                    tint: DriveTheme.skyDeep,
                    action: onSearch
                )
                DrivingModeHeaderButton(
                    icon: "gearshape.fill",
                    tint: DriveTheme.pink,
                    action: onSettings
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(DriveTheme.sky.opacity(0.28), lineWidth: 1.2)
        )
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusTint)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(statusTint.opacity(0.25), lineWidth: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.caption.weight(.black))
                    .foregroundStyle(statusTint)
                Text(model.snapshot.roadName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(model.locationFixQuality.title.uppercased())
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(model.locationFixQuality == .weak ? DriveTheme.amber : DriveTheme.mint)
                Text(model.snapshot.province)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(DriveTheme.surfaceStrong.opacity(0.84), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(statusTint.opacity(0.22), lineWidth: 1.2)
        )
    }

    private var speedCard: some View {
        HStack(spacing: 14) {
            DrivingModeSpeedDial(snapshot: model.snapshot)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.snapshot.isOverSpeed ? "GIẢM TỐC NGAY" : "TỐC ĐỘ HIỆN TẠI")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(0.55)
                    .foregroundStyle(model.snapshot.isOverSpeed ? DriveTheme.danger : DriveTheme.cyan)
                Text(model.snapshot.isOverSpeed
                     ? "Bạn đang vượt giới hạn cho phép"
                     : "Đang theo dõi tốc độ theo dữ liệu firmware")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if model.snapshot.speedLimitKmh > 0 {
                    Text("Giới hạn hiện tại (model.snapshot.speedLimitKmh) km/h")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DriveTheme.ink.opacity(0.62))
                }
            }

            Spacer(minLength: 4)

            VStack(spacing: 3) {
                Text("GIỚI HẠN")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(DriveTheme.ink.opacity(0.48))
                SpeedLimitSign(
                    limit: model.snapshot.speedLimitKmh,
                    isOverSpeedCritical: model.snapshot.isOverSpeedCritical,
                    isOverSpeedMinor: model.snapshot.isOverSpeedMinor,
                    nextLimit: model.snapshot.nextSpeedLimitKmh,
                    nextDistanceMeters: model.snapshot.nextSpeedDistanceMeters
                )
                .scaleEffect(0.86)
                .frame(width: 66, height: 54)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DriveTheme.surfaceStrong.opacity(0.90), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(model.snapshot.isOverSpeed ? DriveTheme.danger.opacity(0.72) : DriveTheme.sky.opacity(0.30), lineWidth: model.snapshot.isOverSpeed ? 2.2 : 1.2)
        )
        .shadow(color: (model.snapshot.isOverSpeed ? DriveTheme.danger : DriveTheme.skyDeep).opacity(0.13), radius: 14, y: 7)
        .animation(.snappy(duration: 0.30), value: model.snapshot.isOverSpeed)
    }

    private var upcomingSignsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("BIỂN BÁO SẮP TỚI", systemImage: "signpost.right.and.left.fill")
                    .font(.caption.weight(.black))
                    .tracking(0.55)
                    .foregroundStyle(DriveTheme.amber)
                Spacer()
                Text("(upcomingAlerts.count) mục")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if upcomingAlerts.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DriveTheme.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chưa có biển báo gần phía trước")
                            .font(.subheadline.weight(.semibold))
                        Text("VietDrive vẫn đang quét dữ liệu quanh vị trí hiện tại.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(upcomingAlerts) { alert in
                    DrivingModeAlertRow(alert: alert)
                    if alert.id != upcomingAlerts.last?.id {
                        Divider().opacity(0.45)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(DriveTheme.surfaceStrong.opacity(0.90), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(DriveTheme.amber.opacity(0.24), lineWidth: 1.2)
        )
    }

    private var guidanceCard: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.turn.up.right")
                .font(.title3.weight(.bold))
                .foregroundStyle(DriveTheme.cyan)
                .frame(width: 42, height: 42)
                .background(DriveTheme.skySoft.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("CHỈ DẪN TIẾP THEO")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(0.55)
                    .foregroundStyle(DriveTheme.cyan)
                Text(model.snapshot.nextManeuver)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                if model.snapshot.maneuverDistanceMeters > 0 {
                    Text("Sau (distanceText(model.snapshot.maneuverDistanceMeters))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(DriveTheme.surfaceStrong.opacity(0.86), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(DriveTheme.cyan.opacity(0.24), lineWidth: 1.2)
        )
    }

    private var modeNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .foregroundStyle(DriveTheme.pink)
            Text("Bản đồ đã tắt để giảm xao nhãng. Vị trí, GPS nền và cảnh báo vẫn hoạt động.")
                .font(.caption2.weight(.medium))
                .foregroundStyle(DriveTheme.ink.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var upcomingAlerts: [DriveAlert] {
        model.visibleAlerts
            .filter { $0.distanceMeters >= -5 && $0.distanceMeters <= 2_500 }
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .prefix(3)
            .map { $0 }
    }

    private var statusTitle: String {
        if model.snapshot.isOverSpeed { return "CẢNH BÁO VƯỢT TỐC ĐỘ" }
        if model.isGuidanceActive { return "ĐANG CHỈ ĐƯỜNG" }
        return "ĐANG LÁI TỰ DO"
    }

    private var statusTint: Color {
        if model.snapshot.isOverSpeed { return DriveTheme.danger }
        if model.isGuidanceActive { return DriveTheme.skyDeep }
        return DriveTheme.mint
    }

    private func distanceText(_ meters: Int) -> String {
        meters >= 1_000
            ? String(format: "%.1f km", Double(meters) / 1_000)
            : "(max(0, meters)) m"
    }
}

private struct DrivingModeHeaderButton: View {
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "gearshape.fill" ? "Cài đặt" : "Tìm kiếm")
    }
}

private struct DrivingModeBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DriveTheme.cloud, DriveTheme.skySoft.opacity(0.82), DriveTheme.pinkSoft.opacity(0.58)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(DriveTheme.sky.opacity(0.18))
                .frame(width: 260, height: 260)
                .blur(radius: 20)
                .offset(x: -150, y: -285)

            Circle()
                .fill(DriveTheme.pink.opacity(0.12))
                .frame(width: 240, height: 240)
                .blur(radius: 24)
                .offset(x: 170, y: 300)
        }
        .ignoresSafeArea()
    }
}

private struct DrivingModeSpeedDial: View {
    let snapshot: DriveSnapshot

    var body: some View {
        ZStack {
            Circle()
                .fill(DriveTheme.ink)
            Circle()
                .stroke(DriveTheme.skySoft.opacity(0.24), lineWidth: 7)
            Circle()
                .trim(from: 0, to: min(1, CGFloat(snapshot.speedKmh) / 140))
                .stroke(
                    snapshot.isOverSpeed ? DriveTheme.danger : DriveTheme.cyan,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: -3) {
                Text("\(snapshot.speedKmh)")
                    .font(.system(size: 31, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(snapshot.isOverSpeed ? DriveTheme.danger : .white)
                    .contentTransition(.numericText())
                Text("KM/H")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(width: 92, height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tốc độ \(snapshot.speedKmh) kilomet mỗi giờ")
    }
}

private struct DrivingModeAlertRow: View {
    let alert: DriveAlert

    private var tint: Color { DriveTheme.alertColor(alert.kind) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.13))
                if let assetName = alert.assetName, !assetName.isEmpty {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: alert.kind.iconName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "location.north.line.fill")
                    Text(distanceText)
                }
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(tint)
                Text(alert.message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.message), \(distanceText)")
    }

    private var distanceText: String {
        let meters = max(0, Int(alert.distanceMeters.rounded()))
        return meters >= 1_000
            ? String(format: "%.1f km", Double(meters) / 1_000)
            : "\(meters) m"
    }
}

private struct DrivingModeCarIllustration: View {
    let isMoving: Bool
    let reduceMotion: Bool
    @State private var travel = false

    var body: some View {
        GeometryReader { proxy in
            let carWidth = min(proxy.size.width * 0.82, 310)
            let carHeight = carWidth * 0.62

            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(DriveTheme.skyDeep.opacity(0.17 - Double(index) * 0.025))
                        .frame(width: carWidth * (0.17 - CGFloat(index) * 0.022), height: 4)
                        .offset(
                            x: -carWidth * (0.48 + CGFloat(index) * 0.07) + (travel ? -7 : 4),
                            y: -carHeight * 0.08 + CGFloat(index) * 17
                        )
                        .opacity(isMoving ? 1 : 0.35)
                }

                Ellipse()
                    .fill(DriveTheme.skyDeep.opacity(0.17))
                    .frame(width: carWidth * 0.76, height: 27)
                    .blur(radius: 8)
                    .offset(y: carHeight * 0.36)

                ZStack {
                    // Wheels sit behind the body.
                    HStack(spacing: carWidth * 0.49) {
                        DrivingModeWheel(size: carWidth * 0.18)
                        DrivingModeWheel(size: carWidth * 0.18)
                    }
                    .offset(y: carHeight * 0.29)

                    RoundedRectangle(cornerRadius: carHeight * 0.20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(red: 0.82, green: 0.88, blue: 0.95)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: carWidth, height: carHeight * 0.46)
                        .overlay(
                            RoundedRectangle(cornerRadius: carHeight * 0.20, style: .continuous)
                                .stroke(DriveTheme.skyDeep.opacity(0.25), lineWidth: 2)
                        )
                        .offset(y: carHeight * 0.12)

                    Path { path in
                        path.move(to: CGPoint(x: carWidth * 0.12, y: carHeight * 0.16))
                        path.addQuadCurve(
                            to: CGPoint(x: carWidth * 0.42, y: carHeight * 0.01),
                            control: CGPoint(x: carWidth * 0.26, y: carHeight * 0.01)
                        )
                        path.addLine(to: CGPoint(x: carWidth * 0.72, y: carHeight * 0.08))
                        path.addQuadCurve(
                            to: CGPoint(x: carWidth * 0.88, y: carHeight * 0.19),
                            control: CGPoint(x: carWidth * 0.82, y: carHeight * 0.10)
                        )
                        path.addLine(to: CGPoint(x: carWidth * 0.11, y: carHeight * 0.19))
                        path.closeSubpath()
                    }
                    .fill(Color.white)
                    .overlay(
                        Path { path in
                            path.move(to: CGPoint(x: carWidth * 0.12, y: carHeight * 0.16))
                            path.addQuadCurve(
                                to: CGPoint(x: carWidth * 0.42, y: carHeight * 0.01),
                                control: CGPoint(x: carWidth * 0.26, y: carHeight * 0.01)
                            )
                            path.addLine(to: CGPoint(x: carWidth * 0.72, y: carHeight * 0.08))
                            path.addQuadCurve(
                                to: CGPoint(x: carWidth * 0.88, y: carHeight * 0.19),
                                control: CGPoint(x: carWidth * 0.82, y: carHeight * 0.10)
                            )
                            path.addLine(to: CGPoint(x: carWidth * 0.11, y: carHeight * 0.19))
                            path.closeSubpath()
                        }
                        .stroke(DriveTheme.skyDeep.opacity(0.25), lineWidth: 2)
                    )

                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(DriveTheme.ink.opacity(0.90))
                            .frame(width: carWidth * 0.24, height: carHeight * 0.20)
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(DriveTheme.ink.opacity(0.90))
                            .frame(width: carWidth * 0.24, height: carHeight * 0.20)
                    }
                    .offset(x: -carWidth * 0.06, y: carHeight * 0.095)

                    Capsule()
                        .fill(DriveTheme.skyDeep.opacity(0.32))
                        .frame(width: carWidth * 0.62, height: 3)
                        .offset(x: -carWidth * 0.04, y: carHeight * 0.22)

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(red: 0.86, green: 0.91, blue: 0.97)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: carWidth * 0.28, height: carHeight * 0.29)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(DriveTheme.skyDeep.opacity(0.22), lineWidth: 1.2)
                        )
                        .offset(x: carWidth * 0.36, y: carHeight * 0.12)

                    HStack(spacing: carWidth * 0.28) {
                        Capsule()
                            .fill(Color.white.opacity(0.96))
                            .frame(width: carWidth * 0.12, height: carHeight * 0.06)
                            .shadow(color: .white, radius: 4)
                        Capsule()
                            .fill(Color.white.opacity(0.96))
                            .frame(width: carWidth * 0.12, height: carHeight * 0.06)
                            .shadow(color: .white, radius: 4)
                    }
                    .offset(x: carWidth * 0.35, y: carHeight * 0.045)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(DriveTheme.ink)
                        .frame(width: carWidth * 0.16, height: carHeight * 0.075)
                        .overlay(
                            Text("86A 26427")
                                .font(.system(size: max(6, carWidth * 0.027), weight: .black, design: .monospaced))
                                .minimumScaleFactor(0.7)
                                .foregroundStyle(.white)
                        )
                        .offset(x: carWidth * 0.37, y: carHeight * 0.22)

                    Circle()
                        .fill(Color.white.opacity(0.86))
                        .frame(width: carWidth * 0.075, height: carWidth * 0.075)
                        .overlay(Text("M").font(.system(size: carWidth * 0.032, weight: .black)).foregroundStyle(DriveTheme.ink))
                        .offset(x: carWidth * 0.29, y: carHeight * 0.13)

                    Text("CX-5")
                        .font(.system(size: max(7, carWidth * 0.027), weight: .black, design: .rounded))
                        .foregroundStyle(DriveTheme.ink.opacity(0.42))
                        .offset(x: -carWidth * 0.28, y: carHeight * 0.20)
                }
                .frame(width: carWidth, height: carHeight)
                .offset(x: travel ? 4 : -4, y: travel ? -3 : 3)
                .shadow(color: DriveTheme.skyDeep.opacity(0.18), radius: 14, y: 9)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard isMoving, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                travel = true
            }
        }
        .onChange(of: isMoving) { _, moving in
            guard moving, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                travel = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mazda CX-5 màu trắng, biển số 86A 26427, đang di chuyển")
    }
}

private struct DrivingModeWheel: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(DriveTheme.ink)
            Circle()
                .fill(Color(red: 0.30, green: 0.35, blue: 0.43))
                .padding(size * 0.20)
            Circle()
                .stroke(Color.white.opacity(0.28), lineWidth: 2)
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
    }
}
